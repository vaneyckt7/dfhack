/*
https://github.com/peterix/dfhack
Copyright (c) 2009-2012 Petr Mrázek (peterix@gmail.com)

This software is provided 'as-is', without any express or implied
warranty. In no event will the authors be held liable for any
damages arising from the use of this software.

Permission is granted to anyone to use this software for any
purpose, including commercial applications, and to alter it and
redistribute it freely, subject to the following restrictions:

1. The origin of this software must not be misrepresented; you must
not claim that you wrote the original software. If you use this
software in a product, an acknowledgment in the product documentation
would be appreciated but is not required.

2. Altered source versions must be plainly marked as such, and
must not be misrepresented as being the original software.

3. This notice may not be removed or altered from any source
distribution.
*/

#include "Internal.h"

#include <algorithm>
#include <cstring>
#include <string>
#include <vector>
#include <map>
#include <cinttypes>

#include "MemAccess.h"
#include "Core.h"
#include "VersionInfo.h"
// must be last due to MS stupidity
#include "DataDefs.h"
#include "DataIdentity.h"
#include "Debug.h"
#include "HashUtil.h"
#include "LuaWrapper.h"
#include "LuaTools.h"

#include "MiscUtils.h"

#include <lua.h>
#include <lauxlib.h>

using namespace DFHack;
using namespace DFHack::LuaWrapper;

namespace DFHack
{
    DBG_DECLARE(lua, deprecation, DebugCategory::LWARNING);
}

/**
 * Report an error while accessing a field (index = field name).
 */
[[noreturn]] void LuaWrapper::field_error(lua_State *state, int index, const char *err, const char *mode)
{
    if (lua_islightuserdata(state, UPVAL_METATABLE))
        lua_pushstring(state, "(global)");
    else
        lua_getfield(state, UPVAL_METATABLE, "__metatable");
    const char *cname = lua_tostring(state, -1);
    const char *fname = index ? lua_tostring(state, index) : "*";
    luaL_error(state, "Cannot %s field %s.%s: %s.",
               mode, (cname ? cname : "?"), (fname ? fname : "?"), err);
    std::abort(); // should never be reached but makes gcc happy
}

/* */

[[noreturn]] static int change_error(lua_State *state)
{
    luaL_error(state, "Attempt to change a read-only table.\n");
    std::abort(); // should never be reached but makes gcc happy
}

/**
 * Wrap a table so that it can't be modified.
 */
static void freeze_table(lua_State *state, bool leave_metatable = false, const char *name = NULL)
{
    // rv = {}; setmetatable(rv, { __index = in, __newindex = change_error, __metatable = name })
    int base = lua_gettop(state);
    lua_newtable(state);
    lua_swap(state);
    lua_setfield(state, base, "__index");
    lua_getfield(state, LUA_REGISTRYINDEX, DFHACK_CHANGEERROR_NAME);
    lua_setfield(state, base, "__newindex");
    lua_newtable(state);
    lua_swap(state);
    lua_dup(state);
    lua_setmetatable(state, base);
    if (name)
    {
        lua_pushstring(state, name);
        lua_setfield(state, -2, "__metatable");
    }
    // result: [frozen table] [metatable]
    if (!leave_metatable)
        lua_pop(state, 1);
}

static void LookupInTable(lua_State *state, LuaToken *tname)
{
    lua_rawgetp(state, LUA_REGISTRYINDEX, tname);
    lua_swap(state);
    lua_rawget(state, -2);
    lua_remove(state, -2);
}

/**
 * Look up the key on the stack in DFHACK_TYPETABLE;
 * if found, put result on the stack and return true.
 */
bool LuaWrapper::LookupTypeInfo(lua_State *state, bool in_method)
{
    // stack: [lookup key]

    if (in_method)
    {
        lua_rawget(state, UPVAL_TYPETABLE);
    }
    else
    {
        LookupInTable(state, &DFHACK_TYPETABLE_TOKEN);
    }

    // stack: [info]

    if (lua_isnil(state, -1))
    {
        lua_pop(state, 1);
        return false;
    }
    else
        return true;
}

void LuaWrapper::LookupInTable(lua_State *state, const void *id, LuaToken *tname)
{
    lua_rawgetp(state, LUA_REGISTRYINDEX, tname);
    lua_rawgetp(state, -1, id);
    lua_remove(state, -2);
}

void LuaWrapper::SaveInTable(lua_State *state, void *node, LuaToken *tname)
{
    // stack: [info]
    lua_rawgetp(state, LUA_REGISTRYINDEX, tname);

    lua_pushvalue(state, -2);
    lua_rawsetp(state, -2, node);

    lua_pushvalue(state, -2);
    lua_pushlightuserdata(state, node);
    lua_rawset(state, -3);

    lua_pop(state, 1);
    // stack: [info]
}

void LuaWrapper::SaveTypeInfo(lua_State *state, void *node)
{
    SaveInTable(state, node, &DFHACK_TYPETABLE_TOKEN);
}

static void BuildTypeMetatable(lua_State *state, const type_identity *type);

/**
 * Push the pointer as DF object ref using metatable on the stack.
 */
void LuaWrapper::push_object_ref(lua_State *state, void *ptr)
{
    // stack: [metatable]
    void* stg = lua_newuserdata(state, sizeof(DFRefHeader));
    new (stg) DFRefHeader
    {
        .ptr = ptr,
        .field_info = NULL,
        .tag_ptr = NULL,
        .tag_identity = NULL,
        .tag_attr = NULL,
    };

    lua_swap(state);
    lua_setmetatable(state, -2);
    // stack: [userdata]
}

DFRefHeader *LuaWrapper::get_object_ref_header(lua_State *state, int val_index)
{
    assert(!lua_islightuserdata(state, val_index));

    auto ref = (DFRefHeader*)lua_touserdata(state, val_index);
    return ref;
}

void *LuaWrapper::get_object_ref(lua_State *state, int val_index)
{
    return get_object_ref_header(state, val_index)->ptr;
}

/**
 * Push the pointer using given identity.
 */
void LuaWrapper::push_object_internal(lua_State *state, const type_identity *type, void *ptr, bool in_method)
{
    /*
     * If NULL pointer or no type, push something simple
     */

    if (!ptr || !type)
    {
        if (!ptr)
            lua_pushnil(state);
        else
            lua_pushlightuserdata(state, ptr);

        return;
    }

    /*
     * Resolve actual class using vtable
     */

    if (type->type() == IDTYPE_CLASS)
    {
        const virtual_identity *class_vid = virtual_identity::get(virtual_ptr(ptr));
        if (class_vid)
            type = class_vid;
    }

    /*
     * Resolve metatable by identity, and push the object
     */

    lua_pushlightuserdata(state, const_cast<type_identity*>(type)); // () -> type

    if (!LookupTypeInfo(state, in_method)) // type -> metatable?
        BuildTypeMetatable(state, type); // () -> metatable

    push_object_ref(state, ptr); // metatable -> userdata
}

static void fetch_container_details(lua_State *state, int meta, const type_identity **pitem, int *pcount)
{
    if (!meta) return;

    lua_getfield(state, meta, "_field_identity");
    *pitem = (type_identity*)lua_touserdata(state, -1);
    lua_pop(state, 1);

    if (pcount)
    {
        lua_getfield(state, meta, "_count");
        if (lua_isnumber(state, -1))
            *pcount = lua_tointeger(state, -1);
        lua_pop(state, 1);
    }
}

/**
 * Check if type1 and type2 are compatible, possibly using additional metatable data.
 */
bool LuaWrapper::is_type_compatible(lua_State *state, const type_identity *type1, int meta1,
    const type_identity *type2, int meta2, bool exact_equal)
{
    if (type1 == type2)
        return true;
    if (!exact_equal && !type1)
        return true;
    if (!type1 || !type2)
        return false;

    auto t1 = type1->type();
    if (t1 != type2->type())
        return false;

    switch (t1)
    {
    case IDTYPE_POINTER:
        return is_type_compatible(state,
                                  ((const pointer_identity_base*)type1)->getTarget(), 0,
                                  ((const pointer_identity_base*)type2)->getTarget(), 0,
                                  exact_equal);
        break;

    case IDTYPE_BUFFER:
    {
        auto b1 = (const df::buffer_container_identity*)type1;
        auto b2 = (const df::buffer_container_identity*)type2;
        const type_identity *item1 = b1->getItemType(), *item2 = b2->getItemType();
        int count1 = b1->getSize(), count2 = b2->getSize();

        fetch_container_details(state, meta1, &item1, &count1);
        fetch_container_details(state, meta2, &item2, &count2);

        return item1 && item2 && count1 == count2 &&
               is_type_compatible(state, item1, 0, item2, 0, true);
    }

    case IDTYPE_STL_PTR_VECTOR:
    {
        auto b1 = (const df::ptr_container_identity*)type1;
        auto b2 = (const df::ptr_container_identity*)type2;
        const type_identity *item1 = b1->getItemType(), *item2 = b2->getItemType();

        fetch_container_details(state, meta1, &item1, NULL);
        fetch_container_details(state, meta1, &item2, NULL);

        return is_type_compatible(state, item1, 0, item2, 0, exact_equal);
    }

    case IDTYPE_STRUCT:
    case IDTYPE_UNION:
    case IDTYPE_CLASS:
    {
        auto b1 = (struct_identity*)type1;
        auto b2 = (struct_identity*)type2;

        if (b1->is_equivalent(b2)) return true;

        return (!exact_equal && b1->is_subclass(b2));
    }

    default:
        return false;
    }
}

static bool is_type_compatible(lua_State *state, const type_identity *type1, int meta1,
                               int meta2, bool exact_equal)
{
    lua_rawgetp(state, meta2, &DFHACK_IDENTITY_FIELD_TOKEN);
    auto type2 = (type_identity*)lua_touserdata(state, -1);
    lua_pop(state, 1);

    return is_type_compatible(state, type1, meta1, type2, meta2, exact_equal);
}

static bool is_type_compatible(lua_State *state, int meta1, int meta2, bool exact_equal)
{
    if (lua_rawequal(state, meta1, meta2))
        return true;

    lua_rawgetp(state, meta1, &DFHACK_IDENTITY_FIELD_TOKEN);
    auto type1 = (type_identity*)lua_touserdata(state, -1);
    lua_pop(state, 1);

    return is_type_compatible(state, type1, meta1, meta2, exact_equal);
}

/**
 * Verify that the value matches the identity, and return ptr if so.
 */
