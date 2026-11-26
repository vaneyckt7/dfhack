config.target = 'core'

local function with_job(fn)
    local job = df.job:new()
    local specs = {
        {item_type=df.item_type.BAR, quantity=3, mat_index=10},
        {item_type=df.item_type.BOULDER, quantity=1, mat_index=20},
        {item_type=df.item_type.WOOD, quantity=7, mat_index=30},
    }
    for _, spec in ipairs(specs) do
        local item = df.job_item:new()
        item.item_type, item.quantity, item.mat_index = spec.item_type, spec.quantity, spec.mat_index
        job.job_items.elements:insert('#', item)
    end
    dfhack.with_finalize(function()
        for _, item in ipairs(job.job_items.elements) do if item then item:delete() end end
        job.job_items.elements:resize(0)
        job:delete()
    end, fn, job)
end

local function values(container)
    local list = {}
    for i, v in ipairs(container) do list[i + 1] = v end
    return list
end

function test.values_of_a_vector()
    local path = df.coord_path:new()
    dfhack.with_finalize(function() path:delete() end, function()
        for _, v in ipairs{5, -2, 9, 0} do path.x:insert('#', v) end
        expect.eq(df.write_fields(path.x, {_value={1, 2, 3, 4}}), 4)
        expect.table_eq(values(path.x), {1, 2, 3, 4})
        -- chosen entries, counted from 0, in any order and more than once
        expect.eq(df.write_fields(path.x, {_index={3, 0, 3}, _value={30, 10, 31}}), 3)
        expect.table_eq(values(path.x), {10, 2, 3, 31})
        expect.eq(df.write_fields(path.x, {_index={}, _value={}}), 0)
        expect.table_eq(values(path.x), {10, 2, 3, 31})

        -- what a read returns can be written back
        local out, n = df.read_fields(path.x, {fields={'_index', '_value'}, where={{'_value', '>', 5}}})
        for i = 1, n do out._value[i] = -out._value[i] end
        df.write_fields(path.x, out)
        expect.table_eq(values(path.x), {-10, 2, 3, -31})
    end)
end

function test.fields_of_structures()
    with_job(function(job)
        local items = job.job_items.elements
        df.write_fields(items, {_index={2, 0}, quantity={70, 30}, item_type={df.item_type.BAR, df.item_type.WOOD},
                                ['flags1.improvable']={true, false}})
        expect.eq(items[0].quantity, 30)
        expect.eq(items[1].quantity, 1)
        expect.eq(items[2].quantity, 70)
        expect.eq(items[0].item_type, df.item_type.WOOD)
        expect.eq(items[2].item_type, df.item_type.BAR)
        expect.true_(items[2].flags1.improvable)
        expect.false_(items[0].flags1.improvable)
        expect.false_(items[1].flags1.improvable)
        -- a bitfield as a whole
        df.write_fields(items, {_index={1}, ['flags1.whole']={items[2].flags1.whole}})
        expect.true_(items[1].flags1.improvable)
        df.write_fields(items, {['flags1.whole']={0, 0, 0}})
        expect.false_(items[1].flags1.improvable)
        expect.false_(items[2].flags1.improvable)
        -- a string
        df.write_fields(items, {_index={1}, reaction_class={'FLUX'}})
        expect.eq(items[1].reaction_class, 'FLUX')
        expect.eq(items[0].reaction_class, '')
    end)
end

function test.nested_arrays_are_one_run()
    local block = df.map_block:new()
    dfhack.with_finalize(function() block:delete() end, function()
        df.write_fields(block.designation, {_index={0, 17, 255}, flow_size={1, 2, 3}, hidden={true, false, true}})
        expect.eq(block.designation[0][0].flow_size, 1)
        expect.eq(block.designation[1][1].flow_size, 2)
        expect.eq(block.designation[15][15].flow_size, 3)
        expect.true_(block.designation[0][0].hidden)
        expect.true_(block.designation[15][15].hidden)
        expect.eq(block.designation[0][1].flow_size, 0)
        local out, n = df.read_fields(block.designation, {fields={'_index', 'flow_size'}, where={{'flow_size', '>', 0}}})
        expect.table_eq(out._index, {0, 17, 255})
        df.write_fields(block.tiletype, {_index={16}, _value={df.tiletype.StoneFloor1}})
        expect.eq(block.tiletype[1][0], df.tiletype.StoneFloor1)
        expect.eq(block.tiletype[0][0], 0)
    end)
end

