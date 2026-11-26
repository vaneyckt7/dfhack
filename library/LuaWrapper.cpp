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
#include <cmath>
#include <cstring>
#include <new>
#include <string>
#include <string_view>
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
 * df.read_fields: read chosen fields from every entry of a container in one call.
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
    bool leaf_pointers = false;             // a fixed-size array whose entries are pointers
    const type_identity *ref_target = nullptr;  // what the entries are ids of, when that is known
    // What is read from: a container, a Lua list of objects, or a linked list, which is a chain of
    // structures that each point to an item and to the next link.
    enum Mode { CONTAINER, OBJECTS, LINKS };
    Mode mode = CONTAINER;
    size_t next_offset = 0;                 // of a link's pointer to the next link
    size_t item_offset = 0;                 // of a link's pointer to its item
    const type_identity *link = nullptr;    // what a link is
};

// A run of entries found along a path: a container, or an array of a fixed size.
struct ReadSeq {
    const container_identity *container = nullptr;  // null for an array of a fixed size
    const type_identity *item = nullptr;    // what to ask the container for
    const type_identity *entry = nullptr;   // what one entry is, with a pointer followed; null if unknown
    int count = -1;                         // of an array of a fixed size
    size_t item_size = 0;
    bool pointers = false;                  // the entries are pointers to what is read
    const enum_identity *index_enum = nullptr;
};

// How a path gets from the end of one of its segments to the start of the next.
struct ReadHop {
    // FIND takes the number at the place for an id and looks up the object that has it
    enum Kind { PTR, ITEM, FIND };
    Kind kind = PTR;
    ReadSeq seq;
    int index = 0;
    const function_identity_base *find = nullptr;
    size_t id_size = 0;
    bool id_signed = false;
};

// How a value lies in memory, which decides how a condition reads it.
// LEAF_DYNAMIC is what a function gives back, which is only known once it has been called.
enum ReadLeaf { LEAF_INT, LEAF_BOOL, LEAF_FLOAT, LEAF_DOUBLE, LEAF_STRING, LEAF_CSTRING, LEAF_OTHER, LEAF_DYNAMIC };

struct ReadAttr {
    const enum_identity *owner;
    const struct_field_info *field;
    size_t size = 0;                        // of the attribute when Lua reads it as an integer, else 0
    bool is_signed = false;
    ReadLeaf leaf = LEAF_OTHER;
};

// The object at offset in a path's segment must be an instance of cls for the path to go on.
struct ReadCheck {
    size_t segment;
    size_t offset;
    const virtual_identity *cls;
};

struct ReadAccessor {
    // PTR is a pointer field itself, which a condition can compare with df.NULL or with an object.
    // FROM is the place in the list of the containers an entry came from. FLAG is one flag of a flag
    // array, SIZE the number of entries of a container, TYPE the type of an object, REF whatever
    // reading the place in Lua gives when that is not a single value, and GROUP a run of entries
    // for a condition on any or all of them. CALL is what a function gives back for the entry.
    enum Kind { INDEX, FROM, VALUE, BIT, WHOLE, PTR, FLAG, SIZE, TYPE, REF, GROUP, CALL };
    Kind kind = VALUE;
    size_t source = 0;
    // offsets[0] is added to the entry's address; every further one is added after the hop of the
    // same place, which follows a pointer or goes to an entry of a container
    std::vector<size_t> offsets;
    std::vector<ReadHop> hops;
    ReadSeq seq;                            // SIZE and GROUP
    const df::bit_container_identity *flags = nullptr;
    int flag = 0;
    const struct_field_info *ref_field = nullptr;   // REF: the field to read, or null to read type
    // REF to a union, or a vector of them, that another field of the same structure says how to
    // read: that field, and how far it is from this one
    const struct_field_info *tag_field = nullptr;
    ptrdiff_t tag_offset = 0;
    const char *tag_attr = nullptr;
    const type_identity *seq_target = nullptr;      // GROUP: what the entries are ids of, when known
    const type_identity *type = nullptr;
    unsigned bit = 0;
    int bit_size = 1;
    size_t whole_size = 0;
    std::vector<ReadAttr> attrs;
    std::vector<ReadCheck> checks;
    int call = 0;                           // CALL: where the function is in the table of functions
    std::vector<ReadAccessor> call_args;    // CALL: what is read and passed to it
    // Set when a condition can take the short way for whole numbers or for a single flag.
    // value_leaf, value_size and value_signed describe the value in memory for kind VALUE; leaf is
    // what the whole path ends in.
    enum Native { NOT_NATIVE, NATIVE_INT, NATIVE_BOOL };
    Native native = NOT_NATIVE;
    ReadLeaf value_leaf = LEAF_OTHER;
    size_t value_size = 0;
    bool value_signed = false;
    ReadLeaf leaf = LEAF_OTHER;
};

// A value as a condition sees it. The text of a string is not owned, unless it is in own.
struct ReadScalar {
    enum Kind { NIL, INT, FLOAT, BOOL, STRING, OTHER };
    Kind kind = NIL;
    std::string own;                        // the text, where nothing else keeps it
    int64_t i = 0;
    double f = 0;
    bool b = false;
    const char *s = nullptr;
    size_t len = 0;
};


// Calls a function that DF objects offer, with the arguments on the stack from base on, and leaves
// what it gives back on top of them.
void read_invoke(lua_State *state, const function_identity_base *fn, int base)
{
    try {
        fn->invoke(state, base);
    }
    catch (Error::All &e) {
        luaL_error(state, "df.read_fields: %s", e.what());
    }
    catch (std::exception &e) {
        luaL_error(state, "df.read_fields: C++ exception: %s", e.what());
    }
}

// A condition on a whole number or a flag that lies at a fixed place in an entry, worked out ahead
// so that checking it takes one read and one comparison.
struct ReadFast {
    enum Kind { NONE, COMPARE, SET, TABLE };
    Kind kind = NONE;
    bool index = false;                     // the value is the entry's index
    size_t source = 0;
    size_t offset = 0;
    size_t size = 0;
    bool is_signed = false;
    unsigned shift = 0;
    uint64_t mask = 0;                      // 0 when the number read is the value as it stands
    // TABLE: the answer for every value from first on, and for all values outside the table
    int64_t first = 0;
    std::vector<uint8_t> table;
    bool otherwise = false;
};

struct ReadCond {
    // CMP2 compares two fields, TEXT looks for a piece of text, ANY and ALL test the entries of a
    // container inside the entry, TYPEIS tests the type of an object and PTREQ a pointer's target.
    enum Kind { CMP, IN, ISNULL, AND, OR, NOT, CMP2, TEXT, ANY, ALL, TYPEIS, PTREQ };
    enum TextOp { STARTS, ENDS, CONTAINS };
    Kind kind = AND;
    size_t accessor = 0;
    size_t accessor2 = 0;
    TextOp text_op = STARTS;
    bool fold = false;                  // TEXT: the case of the letters a to z does not matter
    size_t sub = 0;                         // ANY and ALL: which of the plan's subs holds the conditions
    const struct_identity *wanted = nullptr;
    bool exact = false;
    const void *address = nullptr;
    int op = LUA_OPEQ;
    bool swap = false;
    bool negate = false;
    std::vector<size_t> kids;
    // set when both sides are whole numbers, or both are flags
    bool native = false;
    // the value compared against
    ReadScalar::Kind value_kind = ReadScalar::NIL;
    int64_t native_value = 0;
    double float_value = 0;
    std::string text;
    // the values of an 'in' list, each kind sorted
    std::vector<int64_t> native_set;
    std::vector<double> float_set;
    std::vector<std::string> text_set;
    bool has_true = false, has_false = false;
    ReadFast fast;
};

struct ReadPlan {
    std::vector<ReadSource> sources;
    bool named = false;
    std::vector<ReadAccessor> accessors;
    std::vector<ReadCond> conds;
    bool has_where = false;
    size_t root = 0;
    bool has_test = false;
    bool has_each = false;              // each entry kept is handed to a function, not stored
    // the fields to hand back, and the accessor of each
    std::vector<std::string> names;     // what the fields are called in out
    std::vector<std::string> paths;     // and where each is read from
    bool is_sub = false;                // the conditions of an any or all
    std::vector<size_t> columns;
    lua_Integer limit = 0;                  // stop after this many entries; 0 for no limit
    // the conditions of every 'any' and 'all', each set up as a read of the entries it tests
    std::vector<ReadPlan> subs;
};

// Where a container is at the moment, and how many items it holds.
struct ReadBound {
    uint8_t *ptr = nullptr;
    int outer = 0;
};

// How far a read has come in one container.
struct ReadCursor {
    int outer = 0;
    int inner = 0;
    uint8_t *item = nullptr;
    bool item_ok = false;
};

// The part of a container one read is limited to, already clamped to what the container holds:
// outer items first1 to last1 and, in each of them, entries first2 to last2, all counted from 0.
struct ReadRange {
    bool set = false;
    bool empty = false;
    int first1 = 0, last1 = -1;
    int first2 = 0, last2 = -1;
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

const struct_field_info *read_own_field(const struct_identity *type, const std::string &name)
{
    auto field = type->getFields();
    if (!field)
        return nullptr;
    for (; field->mode != struct_field_info::END; field++)
        if (field->name && name == field->name)
            return field;
    return nullptr;
}

// The classes derived from type that declare a field of this name themselves.
void read_find_in_subclasses(const struct_identity *type, const std::string &name,
                             std::vector<const struct_identity*> &found)
{
    for (auto child : type->getChildren())
    {
        if (read_own_field(child, name))
            found.push_back(child);
        else
            read_find_in_subclasses(child, name, found);
    }
}

const struct_identity *read_find_subclass(const struct_identity *type, const std::string &name)
{
    for (auto child : type->getChildren())
    {
        if (name == child->getName())
            return child;
        if (auto deeper = read_find_subclass(child, name))
            return deeper;
    }
    return nullptr;
}

// Works out what kind of container is at idx, where it is and how much it holds.
void read_describe_source(lua_State *state, int idx, ReadSource &src)
{
    if (lua_type(state, idx) != LUA_TUSERDATA)
        luaL_error(state, "df.read_fields: expected a container, or a table of named containers");

    auto id = get_object_identity(state, idx, "df.read_fields()", false, true);
    // stack: [metatable]
    if (!id->isContainer() || id->type() == IDTYPE_BIT_CONTAINER)
        luaL_error(state, "df.read_fields: %s is not a container it can read", id->getFullName().c_str());

    src.container = (const container_identity*)id;
    lua_getfield(state, -1, "_field_identity");
    src.item = (const type_identity*)lua_touserdata(state, -1);
    lua_getfield(state, -2, "_count");
    int fixed = lua_isnil(state, -1) ? -1 : int(lua_tointeger(state, -1));
    lua_pop(state, 3);
    if (!src.item)
        luaL_error(state, "df.read_fields: the container's item type is not known");

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
                luaL_error(state, "df.read_fields: cannot read a nested array of unknown shape");
            src.inner *= buffer->getSize();
            src.leaf = buffer->getItemType();
        }
    }
    src.leaf_size = src.leaf->byte_size();
    if (!src.pointers && src.leaf->type() == IDTYPE_POINTER)
    {
        auto target = ((const pointer_identity_base*)src.leaf)->getTarget();
        if (!target)
            luaL_error(state, "df.read_fields: cannot read a container of untyped pointers");
        src.leaf_pointers = true;
        src.leaf = target;
    }
}

void read_add_source(lua_State *state, ReadPlan &plan, int idx, const std::string &name)
{
    ReadSource src;
    src.name = name;
    read_describe_source(state, idx, src);
    plan.sources.push_back(src);
}

bool read_same_kind(const ReadSource &a, const ReadSource &b)
{
    return a.container == b.container && a.item == b.item && a.leaf == b.leaf && a.leaf_size == b.leaf_size &&
           a.inner == b.inner && a.dynamic == b.dynamic && a.pointers == b.pointers &&
           a.leaf_pointers == b.leaf_pointers && (a.dynamic || a.outer == b.outer);
}

// Points a read at the containers at idx, which must be of the kinds it was set up for: one
// container, or a table of named ones. Returns how many entries they hold.
lua_Integer read_bind(lua_State *state, const ReadPlan &plan, int idx, std::vector<ReadBound> &bound)
{
    if (plan.named && !lua_istable(state, idx))
        luaL_error(state, "df.read_fields: expected a table of named containers");
    lua_Integer total = 0;
    for (size_t i = 0; i < plan.sources.size(); i++)
    {
        const ReadSource &want = plan.sources[i];
        if (plan.named)
        {
            lua_pushlstring(state, want.name.data(), want.name.size());
            lua_rawget(state, idx);
            if (lua_isnil(state, -1))
                luaL_error(state, "df.read_fields: no container named '%s'", want.name.c_str());
        }
        else
            lua_pushvalue(state, idx);
        ReadSource now;
        read_describe_source(state, lua_gettop(state), now);
        lua_pop(state, 1);
        if (!read_same_kind(want, now))
            luaL_error(state, "df.read_fields: a container is not of the kind this read was set up for");
        bound[i].ptr = now.ptr;
        bound[i].outer = now.outer;
        lua_Integer count = lua_Integer(now.outer) * now.inner;
        if (i == 0)
            total = count;
        else if (count != total)
            luaL_error(state, "df.read_fields: the containers do not have the same number of entries");
    }
    return total;
}