void *LuaWrapper::get_object_internal(lua_State *state, const type_identity *type, int val_index, bool exact_type, bool in_method)
{
    /*
     * Non-userdata results in NULL; nil for NULL gets handled here too.
     */
    if (!lua_isuserdata(state, val_index))
        return NULL;

    /*
     * Light user data is allowed with null type; otherwise bail out.
     */
    if (!lua_getmetatable(state, val_index)) // () -> metatable?
    {
        if (!type && lua_islightuserdata(state, val_index))
            return lua_touserdata(state, val_index);

        return NULL;
    }

    /*
     * Verify that the metatable is known, and refers to the correct type.
     * Here doing reverse lookup of identity by metatable.
     */
    if (!LookupTypeInfo(state, in_method)) // metatable -> type?
        return NULL;

    type_identity* othertype = static_cast<type_identity*>(lua_touserdata(state, -1));

    if (type && othertype != type)
    {
        /*
         * If valid but different type, do an intelligent comparison.
         */
        lua_pop(state, 1); // type -> ()
        lua_getmetatable(state, val_index);

        if (!is_type_compatible(state, type, 0, lua_gettop(state), exact_type))
        {
            lua_pop(state, 1); // metatable -> ()
            return NULL;
        }
    }

    lua_pop(state, 1); // type -> ()

    /*
     * Finally decode the reference.
     */
    return get_object_ref(state, val_index);
}

/**
 * Check if the object and metatable are a valid DF reference or type.
 */
static bool is_valid_metatable(lua_State *state, int objidx, int metaidx)
{
    // Verify object type validity
    if (lua_isuserdata(state, objidx))
    {
        lua_pushvalue(state, metaidx);
        lua_rawget(state, UPVAL_TYPETABLE);
    }
    else
    {
        lua_pushvalue(state, objidx);
        LookupInTable(state, &DFHACK_TYPEID_TABLE_TOKEN);
    }

    bool ok = !lua_isnil(state, -1);
    lua_pop(state, 1);
    return ok;
}

bool Lua::IsDFNull(lua_State *state, int val_index)
{
    if (lua_isnil(state, val_index))
        return true;
    if (lua_islightuserdata(state, val_index))
        return lua_touserdata(state, val_index) == NULL;
    return false;
}

Lua::ObjectClass Lua::IsDFObject(lua_State *state, int val_index)
{
    if (lua_isnil(state, val_index))
        return Lua::OBJ_NULL;
    if (lua_islightuserdata(state, val_index))
        return lua_touserdata(state, val_index) ? Lua::OBJ_VOIDPTR : OBJ_NULL;

    Lua::ObjectClass cls;

    if (lua_istable(state, val_index))
    {
        cls = Lua::OBJ_TYPE;
        lua_pushvalue(state, val_index);
        LookupInTable(state, &DFHACK_TYPEID_TABLE_TOKEN);
    }
    else if (lua_isuserdata(state, val_index))
    {
        if (!lua_getmetatable(state, val_index))
            return Lua::OBJ_INVALID;
        cls = Lua::OBJ_REF;
        LookupInTable(state, &DFHACK_TYPETABLE_TOKEN);
    }
    else
        return Lua::OBJ_INVALID;

    bool ok = !lua_isnil(state, -1);
    lua_pop(state, 1);

    return ok ? cls : Lua::OBJ_INVALID;
}

static const char *const primitive_types[] = {
    "string",
    "ptr-string",
    "char",
    "int8_t", "uint8_t", "int16_t", "uint16_t",
    "int32_t", "uint32_t", "int64_t", "uint64_t",
    "intptr_t", "uintptr_t", "long", "unsigned long",
    "bool",
    "float", "double",
    "pointer",
    "ptr-vector",
    "bit-vector",
    "bit-array",
    NULL
};
static const type_identity *const primitive_identities[] = {
    df::identity_traits<std::string>::get(),
    df::identity_traits<const char*>::get(),
    df::identity_traits<char>::get(),
    df::identity_traits<int8_t>::get(), df::identity_traits<uint8_t>::get(),
    df::identity_traits<int16_t>::get(), df::identity_traits<uint16_t>::get(),
    df::identity_traits<int32_t>::get(), df::identity_traits<uint32_t>::get(),
    df::identity_traits<int64_t>::get(), df::identity_traits<uint64_t>::get(),
    df::identity_traits<intptr_t>::get(), df::identity_traits<uintptr_t>::get(),
    df::identity_traits<long>::get(), df::identity_traits<unsigned long>::get(),
    df::identity_traits<bool>::get(),
    df::identity_traits<float>::get(), df::identity_traits<double>::get(),
    df::identity_traits<void*>::get(),
    df::identity_traits<std::vector<void*> >::get(),
    df::identity_traits<std::vector<bool> >::get(),
    df::identity_traits<BitArray<int> >::get(),
    NULL
};

/**
 * Given a DF object reference or type, safely retrieve its identity pointer.
 */
const type_identity *LuaWrapper::get_object_identity(lua_State *state, int objidx,
                                               const char *ctx, bool allow_type,
                                               bool keep_metatable)
{
    if (allow_type && !keep_metatable && lua_isstring(state, objidx))
    {
        int idx = luaL_checkoption(state, objidx, NULL, primitive_types);
        return primitive_identities[idx];
    }

    if (!lua_getmetatable(state, objidx))
        luaL_error(state, "Invalid object in %s", ctx);

    if (!allow_type && !lua_isuserdata(state, objidx))
        luaL_error(state, "Object expected in %s", ctx);

    if (!is_valid_metatable(state, objidx, -1))
        luaL_error(state, "Invalid object metatable in %s", ctx);

    // Extract identity from metatable
    lua_rawgetp(state, -1, &DFHACK_IDENTITY_FIELD_TOKEN);

    type_identity *id = (type_identity*)lua_touserdata(state, -1);
    if (!id)
        luaL_error(state, "Invalid object identity in %s", ctx);

    lua_pop(state, keep_metatable ? 1 : 2);
    return id;
}

static bool check_type_compatible(lua_State *state, int obj1, int obj2,
                                  const type_identity **type1, const type_identity **type2,
                                  const char *ctx, bool allow_type, bool exact, bool error = true)
{
    int base = lua_gettop(state);

    *type1 = get_object_identity(state, obj1, ctx, allow_type, true);
    *type2 = get_object_identity(state, obj2, ctx, allow_type, true);

    if (!is_type_compatible(state, *type1, base+1, *type2, base+2, exact))
    {
        if (!error)
        {
            lua_pop(state, 2);
            return false;
        }

        lua_getfield(state, base+1, "__metatable");
        const char *cname1 = lua_tostring(state, -1);
        lua_getfield(state, base+2, "__metatable");
        const char *cname2 = lua_tostring(state, -1);

        luaL_error(state, "Types %s and %s incompatible in %s", cname1, cname2, ctx);
    }

    lua_pop(state, 2);
    return true;
}

/**
 * Metamethod: compare two DF object references.
 *
 * Equal if same pointer and same metatable.
 */
static int meta_ptr_compare(lua_State *state)
{
    if (!lua_isuserdata(state, 1) || !lua_isuserdata(state, 2) ||
        !lua_getmetatable(state, 1) || !lua_getmetatable(state, 2) ||
        get_object_ref(state, 1) != get_object_ref(state, 2) ||
        !is_type_compatible(state, 3, 4, true))
    {
        lua_pushboolean(state, false);
        return 1;
    }

    lua_pushboolean(state, true);
    return 1;
}

/**
 * Method: sizeof for DF object references.
 *
 * Returns: size[, address]
 */
static int meta_sizeof(lua_State *state)
{
    int argc = lua_gettop(state);

    if (argc != 1)
        luaL_error(state, "Usage: object:sizeof() or df.sizeof(object)");

    // Two special cases: nil and lightuserdata for NULL and void*
    if (lua_isnil(state, 1) || lua_islightuserdata(state, 1))
    {
        lua_pushnil(state);
        lua_pushinteger(state, (size_t)lua_touserdata(state, 1));
        return 2;
    }

    const type_identity *id = get_object_identity(state, 1, "df.sizeof()", true, true);

    // Static arrays need special handling
    if (id->type() == IDTYPE_BUFFER)
    {
        auto buf = (const df::buffer_container_identity*)id;
        const type_identity *item = buf->getItemType();
        int count = buf->getSize();

        fetch_container_details(state, lua_gettop(state), &item, &count);

        lua_pushinteger(state, item->byte_size() * count);
    }
    else
        lua_pushinteger(state, id->byte_size());

    // Add the address
    if (lua_isuserdata(state, 1))
    {
        lua_pushinteger(state, (size_t)get_object_ref(state, 1));
        return 2;
    }
    else
        return 1;
}

/**
 * Method: displace for DF object references.
 *
 * Returns: a reference with the same type, but modified address
 */
static int meta_displace(lua_State *state)
{
    int argc = lua_gettop(state);

    bool has_step = (argc >= 3);
    if ((argc < 2 || argc > 3) ||
        !lua_isnumber(state, 2) ||
        (has_step && !lua_isnumber(state, 3)))
    {
        luaL_error(state, "Usage: object:_displace(index[,step]) or df._displace(object,...)");
    }

    int index = lua_tointeger(state, 2);
    int step = has_step ? lua_tointeger(state, 3) : 1;

    // Two special cases: nil and lightuserdata for NULL and void*
    if (lua_isnil(state, 1))
    {
        lua_pushnil(state);
        return 1;
    }

    if (lua_islightuserdata(state, 1))
    {
        if (!has_step)
            luaL_error(state, "Step is mandatory in _displace of void*");

        auto ptr = (uint8_t*)lua_touserdata(state, 1);
        lua_pushlightuserdata(state, ptr + index*step);
        return 1;
    }

    const type_identity *id = get_object_identity(state, 1, "df._displace()");

    if (!has_step)
        step = id->byte_size();

    if (index == 0 || step == 0)
    {
        lua_pushvalue(state, 1);
    }
    else
    {
        auto ptr = (uint8_t*)get_object_ref(state, 1);
        lua_getmetatable(state, 1);
        push_object_ref(state, ptr + index*step);
    }

    return 1;
}

/**
 * Method: allocation for DF object references.
 */
static int meta_new(lua_State *state)
{
    int argc = lua_gettop(state);

    if (argc != 1 && argc != 2)
        luaL_error(state, "Usage: object:new() or df.new(object) or df.new(ptype,count)");

    const type_identity *id = get_object_identity(state, 1, "df.new()", true);

    void *ptr = nullptr;
    std::string err_context;

    // Support arrays of primitive types
    if (argc == 2)
    {
        int cnt = luaL_checkint(state, 2);
        if (cnt <= 0)
            luaL_error(state, "Invalid array size in df.new()");
        if (id->type() != IDTYPE_PRIMITIVE)
            luaL_error(state, "Cannot allocate arrays of non-primitive types.");

        size_t sz = id->byte_size() * cnt;
        ptr = malloc(sz);
        if (ptr)
            memset(ptr, 0, sz);
    }
    else
    {
        try {
            ptr = id->allocate();
        }
        catch (std::exception &e) {
            if (e.what()) {
                err_context = e.what();
            }
        }
    }

    if (!ptr)
        luaL_error(state, "Cannot allocate %s%s%s",
            id->getFullName().c_str(),
            err_context.empty() ? "" : ": ",
            err_context.c_str()
        );

    if (lua_isuserdata(state, 1))
    {
        lua_getmetatable(state, 1);
        push_object_ref(state, ptr);

        id->copy(ptr, get_object_ref(state, 1));
    }
    else
        push_object_internal(state, id, ptr);

    return 1;
}

