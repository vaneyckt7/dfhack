config.target = 'core'

local function with_bit_vector(fn)
    local info = df.burrow_infost:new()
    dfhack.with_finalize(
        function() info:delete() end,
        function() fn(info.sel_units) end)
end

local function contents(v)
    local out = {}
    for i = 0, #v - 1 do
        out[i + 1] = v[i]
    end
    return out
end

function test.bit_vector_insert_at_end()
    with_bit_vector(function(v)
        v:insert('#', true)
        v:insert('#', false)
        v:insert(#v, true)
        expect.table_eq(contents(v), {true, false, true})
    end)
end

function test.bit_vector_insert_in_middle()
    with_bit_vector(function(v)
        v:resize(3)
        v:insert(0, true)
        v:insert(2, true)
        expect.table_eq(contents(v), {true, false, true, false, false})
    end)
end

function test.bit_vector_insert_many()
    -- enough to make the vector grow past several storage words
    with_bit_vector(function(v)
        local expected = {}
        for i = 1, 200 do
            v:insert('#', i % 3 == 0)
            expected[i] = i % 3 == 0
        end
        expect.table_eq(contents(v), expected)
    end)
end

function test.bit_vector_insert_values()
    with_bit_vector(function(v)
        v:insert('#', 1)
        v:insert('#', 0)
        v:insert('#', nil)
        expect.table_eq(contents(v), {true, false, false})
        expect.error_match('boolean or number expected', function() v:insert('#', 'true') end)
        expect.error_match('boolean or number expected', function() v:insert('#', {}) end)
        expect.eq(#v, 3)
    end)
end

function test.bit_vector_insert_bad_index()
    with_bit_vector(function(v)
        v:resize(2)
        expect.error(function() v:insert(3, true) end)
        expect.error(function() v:insert(-1, true) end)
        expect.eq(#v, 2)
    end)
end

function test.bit_vector_erase_and_resize()
    with_bit_vector(function(v)
        v:insert('#', true)
        v:insert('#', false)
        v:insert('#', true)
        v:erase(0)
        expect.table_eq(contents(v), {false, true})
        v:resize(4)
        expect.table_eq(contents(v), {false, true, false, false})
    end)
end

function test.flag_array_insert_not_supported()
    local mat = df.material:new()
    dfhack.with_finalize(
        function() mat:delete() end,
        function()
            expect.error_match('not supported', function() mat.flags:insert('#', true) end)
            expect.error_match('not supported', function() mat.flags:insert(0, true) end)
        end)
end