// The size in bytes of a value that Lua reads as an integer, or 0 for anything else. Whether it is
// signed is found by reading all ones through the type's own reader.
size_t read_integer_size(lua_State *state, const type_identity *type, bool &is_signed)
{
    if (type && type->type() == IDTYPE_ENUM)
        type = ((const enum_identity*)type)->getBaseType();
    auto number = type ? dynamic_cast<const df::number_identity_base*>(type) : nullptr;
    if (!number || !number->isInteger())
        return 0;
    size_t size = number->byte_size();
    if (size != 1 && size != 2 && size != 4 && size != 8)
        return 0;
    uint8_t ones[8];
    memset(ones, 0xFF, sizeof(ones));
    number->lua_read(state, 0, ones);
    bool integer = lua_isinteger(state, -1) != 0;
    is_signed = integer && lua_tointeger(state, -1) < 0;
    lua_pop(state, 1);
    return integer ? size : 0;
}

ReadLeaf read_classify(lua_State *state, const type_identity *type, size_t &size, bool &is_signed)
{
    size = 0;
    is_signed = false;
    if (type == (const type_identity*)df::identity_traits<bool>::get())
        return LEAF_BOOL;
    if (type == (const type_identity*)df::identity_traits<float>::get())
        return LEAF_FLOAT;
    if (type == (const type_identity*)df::identity_traits<double>::get())
        return LEAF_DOUBLE;
    if (type == (const type_identity*)df::identity_traits<std::string>::get())
        return LEAF_STRING;
    if (type == (const type_identity*)df::identity_traits<char*>::get() ||
        type == (const type_identity*)df::identity_traits<const char*>::get())
        return LEAF_CSTRING;
    size = read_integer_size(state, type, is_signed);
    if (size)
        return LEAF_INT;
    return LEAF_OTHER;
}

// The run of entries that a value of this type is, if it is one.
bool read_seq_from_type(const type_identity *type, ReadSeq &seq)
{
    seq = ReadSeq();
    switch (type->type())
    {
    case IDTYPE_BUFFER:
    {
        auto buffer = (const df::buffer_container_identity*)type;
        if (!buffer->getItemType() || buffer->getSize() <= 0)
            return false;
        seq.item = buffer->getItemType();
        seq.count = buffer->getSize();
        seq.item_size = seq.item->byte_size();
        seq.index_enum = (const enum_identity*)buffer->getIndexEnumType();
        break;
    }
    case IDTYPE_CONTAINER:
        seq.container = (const container_identity*)type;
        seq.item = seq.container->getItemType();
        seq.index_enum = (const enum_identity*)seq.container->getIndexEnumType();
        break;
    case IDTYPE_PTR_CONTAINER:
    case IDTYPE_STL_PTR_VECTOR:
        seq.container = (const container_identity*)type;
        seq.entry = seq.container->getItemType();
        seq.item = &df::identity_traits<void*>::identity;
        seq.pointers = true;
        seq.index_enum = (const enum_identity*)seq.container->getIndexEnumType();
        return true;
    default:
        return false;
    }
    if (!seq.item)
        return false;
    seq.entry = seq.item;
    if (seq.item->type() == IDTYPE_POINTER)
    {
        seq.pointers = true;
        seq.entry = ((const pointer_identity_base*)seq.item)->getTarget();
    }
    return true;
}

// The run of entries that a field holds, if it holds one.
bool read_seq_from_field(const struct_field_info *field, ReadSeq &seq)
{
    seq = ReadSeq();
    switch (field->mode)
    {
    case struct_field_info::STATIC_ARRAY:
        if (!field->type || field->count <= 0)
            return false;
        seq.item = field->type;
        seq.count = int(field->count);
        seq.item_size = seq.item->byte_size();
        seq.entry = seq.item;
        if (seq.item->type() == IDTYPE_POINTER)
        {
            seq.pointers = true;
            seq.entry = ((const pointer_identity_base*)seq.item)->getTarget();
        }
        break;
    case struct_field_info::STL_VECTOR_PTR:
        seq.container = &df::identity_traits<std::vector<void*> >::identity;
        seq.item = &df::identity_traits<void*>::identity;
        seq.entry = field->type;
        seq.pointers = true;
        break;
    case struct_field_info::CONTAINER:
        if (!field->type || !read_seq_from_type(field->type, seq))
            return false;
        break;
    default:
        return false;
    }
    if (field->extra && field->extra->index_enum)
        seq.index_enum = field->extra->index_enum;
    return true;
}

inline int read_seq_count(const ReadSeq &seq, uint8_t *ptr)
{
    return seq.container ? seq.container->raw_item_count(ptr) : seq.count;
}

// Entry idx of a run at ptr; idx must be within the count. Null for a null pointer in its place.
inline uint8_t *read_seq_entry(const ReadSeq &seq, uint8_t *ptr, int idx)
{
    uint8_t *entry = seq.container ? (uint8_t*)seq.container->raw_item_pointer(seq.item, ptr, idx)
                                   : ptr + size_t(idx) * seq.item_size;
    if (entry && seq.pointers)
        entry = *(uint8_t**)entry;
    return entry;
}

// The number a path step stands for where an index is wanted: a whole number, or a key of the enum
// the entries are indexed by.
bool read_step_index(const std::string &part, const enum_identity *index_enum, int64_t &value)
{
    if (!part.empty() && part.find_first_not_of("0123456789") == std::string::npos && part.size() <= 9)
    {
        value = strtoll(part.c_str(), nullptr, 10);
        return true;
    }
    if (!index_enum || !index_enum->getKeys())
        return false;
    auto keys = index_enum->getKeys();
    auto complex = index_enum->getComplex();
    int count = complex ? int(complex->size()) : index_enum->getCount();
    for (int i = 0; i < count; i++)
    {
        if (keys[i] && part == keys[i])
        {
            value = complex ? complex->index_value_map[size_t(i)] : index_enum->getFirstItem() + i;
            return true;
        }
    }
    return false;
}

// The place, in the list that is being read, of the container the entry in hand came from: the
// value of _from. Set before the conditions of each entry are tested.
thread_local lua_Integer read_place = 0;
// The stack index of the table of the functions the fields and conditions of the read call.
thread_local int read_calls_idx = 0;
// The same while a read is being set up. It is kept apart because setting up can run Lua code, the
// __index of an options table, and that code may do a whole read of its own.
thread_local int read_setup_calls_idx = 0;
// Puts it back when a setup ends, whether it returns or raises an error.
struct ReadSetupGuard {
    const int calls_idx = read_setup_calls_idx;
    ReadSetupGuard() = default;
    ReadSetupGuard(const ReadSetupGuard&) = delete;
    ReadSetupGuard &operator=(const ReadSetupGuard&) = delete;
    ~ReadSetupGuard() { read_setup_calls_idx = calls_idx; }
};
// What a function called in the middle of a read is followed by: refresh finds the entry being read
// again, since the function may have moved or replaced it, and returns false when it is gone. The
// entries of an any or all have a frame of their own, whose parent is the one around it.
struct ReadFrame {
    ReadFrame *parent = nullptr;
    bool (*refresh)(ReadFrame*) = nullptr;
    void *ctx = nullptr;
};
thread_local ReadFrame *read_frame = nullptr;
// Puts the three of them back when a read ends, also when it ends with an error. A read can start
// in the middle of another one wherever Lua code can run, a finalizer included, and the outer read
// must find them as it left them.
struct ReadStateGuard {
    const lua_Integer place = read_place;
    const int calls_idx = read_calls_idx;
    ReadFrame *const frame = read_frame;
    ReadStateGuard() = default;
    ReadStateGuard(const ReadStateGuard&) = delete;
    ReadStateGuard &operator=(const ReadStateGuard&) = delete;
    ~ReadStateGuard()
    {
        read_place = place;
        read_calls_idx = calls_idx;
        read_frame = frame;
    }
};

// What a path is compiled for: a field to hand back, a value for a condition to compare, or a run
// of entries for a condition on any or all of them.
enum ReadUse { USE_OUTPUT, USE_COND, USE_GROUP };