/*
 * df.readFields: read chosen fields from every entry of a container in one call.
 */
namespace {

struct ReadSource {
    std::string name;
    const container_identity *container = nullptr;
    const type_identity *item = nullptr;    // what the container holds
    const type_identity *leaf = nullptr;    // one entry, after flattening nested fixed-size arrays
    uint8_t *ptr = nullptr;
    size_t leaf_size = 0;
    int outer = 0;                          // items in the container itself
    int inner = 1;                          // entries per item
    bool dynamic = false;                   // the item count can change
    bool pointers = false;                  // the container holds pointers to its entries
};

struct ReadAttr {
    const enum_identity *owner;
    const struct_field_info *field;
};

struct ReadAccessor {
    enum Kind { INDEX, VALUE, BIT, WHOLE };
    Kind kind = VALUE;
    size_t source = 0;
    // offsets[0] is added to the entry's address; every further one follows a pointer first
    std::vector<size_t> offsets;
    const type_identity *type = nullptr;
    unsigned bit = 0;
    int bit_size = 1;
    size_t whole_size = 0;
    std::vector<ReadAttr> attrs;
};

struct ReadCond {
    enum Kind { CMP, IN, AND, OR, NOT };
    Kind kind = AND;
    size_t accessor = 0;
    int op = LUA_OPEQ;
    bool swap = false;
    bool negate = false;
    int value = 0;                          // ordinal while parsing, stack index while reading
    std::vector<size_t> kids;
};

struct ReadPlan {
    std::vector<ReadSource> sources;
    bool named = false;
    std::vector<ReadAccessor> accessors;
    std::vector<ReadCond> conds;
    int values_idx = 0;
    int value_count = 0;
};

bool read_is_struct(const type_identity *type)
{
    switch (type->type())
    {
    case IDTYPE_STRUCT:
    case IDTYPE_CLASS:
    case IDTYPE_UNION:
        return true;
    default:
        return false;
    }
}

bool read_is_value(const type_identity *type)
{
    return type->type() == IDTYPE_PRIMITIVE || type->type() == IDTYPE_ENUM;
}

const struct_field_info *read_find_field(const struct_identity *type, const std::string &name)
{
    for (auto cur = type; cur; cur = cur->getParent())
    {
        auto field = cur->getFields();
        if (!field)
            continue;
        for (; field->mode != struct_field_info::END; field++)
            if (field->name && name == field->name)
                return field;
    }
    return nullptr;
}

void read_add_source(lua_State *state, ReadPlan &plan, int idx, const std::string &name)
{
    if (lua_type(state, idx) != LUA_TUSERDATA)
        luaL_error(state, "df.readFields: expected a container, or a table of named containers");

    auto id = get_object_identity(state, idx, "df.readFields()", false, true);
    // stack: [metatable]
    if (!id->isContainer() || id->type() == IDTYPE_BIT_CONTAINER)
        luaL_error(state, "df.readFields: %s is not a container it can read", id->getFullName().c_str());

    ReadSource src;
    src.name = name;
    src.container = (const container_identity*)id;
    lua_getfield(state, -1, "_field_identity");
    src.item = (const type_identity*)lua_touserdata(state, -1);
    lua_getfield(state, -2, "_count");
    int fixed = lua_isnil(state, -1) ? -1 : int(lua_tointeger(state, -1));
    lua_pop(state, 3);
    if (!src.item)
        luaL_error(state, "df.readFields: the container's item type is not known");

    src.ptr = (uint8_t*)get_object_ref(state, idx);
    src.pointers = id->type() == IDTYPE_PTR_CONTAINER || id->type() == IDTYPE_STL_PTR_VECTOR;
    src.dynamic = fixed < 0;
    src.outer = src.dynamic ? src.container->raw_item_count(src.ptr) : fixed;
    src.leaf = src.item;
    if (!src.pointers)
    {
        while (src.leaf->type() == IDTYPE_BUFFER)
        {
            auto buffer = (const df::buffer_container_identity*)src.leaf;
            if (!buffer->getItemType() || buffer->getSize() <= 0)
                luaL_error(state, "df.readFields: cannot read a nested array of unknown shape");
            src.inner *= buffer->getSize();
            src.leaf = buffer->getItemType();
        }
    }
    src.leaf_size = src.leaf->byte_size();
    plan.sources.push_back(src);
}

size_t read_compile(lua_State *state, ReadPlan &plan, const std::string &path)
{
    ReadAccessor acc;
    if (path == "_index")
    {
        acc.kind = ReadAccessor::INDEX;
        plan.accessors.push_back(acc);
        return plan.accessors.size() - 1;
    }

    std::vector<std::string> parts;
    split_string(&parts, path, ".");
    if (parts.empty() || parts[0].empty())
        luaL_error(state, "df.readFields: empty field name");

    size_t at = 0;
    if (plan.named)
    {
        bool found = false;
        for (size_t i = 0; i < plan.sources.size(); i++)
        {
            if (plan.sources[i].name == parts[0])
            {
                acc.source = i;
                found = true;
                break;
            }
        }
        if (!found)
            luaL_error(state, "df.readFields: '%s' does not start with the name of a container", path.c_str());
        at = 1;
    }
    else if (parts[0] == "_value")
        at = 1;

    acc.offsets.push_back(0);
    const type_identity *cur = plan.sources[acc.source].leaf;
    const enum_identity *owner = nullptr;
    bool done = false;
    if (read_is_value(cur))
    {
        acc.type = cur;
        done = true;
        owner = cur->type() == IDTYPE_ENUM ? (const enum_identity*)cur : nullptr;
    }

    for (; at < parts.size(); at++)
    {
        const std::string &part = parts[at];
        if (done)
        {
            // a step past a value looks the value up in its enum's attributes
            if (!owner || !owner->getAttrs() || !owner->getAttrType())
                luaL_error(state, "df.readFields: '%s' in '%s' follows a value that has no attributes",
                           part.c_str(), path.c_str());
            auto field = read_find_field(owner->getAttrType(), part);
            if (!field || field->mode != struct_field_info::PRIMITIVE || !field->type || !read_is_value(field->type))
                luaL_error(state, "df.readFields: no readable attribute '%s' in '%s'", part.c_str(), path.c_str());
            acc.attrs.push_back(ReadAttr{owner, field});
            owner = field->type->type() == IDTYPE_ENUM ? (const enum_identity*)field->type : nullptr;
            continue;
        }

        if (read_is_struct(cur))
        {
            auto field = read_find_field((const struct_identity*)cur, part);
            if (!field)
                luaL_error(state, "df.readFields: no field '%s' in '%s'", part.c_str(), path.c_str());
            switch (field->mode)
            {
            case struct_field_info::PRIMITIVE:
            case struct_field_info::SUBSTRUCT:
                if (!field->type)
                    luaL_error(state, "df.readFields: cannot read '%s' in '%s'", part.c_str(), path.c_str());
                acc.offsets.back() += field->offset;
                cur = field->type;
                break;
            case struct_field_info::POINTER:
                if (!field->type || (field->count & PTRFLAG_IS_ARRAY))
                    luaL_error(state, "df.readFields: cannot follow the pointer '%s' in '%s'", part.c_str(), path.c_str());
                acc.offsets.back() += field->offset;
                acc.offsets.push_back(0);
                cur = field->type;
                break;
            default:
                luaL_error(state, "df.readFields: '%s' in '%s' is not a single value or a structure",
                           part.c_str(), path.c_str());
            }
            if (read_is_value(cur))
            {
                acc.type = cur;
                done = true;
                owner = cur->type() == IDTYPE_ENUM ? (const enum_identity*)cur : nullptr;
            }
        }
        else if (cur->type() == IDTYPE_BITFIELD)
        {
            auto bits = (const bitfield_identity*)cur;
            if (part == "whole")
            {
                acc.kind = ReadAccessor::WHOLE;
                acc.whole_size = bits->byte_size();
            }
            else
            {
                unsigned bit = 0;
                if (!findBitfieldField(&bit, part, bits->getNumBits(), bits->getBits()))
                    luaL_error(state, "df.readFields: no flag '%s' in '%s'", part.c_str(), path.c_str());
                acc.kind = ReadAccessor::BIT;
                acc.bit = bit;
                acc.bit_size = std::max(1, bits->getBits()[bit].size);
            }
            done = true;
            owner = nullptr;
        }
        else
            luaL_error(state, "df.readFields: '%s' in '%s' follows something that has no fields",
                       part.c_str(), path.c_str());
    }

    if (!done)
    {
        if (cur->type() != IDTYPE_BITFIELD)
            luaL_error(state, "df.readFields: '%s' is not a single value; name one of its fields", path.c_str());
        acc.kind = ReadAccessor::WHOLE;
        acc.whole_size = cur->byte_size();
    }

    plan.accessors.push_back(acc);
    return plan.accessors.size() - 1;
}

// Pushes exactly one value. Returns false, having pushed nil, when the value could not be reached.
bool read_push(lua_State *state, const ReadAccessor &acc, const std::vector<uint8_t*> &bases, lua_Integer index)
{
    if (acc.kind == ReadAccessor::INDEX)
    {
        lua_pushinteger(state, index);
        return true;
    }

    uint8_t *ptr = bases[acc.source] + acc.offsets[0];
    for (size_t i = 1; i < acc.offsets.size(); i++)
    {
        ptr = *(uint8_t**)ptr;
        if (!ptr)
        {
            lua_pushnil(state);
            return false;
        }
        ptr += acc.offsets[i];
    }

    switch (acc.kind)
    {
    case ReadAccessor::BIT:
    {
        int value = getBitfieldField(ptr, acc.bit, unsigned(acc.bit_size));
        if (acc.bit_size <= 1)
            lua_pushboolean(state, value != 0);
        else
            lua_pushinteger(state, value);
        break;
    }
    case ReadAccessor::WHOLE:
    {
        size_t value = 0;
        memcpy(&value, ptr, std::min(sizeof(value), acc.whole_size));
        lua_pushinteger(state, lua_Integer(value));
        break;
    }
    default:
        acc.type->lua_read(state, 0, ptr);
    }

    for (const ReadAttr &attr : acc.attrs)
    {
        if (!lua_isinteger(state, -1))
        {
            lua_pop(state, 1);
            lua_pushnil(state);
            return false;
        }
        int64_t idx = lua_tointeger(state, -1);
        lua_pop(state, 1);

        // out-of-range values read the default entry, as enum.attrs[] does
        if (auto complex = attr.owner->getComplex())
        {
            auto it = complex->value_index_map.find(idx);
            if (it != complex->value_index_map.end())
                idx = int64_t(it->second);
            else
                idx = attr.owner->getLastItem() + 1;
        }
        else
        {
            if (idx < attr.owner->getFirstItem() || idx > attr.owner->getLastItem())
                idx = attr.owner->getLastItem() + 1;
            idx -= attr.owner->getFirstItem();
        }

        auto row = (uint8_t*)attr.owner->getAttrs() + attr.owner->getAttrType()->byte_size() * size_t(idx);
        attr.field->type->lua_read(state, 0, row + attr.field->offset);
    }
    return true;
}

size_t read_parse_cond(lua_State *state, ReadPlan &plan, int idx, int depth)
{
    if (depth > 32)
        luaL_error(state, "df.readFields: conditions are nested too deeply");
    luaL_checkstack(state, 10, "df.readFields: conditions are nested too deeply");
    if (!lua_istable(state, idx))
        luaL_error(state, "df.readFields: each condition must be a table");

    ReadCond cond;
    lua_rawgeti(state, idx, 1);
    lua_rawgeti(state, idx, 2);
    // stack: [head, second]
    if (lua_type(state, -2) != LUA_TSTRING)
        luaL_error(state, "df.readFields: a condition must start with a field name, 'and', 'or' or 'not'");
    std::string head = lua_tostring(state, -2);

    if (lua_istable(state, -1) && (head == "and" || head == "or" || head == "not"))
    {
        cond.kind = head == "and" ? ReadCond::AND : head == "or" ? ReadCond::OR : ReadCond::NOT;
        int count = int(lua_rawlen(state, idx));
        if (cond.kind == ReadCond::NOT && count != 2)
            luaL_error(state, "df.readFields: 'not' takes exactly one condition");
        for (int i = 2; i <= count; i++)
        {
            lua_rawgeti(state, idx, i);
            cond.kids.push_back(read_parse_cond(state, plan, lua_gettop(state), depth + 1));
            lua_pop(state, 1);
        }
        lua_pop(state, 2);
    }
    else
    {
        if (lua_type(state, -1) != LUA_TSTRING)
            luaL_error(state, "df.readFields: the condition on '%s' has no comparison", head.c_str());
        std::string op = lua_tostring(state, -1);
        lua_pop(state, 2);

        cond.kind = ReadCond::CMP;
        bool ordered = true;
        if (op == "==")
            ordered = false;
        else if (op == "~=")
        {
            ordered = false;
            cond.negate = true;
        }
        else if (op == "<")
            cond.op = LUA_OPLT;
        else if (op == "<=")
            cond.op = LUA_OPLE;
        else if (op == ">")
        {
            cond.op = LUA_OPLT;
            cond.swap = true;
        }
        else if (op == ">=")
        {
            cond.op = LUA_OPLE;
            cond.swap = true;
        }
        else if (op == "in")
        {
            ordered = false;
            cond.kind = ReadCond::IN;
        }
        else
            luaL_error(state, "df.readFields: unknown comparison '%s' on '%s'", op.c_str(), head.c_str());

        cond.accessor = read_compile(state, plan, head);

        lua_rawgeti(state, idx, 3);
        if (cond.kind == ReadCond::IN)
        {
            if (!lua_istable(state, -1))
                luaL_error(state, "df.readFields: 'in' on '%s' needs a list of values", head.c_str());
            int count = int(lua_rawlen(state, -1));
            lua_createtable(state, 0, count);
            for (int i = 1; i <= count; i++)
            {
                lua_rawgeti(state, -2, i);
                lua_pushboolean(state, true);
                lua_rawset(state, -3);
            }
            lua_remove(state, -2);
        }
        else if (ordered ? !(lua_type(state, -1) == LUA_TNUMBER || lua_type(state, -1) == LUA_TSTRING)
                         : lua_isnil(state, -1))
            luaL_error(state, "df.readFields: the condition on '%s' has no usable value", head.c_str());
        cond.value = ++plan.value_count;
        lua_rawseti(state, plan.values_idx, cond.value);
    }

    plan.conds.push_back(cond);
    return plan.conds.size() - 1;
}

bool read_test(lua_State *state, const ReadPlan &plan, size_t node, const std::vector<uint8_t*> &bases, lua_Integer index)
{
    const ReadCond &cond = plan.conds[node];
    switch (cond.kind)
    {
    case ReadCond::AND:
        for (size_t kid : cond.kids)
            if (!read_test(state, plan, kid, bases, index))
                return false;
        return true;
    case ReadCond::OR:
        for (size_t kid : cond.kids)
            if (read_test(state, plan, kid, bases, index))
                return true;
        return false;
    case ReadCond::NOT:
        return !read_test(state, plan, cond.kids[0], bases, index);
    case ReadCond::IN:
    {
        bool found = false;
        if (read_push(state, plan.accessors[cond.accessor], bases, index) && !lua_isnil(state, -1))
        {
            lua_rawget(state, cond.value);
            found = !lua_isnil(state, -1);
        }
        lua_pop(state, 1);
        return found;
    }
    default:
    {
        bool result = false;
        if (read_push(state, plan.accessors[cond.accessor], bases, index))
        {
            if (cond.op == LUA_OPEQ)
                result = (lua_rawequal(state, -1, cond.value) != 0) != cond.negate;
            else if (lua_type(state, -1) == lua_type(state, cond.value))
                result = (cond.swap ? lua_compare(state, cond.value, -1, cond.op)
                                    : lua_compare(state, -1, cond.value, cond.op)) != 0;
        }
        lua_pop(state, 1);
        return result;
    }
    }
}

}