function test.a_run_behind_a_pointer()
    local path = df.coord_path:new()
    dfhack.with_finalize(function() path:delete() end, function()
        for _, v in ipairs{5, -2, 9, 0} do path.x:insert('#', v) end
        -- the first entry, as a pointer to an array reads in Lua
        local first = path.x:_field(0)
        df.write_fields(first, {_index={1, 3}, _value={20, 40}}, {count=4})
        expect.table_eq(values(path.x), {5, 20, 9, 40})
        df.write_fields(first, {_value={1, 2}}, {count=2})
        expect.table_eq(values(path.x), {1, 2, 9, 40})
        expect.error_match('outside the 3 entries', function()
            df.write_fields(first, {_index={0, 3}, _value={7, 7}}, {count=3})
        end)
        expect.table_eq(values(path.x), {1, 2, 9, 40})
        expect.error_match("say how many there are with 'count'", function()
            df.write_fields(first, {_index={0}, _value={7}})
        end)
        expect.error_match("'count' is for an object that is not a container", function()
            df.write_fields(path.x, {_index={0}, _value={7}}, {count=4})
        end)
        expect.error_match("'count' must be", function()
            df.write_fields(first, {_index={0}, _value={7}}, {count=-1})
        end)
        expect.error_match("the only option is 'count'", function()
            df.write_fields(first, {_index={0}, _value={7}}, {size=4})
        end)
    end)
end

function test.errors()
    with_job(function(job)
        local items = job.job_items.elements
        expect.error_match('Usage', function() df.write_fields(items) end)
        expect.error_match('columns must be a table', function() df.write_fields(items, 5) end)
        expect.error_match('expected a container', function() df.write_fields({}, {quantity={1}}) end)
        expect.error_match('no column of values', function() df.write_fields(items, {_index={0}}) end)
        expect.error_match('must be a list of values', function() df.write_fields(items, {quantity=5}) end)
        expect.error_match('named by the field', function() df.write_fields(items, {{1, 2, 3}}) end)
        expect.error_match('same number of values', function()
            df.write_fields(items, {_index={0, 1}, quantity={1}})
        end)
        expect.error_match('one value for every entry, 3 here', function()
            df.write_fields(items, {quantity={1, 2}})
        end)
        expect.error_match('not a whole number', function()
            df.write_fields(items, {_index={0, 1.5}, quantity={1, 2}})
        end)
        -- a bad index is found before anything is written
        expect.error_match("'_index' 2 is 3, outside the 3 entries", function()
            df.write_fields(items, {_index={0, 3}, quantity={100, 200}})
        end)
        expect.error_match('outside the 3 entries', function()
            df.write_fields(items, {_index={0, -1}, quantity={100, 200}})
        end)
        expect.eq(items[0].quantity, 3)
        -- paths are reported under this function's name
        expect.error_match('^[^\n]*df.write_fields: [^\n]*nonsense', function()
            df.write_fields(items, {nonsense={1, 2, 3}})
        end)
        -- things that are not a single value
        for _, path in ipairs{'flags1', 'item_type.caption', 'contains', 'contains._size', '_from'} do
            expect.error(function() df.write_fields(items, {_index={0}, [path]={1}}) end, path)
        end
        expect.error_match('not a value that can be written', function()
            df.write_fields(items, {_index={0}, flags1={1}})
        end)
        -- a value of the wrong type stops the write; the rows before it stay written
        expect.error_match('df.write_fields.quantity', function()
            df.write_fields(items, {quantity={100, 'many', 300}})
        end)
        expect.eq(items[0].quantity, 100)
        expect.eq(items[1].quantity, 1)
        expect.eq(items[2].quantity, 7)
        expect.error_match('must be a boolean or a whole number', function()
            df.write_fields(items, {_index={0}, ['flags1.improvable']={'yes'}})
        end)
        expect.error_match('must be a whole number', function()
            df.write_fields(items, {_index={0}, ['flags1.whole']={true}})
        end)
        -- an entry that is a null pointer
        local removed = items[1]
        items[1] = nil
        dfhack.with_finalize(function() items[1] = removed end, function()
            expect.error_match('entry 1 is a null pointer', function()
                df.write_fields(items, {quantity={11, 12, 13}})
            end)
            expect.eq(items[0].quantity, 11)
            expect.eq(items[2].quantity, 7)
        end)
    end)
end

function test.flags_and_unreachable_places()
    local a = df.material:new()
    dfhack.with_finalize(function() a:delete() end, function()
        a.reaction_product.item_type:insert('#', df.item_type.BAR)
        -- one object is a run of one entry
        df.write_fields(a, {['flags.IS_METAL']={true}, ['reaction_product.item_type.0']={df.item_type.WOOD},
                            ['state_color.Liquid']={9}}, {count=1})
        expect.true_(a.flags.IS_METAL)
        expect.false_(a.flags.IS_STONE)
        expect.eq(a.reaction_product.item_type[0], df.item_type.WOOD)
        expect.eq(a.state_color.Liquid, 9)
        df.write_fields(a, {['flags.IS_METAL']={false}}, {count=1})
        expect.false_(a.flags.IS_METAL)
        expect.error_match("entry 0 has no 'reaction_product.item_type.1' to write to", function()
            df.write_fields(a, {['reaction_product.item_type.1']={df.item_type.WOOD}}, {count=1})
        end)
        expect.error_match('must be a boolean', function()
            df.write_fields(a, {['flags.IS_METAL']={1}}, {count=1})
        end)
    end)
end