size_t read_compile(lua_State *state, ReadPlan &plan, const std::string &path, ReadUse use = USE_OUTPUT)
{
    const bool for_cond = use != USE_OUTPUT;
    ReadAccessor acc;
    if (path == "_index")
    {
        if (use == USE_GROUP)
            luaL_error(state, "df.read_fields: '_index' is not a container");
        acc.kind = ReadAccessor::INDEX;
        acc.native = ReadAccessor::NATIVE_INT;
        acc.leaf = LEAF_INT;
        plan.accessors.push_back(acc);
        return plan.accessors.size() - 1;
    }

    if (path == "_from")
    {
        if (use == USE_GROUP)
            luaL_error(state, "df.read_fields: '_from' is not a container");
        if (plan.is_sub)
            luaL_error(state, "df.read_fields: '_from' cannot be used in the conditions of any or all");
        acc.kind = ReadAccessor::FROM;
        acc.native = ReadAccessor::NATIVE_INT;
        acc.leaf = LEAF_INT;
        plan.accessors.push_back(acc);
        return plan.accessors.size() - 1;
    }

    std::vector<std::string> parts;
    split_string(&parts, path, ".");
    if (parts.empty() || parts[0].empty())
        luaL_error(state, "df.read_fields: empty field name");

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
            luaL_error(state, "df.read_fields: '%s' does not start with the name of a container", path.c_str());
        at = 1;
    }
    else if (parts[0] == "_value")
        at = 1;

    acc.offsets.push_back(0);
    acc.hops.push_back(ReadHop());
    const type_identity *cur = plan.sources[acc.source].leaf;
    const enum_identity *owner = nullptr;
    bool done = false;
    // What the path has come to when it is not at a structure or a value: a run of entries, or a
    // flag array. from_field is the field that holds it, when the last step was a field.
    enum { AT_TYPE, AT_SEQ, AT_FLAGS } where = AT_TYPE;
    ReadSeq seq;
    const df::bit_container_identity *flags = nullptr;
    const enum_identity *flags_enum = nullptr;
    const struct_field_info *from_field = nullptr;
    // the field that says which member of a union is in use, when the step at tag_step was the
    // union or a vector of them
    const struct_field_info *tag_field = nullptr;
    ptrdiff_t tag_offset = 0;
    const char *tag_attr = nullptr;
    size_t tag_step = 0;
    // what a value is the id of, as the field it was read from says, and the same for the
    // entries of the run the path is at
    const type_identity *value_target = plan.sources[acc.source].ref_target;
    const type_identity *seq_target = nullptr;

    // Works out where the path stands once it has come to something of type cur.
    auto settle = [&]() {
        while (cur->type() == IDTYPE_POINTER)
        {
            // a pointer met inside an array or a container
            auto target = ((const pointer_identity_base*)cur)->getTarget();
            if (!target)
                luaL_error(state, "df.read_fields: '%s' goes through an untyped pointer", path.c_str());
            acc.offsets.push_back(0);
            acc.hops.push_back(ReadHop());
            cur = target;
        }
        if (read_is_value(cur))
        {
            acc.type = cur;
            done = true;
            owner = cur->type() == IDTYPE_ENUM ? (const enum_identity*)cur : nullptr;
        }
        else if (cur->type() == IDTYPE_BIT_CONTAINER)
        {
            where = AT_FLAGS;
            flags = (const df::bit_container_identity*)cur;
            flags_enum = (const enum_identity*)flags->getIndexEnumType();
        }
        else if (read_seq_from_type(cur, seq))
            where = AT_SEQ;
    };
    settle();

    for (; at < parts.size(); at++)
    {
        const std::string &part = parts[at];
        if (done && part == "_target")
        {
            // the value is the id of an object, which is looked up as the type's find() does
            auto target = acc.kind == ReadAccessor::VALUE && acc.attrs.empty() ? value_target : nullptr;
            if (!target || !read_is_struct(target))
                luaL_error(state, "df.read_fields: '_target' in '%s' follows something that is not the id of "
                                  "an object", path.c_str());
            auto find = read_find_field((const struct_identity*)target, "find");
            auto fn = find && find->mode == struct_field_info::CLASS_METHOD ?
                      (const function_identity_base*)find->type : nullptr;
            ReadHop hop;
            hop.kind = ReadHop::FIND;
            hop.find = fn;
            hop.id_size = read_integer_size(state, acc.type, hop.id_signed);
            if (!fn || fn->getNumArgs() != 1 || !hop.id_size)
                luaL_error(state, "df.read_fields: '_target' in '%s': %s cannot be looked up by id", path.c_str(),
                           target->getFullName().c_str());
            acc.offsets.push_back(0);
            acc.hops.push_back(hop);
            acc.type = nullptr;
            done = false;
            owner = nullptr;
            value_target = nullptr;
            cur = target;
            settle();
            continue;
        }
        if (done)
        {
            // a step past a value looks the value up in its enum's attributes
            if (!owner || !owner->getAttrs() || !owner->getAttrType())
                luaL_error(state, "df.read_fields: '%s' in '%s' follows a value that has no attributes",
                           part.c_str(), path.c_str());
            auto field = read_find_field(owner->getAttrType(), part);
            if (!field || field->mode != struct_field_info::PRIMITIVE || !field->type || !read_is_value(field->type))
                luaL_error(state, "df.read_fields: no readable attribute '%s' in '%s'", part.c_str(), path.c_str());
            acc.attrs.push_back(ReadAttr{owner, field, 0, false});
            owner = field->type->type() == IDTYPE_ENUM ? (const enum_identity*)field->type : nullptr;
            continue;
        }

        if (where == AT_SEQ)
        {
            if (part == "_size")
            {
                acc.kind = ReadAccessor::SIZE;
                acc.seq = seq;
                where = AT_TYPE;
                done = true;
                owner = nullptr;
                continue;
            }
            int64_t index;
            if (!read_step_index(part, seq.index_enum, index))
                luaL_error(state, "df.read_fields: '%s' in '%s' must be the index of an entry, or '_size'",
                           part.c_str(), path.c_str());
            if (!seq.entry)
                luaL_error(state, "df.read_fields: '%s' goes through an untyped pointer", path.c_str());
            if (index < 0 || (!seq.container && index >= seq.count))
                luaL_error(state, "df.read_fields: '%s' in '%s' is outside the array", part.c_str(), path.c_str());
            if (seq.container)
            {
                ReadHop hop;
                hop.kind = ReadHop::ITEM;
                hop.seq = seq;
                hop.index = int(index);
                acc.offsets.push_back(0);
                acc.hops.push_back(hop);
            }
            else
            {
                acc.offsets.back() += size_t(index) * seq.item_size;
                if (seq.pointers)
                {
                    acc.offsets.push_back(0);
                    acc.hops.push_back(ReadHop());
                }
            }
            cur = seq.entry;
            where = AT_TYPE;
            from_field = nullptr;
            value_target = seq_target;
            seq_target = nullptr;
            settle();
            continue;
        }

        if (where == AT_FLAGS)
        {
            int64_t index;
            if (!read_step_index(part, flags_enum, index) || index < 0 || index > INT_MAX)
                luaL_error(state, "df.read_fields: no flag '%s' in '%s'", part.c_str(), path.c_str());
            acc.kind = ReadAccessor::FLAG;
            acc.flags = flags;
            acc.flag = int(index);
            where = AT_TYPE;
            done = true;
            owner = nullptr;
            continue;
        }

        if (read_is_struct(cur))
        {
            if (part == "_type")
            {
                acc.kind = ReadAccessor::TYPE;
                acc.type = cur;
                done = true;
                owner = nullptr;
                continue;
            }
            auto owner_type = (const struct_identity*)cur;
            std::string field_name = part;
            const struct_identity *narrowed = nullptr;
            size_t colon = field_name.find(':');
            if (colon != std::string::npos)
            {
                // Class:field reads a field of a class derived from the declared one
                std::string class_name = field_name.substr(0, colon);
                field_name = field_name.substr(colon + 1);
                if (cur->type() == IDTYPE_CLASS)
                    narrowed = read_find_subclass(owner_type, class_name);
                if (!narrowed)
                    luaL_error(state, "df.read_fields: '%s' in '%s' does not name a class derived from %s",
                               class_name.c_str(), path.c_str(), cur->getFullName().c_str());
            }
            auto field = read_find_field(narrowed ? narrowed : owner_type, field_name);
            if (!field && !narrowed && cur->type() == IDTYPE_CLASS)
            {
                std::vector<const struct_identity*> found;
                read_find_in_subclasses(owner_type, field_name, found);
                if (found.size() > 1)
                    luaL_error(state, "df.read_fields: several classes derived from %s have a field '%s'; "
                                      "write it as Class:%s in '%s'", cur->getFullName().c_str(),
                               field_name.c_str(), field_name.c_str(), path.c_str());
                if (found.size() == 1)
                {
                    narrowed = found[0];
                    field = read_own_field(narrowed, field_name);
                }
            }
            if (!field)
                luaL_error(state, "df.read_fields: no field '%s' in %s (path '%s')", field_name.c_str(),
                           cur->getFullName().c_str(), path.c_str());
            if (narrowed)
            {
                if (narrowed->type() != IDTYPE_CLASS)
                    luaL_error(state, "df.read_fields: cannot read '%s' in '%s'", part.c_str(), path.c_str());
                acc.checks.push_back(ReadCheck{acc.offsets.size() - 1, acc.offsets.back(),
                                               (const virtual_identity*)narrowed});
            }
            from_field = nullptr;
            if (field->mode == struct_field_info::SUBSTRUCT || field->mode == struct_field_info::CONTAINER)
            {
                tag_field = find_union_tag(narrowed ? narrowed : owner_type, field);
                if (tag_field)
                {
                    tag_offset = ptrdiff_t(tag_field->offset) - ptrdiff_t(field->offset);
                    tag_attr = field->extra ? field->extra->union_tag_attr : nullptr;
                    tag_step = at;
                }
            }
            if (field->mode == struct_field_info::OBJ_METHOD)
                luaL_error(state, "df.read_fields: '%s' in '%s' is a method, which a path cannot call; "
                                  "call it in a function given as {call=...}, or in 'test' or 'each'", field_name.c_str(), path.c_str());
            switch (field->mode)
            {
            case struct_field_info::PRIMITIVE:
            case struct_field_info::SUBSTRUCT:
                if (!field->type)
                    luaL_error(state, "df.read_fields: cannot read '%s' in '%s'", part.c_str(), path.c_str());
                acc.offsets.back() += field->offset;
                cur = field->type;
                value_target = field->extra ? field->extra->ref_target : nullptr;
                seq_target = nullptr;
                settle();
                break;
            case struct_field_info::POINTER:
                if (for_cond && at + 1 == parts.size() && use != USE_GROUP)
                {
                    acc.offsets.back() += field->offset;
                    acc.kind = ReadAccessor::PTR;
                    done = true;
                    owner = nullptr;
                    break;
                }
                if (!field->type || (field->count & (PTRFLAG_IS_ARRAY | PTRFLAG_HAS_BAD_POINTERS)))
                    luaL_error(state, "df.read_fields: cannot follow the pointer '%s' in '%s'", part.c_str(), path.c_str());
                acc.offsets.back() += field->offset;
                acc.offsets.push_back(0);
                acc.hops.push_back(ReadHop());
                cur = field->type;
                value_target = nullptr;
                seq_target = nullptr;
                settle();
                break;
            case struct_field_info::STATIC_ARRAY:
            case struct_field_info::STL_VECTOR_PTR:
            case struct_field_info::CONTAINER:
                acc.offsets.back() += field->offset;
                from_field = field;
                seq_target = field->extra ? field->extra->ref_target : nullptr;
                if (field->mode == struct_field_info::CONTAINER && field->type &&
                    field->type->type() == IDTYPE_BIT_CONTAINER)
                {
                    where = AT_FLAGS;
                    flags = (const df::bit_container_identity*)field->type;
                    flags_enum = field->extra && field->extra->index_enum ? field->extra->index_enum
                                 : (const enum_identity*)flags->getIndexEnumType();
                }
                else if (read_seq_from_field(field, seq))
                    where = AT_SEQ;
                else
                    luaL_error(state, "df.read_fields: cannot read '%s' in '%s'", part.c_str(), path.c_str());
                break;
            case struct_field_info::STATIC_STRING:
                if (for_cond || at + 1 != parts.size())
                    luaL_error(state, "df.read_fields: '%s' in '%s' is a fixed piece of text, which can only be "
                                      "handed back", part.c_str(), path.c_str());
                acc.offsets.back() += field->offset;
                acc.kind = ReadAccessor::REF;
                acc.ref_field = field;
                done = true;
                owner = nullptr;
                break;
            default:
                luaL_error(state, "df.read_fields: '%s' in '%s' is not something that can be read",
                           part.c_str(), path.c_str());
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
                    luaL_error(state, "df.read_fields: no flag '%s' in '%s'", part.c_str(), path.c_str());
                acc.kind = ReadAccessor::BIT;
                acc.bit = bit;
                acc.bit_size = std::max(1, bits->getBits()[bit].size);
            }
            done = true;
            owner = nullptr;
        }
        else
            luaL_error(state, "df.read_fields: '%s' in '%s' follows something that has no fields",
                       part.c_str(), path.c_str());
    }

    if (use == USE_GROUP)
    {
        if (done || where != AT_SEQ)
            luaL_error(state, "df.read_fields: '%s' is not a container or an array, which 'any' and 'all' need",
                       path.c_str());
        if (!seq.entry)
            luaL_error(state, "df.read_fields: '%s' holds untyped pointers", path.c_str());
        acc.kind = ReadAccessor::GROUP;
        acc.seq = seq;
        acc.seq_target = seq_target;
    }
    else if (!done)
    {
        if (where == AT_TYPE && cur->type() == IDTYPE_BITFIELD)
        {
            acc.kind = ReadAccessor::WHOLE;
            acc.whole_size = cur->byte_size();
        }
        else if (for_cond)
            luaL_error(state, "df.read_fields: '%s' is not a single value; name one of its fields", path.c_str());
        else if (where != AT_TYPE || read_is_struct(cur))
        {
            // handed back as Lua reads it: a reference to the structure, the container or the array
            acc.kind = ReadAccessor::REF;
            acc.ref_field = from_field;
            acc.type = cur;
            if (tag_field && tag_step + 1 == parts.size())
            {
                acc.tag_field = tag_field;
                acc.tag_offset = tag_offset;
                acc.tag_attr = tag_attr;
            }
        }
        else
            luaL_error(state, "df.read_fields: '%s' is not something that can be read", path.c_str());
    }

    // How the value lies in memory. Conditions on integers and flags are the common case and take
    // a shorter way.
    bool attrs_native = true;
    for (ReadAttr &attr : acc.attrs)
    {
        attr.leaf = read_classify(state, attr.field->type, attr.size, attr.is_signed);
        if (attr.leaf != LEAF_INT)
            attrs_native = false;
    }
    if (acc.kind == ReadAccessor::VALUE)
        acc.value_leaf = read_classify(state, acc.type, acc.value_size, acc.value_signed);
    if (!acc.attrs.empty())
        acc.leaf = acc.attrs.back().leaf;
    else switch (acc.kind)
    {
    case ReadAccessor::VALUE: acc.leaf = acc.value_leaf; break;
    case ReadAccessor::BIT:   acc.leaf = acc.bit_size <= 1 ? LEAF_BOOL : LEAF_INT; break;
    case ReadAccessor::WHOLE: acc.leaf = LEAF_INT; break;
    case ReadAccessor::FLAG:  acc.leaf = LEAF_BOOL; break;
    case ReadAccessor::SIZE:  acc.leaf = LEAF_INT; break;
    default:                  acc.leaf = LEAF_OTHER;
    }
    if (!attrs_native)
        acc.native = ReadAccessor::NOT_NATIVE;
    else if (acc.kind == ReadAccessor::VALUE && acc.value_leaf == LEAF_INT)
        acc.native = ReadAccessor::NATIVE_INT;
    else if (acc.kind == ReadAccessor::WHOLE || (acc.kind == ReadAccessor::BIT && acc.bit_size > 1))
        acc.native = ReadAccessor::NATIVE_INT;
    else if (acc.kind == ReadAccessor::BIT)
        acc.native = ReadAccessor::NATIVE_BOOL;
    else
        acc.native = ReadAccessor::NOT_NATIVE;

    plan.accessors.push_back(acc);
    return plan.accessors.size() - 1;
}

int64_t read_integer_at(const uint8_t *ptr, size_t size, bool is_signed)
{
    switch (size)
    {
    case 1: return is_signed ? int64_t(*(const int8_t*)ptr) : int64_t(*ptr);
    case 2: { uint16_t v; memcpy(&v, ptr, 2); return is_signed ? int64_t(int16_t(v)) : int64_t(v); }
    case 4: { uint32_t v; memcpy(&v, ptr, 4); return is_signed ? int64_t(int32_t(v)) : int64_t(v); }
    default: { int64_t v; memcpy(&v, ptr, 8); return v; }
    }
}

// Where the path ends in memory, or null when a null pointer or an object of another class is in
// the way.
uint8_t *read_reach(lua_State *state, const ReadAccessor &acc, const std::vector<uint8_t*> &bases)
{
    uint8_t *ptr = bases[acc.source];
    size_t check = 0;
    for (size_t i = 0; i < acc.offsets.size(); i++)
    {
        if (i > 0)
        {
            const ReadHop &hop = acc.hops[i];
            if (hop.kind == ReadHop::PTR)
                ptr = *(uint8_t**)ptr;
            else if (hop.kind == ReadHop::FIND)
            {
                lua_pushinteger(state, lua_Integer(read_integer_at(ptr, hop.id_size, hop.id_signed)));
                read_invoke(state, hop.find, lua_gettop(state));
                ptr = lua_type(state, -1) == LUA_TUSERDATA ? (uint8_t*)get_object_ref(state, -1) : nullptr;
                lua_pop(state, 2);
            }
            else if (hop.index >= read_seq_count(hop.seq, ptr))
                return nullptr;
            else
                ptr = read_seq_entry(hop.seq, ptr, hop.index);
        }
        if (!ptr)
            return nullptr;
        for (; check < acc.checks.size() && acc.checks[check].segment == i; check++)
            if (!acc.checks[check].cls->is_instance(virtual_ptr(ptr + acc.checks[check].offset)))
                return nullptr;
        ptr += acc.offsets[i];
    }
    return ptr;
}