static int meta_read_fields(lua_State *state)
{
    int argc = lua_gettop(state);
    if (argc < 1 || argc > 3)
        luaL_error(state, "Usage: df.readFields(container[, options[, out]])");
    lua_settop(state, 3);
    if (!lua_isnil(state, 2) && !lua_istable(state, 2))
        luaL_error(state, "df.readFields: options must be a table");
    if (lua_isnil(state, 3))
    {
        lua_newtable(state);
        lua_replace(state, 3);
    }
    else if (!lua_istable(state, 3))
        luaL_error(state, "df.readFields: out must be a table");
    luaL_checkstack(state, 20, "df.readFields");

    ReadPlan plan;
    if (lua_istable(state, 1))
    {
        plan.named = true;
        lua_pushnil(state);
        while (lua_next(state, 1))
        {
            if (lua_type(state, -2) != LUA_TSTRING)
                luaL_error(state, "df.readFields: containers in a table must have string names");
            std::string name = lua_tostring(state, -2);
            if (name.empty() || name == "_index" || name.find('.') != std::string::npos)
                luaL_error(state, "df.readFields: '%s' cannot be used as a container name", name.c_str());
            read_add_source(state, plan, lua_gettop(state), name);
            lua_pop(state, 1);
        }
        if (plan.sources.empty())
            luaL_error(state, "df.readFields: no containers given");
    }
    else
        read_add_source(state, plan, 1, "");

    lua_Integer total = lua_Integer(plan.sources[0].outer) * plan.sources[0].inner;
    for (const ReadSource &src : plan.sources)
        if (lua_Integer(src.outer) * src.inner != total)
            luaL_error(state, "df.readFields: the containers do not have the same number of entries");

    lua_newtable(state);
    plan.values_idx = 4;
    lua_pushnil(state);
    const int test_idx = 5;
    bool has_where = false, has_test = false;
    size_t root = 0;
    std::vector<std::string> names;

    if (lua_istable(state, 2))
    {
        lua_getfield(state, 2, "test");
        if (!lua_isnil(state, -1))
        {
            if (!lua_isfunction(state, -1))
                luaL_error(state, "df.readFields: test must be a function");
            has_test = true;
        }
        lua_replace(state, test_idx);

        lua_getfield(state, 2, "where");
        if (!lua_isnil(state, -1))
        {
            if (!lua_istable(state, -1))
                luaL_error(state, "df.readFields: where must be a table");
            int where_idx = lua_gettop(state);
            ReadCond all;
            int count = int(lua_rawlen(state, where_idx));
            for (int i = 1; i <= count; i++)
            {
                lua_rawgeti(state, where_idx, i);
                all.kids.push_back(read_parse_cond(state, plan, lua_gettop(state), 0));
                lua_pop(state, 1);
            }
            plan.conds.push_back(all);
            root = plan.conds.size() - 1;
            has_where = true;
        }
        lua_pop(state, 1);

        lua_getfield(state, 2, "fields");
        if (!lua_isnil(state, -1))
        {
            if (!lua_istable(state, -1))
                luaL_error(state, "df.readFields: fields must be a table");
            int count = int(lua_rawlen(state, -1));
            for (int i = 1; i <= count; i++)
            {
                lua_rawgeti(state, -1, i);
                if (lua_type(state, -1) != LUA_TSTRING)
                    luaL_error(state, "df.readFields: field names must be strings");
                std::string name = lua_tostring(state, -1);
                lua_pop(state, 1);
                if (std::find(names.begin(), names.end(), name) == names.end())
                    names.push_back(name);
            }
        }
        lua_pop(state, 1);
    }

    luaL_checkstack(state, plan.value_count + int(names.size()) + 20, "df.readFields: too many fields or conditions");

    // the values that conditions compare against, each at a fixed stack index
    int value_base = lua_gettop(state);
    for (int i = 1; i <= plan.value_count; i++)
        lua_rawgeti(state, plan.values_idx, i);
    for (ReadCond &cond : plan.conds)
        if (cond.kind == ReadCond::CMP || cond.kind == ReadCond::IN)
            cond.value += value_base;

    // one array per field, each at a fixed stack index
    std::vector<size_t> columns;
    int column_base = lua_gettop(state);
    for (const std::string &name : names)
    {
        columns.push_back(read_compile(state, plan, name));
        lua_getfield(state, 3, name.c_str());
        if (!lua_istable(state, -1))
        {
            lua_pop(state, 1);
            lua_newtable(state);
            lua_pushvalue(state, -1);
            lua_setfield(state, 3, name.c_str());
        }
    }

    std::vector<uint8_t*> bases(plan.sources.size());
    lua_Integer found = 0;
    for (lua_Integer index = 0; index < total; index++)
    {
        bool present = true;
        for (size_t i = 0; i < plan.sources.size(); i++)
        {
            const ReadSource &src = plan.sources[i];
            int outer = int(index / src.inner);
            uint8_t *entry;
            if (src.pointers)
                entry = *(uint8_t**)src.container->raw_item_pointer(&df::identity_traits<void*>::identity, src.ptr, outer);
            else
            {
                entry = (uint8_t*)src.container->raw_item_pointer(src.item, src.ptr, outer);
                if (entry)
                    entry += size_t(index % src.inner) * src.leaf_size;
            }
            if (!entry)
                present = false;
            bases[i] = entry;
        }
        if (!present)
            continue;

        if (has_where && !read_test(state, plan, root, bases, index))
            continue;

        if (has_test)
        {
            lua_pushvalue(state, test_idx);
            lua_pushinteger(state, index);
            lua_call(state, 1, 1);
            bool keep = lua_toboolean(state, -1) != 0;
            lua_pop(state, 1);
            for (const ReadSource &src : plan.sources)
                if (src.dynamic && src.container->raw_item_count(src.ptr) != src.outer)
                    luaL_error(state, "df.readFields: a container changed size during the read");
            if (!keep)
                continue;
        }

        found++;
        for (size_t i = 0; i < columns.size(); i++)
        {
            read_push(state, plan.accessors[columns[i]], bases, index);
            lua_rawseti(state, column_base + 1 + int(i), found);
        }
    }

    lua_pushvalue(state, 3);
    lua_pushinteger(state, found);
    return 2;
}