// One flag of a flag array, or false with ok unset when the array is too short to hold it.
inline bool read_flag(const ReadAccessor &acc, const uint8_t *ptr, bool &ok)
{
    int count = acc.flags->raw_read_count((void*)ptr);
    ok = count < 0 || acc.flag < count;
    return ok && acc.flags->raw_item_bit((void*)ptr, acc.flag);
}

// The type an object really is, which for a class is found through its vtable.
inline const type_identity *read_dynamic_type(const ReadAccessor &acc, const uint8_t *ptr)
{
    if (acc.type->type() == IDTYPE_CLASS)
        if (auto cls = virtual_identity::get(virtual_ptr(ptr)))
            return cls;
    return acc.type;
}

// The row of an enum's attribute table that belongs to a value; out-of-range values read the
// default row, as enum.attrs[] does.
const uint8_t *read_attr_row(const ReadAttr &attr, int64_t idx)
{
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
    return (const uint8_t*)attr.owner->getAttrs() + attr.owner->getAttrType()->byte_size() * size_t(idx);
}

void read_scalar_at(const uint8_t *ptr, ReadLeaf leaf, size_t size, bool is_signed, ReadScalar &out)
{
    switch (leaf)
    {
    case LEAF_INT:
        out.kind = ReadScalar::INT;
        out.i = read_integer_at(ptr, size, is_signed);
        break;
    case LEAF_BOOL:
        out.kind = ReadScalar::BOOL;
        out.b = *(const bool*)ptr;
        break;
    case LEAF_FLOAT:
    {
        float v;
        memcpy(&v, ptr, sizeof(v));
        out.kind = ReadScalar::FLOAT;
        out.f = double(v);
        break;
    }
    case LEAF_DOUBLE:
        out.kind = ReadScalar::FLOAT;
        memcpy(&out.f, ptr, sizeof(out.f));
        break;
    case LEAF_STRING:
    {
        auto text = (const std::string*)ptr;
        out.kind = ReadScalar::STRING;
        out.s = text->c_str();
        out.len = text->size();
        break;
    }
    case LEAF_CSTRING:
    {
        const char *text = *(const char* const*)ptr;
        out.kind = text ? ReadScalar::STRING : ReadScalar::NIL;
        out.s = text;
        out.len = text ? strlen(text) : 0;
        break;
    }
    default:
        out.kind = ReadScalar::OTHER;
    }
}

bool read_push(lua_State *state, const ReadAccessor &acc, const std::vector<uint8_t*> &bases, lua_Integer index);
void read_scalar_from_lua(lua_State *state, int idx, ReadScalar &out);

// Calls the function of a CALL accessor with what its arguments read for the entry, and leaves the
// one value it gives back on the stack. Returns false, having pushed nil and called nothing, when
// one of the arguments could not be reached.
bool read_call(lua_State *state, const ReadAccessor &acc, const std::vector<uint8_t*> &bases, lua_Integer index)
{
    const int top = lua_gettop(state);
    luaL_checkstack(state, int(acc.call_args.size()) + 4, "df.read_fields: too many arguments");
    lua_rawgeti(state, read_calls_idx, acc.call);
    for (const ReadAccessor &arg : acc.call_args)
        // text that is not there reads as nil, and is as absent as what cannot be reached
        if (!read_push(state, arg, bases, index) || lua_isnil(state, -1))
        {
            lua_settop(state, top);
            lua_pushnil(state);
            return false;
        }
    // the function may itself read fields
    const int calls_idx = read_calls_idx;
    const lua_Integer place = read_place;
    ReadFrame *const frame = read_frame;
    lua_call(state, int(acc.call_args.size()), 1);
    read_calls_idx = calls_idx;
    read_place = place;
    read_frame = frame;
    // the function may have moved, replaced or removed what is being read, so it is found again
    // before anything else is read from it
    if (frame && frame->refresh && !frame->refresh(frame))
        luaL_error(state, "df.read_fields: an entry was removed during the read");
    return true;
}

// The value at the end of a path, for a condition. Returns false when it could not be reached.
bool read_scalar(lua_State *state, const ReadAccessor &acc, const std::vector<uint8_t*> &bases, lua_Integer index, ReadScalar &out)
{
    if (acc.kind == ReadAccessor::INDEX || acc.kind == ReadAccessor::FROM)
    {
        out.kind = ReadScalar::INT;
        out.i = acc.kind == ReadAccessor::INDEX ? index : read_place;
        return true;
    }
    if (acc.kind == ReadAccessor::CALL)
    {
        const bool called = read_call(state, acc, bases, index);
        const bool nothing = lua_isnil(state, -1);
        read_scalar_from_lua(state, -1, out);
        if (out.kind == ReadScalar::OTHER && !nothing)
            luaL_error(state, "df.read_fields: a call in a condition returned a %s, which conditions "
                              "cannot compare", luaL_typename(state, -1));
        if (out.kind == ReadScalar::STRING)
        {
            // the text goes away with the value on the stack
            out.own.assign(out.s, out.len);
            out.s = out.own.data();
        }
        lua_pop(state, 1);
        return called && !nothing;
    }
    const uint8_t *ptr = read_reach(state, acc, bases);
    if (!ptr)
        return false;

    switch (acc.kind)
    {
    case ReadAccessor::BIT:
    {
        int value = getBitfieldField(ptr, acc.bit, unsigned(acc.bit_size));
        if (acc.bit_size <= 1)
        {
            out.kind = ReadScalar::BOOL;
            out.b = value != 0;
        }
        else
        {
            out.kind = ReadScalar::INT;
            out.i = value;
        }
        break;
    }
    case ReadAccessor::WHOLE:
    {
        size_t whole = 0;
        memcpy(&whole, ptr, std::min(sizeof(whole), acc.whole_size));
        out.kind = ReadScalar::INT;
        out.i = int64_t(lua_Integer(whole));
        break;
    }
    case ReadAccessor::VALUE:
        read_scalar_at(ptr, acc.value_leaf, acc.value_size, acc.value_signed, out);
        break;
    case ReadAccessor::FLAG:
    {
        bool ok;
        out.kind = ReadScalar::BOOL;
        out.b = read_flag(acc, ptr, ok);
        if (!ok)
            return false;
        break;
    }
    case ReadAccessor::SIZE:
        out.kind = ReadScalar::INT;
        out.i = read_seq_count(acc.seq, (uint8_t*)ptr);
        break;
    default:
        return false;
    }

    for (const ReadAttr &attr : acc.attrs)
    {
        if (out.kind != ReadScalar::INT)
            return false;
        read_scalar_at(read_attr_row(attr, out.i) + attr.field->offset, attr.leaf, attr.size, attr.is_signed, out);
    }
    // text that is not there is nil, which passes no comparison
    return out.kind != ReadScalar::NIL;
}

// Compares a whole number with a floating-point one exactly: -1, 0 or 1, or 2 when the float is
// not a number.
int read_cmp_int_float(int64_t i, double f)
{
    if (f != f)
        return 2;
    if (f >= 9223372036854775808.0)
        return -1;
    if (f < -9223372036854775808.0)
        return 1;
    double whole = std::floor(f);
    int64_t fi = int64_t(whole);
    if (i < fi)
        return -1;
    if (i > fi)
        return 1;
    return f > whole ? -1 : 0;
}

// Orders two strings the way Lua does: by the current locale, a chunk at a time where they hold
// zero bytes. Both must end in a zero byte.
int read_cmp_text(const char *l, size_t ll, const char *r, size_t lr)
{
    for (;;)
    {
        int order = strcoll(l, r);
        if (order != 0)
            return order;
        size_t len = strlen(l);
        if (len == lr)
            return len == ll ? 0 : 1;
        if (len == ll)
            return -1;
        len++;
        l += len; ll -= len;
        r += len; lr -= len;
    }
}

// Equality as Lua's rawequal has it: numbers by value whatever their kind, other values only
// against their own kind.
bool read_equal(const ReadScalar &a, const ReadScalar &b)
{
    switch (a.kind)
    {
    case ReadScalar::INT:
        if (b.kind == ReadScalar::INT)
            return a.i == b.i;
        return b.kind == ReadScalar::FLOAT && read_cmp_int_float(a.i, b.f) == 0;
    case ReadScalar::FLOAT:
        if (b.kind == ReadScalar::FLOAT)
            return a.f == b.f;
        return b.kind == ReadScalar::INT && read_cmp_int_float(b.i, a.f) == 0;
    case ReadScalar::BOOL:
        return b.kind == ReadScalar::BOOL && a.b == b.b;
    case ReadScalar::STRING:
        return b.kind == ReadScalar::STRING && a.len == b.len && memcmp(a.s, b.s, a.len) == 0;
    default:
        return false;
    }
}

// a < b, or a <= b. Values of different kinds are never in order; numbers of either kind are.
bool read_less(const ReadScalar &a, const ReadScalar &b, bool or_equal)
{
    int order;
    if (a.kind == ReadScalar::INT && b.kind == ReadScalar::INT)
        order = a.i < b.i ? -1 : a.i > b.i ? 1 : 0;
    else if (a.kind == ReadScalar::INT && b.kind == ReadScalar::FLOAT)
        order = read_cmp_int_float(a.i, b.f);
    else if (a.kind == ReadScalar::FLOAT && b.kind == ReadScalar::INT)
    {
        order = read_cmp_int_float(b.i, a.f);
        if (order != 2)
            order = -order;
    }
    else if (a.kind == ReadScalar::FLOAT && b.kind == ReadScalar::FLOAT)
        return or_equal ? a.f <= b.f : a.f < b.f;
    else if (a.kind == ReadScalar::STRING && b.kind == ReadScalar::STRING)
        order = read_cmp_text(a.s, a.len, b.s, b.len);
    else
        return false;
    return order == 2 ? false : or_equal ? order <= 0 : order < 0;
}

// The value of a Lua number or string, as a condition compares against it.
void read_scalar_from_lua(lua_State *state, int idx, ReadScalar &out)
{
    switch (lua_type(state, idx))
    {
    case LUA_TNUMBER:
        if (lua_isinteger(state, idx))
        {
            out.kind = ReadScalar::INT;
            out.i = lua_tointeger(state, idx);
        }
        else
        {
            out.kind = ReadScalar::FLOAT;
            out.f = lua_tonumber(state, idx);
        }
        break;
    case LUA_TBOOLEAN:
        out.kind = ReadScalar::BOOL;
        out.b = lua_toboolean(state, idx) != 0;
        break;
    case LUA_TSTRING:
        out.kind = ReadScalar::STRING;
        out.s = lua_tolstring(state, idx, &out.len);
        break;
    default:
        out.kind = ReadScalar::OTHER;
    }
}

// Whether a float is a whole number that fits an integer, which is how Lua files it as a table key.
bool read_float_is_int(double f, int64_t &i)
{
    if (!(f >= -9223372036854775808.0 && f < 9223372036854775808.0) || std::floor(f) != f)
        return false;
    i = int64_t(f);
    return true;
}

// A whole number against the value of a condition whose native flag is set.
inline bool read_compare(const ReadCond &cond, int64_t value)
{
    if (cond.op == LUA_OPEQ)
        return (value == cond.native_value) != cond.negate;
    if (cond.op == LUA_OPLT)
        return cond.swap ? cond.native_value < value : value < cond.native_value;
    return cond.swap ? cond.native_value <= value : value <= cond.native_value;
}

// Sets up the short way for a condition, when its value is a whole number or a flag held in the
// entry itself. What the general way would answer is unchanged.
void read_make_fast(const ReadPlan &plan, ReadCond &cond)
{
    const size_t table_limit = 4096;
    if ((cond.kind != ReadCond::CMP && cond.kind != ReadCond::IN) || !cond.native)
        return;
    const ReadAccessor &acc = plan.accessors[cond.accessor];
    if (!acc.checks.empty())
        return;

    ReadFast fast;
    fast.source = acc.source;
    if (acc.kind == ReadAccessor::INDEX)
        fast.index = true;
    else
    {
        if (acc.offsets.size() != 1)
            return;
        fast.offset = acc.offsets[0];
        if (acc.kind == ReadAccessor::VALUE)
        {
            fast.size = acc.value_size;
            fast.is_signed = acc.value_signed;
        }
        else if (acc.kind == ReadAccessor::BIT)
        {
            // the same bytes getBitfieldField reads
            unsigned size = unsigned(acc.bit_size);
            unsigned shift = acc.bit % 8;
            if (size + shift > 31)
                return;
            uint32_t mask = ((uint32_t(1) << size) - 1) << shift;
            fast.offset += acc.bit / 8;
            fast.size = !(mask & ~0xFFU) ? 1 : !(mask & ~0xFFFFU) ? 2 : 4;
            fast.shift = shift;
            fast.mask = (uint64_t(1) << size) - 1;
        }
        else if (acc.kind == ReadAccessor::WHOLE)
        {
            if (acc.whole_size != 1 && acc.whole_size != 2 && acc.whole_size != 4 && acc.whole_size != 8)
                return;
            fast.size = acc.whole_size;
        }
        else
            return;
    }

    if (!acc.attrs.empty())
    {
        // an attribute of an enum value: work the answer out for every value the enum has
        for (const ReadAttr &attr : acc.attrs)
            if (attr.owner->getComplex())
                return;
        int64_t first = acc.attrs[0].owner->getFirstItem(), last = acc.attrs[0].owner->getLastItem();
        if (last < first || uint64_t(last - first) >= table_limit)
            return;
        auto passes = [&acc, &cond](int64_t value) {
            for (const ReadAttr &attr : acc.attrs)
                value = read_integer_at(read_attr_row(attr, value) + attr.field->offset, attr.size, attr.is_signed);
            if (cond.kind == ReadCond::IN)
                return std::binary_search(cond.native_set.begin(), cond.native_set.end(), value);
            return read_compare(cond, value);
        };
        fast.first = first;
        fast.table.resize(size_t(last - first) + 1);
        for (int64_t value = first; value <= last; value++)
            fast.table[size_t(value - first)] = passes(value);
        fast.otherwise = passes(last + 1);
        fast.kind = ReadFast::TABLE;
    }
    else if (cond.kind == ReadCond::IN)
    {
        const std::vector<int64_t> &set = cond.native_set;
        if (set.empty())
            fast.kind = ReadFast::TABLE;
        else if (uint64_t(set.back()) - uint64_t(set.front()) < table_limit)
        {
            fast.first = set.front();
            fast.table.resize(size_t(uint64_t(set.back()) - uint64_t(set.front())) + 1);
            for (int64_t value : set)
                fast.table[size_t(uint64_t(value) - uint64_t(set.front()))] = 1;
            fast.kind = ReadFast::TABLE;
        }
        else
            fast.kind = ReadFast::SET;
    }
    else
        fast.kind = ReadFast::COMPARE;
    cond.fast = std::move(fast);
}