/**
 * Method: type casting of pointers.
 */
static int meta_reinterpret_cast(lua_State *state)
{
    int argc = lua_gettop(state);

    if (argc != 2)
        luaL_error(state, "Usage: df.reinterpret_cast(type,ptr)");

    const type_identity *id = get_object_identity(state, 1, "df.reinterpret_cast()", true);

    // Find the raw pointer value
    void *ptr;

    if (lua_isnil(state, 2))
        ptr = NULL;
    else if (lua_isnumber(state, 2))
        ptr = (void*)lua_tounsigned(state, 2);
    else
    {
        ptr = get_object_internal(state, NULL, 2, false, true);
        if (!ptr)
            luaL_error(state, "Invalid pointer argument in df.reinterpret_cast.\n");
    }

    // Convert it to the appropriate representation
    if (ptr == NULL)
    {
        lua_pushnil(state);
    }
    else if (lua_isuserdata(state, 1))
    {
        lua_getmetatable(state, 1);
        push_object_ref(state, ptr);
    }
    else
        push_object_internal(state, id, ptr);

    return 1;
}

static void invoke_resize(lua_State *state, int table, lua_Integer size)
{
    lua_getfield(state, table, "resize");
    lua_pushvalue(state, table);
    lua_pushinteger(state, size);
    lua_call(state, 2, 0);
}

static void copy_table(lua_State *state, int dest, int src, int skipbase)
{
    // stack: (skipbase) skipkey skipkey |

    int top = lua_gettop(state);

    lua_pushnil(state);

    while (lua_next(state, src))
    {
        for (int i = skipbase+1; i <= top; i++)
        {
            if (lua_rawequal(state, -2, i))
            {
                lua_pop(state, 1);
                goto next_outer;
            }
        }

        {
            lua_pushvalue(state, -2);
            lua_swap(state);
            lua_settable(state, dest);
        }

    next_outer:;
    }
}

/**
 * Method: assign data between objects.
 */
static int meta_assign(lua_State *state)
{
    int argc = lua_gettop(state);

    if (argc != 2)
        luaL_error(state, "Usage: target:assign(src) or df.assign(target,src)");

    if (!lua_istable(state, 2))
    {
        const type_identity *id1, *id2;
        check_type_compatible(state, 1, 2, &id1, &id2, "df.assign()", false, false);

        if (!id1->copy(get_object_ref(state, 1), get_object_ref(state, 2)))
            luaL_error(state, "No copy support for %s", id1->getFullName().c_str());
    }
    else
    {
        const type_identity *id = get_object_identity(state, 1, "df.assign()", false);

        if (lua_getmetatable(state, 2))
            luaL_error(state, "cannot use lua tables with metatable in df.assign()");

        int base = lua_gettop(state);

        // x:assign{ assign = foo } => x:assign(foo)
        bool has_assign = false;

        lua_pushstring(state, "assign");
        lua_dup(state);
        lua_rawget(state, 2);

        if (!lua_isnil(state,-1))
        {
            has_assign = true;
            lua_getfield(state, LUA_REGISTRYINDEX, DFHACK_ASSIGN_NAME);
            lua_pushvalue(state, 1);
            lua_pushvalue(state, base+2);
            lua_call(state, 2, 0);
        }

        lua_pop(state, 1);

        // new is used by autovivification and should be skipped
        lua_pushstring(state, "new");

        if (id->isContainer())
        {
            // check resize field
            lua_pushstring(state, "resize");
            lua_dup(state);
            lua_rawget(state, 2);

            if (lua_isnil(state,-1) && !has_assign)
            {
                /*
                 * no assign && nil or missing resize field => 1-based lua array
                 */
                int size = lua_rawlen(state, 2);

                lua_pop(state, 1);
                invoke_resize(state, 1, size);

                for (int i = 1; i <= size; i++)
                {
                    lua_pushinteger(state, i-1);
                    lua_rawgeti(state, 2, i);
                    lua_settable(state, 1);
                }
            }
            else
            {
                if (lua_isboolean(state, -1) || lua_isnil(state, -1))
                {
                    // resize=false => just assign
                    // resize=true => find the largest index
                    if (lua_toboolean(state, -1))
                    {
                        lua_Integer size = 0;

                        lua_pushnil(state);
                        while (lua_next(state, 2))
                        {
                            lua_pop(state, 1);
                            if (lua_isnumber(state,-1))
                                size = std::max(size, lua_tointeger(state,-1)+1);
                        }

                        invoke_resize(state, 1, size);
                    }
                }
                else
                {
                    // otherwise, must be an explicit number
                    if (!lua_isnumber(state,-1))
                        luaL_error(state, "Invalid container.resize value in df.assign()");

                    invoke_resize(state, 1, lua_tointeger(state, -1));
                }

                lua_pop(state, 1);
                copy_table(state, 1, 2, base);
            }
        }
        else
        {

            copy_table(state, 1, 2, base);
        }
    }

    return 0;
}

/**
 * Method: check if the two objects are assignment-compatible.
 */
static int meta_is_instance(lua_State *state)
{
    int argc = lua_gettop(state);

    if (argc != 2)
        luaL_error(state, "Usage: type:is_instance(obj) or df.is_instance(type,obj)");

    // If garbage as second argument, return nil
    if (!lua_istable(state, 2) && (!lua_isuserdata(state,2) || lua_islightuserdata(state, 2)))
    {
        lua_pushnil(state);
        return 1;
    }

    const type_identity *id1, *id2;
    bool ok = check_type_compatible(state, 1, 2, &id1, &id2, "df.is_instance()", true, false, false);

    lua_pushboolean(state, ok);
    return 1;
}

/**
 * Method: deallocation for DF object references.
 */
static int meta_delete(lua_State *state)
{
    int argc = lua_gettop(state);

    if (argc != 1)
        luaL_error(state, "Usage: object:delete() or df.delete(object)");

    if (lua_isnil(state, 1))
    {
        lua_pushboolean(state, true);
        return 1;
    }

    const type_identity *id = get_object_identity(state, 1, "df.delete()", false);

    bool ok = id->destroy(get_object_ref(state, 1));

    lua_pushboolean(state, ok);
    return 1;
}

/**
 * Verify that the object is a DF ref with UPVAL_METATABLE.
 * If everything ok, extract the address.
 */
uint8_t *LuaWrapper::get_object_addr(lua_State *state, int obj, int field, const char *mode)
{
    if (!lua_isuserdata(state, obj) ||
        !lua_getmetatable(state, obj))
        field_error(state, field, "invalid object", mode);

    if (!lua_rawequal(state, -1, UPVAL_METATABLE))
        field_error(state, field, "invalid object metatable", mode);

    lua_pop(state, 1);

    return (uint8_t*)get_object_ref(state, obj);
}

/**
 * Metamethod: represent a type node as string.
 */
static int meta_type_tostring(lua_State *state)
{
    if (!lua_getmetatable(state, 1))
        return 0;

    lua_getfield(state, -1, "__metatable");
    const char *cname = lua_tostring(state, -1);

    auto str = fmt::format("<type: {}>", cname);
    lua_pushlstring(state, str.data(), str.size());
    return 1;
}

/**
 * Metamethod: represent a DF object reference as string.
 */
static int meta_ptr_tostring(lua_State *state)
{
    uint8_t *ptr = get_object_addr(state, 1, 0, "access");

    bool has_length = false;
    uint64_t length = 0;
    auto *cid = dynamic_cast<const df::container_identity*>(get_object_identity(state, 1, "__tostring()", true, true));

    if (cid && (cid->type() == IDTYPE_CONTAINER || cid->type() == IDTYPE_STL_PTR_VECTOR))
    {
        has_length = true;
        length = cid->lua_item_count(state, ptr, container_identity::COUNT_LEN);
    }

    lua_getfield(state, UPVAL_METATABLE, "__metatable");
    const char *cname = lua_tostring(state, -1);

    auto str = has_length ?
        fmt::format("<{}[{}]: {}>", cname, length, static_cast<void*>(ptr)) :
        fmt::format("<{}: {}>", cname, static_cast<void*>(ptr));

    lua_pushlstring(state, str.data(), str.size());

    return 1;
}

/**
 * Push the attr entry for the given enum item value.
 * Out-of-range values resolve to the default entry.
 */
static void push_enum_attr(lua_State *state, enum_identity *id, int64_t idx)
{
    if (auto *complex = id->getComplex())
    {
        auto it = complex->value_index_map.find(idx);
        if (it != complex->value_index_map.end())
            idx = int64_t(it->second);
        else
            idx = id->getLastItem() + 1;
    }
    else
    {
        if (idx < id->getFirstItem() || idx > id->getLastItem())
            idx = id->getLastItem()+1;
        idx -= id->getFirstItem();
    }

    uint8_t *ptr = (uint8_t*)id->getAttrs();
    auto atype = id->getAttrType();

    push_object_internal(state, atype, ptr + unsigned(atype->byte_size()*idx));
}

/**
 * Metamethod: __index for enum.attrs
 */
static int meta_enum_attr_index(lua_State *state)
{
    if (!lua_isnumber(state, 2))
        lua_rawget(state, UPVAL_FIELDTABLE);
    if (!lua_isnumber(state, 2))
        luaL_error(state, "Invalid index in enum.attrs[]");

    auto id = (enum_identity*)lua_touserdata(state, lua_upvalueindex(2));
    push_enum_attr(state, id, lua_tonumber(state, 2));
    return 1;
}

/**
 * Metamethod: df.isvalid(obj[,allow_null])
 */