// The value read_push would push, for an accessor that is NATIVE_INT or NATIVE_BOOL. Returns false
// where read_push would: when the value could not be reached.
bool read_native(lua_State *state, const ReadAccessor &acc, const std::vector<uint8_t*> &bases, lua_Integer index, int64_t &value)
{
    if (acc.kind == ReadAccessor::INDEX || acc.kind == ReadAccessor::FROM)
    {
        value = acc.kind == ReadAccessor::INDEX ? index : read_place;
        return true;
    }

    const uint8_t *ptr = read_reach(state, acc, bases);
    if (!ptr)
        return false;

    switch (acc.kind)
    {
    case ReadAccessor::BIT:
        value = getBitfieldField(ptr, acc.bit, unsigned(acc.bit_size));
        if (acc.bit_size <= 1)
            value = value != 0;
        break;
    case ReadAccessor::WHOLE:
    {
        size_t whole = 0;
        memcpy(&whole, ptr, std::min(sizeof(whole), acc.whole_size));
        value = int64_t(lua_Integer(whole));
        break;
    }
    default:
        value = read_integer_at(ptr, acc.value_size, acc.value_signed);
    }

    for (const ReadAttr &attr : acc.attrs)
        value = read_integer_at(read_attr_row(attr, value) + attr.field->offset, attr.size, attr.is_signed);
    return true;
}

// Pushes exactly one value. Returns false, having pushed nil, when the value could not be reached.
bool read_push(lua_State *state, const ReadAccessor &acc, const std::vector<uint8_t*> &bases, lua_Integer index)
{
    if (acc.kind == ReadAccessor::INDEX || acc.kind == ReadAccessor::FROM)
    {
        lua_pushinteger(state, acc.kind == ReadAccessor::INDEX ? index : read_place);
        return true;
    }
    if (acc.kind == ReadAccessor::CALL)
        return read_call(state, acc, bases, index);

    uint8_t *ptr = read_reach(state, acc, bases);
    if (!ptr)
    {
        lua_pushnil(state);
        return false;
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
    case ReadAccessor::FLAG:
    {
        bool ok;
        bool value = read_flag(acc, ptr, ok);
        if (!ok)
        {
            lua_pushnil(state);
            return false;
        }
        lua_pushboolean(state, value);
        break;
    }
    case ReadAccessor::SIZE:
        lua_pushinteger(state, read_seq_count(acc.seq, ptr));
        break;
    case ReadAccessor::TYPE:
        LookupInTable(state, read_dynamic_type(acc, ptr), &DFHACK_TYPEID_TABLE_TOKEN);
        break;
    case ReadAccessor::REF:
        if (acc.ref_field)
            push_field_value(state, acc.ref_field, ptr);
        else
            acc.type->lua_read(state, 0, ptr);
        if (acc.tag_field && lua_type(state, -1) == LUA_TUSERDATA)
        {
            // as when Lua reads the field: the reference knows which member of the union is in use
            auto header = get_object_ref_header(state, -1);
            header->tag_ptr = ptr + acc.tag_offset;
            header->tag_identity = acc.tag_field->type;
            header->tag_attr = acc.tag_attr;
        }
        break;
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

// The identity of the DF object or type at idx, or null when it is neither. Raises no errors.
const type_identity *read_peek_identity(lua_State *state, int idx)
{
    int kind = lua_type(state, idx);
    if (kind != LUA_TUSERDATA && kind != LUA_TTABLE)
        return nullptr;
    if (!lua_getmetatable(state, idx))
        return nullptr;
    lua_rawgetp(state, -1, &DFHACK_IDENTITY_FIELD_TOKEN);
    auto id = (const type_identity*)lua_touserdata(state, -1);
    lua_pop(state, 2);
    return id;
}

bool read_derives(const type_identity *type, const type_identity *base)
{
    if (!read_is_struct(type))
        return false;
    for (auto cur = (const struct_identity*)type; cur; cur = cur->getParent())
        if (cur == base)
            return true;
    return false;
}

// Adds one value to the lists an 'in' condition looks through.
void read_add_to_set(lua_State *state, ReadCond &cond, int idx)
{
    ReadScalar item;
    read_scalar_from_lua(state, idx, item);
    int64_t whole;
    if (item.kind == ReadScalar::INT)
        cond.native_set.push_back(item.i);
    else if (item.kind == ReadScalar::FLOAT && read_float_is_int(item.f, whole))
        cond.native_set.push_back(whole);
    else if (item.kind == ReadScalar::FLOAT && item.f == item.f)
        cond.float_set.push_back(item.f);
    else if (item.kind == ReadScalar::BOOL)
        (item.b ? cond.has_true : cond.has_false) = true;
    else if (item.kind == ReadScalar::STRING)
        cond.text_set.emplace_back(item.s, item.len);
}

// Sets up {call=function, args={'path', ...}}: a value that is not read but worked out, by a function
// that is handed what the paths read for the entry, or the entry itself when no paths are given.
// allow_as says the table may also hold 'as', which the fields option gives a name with.
size_t read_compile_call(lua_State *state, ReadPlan &plan, int spec_idx, bool allow_as)
{
    luaL_checkstack(state, 10, "df.read_fields");
    lua_pushnil(state);
    while (lua_next(state, spec_idx))
    {
        lua_pop(state, 1);
        const char *key = lua_type(state, -1) == LUA_TSTRING ? lua_tostring(state, -1) : "";
        if (strcmp(key, "call") && strcmp(key, "args") && (!allow_as || strcmp(key, "as")))
            luaL_error(state, allow_as ? "df.read_fields: a call must be {call=function, args={'path', ...}, as='name'}"
                                       : "df.read_fields: a call must be {call=function, args={'path', ...}}");
    }
    ReadAccessor acc;
    acc.kind = ReadAccessor::CALL;
    acc.leaf = LEAF_DYNAMIC;
    lua_getfield(state, spec_idx, "call");
    if (!lua_isfunction(state, -1))
        luaL_error(state, "df.read_fields: 'call' must be a function");
    acc.call = int(lua_rawlen(state, read_setup_calls_idx)) + 1;
    lua_rawseti(state, read_setup_calls_idx, acc.call);

    lua_getfield(state, spec_idx, "args");
    if (lua_isnil(state, -1))
    {
        if (plan.named)
            luaL_error(state, "df.read_fields: a call on named containers needs args, the paths of what "
                              "the function is given");
        size_t arg = read_compile(state, plan, "_value");
        acc.call_args.push_back(plan.accessors[arg]);
    }
    else
    {
        if (!lua_istable(state, -1))
            luaL_error(state, "df.read_fields: the args of a call must be a list of paths");
        int count = int(lua_rawlen(state, -1));
        if (count > 16)
            luaL_error(state, "df.read_fields: a call can be given 16 values at most");
        for (int i = 1; i <= count; i++)
        {
            lua_rawgeti(state, -1, i);
            if (lua_type(state, -1) != LUA_TSTRING)
                luaL_error(state, "df.read_fields: the args of a call must be a list of paths");
            size_t arg = read_compile(state, plan, lua_tostring(state, -1));
            acc.call_args.push_back(plan.accessors[arg]);
            lua_pop(state, 1);
        }
    }
    lua_pop(state, 1);
    plan.accessors.push_back(acc);
    return plan.accessors.size() - 1;
}

size_t read_parse_cond(lua_State *state, ReadPlan &plan, int idx, int depth)
{
    if (depth > 32)
        luaL_error(state, "df.read_fields: conditions are nested too deeply");
    luaL_checkstack(state, 10, "df.read_fields: conditions are nested too deeply");
    if (!lua_istable(state, idx))
        luaL_error(state, "df.read_fields: each condition must be a table");

    ReadCond cond;
    lua_rawgeti(state, idx, 1);
    lua_rawgeti(state, idx, 2);
    // stack: [head, second]
    const bool head_is_call = lua_istable(state, -2);
    if (lua_type(state, -2) != LUA_TSTRING && !head_is_call)
        luaL_error(state, "df.read_fields: a condition must start with a field name, a call, 'and', 'or' or 'not'");
    std::string head = head_is_call ? "a call" : lua_tostring(state, -2);

    if (!head_is_call &&
        ((lua_istable(state, -1) && (head == "and" || head == "or" || head == "not")) ||
         (lua_isnil(state, -1) && (head == "and" || head == "or"))))
    {
        cond.kind = head == "and" ? ReadCond::AND : head == "or" ? ReadCond::OR : ReadCond::NOT;
        int count = int(lua_rawlen(state, idx));
        if (cond.kind == ReadCond::NOT && count != 2)
            luaL_error(state, "df.read_fields: 'not' takes exactly one condition");
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
            luaL_error(state, "df.read_fields: the condition on '%s' has no comparison", head.c_str());
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
        else if (op == "in" || op == "in_keys")
        {
            ordered = false;
            cond.kind = ReadCond::IN;
        }
        else if (op == "startswith" || op == "endswith" || op == "contains" ||
                 op == "istartswith" || op == "iendswith" || op == "icontains")
        {
            ordered = false;
            cond.kind = ReadCond::TEXT;
            cond.fold = op[0] == 'i';
            const std::string plain = cond.fold ? op.substr(1) : op;
            cond.text_op = plain == "startswith" ? ReadCond::STARTS : plain == "endswith" ? ReadCond::ENDS : ReadCond::CONTAINS;
        }
        else if (op == "any" || op == "all")
        {
            ordered = false;
            cond.kind = op == "any" ? ReadCond::ANY : ReadCond::ALL;
        }
        else if (op == "is_instance")
        {
            ordered = false;
            cond.kind = ReadCond::TYPEIS;
        }
        else
            luaL_error(state, "df.read_fields: unknown comparison '%s' on '%s'", op.c_str(), head.c_str());

        const bool group = cond.kind == ReadCond::ANY || cond.kind == ReadCond::ALL;
        if (head_is_call)
        {
            if (group)
                luaL_error(state, "df.read_fields: '%s' needs a container or an array, not a call", op.c_str());
            lua_rawgeti(state, idx, 1);
            cond.accessor = read_compile_call(state, plan, lua_gettop(state), false);
            lua_pop(state, 1);
        }
        else
        cond.accessor = read_compile(state, plan, head, group ? USE_GROUP : USE_COND);
        // a copy, as compiling another path moves the accessors
        const ReadAccessor acc = plan.accessors[cond.accessor];

        lua_rawgeti(state, idx, 3);
        // stack: [value]
        if (group)
        {
            // the conditions are set up as a read of the entries of the container
            if (!lua_istable(state, -1))
                luaL_error(state, "df.read_fields: '%s' on '%s' needs a list of conditions", op.c_str(), head.c_str());
            int list_idx = lua_gettop(state);
            ReadPlan sub;
            sub.is_sub = true;
            ReadSource entries;
            entries.leaf = acc.seq.entry;
            entries.ref_target = acc.seq_target;
            sub.sources.push_back(entries);
            ReadCond all;
            int count = int(lua_rawlen(state, list_idx));
            for (int i = 1; i <= count; i++)
            {
                lua_rawgeti(state, list_idx, i);
                all.kids.push_back(read_parse_cond(state, sub, lua_gettop(state), depth + 1));
                lua_pop(state, 1);
            }
            sub.conds.push_back(all);
            sub.root = sub.conds.size() - 1;
            plan.subs.push_back(std::move(sub));
            cond.sub = plan.subs.size() - 1;
        }
        else if (acc.kind == ReadAccessor::TYPE)
        {
            if (cond.kind == ReadCond::CMP && !ordered)
                cond.exact = true;
            else if (cond.kind != ReadCond::TYPEIS)
                luaL_error(state, "df.read_fields: '%s' is a type, which can only be tested with ==, ~= or "
                                  "is_instance", head.c_str());
            auto wanted = lua_istable(state, -1) ? read_peek_identity(state, -1) : nullptr;
            if (!wanted || !read_is_struct(wanted))
                luaL_error(state, "df.read_fields: the condition on '%s' needs a type, such as df.unit", head.c_str());
            cond.kind = ReadCond::TYPEIS;
            cond.wanted = (const struct_identity*)wanted;
        }
        else if (cond.kind == ReadCond::TYPEIS)
            luaL_error(state, "df.read_fields: is_instance needs a path that ends in '_type', which '%s' does not",
                       head.c_str());
        else if (acc.kind == ReadAccessor::PTR)
        {
            if (cond.kind != ReadCond::CMP || ordered)
                luaL_error(state, "df.read_fields: '%s' is a pointer, which can only be compared with df.NULL "
                                  "or an object, using == or ~=", head.c_str());
            if (lua_type(state, -1) == LUA_TLIGHTUSERDATA && lua_touserdata(state, -1) == nullptr)
                cond.kind = ReadCond::ISNULL;
            else if (lua_type(state, -1) == LUA_TUSERDATA && read_peek_identity(state, -1))
            {
                cond.kind = ReadCond::PTREQ;
                cond.address = get_object_ref(state, lua_gettop(state));
            }
            else
                luaL_error(state, "df.read_fields: '%s' is a pointer, which can only be compared with df.NULL "
                                  "or an object, using == or ~=", head.c_str());
        }
        else if (acc.leaf == LEAF_OTHER)
            luaL_error(state, "df.read_fields: '%s' holds a kind of value that conditions cannot compare", head.c_str());
        else if (cond.kind == ReadCond::TEXT)
        {
            if ((acc.leaf != LEAF_STRING && acc.leaf != LEAF_CSTRING && acc.leaf != LEAF_DYNAMIC) ||
                lua_type(state, -1) != LUA_TSTRING)
                luaL_error(state, "df.read_fields: '%s' on '%s' needs a field that holds text, and text to look for",
                           op.c_str(), head.c_str());
            size_t len;
            const char *text = lua_tolstring(state, -1, &len);
            cond.text.assign(text, len);
            if (cond.fold)
                for (char &c : cond.text)
                    if (c >= 'A' && c <= 'Z')
                        c = char(c - 'A' + 'a');
        }
        else if (cond.kind == ReadCond::IN)
        {
            if (!lua_istable(state, -1))
                luaL_error(state, op == "in" ? "df.read_fields: '%s' on '%s' needs a list of values"
                                             : "df.read_fields: '%s' on '%s' needs a table with the values as keys",
                           op.c_str(), head.c_str());
            if (op == "in_keys")
            {
                // a set as Lua code keeps one: the values are the keys that are not set to false
                int set_idx = lua_gettop(state);
                lua_pushnil(state);
                while (lua_next(state, set_idx))
                {
                    if (lua_toboolean(state, -1))
                        read_add_to_set(state, cond, lua_gettop(state) - 1);
                    lua_pop(state, 1);
                }
            }
            else
            {
                int count = int(lua_rawlen(state, -1));
                for (int i = 1; i <= count; i++)
                {
                    lua_rawgeti(state, -1, i);
                    read_add_to_set(state, cond, lua_gettop(state));
                    lua_pop(state, 1);
                }
            }
            std::sort(cond.native_set.begin(), cond.native_set.end());
            std::sort(cond.float_set.begin(), cond.float_set.end());
            std::sort(cond.text_set.begin(), cond.text_set.end());
            cond.native = acc.native == ReadAccessor::NATIVE_INT;
        }
        else if (lua_istable(state, -1) && (lua_pushliteral(state, "field"), lua_rawget(state, -2), true) &&
                 (lua_type(state, -1) == LUA_TSTRING || (lua_pop(state, 1), false)))
        {
            // {field='path'} compares with another field of the same entry
            std::string other = lua_tostring(state, -1);
            lua_pop(state, 1);
            cond.accessor2 = read_compile(state, plan, other, USE_COND);
            const ReadAccessor &acc2 = plan.accessors[cond.accessor2];
            if (acc2.kind == ReadAccessor::PTR || acc2.leaf == LEAF_OTHER)
                luaL_error(state, "df.read_fields: '%s' holds a kind of value that conditions cannot compare",
                           other.c_str());
            cond.kind = ReadCond::CMP2;
        }
        else
        {
            if (lua_istable(state, -1))
                luaL_error(state, "df.read_fields: the condition on '%s' has no usable value; a table must be "
                                  "{field='path'}", head.c_str());
            if (ordered ? !(lua_type(state, -1) == LUA_TNUMBER || lua_type(state, -1) == LUA_TSTRING)
                        : lua_isnil(state, -1))
                luaL_error(state, "df.read_fields: the condition on '%s' has no usable value", head.c_str());
            ReadScalar value;
            read_scalar_from_lua(state, -1, value);
            cond.value_kind = value.kind;
            cond.native_value = value.kind == ReadScalar::BOOL ? int64_t(value.b) : value.i;
            cond.float_value = value.f;
            if (value.kind == ReadScalar::STRING)
                cond.text.assign(value.s, value.len);
            // whole numbers against whole numbers, and flags against true or false, take a shorter way
            cond.native = (acc.native == ReadAccessor::NATIVE_INT && value.kind == ReadScalar::INT) ||
                          (acc.native == ReadAccessor::NATIVE_BOOL && value.kind == ReadScalar::BOOL && !ordered);
        }
        lua_pop(state, 1);
    }

    read_make_fast(plan, cond);
    plan.conds.push_back(cond);
    return plan.conds.size() - 1;
}

bool read_test(lua_State *state, const ReadPlan &plan, size_t node, const std::vector<uint8_t*> &bases, lua_Integer index)
{
    const ReadCond &cond = plan.conds[node];
    if (cond.fast.kind != ReadFast::NONE)
    {
        const ReadFast &fast = cond.fast;
        int64_t value = index;
        if (!fast.index)
        {
            value = read_integer_at(bases[fast.source] + fast.offset, fast.size, fast.is_signed);
            if (fast.mask)
                value = int64_t((uint64_t(value) >> fast.shift) & fast.mask);
        }
        if (fast.kind == ReadFast::COMPARE)
            return read_compare(cond, value);
        if (fast.kind == ReadFast::SET)
            return std::binary_search(cond.native_set.begin(), cond.native_set.end(), value);
        uint64_t at = uint64_t(value) - uint64_t(fast.first);
        return at < fast.table.size() ? fast.table[size_t(at)] != 0 : fast.otherwise;
    }
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
    case ReadCond::ISNULL:
    case ReadCond::PTREQ:
    {
        // false either way when the pointer itself cannot be reached
        const uint8_t *ptr = read_reach(state, plan.accessors[cond.accessor], bases);
        return ptr && (*(void* const*)ptr == cond.address) != cond.negate;
    }
    case ReadCond::TYPEIS:
    {
        const ReadAccessor &acc = plan.accessors[cond.accessor];
        const uint8_t *ptr = read_reach(state, acc, bases);
        if (!ptr)
            return false;
        auto type = read_dynamic_type(acc, ptr);
        return (cond.exact ? type == cond.wanted : read_derives(type, cond.wanted)) != cond.negate;
    }
    case ReadCond::CMP2:
    {
        ReadScalar value, against;
        if (!read_scalar(state, plan.accessors[cond.accessor], bases, index, value) ||
            !read_scalar(state, plan.accessors[cond.accessor2], bases, index, against))
            return false;
        if (cond.op == LUA_OPEQ)
            return read_equal(value, against) != cond.negate;
        return cond.swap ? read_less(against, value, cond.op == LUA_OPLE)
                         : read_less(value, against, cond.op == LUA_OPLE);
    }
    case ReadCond::TEXT:
    {
        ReadScalar value;
        if (!read_scalar(state, plan.accessors[cond.accessor], bases, index, value) || value.kind != ReadScalar::STRING)
            return false;
        std::string folded;
        if (cond.fold)
        {
            folded.assign(value.s, value.len);
            for (char &c : folded)
                if (c >= 'A' && c <= 'Z')
                    c = char(c - 'A' + 'a');
        }
        std::string_view text = cond.fold ? std::string_view(folded) : std::string_view(value.s, value.len);
        std::string_view wanted(cond.text);
        if (cond.text_op == ReadCond::STARTS)
            return text.substr(0, wanted.size()) == wanted;
        if (cond.text_op == ReadCond::ENDS)
            return text.size() >= wanted.size() && text.substr(text.size() - wanted.size()) == wanted;
        return text.find(wanted) != std::string_view::npos;
    }
    case ReadCond::ANY:
    case ReadCond::ALL:
    {
        // an entry that is a null pointer is passed over, as a read passes over one
        const ReadAccessor &acc = plan.accessors[cond.accessor];
        uint8_t *ptr = read_reach(state, acc, bases);
        if (!ptr)
            return false;
        const ReadPlan &sub = plan.subs[cond.sub];
        const bool any = cond.kind == ReadCond::ANY;
        std::vector<uint8_t*> entry(1);
        int count = read_seq_count(acc.seq, ptr);
        int i = 0;
        // After a function was called for one of the entries: finds the entry again.
        struct Inner {
            lua_State *state; const ReadAccessor &acc; const std::vector<uint8_t*> &bases;
            std::vector<uint8_t*> &entry; uint8_t *&ptr; int &count; int &i;
        } inner{state, acc, bases, entry, ptr, count, i};
        ReadFrame frame;
        frame.parent = read_frame;
        frame.ctx = &inner;
        frame.refresh = [](ReadFrame *self) {
            if (self->parent && self->parent->refresh && !self->parent->refresh(self->parent))
                return false;
            Inner &in = *(Inner*)self->ctx;
            in.ptr = read_reach(in.state, in.acc, in.bases);
            if (!in.ptr)
                return false;
            if (read_seq_count(in.acc.seq, in.ptr) != in.count)
                luaL_error(in.state, "df.read_fields: a container changed size during the read");
            in.entry[0] = read_seq_entry(in.acc.seq, in.ptr, in.i);
            return in.entry[0] != nullptr;
        };
        bool result = !any;
        read_frame = &frame;
        for (; i < count; i++)
        {
            entry[0] = read_seq_entry(acc.seq, ptr, i);
            if (entry[0] && read_test(state, sub, sub.root, entry, i) == any)
            {
                result = any;
                break;
            }
        }
        read_frame = frame.parent;
        return result;
    }
    case ReadCond::IN:
    {
        if (cond.native)
        {
            int64_t value;
            return read_native(state, plan.accessors[cond.accessor], bases, index, value) &&
                   std::binary_search(cond.native_set.begin(), cond.native_set.end(), value);
        }
        ReadScalar value;
        if (!read_scalar(state, plan.accessors[cond.accessor], bases, index, value))
            return false;
        int64_t whole;
        switch (value.kind)
        {
        case ReadScalar::INT:
            return std::binary_search(cond.native_set.begin(), cond.native_set.end(), value.i);
        case ReadScalar::FLOAT:
            if (read_float_is_int(value.f, whole))
                return std::binary_search(cond.native_set.begin(), cond.native_set.end(), whole);
            return value.f == value.f && std::binary_search(cond.float_set.begin(), cond.float_set.end(), value.f);
        case ReadScalar::BOOL:
            return value.b ? cond.has_true : cond.has_false;
        case ReadScalar::STRING:
        {
            std::string_view text(value.s, value.len);
            auto it = std::lower_bound(cond.text_set.begin(), cond.text_set.end(), text,
                [](const std::string &entry, const std::string_view &wanted) { return std::string_view(entry) < wanted; });
            return it != cond.text_set.end() && std::string_view(*it) == text;
        }
        default:
            return false;
        }
    }
    default:
    {
        if (cond.native)
        {
            int64_t value;
            if (!read_native(state, plan.accessors[cond.accessor], bases, index, value))
                return false;
            return read_compare(cond, value);
        }
        ReadScalar value, against;
        if (!read_scalar(state, plan.accessors[cond.accessor], bases, index, value))
            return false;
        against.kind = cond.value_kind;
        against.i = cond.native_value;
        against.f = cond.float_value;
        against.b = cond.native_value != 0;
        against.s = cond.text.c_str();
        against.len = cond.text.size();
        if (cond.op == LUA_OPEQ)
            return read_equal(value, against) != cond.negate;
        return cond.swap ? read_less(against, value, cond.op == LUA_OPLE)
                         : read_less(value, against, cond.op == LUA_OPLE);
    }
    }
}

}