static int meta_isvalid(lua_State *state)
{
    luaL_checkany(state, 1);

    switch (Lua::IsDFObject(state, 1))
    {
    case Lua::OBJ_NULL:
        lua_settop(state, 2);
        if (lua_toboolean(state, 2))
            lua_pushvalue(state, lua_upvalueindex(1));
        else
            lua_pushnil(state);
        return 1;

    case Lua::OBJ_TYPE:
        lua_pushvalue(state, lua_upvalueindex(2));
        return 1;

    case Lua::OBJ_VOIDPTR:
        lua_pushvalue(state, lua_upvalueindex(3));
        return 1;

    case Lua::OBJ_REF:
        lua_pushvalue(state, lua_upvalueindex(4));
        return 1;

    case Lua::OBJ_INVALID:
    default:
        lua_pushnil(state);
        return 1;
    }
}

/**
 * Metamethod: df.isnull(obj)
 */
static int meta_isnull(lua_State *state)
{
    luaL_checkany(state, 1);
    lua_pushboolean(state, Lua::IsDFNull(state, 1));
    return 1;
}

static int meta_nodata(lua_State *state)
{
    return 0;
}

/**
 * Metamethod: __pairs, returning 1st upvalue as iterator
 */
static int meta_pairs(lua_State *state)
{
    luaL_checkany(state, 1);
    lua_pushvalue(state, lua_upvalueindex(1));
    lua_pushvalue(state, 1);
    lua_pushnil(state);
    return 3;
}

/**
 * Make a metatable with most common fields, and an empty table for UPVAL_FIELDTABLE.
 */
void LuaWrapper::MakeMetatable(lua_State *state, const type_identity *type, const char *kind)
{
    int base = lua_gettop(state);
    lua_newtable(state); // metatable

    lua_pushstring(state, type->getFullName().c_str());
    lua_setfield(state, base+1, "__metatable");

    lua_pushlightuserdata(state, const_cast<type_identity*>(type));
    lua_rawsetp(state, base+1, &DFHACK_IDENTITY_FIELD_TOKEN);

    LookupInTable(state, const_cast<type_identity*>(type), &DFHACK_TYPEID_TABLE_TOKEN);
    if (lua_isnil(state, -1))
    {
        // Copy the string from __metatable if no real type
        lua_pop(state, 1);
        lua_getfield(state, base+1, "__metatable");
    }
    lua_setfield(state, base+1, "_type");

    lua_pushstring(state, kind);
    lua_setfield(state, base+1, "_kind");

    // Create the field table
    lua_newtable(state);
}

/**
 * Enable a metafield by injecting an entry into a UPVAL_FIELDTABLE.
 */
void LuaWrapper::EnableMetaField(lua_State *state, int ftable_idx, const char *name, void *id)
{
    lua_pushlightuserdata(state, id);
    lua_setfield(state, ftable_idx, name);
}

/**
 * Set metatable properties common to all actual DF object references.
 */
void LuaWrapper::SetPtrMethods(lua_State *state, int meta_idx, int read_idx)
{
    lua_getfield(state, LUA_REGISTRYINDEX, DFHACK_COMPARE_NAME);
    lua_setfield(state, meta_idx, "__eq");

    lua_rawgetp(state, LUA_REGISTRYINDEX, &DFHACK_TYPETABLE_TOKEN);
    lua_pushvalue(state, meta_idx);
    lua_pushcclosure(state, meta_ptr_tostring, 2);
    lua_setfield(state, meta_idx, "__tostring");

    EnableMetaField(state, read_idx, "_type");
    EnableMetaField(state, read_idx, "_kind");

    EnableMetaField(state, read_idx, "_field");

    lua_getfield(state, LUA_REGISTRYINDEX, DFHACK_SIZEOF_NAME);
    lua_setfield(state, meta_idx, "sizeof");
    EnableMetaField(state, read_idx, "sizeof");

    lua_getfield(state, LUA_REGISTRYINDEX, DFHACK_NEW_NAME);
    lua_setfield(state, meta_idx, "new");
    EnableMetaField(state, read_idx, "new");

    lua_getfield(state, LUA_REGISTRYINDEX, DFHACK_DELETE_NAME);
    lua_setfield(state, meta_idx, "delete");
    EnableMetaField(state, read_idx, "delete");

    lua_getfield(state, LUA_REGISTRYINDEX, DFHACK_ASSIGN_NAME);
    lua_setfield(state, meta_idx, "assign");
    EnableMetaField(state, read_idx, "assign");

    lua_getfield(state, LUA_REGISTRYINDEX, DFHACK_DISPLACE_NAME);
    lua_setfield(state, meta_idx, "_displace");
    EnableMetaField(state, read_idx, "_displace");
}

/**
 * Add a __pairs/__ipairs metamethod using iterator on the top of stack.
 */
void LuaWrapper::SetPairsMethod(lua_State *state, int meta_idx, const char *name)
{
    if (lua_isnil(state, -1))
    {
        lua_pop(state, 1);
        lua_pushcfunction(state, meta_nodata);
    }

    lua_pushcclosure(state, meta_pairs, 1);
    lua_setfield(state, meta_idx, name);
}

/**
 * Add a struct-style (3 upvalues) metamethod to the metatable.
 */
void LuaWrapper::PushStructMethod(lua_State *state, int meta_idx, int ftable_idx,
                                  lua_CFunction function)
{
    lua_rawgetp(state, LUA_REGISTRYINDEX, &DFHACK_TYPETABLE_TOKEN);
    lua_pushvalue(state, meta_idx);
    lua_pushvalue(state, ftable_idx);
    lua_pushcclosure(state, function, 3);
}

/**
 * Add a struct-style (3 upvalues) metamethod to the metatable.
 */
void LuaWrapper::SetStructMethod(lua_State *state, int meta_idx, int ftable_idx,
                                 lua_CFunction function, const char *name)
{
    PushStructMethod(state, meta_idx, ftable_idx, function);
    lua_setfield(state, meta_idx, name);
}

/**
 * Add a 6 upvalue metamethod to the metatable.
 */
void LuaWrapper::PushContainerMethod(lua_State *state, int meta_idx, int ftable_idx,
                                     lua_CFunction function,
    const type_identity *container, const type_identity *item, int count)
{
    lua_rawgetp(state, LUA_REGISTRYINDEX, &DFHACK_TYPETABLE_TOKEN);
    lua_pushvalue(state, meta_idx);
    lua_pushvalue(state, ftable_idx);

    lua_pushlightuserdata(state, const_cast<type_identity*>(container));
    lua_pushlightuserdata(state, const_cast<type_identity*>(item));
    if (count < 0)
        lua_pushnil(state);
    else
        lua_pushinteger(state, count);

    lua_pushcclosure(state, function, 6);
}

/**
 * Add a 6 upvalue metamethod to the metatable.
 */
void LuaWrapper::SetContainerMethod(lua_State *state, int meta_idx, int ftable_idx,
                                    lua_CFunction function, const char *name,
    const type_identity *container, const type_identity *item, int count)
{
    PushContainerMethod(state, meta_idx, ftable_idx, function, container, item, count);
    lua_setfield(state, meta_idx, name);
}

/**
 * If ienum refers to a valid enum, attach its keys to UPVAL_FIELDTABLE,
 * and the enum itself to the _enum metafield. Pushes the key table on the stack
 */
void LuaWrapper::AttachEnumKeys(lua_State *state, int meta_idx, int ftable_idx, const type_identity *ienum)
{
    EnableMetaField(state, ftable_idx, "_enum");

    LookupInTable(state, const_cast<type_identity*>(ienum), &DFHACK_TYPEID_TABLE_TOKEN);
    lua_setfield(state, meta_idx, "_enum");

    LookupInTable(state, const_cast<type_identity*>(ienum), &DFHACK_ENUM_TABLE_TOKEN);

    if (!lua_isnil(state, -1))
    {
        lua_dup(state);
        lua_newtable(state);
        lua_swap(state);
        lua_setfield(state, -2, "__index");
        lua_setmetatable(state, ftable_idx);
    }
    else
    {
        lua_pop(state, 1);
        lua_rawgetp(state, LUA_REGISTRYINDEX, &DFHACK_EMPTY_TABLE_TOKEN);
    }

    lua_dup(state);
    lua_setfield(state, meta_idx, "_index_table");
}

static void BuildTypeMetatable(lua_State *state, const type_identity *type)
{
    type->build_metatable(state);

    lua_pop(state, 1);

    SaveTypeInfo(state, const_cast<type_identity*>(type));
}

/*
 * Recursive walk of scopes to construct the df... tree.
 */

static int wtype_pnext(lua_State *L)
{
    lua_settop(L, 2);  /* create a 2nd argument if there isn't one */
    if (lua_next(L, lua_upvalueindex(1)))
        return 2;
    lua_pushnil(L);
    return 1;
}

static int wtype_pairs(lua_State *state)
{
    lua_pushvalue(state, lua_upvalueindex(1));
    lua_pushcclosure(state, wtype_pnext, 1);
    lua_pushnil(state);
    lua_pushnil(state);
    return 3;
}

static int wtype_inext(lua_State *L)
{
    int i = luaL_checkint(L, 2);
    i++;  /* next value */
    if (i <= lua_tointeger(L, lua_upvalueindex(2)))
    {
        lua_pushinteger(L, i);
        lua_rawgeti(L, lua_upvalueindex(1), i);
        return 2;
    }
    else
    {
        lua_pushnil(L);
        return 1;
    }
}

static int wtype_ipairs(lua_State *state)
{
    lua_pushvalue(state, lua_upvalueindex(1));
    lua_pushvalue(state, lua_upvalueindex(3));
    lua_pushcclosure(state, wtype_inext, 2);
    lua_pushnil(state);
    lua_pushvalue(state, lua_upvalueindex(2));
    return 3;
}

static int wtype_next_item(lua_State *state)
{
    int first = lua_tointeger(state, lua_upvalueindex(1)),
        last = lua_tointeger(state, lua_upvalueindex(2)),
        cur = luaL_checkint(state, lua_gettop(state) > 1 ? 2 : 1); // 'self' optional
    if (cur < last)
        lua_pushinteger(state, cur + 1);
    else
        lua_pushinteger(state, first);
    return 1;
}

/*
 * Complex enums
 *
 * upvalues for all of these:
 *  1: key table? unsure, taken from wtype stuff
 *  2: enum_identity::ComplexData
 */

static bool complex_enum_next_item_helper(lua_State *L, int64_t &item, bool wrap = false)
{
    const auto *complex = (enum_identity::ComplexData*)lua_touserdata(L, lua_upvalueindex(2));
    auto it = complex->value_index_map.find(item);
    if (it != complex->value_index_map.end())
    {
        size_t index = it->second;
        if (!wrap && index >= complex->size() - 1)
            return false;

        item = complex->index_value_map[(index + 1) % complex->size()];
        return true;
    }
    return false;
}