namespace {

// What a call was given to read from.
enum ReadFrom { READ_ONE, READ_LIST, READ_NOTHING };

ReadFrom read_from(lua_State *state, int idx)
{
    // a type, which a read of objects can be set up from, is a table too
    if (!lua_istable(state, idx) || read_peek_identity(state, idx))
        return READ_ONE;
    lua_rawgeti(state, idx, 1);
    bool list = !lua_isnil(state, -1);
    lua_pop(state, 1);
    if (list)
        return READ_LIST;
    lua_pushnil(state);
    if (!lua_next(state, idx))
        return READ_NOTHING;
    lua_pop(state, 2);
    return READ_ONE;
}

// Turns the table of numbers at idx into a range of a container that holds outer items. The range
// is {first, last}, or {first, last, first2, last2} to limit the entries inside each item too.
void read_parse_range(lua_State *state, const ReadPlan &plan, int idx, int outer, ReadRange &range)
{
    if (!lua_istable(state, idx))
        luaL_error(state, "df.read_fields: a range must be a table of 2 or 4 whole numbers");
    lua_Integer count = lua_Integer(lua_rawlen(state, idx));
    if (count != 2 && count != 4)
        luaL_error(state, "df.read_fields: a range must be a table of 2 or 4 whole numbers");
    lua_Integer value[4] = {0, 0, 0, 0};
    for (int i = 0; i < count; i++)
    {
        int is_whole = 0;
        lua_rawgeti(state, idx, i + 1);
        if (lua_type(state, -1) == LUA_TNUMBER)
            value[i] = lua_tointegerx(state, -1, &is_whole);
        lua_pop(state, 1);
        if (!is_whole)
            luaL_error(state, "df.read_fields: the numbers in a range must be whole numbers");
    }

    const lua_Integer inner = plan.sources[0].inner;
    for (const ReadSource &src : plan.sources)
        if (src.inner != plan.sources[0].inner)
            luaL_error(state, "df.read_fields: a range needs containers that are all arranged the same way");
    if (count == 4 && inner == 1)
        luaL_error(state, "df.read_fields: a range of 4 numbers needs a container of containers");

    lua_Integer first1 = value[0], last1 = value[1];
    lua_Integer first2 = 0, last2 = inner - 1;
    if (count == 4)
    {
        first2 = value[2];
        last2 = value[3];
    }
    first1 = std::max<lua_Integer>(first1, 0);
    last1 = std::min<lua_Integer>(last1, outer - 1);
    first2 = std::max<lua_Integer>(first2, 0);
    last2 = std::min<lua_Integer>(last2, inner - 1);

    range.set = true;
    range.empty = first1 > last1 || first2 > last2;
    if (!range.empty)
    {
        range.first1 = int(first1);
        range.last1 = int(last1);
        range.first2 = int(first2);
        range.last2 = int(last2);
    }
}

// Looks for the range of the place-th item of the list, which is the table at item_idx when it is
// one of named containers and has the key '_range'.
void read_find_range(lua_State *state, const ReadPlan &plan, int item_idx, int outer, ReadRange &range)
{
    if (!plan.named || !lua_istable(state, item_idx))
        return;
    lua_pushliteral(state, "_range");
    lua_rawget(state, item_idx);
    if (!lua_isnil(state, -1))
        read_parse_range(state, plan, lua_gettop(state), outer, range);
    lua_pop(state, 1);
}

// Whether type is a link of a linked list: a structure that points to an item and to the next link.
bool read_describe_links(const type_identity *type, ReadSource &src)
{
    if (type->type() != IDTYPE_STRUCT)
        return false;
    auto next = read_find_field((const struct_identity*)type, "next");
    auto item = read_find_field((const struct_identity*)type, "item");
    if (!next || next->mode != struct_field_info::POINTER || next->type != type ||
        !item || item->mode != struct_field_info::POINTER || !item->type ||
        ((next->count | item->count) & (PTRFLAG_IS_ARRAY | PTRFLAG_HAS_BAD_POINTERS)))
        return false;
    src.mode = ReadSource::LINKS;
    src.link = type;
    src.leaf = item->type;
    src.next_offset = next->offset;
    src.item_offset = item->offset;
    return true;
}

// Sets a read up for what is at first_idx and the options at options_idx. That is a container, a
// table of named containers, a linked list, or else an object (when it was taken from a list, as
// from_list says) or a type, both of which set up a read of a list of objects. Pushes the test
// function, then the each function, with nil for one there is none of, and then the table of the
// functions that fields and conditions call.
void read_setup(lua_State *state, ReadPlan &plan, int first_idx, int options_idx, bool from_list)
{
    luaL_checkstack(state, 20, "df.read_fields");
    auto first_id = read_peek_identity(state, first_idx);
    if (first_id && read_is_struct(first_id))
    {
        ReadSource src;
        const bool is_type = lua_istable(state, first_idx);
        if (is_type || from_list)
        {
            // objects of classes derived from one class can be read together
            auto root = (const struct_identity*)first_id;
            if (!is_type)
            {
                // the nearest class that all the objects of the list (at index 1) derive from
                lua_Integer count = lua_Integer(lua_rawlen(state, 1));
                for (lua_Integer i = 2; i <= count && root; i++)
                {
                    lua_rawgeti(state, 1, i);
                    auto id = lua_type(state, -1) == LUA_TUSERDATA ? read_peek_identity(state, -1) : nullptr;
                    lua_pop(state, 1);
                    while (id && read_is_struct(id) && root && !read_derives(id, root))
                        root = root->getParent();
                }
                // objects with nothing in common are reported when the list is read
                if (!root)
                    root = (const struct_identity*)first_id;
            }
            src.mode = ReadSource::OBJECTS;
            src.leaf = root;
        }
        else if (read_describe_links(first_id, src))
            src.ptr = (uint8_t*)get_object_ref(state, first_idx);
        else
            luaL_error(state, "df.read_fields: %s is not a container; to read objects, pass a list of them",
                       first_id->getFullName().c_str());
        plan.sources.push_back(src);
    }
    else if (lua_istable(state, first_idx))
    {
        plan.named = true;
        lua_pushnil(state);
        while (lua_next(state, first_idx))
        {
            if (lua_type(state, -2) != LUA_TSTRING)
                luaL_error(state, "df.read_fields: containers in a table must have string names");
            std::string name = lua_tostring(state, -2);
            if (name == "_range")
            {
                // the range of this item, not a container
                lua_pop(state, 1);
                continue;
            }
            if (name.empty() || name == "_index" || name == "_from" || name.find('.') != std::string::npos)
                luaL_error(state, "df.read_fields: '%s' cannot be used as a container name", name.c_str());
            read_add_source(state, plan, lua_gettop(state), name);
            lua_pop(state, 1);
        }
        if (plan.sources.empty())
            luaL_error(state, "df.read_fields: no containers given");
    }
    else
        read_add_source(state, plan, first_idx, "");

    lua_Integer total = lua_Integer(plan.sources[0].outer) * plan.sources[0].inner;
    for (const ReadSource &src : plan.sources)
        if (lua_Integer(src.outer) * src.inner != total)
            luaL_error(state, "df.read_fields: the containers do not have the same number of entries");

    lua_pushnil(state);
    const int test_idx = lua_gettop(state);
    lua_pushnil(state);
    const int each_idx = lua_gettop(state);
    lua_newtable(state);
    ReadSetupGuard guard;
    read_setup_calls_idx = lua_gettop(state);

    if (lua_istable(state, options_idx))
    {
        lua_pushnil(state);
        while (lua_next(state, options_idx))
        {
            lua_pop(state, 1);
            const char *key = lua_type(state, -1) == LUA_TSTRING ? lua_tostring(state, -1) : "";
            if (strcmp(key, "fields") && strcmp(key, "where") && strcmp(key, "test") && strcmp(key, "limit") &&
                strcmp(key, "each"))
                luaL_error(state, "df.read_fields: unknown option '%s'; the options are fields, where, test, "
                                  "limit and each", key);
        }

        lua_getfield(state, options_idx, "limit");
        if (!lua_isnil(state, -1))
        {
            int is_whole = 0;
            if (lua_type(state, -1) == LUA_TNUMBER)
                plan.limit = lua_tointegerx(state, -1, &is_whole);
            if (!is_whole || plan.limit < 1)
                luaL_error(state, "df.read_fields: limit must be a whole number of at least 1");
        }
        lua_pop(state, 1);

        lua_getfield(state, options_idx, "test");
        if (!lua_isnil(state, -1))
        {
            if (!lua_isfunction(state, -1))
                luaL_error(state, "df.read_fields: test must be a function");
            plan.has_test = true;
        }
        lua_replace(state, test_idx);

        lua_getfield(state, options_idx, "each");
        if (!lua_isnil(state, -1))
        {
            if (!lua_isfunction(state, -1))
                luaL_error(state, "df.read_fields: each must be a function");
            plan.has_each = true;
        }
        lua_replace(state, each_idx);

        lua_getfield(state, options_idx, "where");
        if (!lua_isnil(state, -1))
        {
            if (!lua_istable(state, -1))
                luaL_error(state, "df.read_fields: where must be a table");
            int where_idx = lua_gettop(state);
            ReadCond all;
            int count = int(lua_rawlen(state, where_idx));
            if (count == 0)
            {
                lua_pushnil(state);
                if (lua_next(state, where_idx))
                    luaL_error(state, "df.read_fields: where must be a list of conditions");
            }
            for (int i = 1; i <= count; i++)
            {
                lua_rawgeti(state, where_idx, i);
                all.kids.push_back(read_parse_cond(state, plan, lua_gettop(state), 0));
                lua_pop(state, 1);
            }
            plan.conds.push_back(all);
            plan.root = plan.conds.size() - 1;
            plan.has_where = true;
        }
        lua_pop(state, 1);

        lua_getfield(state, options_idx, "fields");
        if (!lua_isnil(state, -1))
        {
            if (!lua_istable(state, -1))
                luaL_error(state, "df.read_fields: fields must be a table");
            int count = int(lua_rawlen(state, -1));
            for (int i = 1; i <= count; i++)
            {
                lua_rawgeti(state, -1, i);
                std::string name, path;
                bool ready = false;     // a call, whose accessor is made here
                if (lua_type(state, -1) == LUA_TSTRING)
                    name = path = lua_tostring(state, -1);
                else if (lua_istable(state, -1))
                {
                    // {path='a.b', as='name'}: read from the one, stored under the other
                    const int entry_idx = lua_gettop(state);
                    lua_getfield(state, entry_idx, "call");
                    const bool is_call = !lua_isnil(state, -1);
                    lua_pop(state, 1);
                    if (is_call)
                    {
                        // {call=function, args={...}, as='name'}: worked out by the function
                        lua_getfield(state, entry_idx, "as");
                        if (lua_type(state, -1) != LUA_TSTRING || lua_rawlen(state, -1) == 0)
                            luaL_error(state, "df.read_fields: a call in fields needs as='name' to be stored under");
                        name = lua_tostring(state, -1);
                        lua_pop(state, 1);
                        // not a path any field can have: the accessor is ready, and this says which
                        path = "\x01" + std::to_string(read_compile_call(state, plan, entry_idx, true));
                        ready = true;
                    }
                    else
                    {
                    lua_pushnil(state);
                    while (lua_next(state, entry_idx))
                    {
                        lua_pop(state, 1);
                        const char *key = lua_type(state, -1) == LUA_TSTRING ? lua_tostring(state, -1) : "";
                        if (strcmp(key, "path") && strcmp(key, "as"))
                            luaL_error(state, "df.read_fields: a field given as a table must be "
                                              "{path='...', as='...'}");
                    }
                    lua_getfield(state, entry_idx, "path");
                    lua_getfield(state, entry_idx, "as");
                    if (lua_type(state, -2) != LUA_TSTRING || lua_type(state, -1) != LUA_TSTRING)
                        luaL_error(state, "df.read_fields: a field given as a table must be "
                                          "{path='...', as='...'}, both of them strings");
                    path = lua_tostring(state, -2);
                    name = lua_tostring(state, -1);
                    lua_pop(state, 2);
                    if (name.empty())
                        luaL_error(state, "df.read_fields: a field cannot be stored under an empty name");
                    }
                }
                else
                    luaL_error(state, "df.read_fields: a field must be a string, {path='...', as='...'} or "
                                      "{call=function, args={...}, as='...'}");
                lua_pop(state, 1);
                if (!ready && !path.empty() && path[0] == '\x01')
                    luaL_error(state, "df.read_fields: a field name cannot start with a control character");
                // a function gets its arguments by position, so a name given twice is passed twice
                auto old = std::find(plan.names.begin(), plan.names.end(), name);
                if (plan.has_each || old == plan.names.end())
                {
                    plan.names.push_back(name);
                    plan.paths.push_back(path);
                }
                else if (plan.paths[old - plan.names.begin()] != path)
                    luaL_error(state, "df.read_fields: two different fields would be stored as '%s'", name.c_str());
            }
        }
        lua_pop(state, 1);
    }

    for (const std::string &path : plan.paths)
        plan.columns.push_back(path[0] == '\x01' ? size_t(std::stoul(path.substr(1)))
                                                 : read_compile(state, plan, path));
}

// Does a read that has been set up. from_idx holds what to read from: a list of containers (or of
// tables of named ones) when is_list is set, else just the one. A read set up for objects takes a
// list of them, and one set up for a linked list takes the list's first link. Every container is
// looked at afresh here, also the one the plan was set up from: looking up an option or an array of
// out can run Lua code, which may have changed it since.
int read_run(lua_State *state, const ReadPlan &plan, int from_idx, bool is_list, int out_idx, int test_idx,
             int each_idx, int calls_idx)
{
    ReadStateGuard guard;
    read_calls_idx = calls_idx;
    luaL_checkstack(state, int(plan.names.size()) + 20, "df.read_fields: too many fields");

    // a range belongs to one table of named containers; on the list around them, or on a list of
    // plain containers or of objects, it would go unread
    if (is_list)
    {
        lua_pushliteral(state, "_range");
        lua_rawget(state, from_idx);
        if (!lua_isnil(state, -1))
            luaL_error(state, "df.read_fields: '_range' was given on the list; it goes in a table of "
                              "named containers, next to the containers it limits");
        lua_pop(state, 1);
    }

    // one array per field, each at a fixed stack index; none when the entries go to a function
    int column_base = lua_gettop(state);
    if (!plan.has_each)
    for (const std::string &name : plan.names)
    {
        lua_getfield(state, out_idx, name.c_str());
        if (!lua_istable(state, -1))
        {
            lua_pop(state, 1);
            lua_newtable(state);
            lua_pushvalue(state, -1);
            lua_setfield(state, out_idx, name.c_str());
        }
    }

    const size_t source_count = plan.sources.size();
    std::vector<ReadBound> bound(source_count);
    std::vector<uint8_t*> bases(source_count);
    std::vector<ReadCursor> cursors(source_count);

    // Finds where each container keeps the entry the cursors are at. False when one of them holds
    // a null pointer there.
    auto locate = [&plan, &bound, &bases, &cursors, source_count]() {
        bool present = true;
        for (size_t i = 0; i < source_count; i++)
        {
            const ReadSource &src = plan.sources[i];
            ReadCursor &cursor = cursors[i];
            uint8_t *entry;
            if (src.pointers)
                entry = *(uint8_t**)src.container->raw_item_pointer(&df::identity_traits<void*>::identity,
                                                                    bound[i].ptr, cursor.outer);
            else
            {
                if (!cursor.item_ok)
                {
                    cursor.item = (uint8_t*)src.container->raw_item_pointer(src.item, bound[i].ptr, cursor.outer);
                    cursor.item_ok = true;
                }
                entry = cursor.item;
                if (entry)
                    entry += size_t(cursor.inner) * src.leaf_size;
                if (entry && src.leaf_pointers)
                    entry = *(uint8_t**)entry;
            }
            if (!entry)
                present = false;
            bases[i] = entry;
        }
        return present;
    };
    auto advance = [&plan, &cursors, source_count]() {
        for (size_t i = 0; i < source_count; i++)
        {
            ReadCursor &cursor = cursors[i];
            if (++cursor.inner >= plan.sources[i].inner)
            {
                cursor.inner = 0;
                cursor.outer++;
                cursor.item_ok = false;
            }
        }
    };

    lua_Integer found = 0;
    lua_Integer place = 0;
    const ReadSource::Mode mode = plan.sources[0].mode;
    // only a container is walked with the cursors; otherwise bases is set before each visit
    const bool walk = mode == ReadSource::CONTAINER;
    bool full = false;

    // Stops the read when a function that was called changed how many entries a container has.
    auto changed_size = [&]() {
        for (size_t i = 0; i < source_count; i++)
            if (plan.sources[i].dynamic &&
                plan.sources[i].container->raw_item_count(bound[i].ptr) != bound[i].outer)
                luaL_error(state, "df.read_fields: a container changed size during the read");
    };

    // What a function called for an entry is followed by: the entry is found again, since the
    // function may have moved or replaced it. False when it is no longer there.
    auto refresh = [&]() {
        changed_size();
        for (ReadCursor &cursor : cursors)
            cursor.item_ok = false;
        return locate();
    };
    using Refresh = decltype(refresh);
    ReadFrame frame;
    frame.ctx = &refresh;
    if (walk)
        frame.refresh = [](ReadFrame *self) { return (*(Refresh*)self->ctx)(); };

    // Looks at the entry at index, which the cursors are at, and keeps it if it passes.
    auto visit = [&](lua_Integer index) {
        if (walk && !locate())
            return;

        // set for each entry, since a function called for the one before may have done a read too
        read_place = place;
        read_calls_idx = calls_idx;
        read_frame = &frame;
        if (plan.has_where && !read_test(state, plan, plan.root, bases, index))
            return;

        if (plan.has_test)
        {
            lua_pushvalue(state, test_idx);
            lua_pushinteger(state, index);
            lua_pushinteger(state, place);
            lua_call(state, 2, 1);
            bool keep = lua_toboolean(state, -1) != 0;
            lua_pop(state, 1);
            // the function may have done a read of its own
            read_place = place;
            read_calls_idx = calls_idx;
            read_frame = &frame;
            if (walk)
            {
                changed_size();
                // the function may have moved or replaced the entry
                for (ReadCursor &cursor : cursors)
                    cursor.item_ok = false;
            }
            if (!keep || (walk && !locate()))
                return;
        }

        found++;
        if (plan.has_each)
        {
            // the values are all read before the function gets to run and change anything
            lua_pushvalue(state, each_idx);
            for (size_t column : plan.columns)
            {
                const ReadAccessor &acc = plan.accessors[column];
                if (acc.kind == ReadAccessor::FROM)
                    lua_pushinteger(state, place);
                else
                    read_push(state, acc, bases, index);
            }
            lua_call(state, int(plan.columns.size()), 1);
            // false, but not nil, stops the read
            if (lua_isboolean(state, -1) && !lua_toboolean(state, -1))
                full = true;
            lua_pop(state, 1);
            // after the last call nothing more is read, so what the function did no longer matters
            if (walk && !full)
            {
                changed_size();
                for (ReadCursor &cursor : cursors)
                    cursor.item_ok = false;
            }
        }
        else
        for (size_t i = 0; i < plan.columns.size(); i++)
        {
            const ReadAccessor &acc = plan.accessors[plan.columns[i]];
            if (acc.kind == ReadAccessor::FROM)
                lua_pushinteger(state, place);
            else
                read_push(state, acc, bases, index);
            lua_rawseti(state, column_base + 1 + int(i), found);
        }
        if (plan.limit && found >= plan.limit)
            full = true;
    };

    if (mode == ReadSource::OBJECTS)
    {
        const type_identity *wanted = plan.sources[0].leaf;
        if (!lua_istable(state, from_idx) || read_peek_identity(state, from_idx))
            luaL_error(state, "df.read_fields: this read was set up for a list of objects");
        place = 1;
        lua_Integer count = lua_Integer(lua_rawlen(state, from_idx));
        for (lua_Integer i = 1; i <= count && !full; i++)
        {
            lua_rawgeti(state, from_idx, i);
            auto id = lua_type(state, -1) == LUA_TUSERDATA ? read_peek_identity(state, -1) : nullptr;
            if (!id || !read_derives(id, wanted))
                luaL_error(state, "df.read_fields: entry %d of the list is not a %s", int(i),
                           wanted->getFullName().c_str());
            bases[0] = (uint8_t*)get_object_ref(state, lua_gettop(state));
            lua_pop(state, 1);
            if (bases[0])
                visit(i);
        }
    }
    else if (mode == ReadSource::LINKS)
    {
        const ReadSource &src = plan.sources[0];
        if (lua_type(state, from_idx) != LUA_TUSERDATA || read_peek_identity(state, from_idx) != src.link)
            luaL_error(state, "df.read_fields: this read was set up for a linked list of %s",
                       src.link->getFullName().c_str());
        place = 1;
        uint8_t *link = (uint8_t*)get_object_ref(state, from_idx);
        lua_Integer index = 0;
        while (link && !full)
        {
            // the next link is found first, in case the test function takes this one out
            uint8_t *next = *(uint8_t**)(link + src.next_offset);
            bases[0] = *(uint8_t**)(link + src.item_offset);
            if (bases[0])
                visit(index++);
            link = next;
        }
    }

    lua_Integer places = !walk ? 0 : is_list ? lua_Integer(lua_rawlen(state, from_idx)) : 1;
    for (place = 1; place <= places && !full; place++)
    {
        if (is_list)
            lua_rawgeti(state, from_idx, place);
        else
            lua_pushvalue(state, from_idx);
        const int item_idx = lua_gettop(state);

        const lua_Integer total = read_bind(state, plan, item_idx, bound);

        ReadRange range;
        read_find_range(state, plan, item_idx, bound[0].outer, range);
        lua_pop(state, 1);

        std::fill(cursors.begin(), cursors.end(), ReadCursor());

        if (!range.set)
        {
            for (lua_Integer index = 0; index < total && !full; index++, advance())
                visit(index);
        }
        else if (!range.empty)
        {
            // only the range is walked; every container has the same inner size, as checked above
            const lua_Integer inner = plan.sources[0].inner;
            for (int outer = range.first1; outer <= range.last1 && !full; outer++)
            {
                for (ReadCursor &cursor : cursors)
                {
                    cursor.outer = outer;
                    cursor.inner = range.first2;
                    cursor.item_ok = false;
                }
                for (int at = range.first2; at <= range.last2 && !full; at++, advance())
                    visit(lua_Integer(outer) * inner + at);
            }
        }
    }

    // what an earlier, longer read left behind in the arrays is cleared, up to the first gap
    for (size_t i = 0; !plan.has_each && i < plan.columns.size(); i++)
    {
        const int column = column_base + 1 + int(i);
        for (lua_Integer at = found + 1; lua_rawgeti(state, column, at) != LUA_TNIL; at++)
        {
            lua_pop(state, 1);
            lua_pushnil(state);
            lua_rawseti(state, column, at);
        }
        lua_pop(state, 1);
    }

    lua_pushvalue(state, out_idx);
    lua_pushinteger(state, found);
    return 2;
}

// Makes sure there is a table to write to at idx.
void read_check_out(lua_State *state, int idx)
{
    if (lua_isnil(state, idx))
    {
        lua_newtable(state);
        lua_replace(state, idx);
    }
    else if (!lua_istable(state, idx))
        luaL_error(state, "df.read_fields: out must be a table");
}

}