static int complex_enum_inext(lua_State *L)
{
    bool is_first = lua_isuserdata(L, 2);
    int64_t i = (is_first)
        ? ((enum_identity::ComplexData*)lua_touserdata(L, lua_upvalueindex(2)))->index_value_map[0]
        : luaL_checkint(L, 2);
    if (is_first || complex_enum_next_item_helper(L, i))
    {
        lua_pushinteger(L, i);
        lua_rawgeti(L, lua_upvalueindex(1), i);
        return 2;
    }
    else
    {
        lua_pushnil(L);
        return 1;
    }
}

static int complex_enum_next_item(lua_State *L)
{
    int64_t cur = luaL_checkint(L, lua_gettop(L) > 1 ? 2 : 1); // 'self' optional
    complex_enum_next_item_helper(L, cur, true);
    lua_pushinteger(L, cur);
    return 1;
}

static int complex_enum_ipairs(lua_State *L)
{
    lua_pushvalue(L, lua_upvalueindex(1));
    lua_pushvalue(L, lua_upvalueindex(2));
    lua_pushcclosure(L, complex_enum_inext, 2);
    lua_pushnil(L);
    lua_pushlightuserdata(L, (void*)1);
    return 3;
}

/*
 * enum.attrs ipairs() support
 *
 * enum.attrs[] returns a default entry for out-of-range indexes, so a plain
 * ipairs() would never terminate. These iterators stop at the same place as
 * ipairs() on the enum itself (DFHack/dfhack#1860).
 *
 * upvalues for the *_ipairs functions:
 *  1: enum_identity
 *  2: enum_identity::ComplexData (complex enums only)
 *
 * upvalues for the *_inext iterators (UPVAL_TYPETABLE is required by
 * push_object_internal):
 *  1: DFHACK_TYPETABLE
 *  2: enum_identity (plain) or enum_identity::ComplexData (complex)
 *  3: enum_identity (complex only)
 */

static int meta_enum_attr_inext(lua_State *L)
{
    auto id = (enum_identity*)lua_touserdata(L, lua_upvalueindex(2));
    int64_t i = luaL_checkint(L, 2) + 1;
    if (i <= id->getLastItem())
    {
        lua_pushinteger(L, i);
        push_enum_attr(L, id, i);
        return 2;
    }
    else
    {
        lua_pushnil(L);
        return 1;
    }
}

static int meta_enum_attr_ipairs(lua_State *L)
{
    auto id = (enum_identity*)lua_touserdata(L, lua_upvalueindex(1));
    lua_rawgetp(L, LUA_REGISTRYINDEX, &DFHACK_TYPETABLE_TOKEN);
    lua_pushvalue(L, lua_upvalueindex(1));
    lua_pushcclosure(L, meta_enum_attr_inext, 2);
    lua_pushnil(L);
    lua_pushinteger(L, id->getFirstItem() - 1);
    return 3;
}

static int complex_enum_attr_inext(lua_State *L)
{
    bool is_first = lua_isuserdata(L, 2);
    int64_t i = (is_first)
        ? ((enum_identity::ComplexData*)lua_touserdata(L, lua_upvalueindex(2)))->index_value_map[0]
        : luaL_checkint(L, 2);
    if (is_first || complex_enum_next_item_helper(L, i))
    {
        auto id = (enum_identity*)lua_touserdata(L, lua_upvalueindex(3));
        lua_pushinteger(L, i);
        push_enum_attr(L, id, i);
        return 2;
    }
    else
    {
        lua_pushnil(L);
        return 1;
    }
}

static int complex_enum_attr_ipairs(lua_State *L)
{
    lua_rawgetp(L, LUA_REGISTRYINDEX, &DFHACK_TYPETABLE_TOKEN);
    lua_pushvalue(L, lua_upvalueindex(2));
    lua_pushvalue(L, lua_upvalueindex(1));
    lua_pushcclosure(L, complex_enum_attr_inext, 3);
    lua_pushnil(L);
    lua_pushlightuserdata(L, (void*)1);
    return 3;
}


static void RenderTypeChildren(lua_State *state, const std::vector<const compound_identity*> &children);

void LuaWrapper::AssociateId(lua_State *state, int table, int val, const char *name)
{
    lua_pushinteger(state, val);
    lua_pushstring(state, name);
    lua_dup(state);
    lua_pushinteger(state, val);

    lua_rawset(state, table);
    lua_rawset(state, table);
}

static void FillEnumKeys(lua_State *state, int ix_meta, int ftable, enum_identity *eid)
{
    const char *const *keys = eid->getKeys();

    // Create a new table attached to ftable as __index
    lua_newtable(state);
    int base = lua_gettop(state);
    lua_newtable(state);

    auto *complex = eid->getComplex();

    // For enums, set mapping between keys and values
    if (complex)
    {
        for (size_t i = 0; i < complex->size(); i++)
        {
            if (keys[i])
                AssociateId(state, base+1, complex->index_value_map[i], keys[i]);
        }
    }
    else
    {
        for (int64_t i = eid->getFirstItem(), j = 0; i <= eid->getLastItem(); i++, j++)
        {
            if (keys[j])
                AssociateId(state, base+1, i, keys[j]);
        }
    }

    if (complex)
    {
        lua_pushvalue(state, base + 1);
        lua_pushlightuserdata(state, (void*)complex);
        lua_pushcclosure(state, complex_enum_ipairs, 2);
        lua_setfield(state, ix_meta, "__ipairs");

        lua_pushinteger(state, 0); // unused; to align ComplexData
        lua_pushlightuserdata(state, (void*)complex);
        lua_pushcclosure(state, complex_enum_next_item, 2);
        lua_setfield(state, ftable, "next_item");

        lua_pushinteger(state, eid->getFirstItem());
        lua_setfield(state, ftable, "_first_item");

        lua_pushinteger(state, eid->getLastItem());
        lua_setfield(state, ftable, "_last_item");

        lua_pushboolean(state, true);
        lua_setfield(state, ftable, "_complex");
    }
    else
    {
        if (eid->getFirstItem() <= eid->getLastItem())
        {
            lua_pushvalue(state, base + 1);
            lua_pushinteger(state, eid->getFirstItem() - 1);
            lua_pushinteger(state, eid->getLastItem());
            lua_pushcclosure(state, wtype_ipairs, 3);
            lua_setfield(state, ix_meta, "__ipairs");

            lua_pushinteger(state, eid->getFirstItem());
            lua_pushinteger(state, eid->getLastItem());
            lua_pushcclosure(state, wtype_next_item, 2);
            lua_setfield(state, ftable, "next_item");

            lua_pushinteger(state, eid->getFirstItem());
            lua_setfield(state, ftable, "_first_item");

            lua_pushinteger(state, eid->getLastItem());
            lua_setfield(state, ftable, "_last_item");

            lua_pushboolean(state, false);
            lua_setfield(state, ftable, "_complex");
        }
    }

    SaveInTable(state, eid, &DFHACK_ENUM_TABLE_TOKEN);

    // Add an attribute table if any
    if (eid->getAttrs())
    {
        lua_rawgetp(state, LUA_REGISTRYINDEX, &DFHACK_TYPETABLE_TOKEN);
        lua_pushlightuserdata(state, eid);
        lua_pushvalue(state, base+1);
        lua_pushcclosure(state, meta_enum_attr_index, 3);

        freeze_table(state, true, (eid->getFullName()+".attrs").c_str());

        lua_pushlightuserdata(state, eid);
        if (complex)
        {
            lua_pushlightuserdata(state, (void*)complex);
            lua_pushcclosure(state, complex_enum_attr_ipairs, 2);
        }
        else
        {
            lua_pushcclosure(state, meta_enum_attr_ipairs, 1);
        }
        lua_setfield(state, -2, "__ipairs");
        lua_pop(state, 1);

        lua_setfield(state, ftable, "attrs");
    }

    lua_setfield(state, base, "__index");
    lua_setmetatable(state, ftable);
}

static void FillBitfieldKeys(lua_State *state, int ix_meta, int ftable, bitfield_identity *eid)
{
    // Create a new table attached to ftable as __index
    lua_newtable(state);
    int base = lua_gettop(state);
    lua_newtable(state);

    auto bits = eid->getBits();

    for (int i = 0; i < eid->getNumBits(); i++)
    {
        if (bits[i].name)
            AssociateId(state, base+1, i, bits[i].name);
        if (bits[i].size > 1)
            i += bits[i].size-1;
    }

    lua_pushvalue(state, base+1);
    lua_pushinteger(state, -1);
    lua_pushinteger(state, eid->getNumBits()-1);
    lua_pushcclosure(state, wtype_ipairs, 3);
    lua_setfield(state, ix_meta, "__ipairs");

    lua_pushinteger(state, 0);
    lua_setfield(state, ftable, "_first_item");

    lua_pushinteger(state, eid->getNumBits()-1);
    lua_setfield(state, ftable, "_last_item");

    SaveInTable(state, eid, &DFHACK_ENUM_TABLE_TOKEN);

    lua_setfield(state, base, "__index");
    lua_setmetatable(state, ftable);
}