static int meta_read_fields(lua_State *state)
{
    int argc = lua_gettop(state);
    if (argc < 1 || argc > 3)
        luaL_error(state, "Usage: df.read_fields(container[, options[, out]])");
    lua_settop(state, 3);
    if (!lua_isnil(state, 2) && !lua_istable(state, 2))
        luaL_error(state, "df.read_fields: options must be a table");
    read_check_out(state, 3);
    luaL_checkstack(state, 20, "df.read_fields");

    ReadFrom from = read_from(state, 1);
    if (from == READ_NOTHING)
    {
        lua_pushvalue(state, 3);
        lua_pushinteger(state, 0);
        return 2;
    }

    ReadPlan plan;
    if (from == READ_LIST)
        lua_rawgeti(state, 1, 1);
    else
        lua_pushvalue(state, 1);
    // stack: [container, options, out, first]
    read_setup(state, plan, 4, 2, from == READ_LIST);
    // stack: [container, options, out, first, test, each, calls]
    return read_run(state, plan, 1, from == READ_LIST, 3, 5, 6, 7);
}

static int read_plan_gc(lua_State *state)
{
    ((ReadPlan*)lua_touserdata(state, 1))->~ReadPlan();
    return 0;
}

// The function df.prepare_read_fields returns. Upvalues: the type table, the plan, the test function, the
// each function, the table of the functions that fields and conditions call.
static int read_prepared_call(lua_State *state)
{
    int argc = lua_gettop(state);
    if (argc < 1 || argc > 2)
        luaL_error(state, "Usage: read(container[, out]), with read made by df.prepare_read_fields");
    lua_settop(state, 2);
    read_check_out(state, 2);
    luaL_checkstack(state, 20, "df.read_fields");

    ReadFrom from = read_from(state, 1);
    if (from == READ_NOTHING)
    {
        lua_pushvalue(state, 2);
        lua_pushinteger(state, 0);
        return 2;
    }

    auto plan = (const ReadPlan*)lua_touserdata(state, lua_upvalueindex(2));
    lua_pushvalue(state, lua_upvalueindex(3));
    lua_pushvalue(state, lua_upvalueindex(4));
    lua_pushvalue(state, lua_upvalueindex(5));
    // stack: [container, out, test, each, calls]
    return read_run(state, *plan, 1, from == READ_LIST, 2, 3, 4, 5);
}

static int meta_prepare_read_fields(lua_State *state)
{
    int argc = lua_gettop(state);
    if (argc < 1 || argc > 2)
        luaL_error(state, "Usage: df.prepare_read_fields(container[, options])");
    lua_settop(state, 2);
    if (!lua_isnil(state, 2) && !lua_istable(state, 2))
        luaL_error(state, "df.read_fields: options must be a table");
    luaL_checkstack(state, 20, "df.read_fields");

    ReadFrom from = read_from(state, 1);
    if (from == READ_NOTHING)
        luaL_error(state, "df.read_fields: no containers or objects given");

    auto plan = new (lua_newuserdata(state, sizeof(ReadPlan))) ReadPlan();
    if (luaL_newmetatable(state, "df.read_fields.plan"))
    {
        lua_pushcfunction(state, read_plan_gc);
        lua_setfield(state, -2, "__gc");
    }
    lua_setmetatable(state, 3);
    if (from == READ_LIST)
        lua_rawgeti(state, 1, 1);
    else
        lua_pushvalue(state, 1);
    // stack: [container, options, plan, first]
    read_setup(state, *plan, 4, 2, from == READ_LIST);
    // stack: [container, options, plan, first, test, each, calls]
    lua_pushvalue(state, UPVAL_TYPETABLE);
    lua_pushvalue(state, 3);
    lua_pushvalue(state, 5);
    lua_pushvalue(state, 6);
    lua_pushvalue(state, 7);
    lua_pushcclosure(state, read_prepared_call, 5);
    return 1;
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
    lua_pushcclosure(state, meta_prepare_read_fields, 1);
    lua_setfield(state, LUA_REGISTRYINDEX, DFHACK_PREPARE_READ_FIELDS_NAME);

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
        lua_setfield(state, -2, "read_fields");
        lua_getfield(state, LUA_REGISTRYINDEX, DFHACK_PREPARE_READ_FIELDS_NAME);
        lua_setfield(state, -2, "prepare_read_fields");

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