static void RenderType(lua_State *state, const compound_identity *node)
{
    assert(node->getName());
    std::string name = node->getFullName();

    // Frame:
    //   base+1 - outer table
    //   base+2 - metatable of outer table
    //   base+3 - inner table
    //   base+4 - pairs table
    Lua::StackUnwinder base(state);

    lua_newtable(state);
    if (!lua_checkstack(state, 20))
        return;

    SaveInTable(state, const_cast<compound_identity*>(node), &DFHACK_TYPEID_TABLE_TOKEN);

    // metatable
    lua_newtable(state);
    int ix_meta = base+2;

    lua_dup(state);
    lua_setmetatable(state, base+1);

    lua_pushstring(state, name.c_str());
    lua_setfield(state, ix_meta, "__metatable");

    lua_getfield(state, LUA_REGISTRYINDEX, DFHACK_TYPE_TOSTRING_NAME);
    lua_setfield(state, ix_meta, "__tostring");

    lua_pushlightuserdata(state, const_cast<compound_identity*>(node));
    lua_rawsetp(state, ix_meta, &DFHACK_IDENTITY_FIELD_TOKEN);

    // inner table
    lua_newtable(state);
    int ftable = base+3;

    lua_dup(state);
    lua_setfield(state, ix_meta, "__index");

    // pairs table - reuse index table
    lua_dup(state);
    int ptable = base+4;

    lua_pushvalue(state, ptable);
    lua_pushcclosure(state, wtype_pairs, 1);
    lua_setfield(state, ix_meta, "__pairs");

    switch (node->type())
    {
    case IDTYPE_UNION: // TODO: change this to union-type? what relies on this?
        lua_pushboolean(state, true);
        lua_setfield(state, ftable, "_union");
        [[fallthrough]];
    case IDTYPE_STRUCT:
        lua_pushstring(state, "struct-type");
        lua_setfield(state, ftable, "_kind");
        IndexStatics(state, ix_meta, ftable, (struct_identity*)node);
        break;

    case IDTYPE_CLASS:
        lua_pushstring(state, "class-type");
        lua_setfield(state, ftable, "_kind");
        IndexStatics(state, ix_meta, ftable, (struct_identity*)node);
        break;

    case IDTYPE_ENUM:
        lua_pushstring(state, "enum-type");
        lua_setfield(state, ftable, "_kind");
        FillEnumKeys(state, ix_meta, ftable, (enum_identity*)node);
        break;

    case IDTYPE_BITFIELD:
        lua_pushstring(state, "bitfield-type");
        lua_setfield(state, ftable, "_kind");
        FillBitfieldKeys(state, ix_meta, ftable, (bitfield_identity*)node);
        break;

    case IDTYPE_GLOBAL:
        lua_pushstring(state, "global");
        lua_setfield(state, ftable, "_kind");

        {
            RenderTypeChildren(state, node->getScopeChildren());
            IndexStatics(state, ix_meta, ftable, (struct_identity*)node);

            lua_pushlightuserdata(state, const_cast<compound_identity*>(node));
            lua_setfield(state, ftable, "_identity");

            BuildTypeMetatable(state, node);

            lua_dup(state);
            lua_setmetatable(state, ftable);

            lua_getfield(state, -1, "__newindex");
            lua_setfield(state, ix_meta, "__newindex");
            lua_getfield(state, -1, "__pairs");
            lua_setfield(state, ix_meta, "__pairs");

            base += 1;
            return;
        }

    default:
        break;
    }

    RenderTypeChildren(state, node->getScopeChildren());

    lua_pushlightuserdata(state, const_cast<compound_identity*>(node));
    lua_setfield(state, ftable, "_identity");

    lua_getfield(state, LUA_REGISTRYINDEX, DFHACK_SIZEOF_NAME);
    lua_setfield(state, ftable, "sizeof");

    lua_getfield(state, LUA_REGISTRYINDEX, DFHACK_NEW_NAME);
    lua_setfield(state, ftable, "new");

    lua_getfield(state, LUA_REGISTRYINDEX, DFHACK_IS_INSTANCE_NAME);
    lua_setfield(state, ftable, "is_instance");

    base += 1;
}

static void RenderTypeChildren(lua_State *state, const std::vector<const compound_identity*> &children)
{
    // fieldtable pairstable |
    int base = lua_gettop(state);

    for (size_t i = 0; i < children.size(); i++)
    {
        RenderType(state, children[i]);
        lua_pushstring(state, children[i]->getName());
        lua_swap(state);

        // save in both tables
        lua_pushvalue(state, -2);
        lua_pushvalue(state, -2);
        lua_rawset(state, base);
        lua_rawset(state, base-1);
    }
}

static int DoAttach(lua_State *state)
{
    lua_newtable(state);
    lua_rawsetp(state, LUA_REGISTRYINDEX, &DFHACK_PTR_IDTABLE_TOKEN);

    lua_newtable(state);
    lua_rawsetp(state, LUA_REGISTRYINDEX, &DFHACK_TYPEID_TABLE_TOKEN);

    lua_newtable(state);
    lua_rawsetp(state, LUA_REGISTRYINDEX, &DFHACK_ENUM_TABLE_TOKEN);

    lua_newtable(state);
    lua_rawsetp(state, LUA_REGISTRYINDEX, &DFHACK_EMPTY_TABLE_TOKEN);

    lua_pushcfunction(state, change_error);
    lua_setfield(state, LUA_REGISTRYINDEX, DFHACK_CHANGEERROR_NAME);

    lua_pushcfunction(state, meta_ptr_compare);
    lua_setfield(state, LUA_REGISTRYINDEX, DFHACK_COMPARE_NAME);

    lua_pushcfunction(state, meta_type_tostring);
    lua_setfield(state, LUA_REGISTRYINDEX, DFHACK_TYPE_TOSTRING_NAME);

    lua_rawgetp(state, LUA_REGISTRYINDEX, &DFHACK_TYPETABLE_TOKEN);
    lua_pushcclosure(state, meta_sizeof, 1);
    lua_setfield(state, LUA_REGISTRYINDEX, DFHACK_SIZEOF_NAME);

    lua_rawgetp(state, LUA_REGISTRYINDEX, &DFHACK_TYPETABLE_TOKEN);
    lua_pushcclosure(state, meta_displace, 1);
    lua_setfield(state, LUA_REGISTRYINDEX, DFHACK_DISPLACE_NAME);

    lua_rawgetp(state, LUA_REGISTRYINDEX, &DFHACK_TYPETABLE_TOKEN);
    lua_pushcclosure(state, meta_new, 1);
    lua_setfield(state, LUA_REGISTRYINDEX, DFHACK_NEW_NAME);

    lua_rawgetp(state, LUA_REGISTRYINDEX, &DFHACK_TYPETABLE_TOKEN);
    lua_pushcclosure(state, meta_reinterpret_cast, 1);
    lua_setfield(state, LUA_REGISTRYINDEX, DFHACK_CAST_NAME);

    lua_rawgetp(state, LUA_REGISTRYINDEX, &DFHACK_TYPETABLE_TOKEN);
    lua_pushcclosure(state, meta_read_fields, 1);
    lua_setfield(state, LUA_REGISTRYINDEX, DFHACK_READ_FIELDS_NAME);

    lua_rawgetp(state, LUA_REGISTRYINDEX, &DFHACK_TYPETABLE_TOKEN);
    lua_pushcclosure(state, meta_assign, 1);
    lua_setfield(state, LUA_REGISTRYINDEX, DFHACK_ASSIGN_NAME);

    lua_rawgetp(state, LUA_REGISTRYINDEX, &DFHACK_TYPETABLE_TOKEN);
    lua_pushcclosure(state, meta_is_instance, 1);
    lua_setfield(state, LUA_REGISTRYINDEX, DFHACK_IS_INSTANCE_NAME);

    lua_rawgetp(state, LUA_REGISTRYINDEX, &DFHACK_TYPETABLE_TOKEN);
    lua_pushcclosure(state, meta_delete, 1);
    lua_setfield(state, LUA_REGISTRYINDEX, DFHACK_DELETE_NAME);

    {
        // Assign df a metatable with read-only contents
        lua_newtable(state);
        lua_newtable(state);

        // Render the type structure
        RenderTypeChildren(state, compound_identity::getTopScope());

        lua_swap(state); // -> pairstable fieldtable

        lua_getfield(state, LUA_REGISTRYINDEX, DFHACK_SIZEOF_NAME);
        lua_setfield(state, -2, "sizeof");
        lua_getfield(state, LUA_REGISTRYINDEX, DFHACK_NEW_NAME);
        lua_setfield(state, -2, "new");
        lua_getfield(state, LUA_REGISTRYINDEX, DFHACK_DELETE_NAME);
        lua_setfield(state, -2, "delete");
        lua_getfield(state, LUA_REGISTRYINDEX, DFHACK_DISPLACE_NAME);
        lua_setfield(state, -2, "_displace");
        lua_getfield(state, LUA_REGISTRYINDEX, DFHACK_ASSIGN_NAME);
        lua_setfield(state, -2, "assign");
        lua_getfield(state, LUA_REGISTRYINDEX, DFHACK_IS_INSTANCE_NAME);
        lua_setfield(state, -2, "is_instance");
        lua_getfield(state, LUA_REGISTRYINDEX, DFHACK_CAST_NAME);
        lua_setfield(state, -2, "reinterpret_cast");
        lua_getfield(state, LUA_REGISTRYINDEX, DFHACK_READ_FIELDS_NAME);
        lua_setfield(state, -2, "readFields");

        lua_pushlightuserdata(state, NULL);
        lua_setfield(state, -2, "NULL");
        lua_pushlightuserdata(state, NULL);
        lua_setglobal(state, "NULL");

        lua_pushstring(state, "null");
        lua_pushstring(state, "type");
        lua_pushstring(state, "voidptr");
        lua_pushstring(state, "ref");
        lua_pushcclosure(state, meta_isvalid, 4);
        lua_setfield(state, -2, "isvalid");

        lua_pushcfunction(state, meta_isnull);
        lua_setfield(state, -2, "isnull");

        freeze_table(state, true, "df");

        // pairstable dftable dfmeta

        lua_pushvalue(state, -3);
        lua_pushcclosure(state, wtype_pairs, 1);
        lua_setfield(state, -2, "__pairs");
        lua_pop(state, 1);
        lua_remove(state, -2);
    }

    return 1;
}

/**
 * Initialize access to DF objects from the interpreter
 * context, unless it has already been done.
 */
void LuaWrapper::AttachDFGlobals(lua_State *state)
{
    lua_rawgetp(state, LUA_REGISTRYINDEX, &DFHACK_TYPETABLE_TOKEN);

    if (lua_isnil(state, -1))
    {
        lua_pop(state, 1);
        lua_newtable(state);
        lua_dup(state);
        lua_rawsetp(state, LUA_REGISTRYINDEX, &DFHACK_TYPETABLE_TOKEN);

        luaL_requiref(state, "df", DoAttach, 1);
        lua_pop(state, 1);
    }

    lua_pop(state, 1);
}

namespace
{
    struct deprecation_notification
    {
        std::string name;
        std::string source;
        int line;

        bool operator==(const deprecation_notification& other) const = default;

        struct hash
        {
            std::size_t operator()(const deprecation_notification& n) const noexcept
            {
                return hash_value(n.name, n.source, n.line);
            }
        };
    };

    static std::unordered_set<deprecation_notification, deprecation_notification::hash> deprecation_notification_history;
}

void LuaWrapper::notify_deprecated(lua_State* state, std::string_view name, std::string_view message)
{
    lua_Debug ar;
    std::optional<deprecation_notification> notify;

    for (int depth = 0; lua_getstack(state, depth, &ar); depth++)
    {
        if (lua_getinfo(state, "nSl", &ar) && std::strcmp(ar.what, "Lua") == 0)
        {
            notify = deprecation_notification{std::string(name),ar.short_src,ar.currentline};
            break;
        }
    }

    if (!notify) return;

    if (!deprecation_notification_history.contains(*notify))
    {
        WARN(deprecation).print("Deprecated function {} called from {} at line {}: {}\n", notify->name, notify->source, notify->line, message);
        deprecation_notification_history.insert(*notify);
    }
}

namespace DFHack { namespace LuaWrapper {
    struct LuaToken { int reserved; };

    LuaToken DFHACK_IDENTITY_FIELD_TOKEN;
    LuaToken DFHACK_TYPETABLE_TOKEN;
    LuaToken DFHACK_TYPEID_TABLE_TOKEN;
    LuaToken DFHACK_ENUM_TABLE_TOKEN;
    LuaToken DFHACK_PTR_IDTABLE_TOKEN;
    LuaToken DFHACK_EMPTY_TABLE_TOKEN;
}}
