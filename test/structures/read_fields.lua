config.target = 'core'

-- a job with five required items, none of them linked into the game
local function with_job(fn)
    local job = df.job:new()
    local specs = {
        {item_type=df.item_type.BAR, quantity=3, mat_index=10},
        {item_type=df.item_type.BOULDER, quantity=1, mat_index=20},
        {item_type=df.item_type.WOOD, quantity=7, mat_index=30},
        {item_type=df.item_type.BAR, quantity=5, mat_index=40},
        {item_type=df.item_type.SEEDS, quantity=2, mat_index=50},
    }
    for i, spec in ipairs(specs) do
        job.job_items.elements:insert('#', {new=true, item_type=spec.item_type, quantity=spec.quantity,
                                            mat_index=spec.mat_index})
        job.job_items.elements[i - 1].flags1.improvable = i % 2 == 0
    end
    job.items:insert('#', {new=true, job_item_idx=4})
    job.items:insert('#', {new=true, job_item_idx=2})
    dfhack.with_finalize(
        function()
            for _, item in ipairs(job.job_items.elements) do item:delete() end
            for _, ref in ipairs(job.items) do ref:delete() end
            job.job_items.elements:resize(0)
            job.items:resize(0)
            job:delete()
        end,
        fn, job, specs)
end

local function with_block(fn)
    local block = df.map_block:new()
    dfhack.with_finalize(function() block:delete() end, fn, block)
end

local function column(out, name, n)
    local values = {}
    for i = 1, n do values[i] = out[name][i] end
    return values
end

function test.all_entries()
    with_job(function(job, specs)
        local out, n = df.readFields(job.job_items.elements,
            {fields={'_index', 'item_type', 'quantity', 'mat_index', 'flags1.improvable', 'flags1'}})
        expect.eq(n, #specs)
        for i, spec in ipairs(specs) do
            local item = job.job_items.elements[i - 1]
            expect.eq(out._index[i], i - 1)
            expect.eq(out.item_type[i], spec.item_type)
            expect.eq(out.quantity[i], spec.quantity)
            expect.eq(out.mat_index[i], spec.mat_index)
            expect.eq(out['flags1.improvable'][i], i % 2 == 0)
            expect.eq(out.flags1[i], item.flags1.whole)
        end
    end)
end

function test.count_only()
    with_job(function(job, specs)
        local out, n = df.readFields(job.job_items.elements)
        expect.eq(n, #specs)
        expect.eq(next(out), nil)
        out, n = df.readFields(job.job_items.elements, {where={}})
        expect.eq(n, #specs)
        out, n = df.readFields(job.job_items.elements, {where={{'quantity', '>', 100}}})
        expect.eq(n, 0)
    end)
end

function test.comparisons()
    with_job(function(job)
        local function matches(where)
            local out, n = df.readFields(job.job_items.elements, {fields={'_index'}, where=where})
            return column(out, '_index', n)
        end
        expect.table_eq(matches{{'quantity', '==', 3}}, {0})
        expect.table_eq(matches{{'quantity', '~=', 3}}, {1, 2, 3, 4})
        expect.table_eq(matches{{'quantity', '<', 3}}, {1, 4})
        expect.table_eq(matches{{'quantity', '<=', 3}}, {0, 1, 4})
        expect.table_eq(matches{{'quantity', '>', 3}}, {2, 3})
        expect.table_eq(matches{{'quantity', '>=', 3}}, {0, 2, 3})
        expect.table_eq(matches{{'quantity', '>', 2.5}}, {0, 2, 3})
        expect.table_eq(matches{{'item_type', 'in', {df.item_type.BAR, df.item_type.SEEDS}}}, {0, 3, 4})
        expect.table_eq(matches{{'item_type', 'in', {}}}, {})
        expect.table_eq(matches{{'flags1.improvable', '==', true}}, {1, 3})
        expect.table_eq(matches{{'flags1', '==', 0}}, {0, 2, 4})
        expect.table_eq(matches{{'item_type', '==', df.item_type.BAR}, {'quantity', '>', 3}}, {3})
        -- a value of another type never matches an ordering comparison, and does not raise
        expect.table_eq(matches{{'flags1.improvable', '<', 1}}, {})
    end)
end

function test.combined_conditions()
    with_job(function(job)
        local function matches(where)
            local out, n = df.readFields(job.job_items.elements, {fields={'_index'}, where=where})
            return column(out, '_index', n)
        end
        expect.table_eq(matches{{'or', {'quantity', '==', 1}, {'quantity', '==', 7}}}, {1, 2})
        expect.table_eq(matches{{'not', {'item_type', '==', df.item_type.BAR}}}, {1, 2, 4})
        expect.table_eq(matches{{'or', {'and', {'item_type', '==', df.item_type.BAR}, {'quantity', '>', 3}},
                                       {'mat_index', '==', 50}}}, {3, 4})
        expect.table_eq(matches{{'not', {'or', {'quantity', '<', 3}, {'quantity', '>', 5}}}}, {0, 3})
    end)
end

function test.enum_attributes()
    with_job(function(job, specs)
        local out, n = df.readFields(job.job_items.elements, {fields={'item_type.caption', 'item_type.is_rawable'}})
        for i, spec in ipairs(specs) do
            expect.eq(out['item_type.caption'][i], df.item_type.attrs[spec.item_type].caption)
            expect.eq(out['item_type.is_rawable'][i], df.item_type.attrs[spec.item_type].is_rawable)
        end
        out, n = df.readFields(job.job_items.elements,
            {fields={'_index'}, where={{'item_type.caption', '==', df.item_type.attrs.BAR.caption}}})
        expect.table_eq(column(out, '_index', n), {0, 3})
    end)
end

function test.null_pointer_on_the_path()
    with_job(function(job)
        local out, n = df.readFields(job.items, {fields={'job_item_idx', 'item.id'}})
        expect.eq(n, 2)
        expect.table_eq(column(out, 'job_item_idx', n), {4, 2})
        expect.eq(out['item.id'][1], nil)
        expect.eq(out['item.id'][2], nil)
        out, n = df.readFields(job.items, {where={{'item.id', '~=', 5}}})
        expect.eq(n, 0)
        out, n = df.readFields(job.items, {where={{'not', {'item.id', '==', 5}}}})
        expect.eq(n, 2)
    end)
end

function test.plain_values()
    local path = df.coord_path:new()
    dfhack.with_finalize(function() path:delete() end, function()
        for _, v in ipairs{5, -2, 9, 0} do path.x:insert('#', v) end
        local out, n = df.readFields(path.x, {fields={'_value', '_index'}, where={{'_value', '>', 0}}})
        expect.eq(n, 2)
        expect.table_eq(column(out, '_value', n), {5, 9})
        expect.table_eq(column(out, '_index', n), {0, 2})
    end)
end

-- whole numbers and flags are compared without Lua; other values take the general path. Both must agree.
function test.comparisons_on_whole_numbers()
    local path = df.coord_path:new()
    dfhack.with_finalize(function() path:delete() end, function()
        local values = {5, -2, 9, 0, -32768, 32767, 9}
        for _, v in ipairs(values) do path.x:insert('#', v) end
        local function matches(where)
            local out, n = df.readFields(path.x, {fields={'_index'}, where=where})
            return column(out, '_index', n)
        end
        local function expected(keep)
            local list = {}
            for i, v in ipairs(values) do
                if keep(v, i - 1) then list[#list + 1] = i - 1 end
            end
            return list
        end
        for _, against in ipairs{-32768, -3, -2, 0, 5, 9, 32767, 100000} do
            -- the same number as a float is compared by Lua
            for _, value in ipairs{against, against + 0.0} do
                expect.table_eq(matches{{'_value', '==', value}}, expected(function(v) return v == against end))
                expect.table_eq(matches{{'_value', '~=', value}}, expected(function(v) return v ~= against end))
                expect.table_eq(matches{{'_value', '<', value}}, expected(function(v) return v < against end))
                expect.table_eq(matches{{'_value', '<=', value}}, expected(function(v) return v <= against end))
                expect.table_eq(matches{{'_value', '>', value}}, expected(function(v) return v > against end))
                expect.table_eq(matches{{'_value', '>=', value}}, expected(function(v) return v >= against end))
            end
        end
        expect.table_eq(matches{{'_value', 'in', {9, -2, 9}}}, {1, 2, 6})
        expect.table_eq(matches{{'_value', 'in', {9.0, -2, 'x'}}}, {1, 2, 6})
        expect.table_eq(matches{{'_value', 'in', {-32768}}}, {4})
        expect.table_eq(matches{{'_index', '>=', 5}}, {5, 6})
        expect.table_eq(matches{{'_index', 'in', {0, 6, 7}}}, {0, 6})
        expect.table_eq(matches{{'_index', '~=', 3}, {'_value', '<', 1}}, {1, 4})
        -- a value of another type equals nothing
        expect.table_eq(matches{{'_value', '==', '5'}}, {})
        expect.table_eq(matches{{'_value', '==', true}}, {})
        expect.table_eq(matches{{'_value', '~=', true}}, {0, 1, 2, 3, 4, 5, 6})
    end)
    with_job(function(job)
        local function matches(where)
            local out, n = df.readFields(job.job_items.elements, {fields={'_index'}, where=where})
            return column(out, '_index', n)
        end
        expect.table_eq(matches{{'flags1.improvable', '==', false}}, {0, 2, 4})
        expect.table_eq(matches{{'flags1.improvable', '~=', false}}, {1, 3})
        expect.table_eq(matches{{'flags1.improvable', '~=', true}}, {0, 2, 4})
        expect.table_eq(matches{{'flags1.improvable', '==', 1}}, {})
        expect.table_eq(matches{{'flags1.improvable', 'in', {true}}}, {1, 3})
        expect.table_eq(matches{{'flags1', '~=', 0}}, {1, 3})
        expect.table_eq(matches{{'flags1', 'in', {0}}}, {0, 2, 4})
    end)
end

function test.comparisons_on_unsigned_and_attributes()
    with_block(function(block)
        -- unsigned values with the top bit set must not turn negative
        block.temperature_1[0][1] = 65535
        block.temperature_1[3][0] = 32768
        block.temperature_1[15][15] = 32767
        local function matches(source, where)
            local out, n = df.readFields(source, {fields={'_index'}, where=where})
            return column(out, '_index', n)
        end
        local temp = block.temperature_1
        expect.table_eq(matches(temp, {{'_value', '==', 65535}}), {1})
        expect.table_eq(matches(temp, {{'_value', '==', -1}}), {})
        expect.table_eq(matches(temp, {{'_value', '>', 32767}}), {1, 48})
        expect.table_eq(matches(temp, {{'_value', '>=', 32767}}), {1, 48, 255})
        expect.table_eq(matches(temp, {{'_value', 'in', {32768, 65535, -1}}}), {1, 48})
        expect.table_eq(matches(temp, {{'_value', '<', 0}}), {})

        -- enum attributes, compared directly and through a second attribute step; a new block is all open space
        block.tiletype[0][0] = df.tiletype.Void
        block.tiletype[2][3] = df.tiletype.StoneFloor1
        block.tiletype[4][0] = df.tiletype.StoneWall
        local shape, basic = df.tiletype_shape, df.tiletype_shape_basic
        local tt = block.tiletype
        expect.table_eq(matches(tt, {{'shape', 'in', {shape.FLOOR, shape.WALL}}}), {35, 64})
        expect.table_eq(matches(tt, {{'shape.basic_shape', 'in', {basic.Wall, basic.Floor}}}), {35, 64})
        expect.table_eq(matches(tt, {{'shape.basic_shape', '~=', basic.Open}}), {0, 35, 64})
        expect.table_eq(matches(tt, {{'shape', '>', shape.EMPTY}}), {35, 64})
        -- a tile with no shape reads as -1, also on the way to the next attribute
        expect.table_eq(matches(tt, {{'shape', '<', 0}}), {0})
        expect.table_eq(matches(tt, {{'shape', '==', shape.NONE}, {'shape.basic_shape', '==', basic.None}}), {0})
        expect.table_eq(matches(tt, {{'shape.basic_shape', 'in', {basic.None, basic.Wall}}}), {0, 64})
    end)
end

function test.grids_read_together()
    with_block(function(block)
        block.tiletype[2][3] = df.tiletype.StoneFloor1
        block.tiletype[15][15] = df.tiletype.StoneFloor1
        block.tiletype[4][0] = df.tiletype.StoneWall
        block.designation[2][3].flow_size = 7
        block.designation[4][0].flow_size = 2
        block.designation[15][15].hidden = true
        local grids = {tt=block.tiletype, des=block.designation}

        local out, n = df.readFields(grids, {fields={'tt', 'des.flow_size', 'des'}})
        expect.eq(n, 256)
        for x = 0, 15 do
            for y = 0, 15 do
                local i = x * 16 + y + 1
                expect.eq(out.tt[i], block.tiletype[x][y])
                expect.eq(out['des.flow_size'][i], block.designation[x][y].flow_size)
                expect.eq(out.des[i], block.designation[x][y].whole)
            end
        end

        out, n = df.readFields(grids, {fields={'_index', 'des.flow_size'},
            where={{'tt.shape', '==', df.tiletype_shape.FLOOR}, {'des.hidden', '==', false}}})
        expect.eq(n, 1)
        expect.eq(out._index[1], 2 * 16 + 3)
        expect.eq(out['des.flow_size'][1], 7)

        out, n = df.readFields(grids, {fields={'_index'}, where={{'des.flow_size', '>', 0}}})
        expect.table_eq(column(out, '_index', n), {2 * 16 + 3, 4 * 16})

        out, n = df.readFields(grids, {fields={'_index'},
            where={{'tt.shape.basic_shape', '==', df.tiletype_shape_basic.Wall}}})
        expect.table_eq(column(out, '_index', n), {4 * 16})

        expect.error_match('same number of entries', function()
            df.readFields({tt=block.tiletype, row=block.tiletype[0]})
        end)
    end)
end

function test.test_function()
    with_job(function(job)
        local seen = {}
        local out, n = df.readFields(job.job_items.elements, {fields={'_index'},
            where={{'quantity', '>', 2}},
            test=function(index)
                table.insert(seen, index)
                return job.job_items.elements[index].mat_index ~= 30
            end})
        expect.table_eq(seen, {0, 2, 3})
        expect.table_eq(column(out, '_index', n), {0, 3})

        expect.error_match('changed size', function()
            df.readFields(job.items, {test=function()
                job.items:insert('#', {new=true})
                return true
            end})
        end)
    end)
end

function test.subclass_fields()
    with_job(function(job)
        local refs = job.general_refs
        local worker = df.general_ref_unit_workerst:new()
        worker.unit_id = 7
        local holder = df.general_ref_building_holderst:new()
        holder.building_id = 9
        refs:insert('#', worker)
        refs:insert('#', holder)
        dfhack.with_finalize(
            function()
                refs:resize(0)
                worker:delete()
                holder:delete()
            end,
            function()
                -- a field of a derived class is nil for entries of another class
                local out, n = df.readFields(refs, {fields={'unit_id', 'general_ref_building:building_id'}})
                expect.eq(n, 2)
                expect.eq(out.unit_id[1], 7)
                expect.eq(out.unit_id[2], nil)
                expect.eq(out['general_ref_building:building_id'][1], nil)
                expect.eq(out['general_ref_building:building_id'][2], 9)

                out, n = df.readFields(refs, {fields={'_index'}, where={{'general_ref_building:building_id', '==', 9}}})
                expect.table_eq(column(out, '_index', n), {1})
                out, n = df.readFields(refs, {where={{'unit_id', '~=', 100}}})
                expect.eq(n, 1)

                -- two unrelated reference classes have a building_id, so the class must be named
                expect.error_match('several classes', function() df.readFields(refs, {fields={'building_id'}}) end)
                out, n = df.readFields(refs, {fields={'general_ref_unit:unit_id'}})
                expect.eq(out['general_ref_unit:unit_id'][1], 7)
                expect.eq(out['general_ref_unit:unit_id'][2], nil)
                expect.error_match('does not name a class', function()
                    df.readFields(refs, {fields={'job_item:quantity'}})
                end)
            end)
    end)
end

function test.null_entries_are_skipped()
    with_job(function(job)
        local items = job.job_items.elements
        local removed = items[1]
        items[1] = nil
        dfhack.with_finalize(function() items[1] = removed end, function()
            local out, n = df.readFields(items, {fields={'_index', 'quantity'}})
            expect.eq(n, 4)
            expect.table_eq(column(out, '_index', n), {0, 2, 3, 4})
            expect.table_eq(column(out, 'quantity', n), {3, 7, 5, 2})
        end)
    end)
end

function test.test_function_may_move_entries()
    local path = df.coord_path:new()
    dfhack.with_finalize(function() path:delete() end, function()
        for _, v in ipairs{5, -2, 9, 0} do path.x:insert('#', v) end
        -- growing and shrinking the vector moves its storage without changing its size
        local out, n = df.readFields(path.x, {fields={'_value'}, test=function()
            for _ = 1, 64 do path.x:insert('#', 0) end
            path.x:resize(4)
            return true
        end})
        expect.eq(n, 4)
        expect.table_eq(column(out, '_value', n), {5, -2, 9, 0})
    end)
end

function test.many_conditions()
    with_job(function(job)
        local where, fields = {}, {}
        for i = 1, 60 do
            where[i] = {'quantity', '>', -i}
            fields[i] = i % 2 == 0 and 'quantity' or 'mat_index'
        end
        local out, n = df.readFields(job.job_items.elements, {fields=fields, where=where})
        expect.eq(n, 5)
        expect.table_eq(column(out, 'mat_index', n), {10, 20, 30, 40, 50})
    end)
end

function test.empty_groups()
    with_job(function(job)
        local out, n = df.readFields(job.job_items.elements, {where={{'and'}}})
        expect.eq(n, 5)
        out, n = df.readFields(job.job_items.elements, {where={{'or'}}})
        expect.eq(n, 0)
    end)
end

function test.out_is_reused()
    with_job(function(job)
        local out = {quantity={99, 98, 97, 96, 95, 94}, other={1}}
        local quantity = out.quantity
        local same, n = df.readFields(job.job_items.elements, {fields={'quantity'}, where={{'quantity', '>', 4}}}, out)
        expect.eq(same, out)
        expect.eq(out.quantity, quantity)
        expect.eq(n, 2)
        expect.table_eq(out.quantity, {7, 5, 97, 96, 95, 94})
        expect.table_eq(out.other, {1})
    end)
end

function test.repeated_fields()
    with_job(function(job)
        local fields = {}
        for i = 1, 300 do fields[i] = 'quantity' end
        local out, n = df.readFields(job.job_items.elements, {fields=fields})
        expect.eq(n, 5)
        expect.table_eq(column(out, 'quantity', n), {3, 1, 7, 5, 2})
    end)
end

function test.errors()
    with_job(function(job)
        local items = job.job_items.elements
        expect.error_match('Usage', function() df.readFields() end)
        expect.error_match('expected a container', function() df.readFields(5) end)
        expect.error_match('not a container', function() df.readFields(job) end)
        expect.error_match('options must be a table', function() df.readFields(items, 5) end)
        expect.error_match('out must be a table', function() df.readFields(items, {}, 5) end)
        expect.error_match("no field 'nope'", function() df.readFields(items, {fields={'nope'}}) end)
        expect.error_match("no flag 'nope'", function() df.readFields(items, {fields={'flags1.nope'}}) end)
        expect.error_match('not a single value', function() df.readFields(job.items, {fields={'item'}}) end)
        expect.error_match('no readable attribute', function() df.readFields(items, {fields={'item_type.nope'}}) end)
        expect.error_match('has no attributes', function() df.readFields(items, {fields={'quantity.nope'}}) end)
        expect.error_match('field names must be strings', function() df.readFields(items, {fields={5}}) end)
        expect.error_match('fields must be a table', function() df.readFields(items, {fields='quantity'}) end)
        expect.error_match('where must be a table', function() df.readFields(items, {where='quantity'}) end)
        expect.error_match('list of conditions', function() df.readFields(items, {where={quantity=3}}) end)
        expect.error_match('must be a table', function() df.readFields(items, {where={'quantity'}}) end)
        expect.error_match('unknown comparison', function() df.readFields(items, {where={{'quantity', '=', 1}}}) end)
        expect.error_match('no comparison', function() df.readFields(items, {where={{'quantity'}}}) end)
        expect.error_match('no usable value', function() df.readFields(items, {where={{'quantity', '<', true}}}) end)
        expect.error_match('no usable value', function() df.readFields(items, {where={{'quantity', '=='}}}) end)
        expect.error_match('needs a list', function() df.readFields(items, {where={{'quantity', 'in', 3}}}) end)
        expect.error_match('exactly one', function()
            df.readFields(items, {where={{'not', {'quantity', '==', 1}, {'quantity', '==', 2}}}})
        end)
        expect.error_match('test must be a function', function() df.readFields(items, {test=5}) end)
        expect.error_match('name of a container', function() df.readFields({a=items}, {fields={'quantity'}}) end)
        expect.error_match('string names', function() df.readFields({a=items, [2]=items}) end)
        expect.error_match('cannot be used as a container name', function() df.readFields({_from=items}) end)
    end)
end

function test.null_pointers()
    with_job(function(job)
        local out, n = df.readFields(job.items, {fields={'_index'}, where={{'item', '==', df.NULL}}})
        expect.eq(n, 2)
        out, n = df.readFields(job.items, {where={{'item', '~=', df.NULL}}})
        expect.eq(n, 0)

        local item = df.item_boulderst:new()
        dfhack.with_finalize(
            function()
                job.items[1].item = nil
                item:delete()
            end,
            function()
                job.items[1].item = item
                out, n = df.readFields(job.items, {fields={'_index'}, where={{'item', '==', df.NULL}}})
                expect.eq(n, 1)
                expect.eq(out._index[1], 0)
                out, n = df.readFields(job.items, {fields={'_index'}, where={{'item', '~=', df.NULL}}})
                expect.eq(n, 1)
                expect.eq(out._index[1], 1)
                out, n = df.readFields(job.items, {fields={'_index'}, where={{'not', {'item', '==', df.NULL}}}})
                expect.eq(n, 1)
                expect.eq(out._index[1], 1)
                out, n = df.readFields(job.items, {where={{'or', {'item', '==', df.NULL}, {'job_item_idx', '==', 2}}}})
                expect.eq(n, 2)
            end)

        expect.error_match('only be compared with df.NULL', function()
            df.readFields(job.items, {where={{'item', '==', 5}}})
        end)
        expect.error_match('only be compared with df.NULL', function()
            df.readFields(job.items, {where={{'item', '<', df.NULL}}})
        end)
        expect.error_match('only be compared with df.NULL', function()
            df.readFields(job.items, {where={{'item', 'in', {df.NULL}}}})
        end)
        -- a pointer is still not something to hand back
        expect.error_match('not a single value', function() df.readFields(job.items, {fields={'item'}}) end)
    end)
end

function test.comparisons_on_text()
    with_job(function(job)
        local items = job.job_items.elements
        local texts = {'pear', '', 'apple', 'pear', 'Apple'}
        for i, text in ipairs(texts) do items[i - 1].reaction_class = text end
        local function matching(cond)
            local out, n = df.readFields(items, {fields={'_index'}, where={cond}})
            return column(out, '_index', n)
        end
        expect.table_eq(matching{'reaction_class', '==', 'pear'}, {0, 3})
        expect.table_eq(matching{'reaction_class', '~=', 'pear'}, {1, 2, 4})
        expect.table_eq(matching{'reaction_class', '==', ''}, {1})
        expect.table_eq(matching{'reaction_class', '==', 'pea'}, {})
        expect.table_eq(matching{'reaction_class', 'in', {'apple', 'Apple', 7, true}}, {2, 4})
        expect.table_eq(matching{'reaction_class', 'in', {}}, {})
        -- text is put in order the way Lua does it
        for _, op in ipairs{'<', '<=', '>', '>='} do
            local want = {}
            for i, text in ipairs(texts) do
                local yes
                if op == '<' then yes = text < 'b' elseif op == '<=' then yes = text <= 'apple'
                elseif op == '>' then yes = text > 'apple' else yes = text >= 'pear' end
                if yes then want[#want + 1] = i - 1 end
            end
            local against = op == '<' and 'b' or op == '>=' and 'pear' or 'apple'
            expect.table_eq(matching{'reaction_class', op, against}, want, op)
        end
        -- values of different kinds are never equal and never in order
        expect.table_eq(matching{'reaction_class', '==', 5}, {})
        expect.table_eq(matching{'reaction_class', '~=', 5}, {0, 1, 2, 3, 4})
        expect.table_eq(matching{'reaction_class', '<', 5}, {})
        expect.table_eq(matching{'reaction_class', '>=', 5}, {})
        expect.table_eq(matching{'quantity', '==', '3'}, {})
        expect.table_eq(matching{'quantity', '~=', '3'}, {0, 1, 2, 3, 4})
        expect.table_eq(matching{'quantity', '<', 'a'}, {})
        expect.table_eq(matching{'quantity', '==', true}, {})
        expect.table_eq(matching{'flags1.improvable', '==', 1}, {})
        expect.table_eq(matching{'flags1.improvable', '~=', 1}, {0, 1, 2, 3, 4})
        expect.table_eq(matching{'flags1.improvable', 'in', {true}}, {1, 3})
        expect.table_eq(matching{'flags1.improvable', 'in', {false, 1}}, {0, 2, 4})
    end)
end

function test.comparisons_on_decimals_and_booleans()
    local mat = df.material:new()
    dfhack.with_finalize(function() mat:delete() end, function()
        mat.mat_rgb[0], mat.mat_rgb[1], mat.mat_rgb[2] = 0.5, 2, -1.25
        local function matching(cond)
            local out, n = df.readFields(mat.mat_rgb, {fields={'_index'}, where={cond}})
            return column(out, '_index', n)
        end
        expect.table_eq(matching{'_value', '==', 0.5}, {0})
        expect.table_eq(matching{'_value', '==', 2}, {1})
        expect.table_eq(matching{'_value', '==', 2.0}, {1})
        expect.table_eq(matching{'_value', '~=', 2}, {0, 2})
        expect.table_eq(matching{'_value', '<', 1}, {0, 2})
        expect.table_eq(matching{'_value', '<', 0.5}, {2})
        expect.table_eq(matching{'_value', '<=', 0.5}, {0, 2})
        expect.table_eq(matching{'_value', '>', -2}, {0, 1, 2})
        expect.table_eq(matching{'_value', '>=', 2}, {1})
        expect.table_eq(matching{'_value', 'in', {2, 0.5, 'x'}}, {0, 1})
        expect.table_eq(matching{'_value', 'in', {2.0, -1.25}}, {1, 2})
        expect.table_eq(matching{'_value', '==', '2'}, {})
        expect.table_eq(matching{'_value', '<', 'x'}, {})
        -- not-a-number is equal to nothing and in no order with anything
        mat.mat_rgb[0] = 0 / 0
        expect.table_eq(matching{'_value', '==', 0 / 0}, {})
        expect.table_eq(matching{'_value', '~=', 2}, {0, 2})
        expect.table_eq(matching{'_value', '<', 100}, {1, 2})
        expect.table_eq(matching{'_value', '>=', -100}, {1, 2})
        expect.table_eq(matching{'_value', 'in', {0 / 0, 2}}, {1})
    end)

    local pile = df.stockpile_parameter_furniturest:new()
    dfhack.with_finalize(function() pile:delete() end, function()
        pile.quality_core[2] = true
        pile.quality_core[5] = true
        local function matching(cond)
            local out, n = df.readFields(pile.quality_core, {fields={'_index'}, where={cond}})
            return column(out, '_index', n)
        end
        expect.table_eq(matching{'_value', '==', true}, {2, 5})
        expect.table_eq(matching{'_value', '~=', true}, {0, 1, 3, 4, 6})
        expect.table_eq(matching{'_value', '==', false}, {0, 1, 3, 4, 6})
        expect.table_eq(matching{'_value', 'in', {true}}, {2, 5})
        expect.table_eq(matching{'_value', '==', 1}, {})
        expect.error_match('no usable value', function() matching{'_value', '<', true} end)
    end)
end

function test.conditions_on_grids()
    with_block(function(block)
        for x = 0, 15 do
            for y = 0, 15 do
                block.designation[x][y].flow_size = (x + y) % 8
                block.designation[x][y].hidden = x >= 8
                block.temperature_1[x][y] = x * 16 + y
            end
        end
        local source = {des=block.designation, t=block.temperature_1}
        local function check(where, want)
            local out, n = df.readFields(source, {fields={'_index'}, where=where})
            local expected = {}
            for index = 0, 255 do
                local x, y = index // 16, index % 16
                if want(block.designation[x][y], index) then expected[#expected + 1] = index end
            end
            expect.table_eq(column(out, '_index', n), expected)
        end
        check({{'des.flow_size', '>', 3}}, function(des) return des.flow_size > 3 end)
        check({{'des.flow_size', 'in', {0, 7, 9}}}, function(des) return des.flow_size == 0 or des.flow_size == 7 end)
        check({{'des.hidden', '==', false}, {'des.flow_size', '~=', 2}},
              function(des) return not des.hidden and des.flow_size ~= 2 end)
        check({{'des.hidden', '==', false}, {'or', {'des.flow_size', '>', 5}, {'and', {'t', 'in', {3, 40, 200}},
                                                                             {'des.flow_size', '<=', 3}}}},
              function(des, index)
                  return not des.hidden and (des.flow_size > 5 or
                      ((index == 3 or index == 40 or index == 200) and des.flow_size <= 3))
              end)
        check({{'des', '==', block.designation[1][2].whole}},
              function(des) return des.whole == block.designation[1][2].whole end)
        check({{'t', 'in', {5, 100000, -3, 250}}}, function(_, index) return index == 5 or index == 250 end)
        check({{'t', 'in', {}}}, function() return false end)
        check({{'_index', 'in', {0, 255, 256, -1}}}, function(_, index) return index == 0 or index == 255 end)
        check({{'_index', '>=', 250}, {'t', '<', 253}}, function(_, index) return index >= 250 and index < 253 end)
        check({{'not', {'t', 'in', {1, 2, 3}}}, {'_index', '<', 6}},
              function(_, index) return index < 6 and not (index >= 1 and index <= 3) end)
    end)
end

function test.lists_of_containers()
    with_job(function(job)
        with_job(function(other)
            local a, b = job.job_items.elements, other.job_items.elements
            b[4]:delete()
            b:erase(4)
            b[0].quantity = 100

            local out, n = df.readFields({a, b}, {fields={'_from', '_index', 'quantity'}})
            expect.eq(n, 9)
            expect.table_eq(column(out, '_from', n), {1, 1, 1, 1, 1, 2, 2, 2, 2})
            expect.table_eq(column(out, '_index', n), {0, 1, 2, 3, 4, 0, 1, 2, 3})
            expect.table_eq(column(out, 'quantity', n), {3, 1, 7, 5, 2, 100, 1, 7, 5})

            out, n = df.readFields({b, a, b}, {fields={'_from', '_index'}, where={{'quantity', '>=', 5}}})
            expect.table_eq(column(out, '_from', n), {1, 1, 1, 2, 2, 3, 3, 3})
            expect.table_eq(column(out, '_index', n), {0, 2, 3, 2, 3, 0, 2, 3})

            -- one container reads as a list of one
            out, n = df.readFields(a, {fields={'_from'}})
            expect.table_eq(column(out, '_from', n), {1, 1, 1, 1, 1})
            out, n = df.readFields({a})
            expect.eq(n, 5)

            -- nothing to read from
            out, n = df.readFields({}, {fields={'quantity'}})
            expect.eq(n, 0)

            local seen = {}
            out, n = df.readFields({a, b}, {fields={'_from'}, test=function(index)
                seen[#seen + 1] = index
                return index == 3
            end})
            expect.table_eq(seen, {0, 1, 2, 3, 4, 0, 1, 2, 3})
            expect.table_eq(column(out, '_from', n), {1, 2})

            expect.error_match('not of the kind', function() df.readFields({a, job.items}) end)
            expect.error_match('expected a container', function() df.readFields({a, 5}) end)
            expect.error_match('expected a container', function() df.readFields({a, {x=b}}) end)
            expect.error_match("'_from' cannot be used in a condition", function()
                df.readFields({a, b}, {where={{'_from', '==', 1}}})
            end)
        end)
    end)

    with_block(function(block)
        with_block(function(other)
            block.designation[0][5].flow_size = 7
            other.designation[2][0].flow_size = 4
            block.temperature_1[0][5] = 0
            other.temperature_1[2][0] = 9
            local out, n = df.readFields(
                {{des=block.designation, t=block.temperature_1}, {des=other.designation, t=other.temperature_1}},
                {fields={'_from', '_index', 'des.flow_size', 't'}, where={{'des.flow_size', '>', 0}}})
            expect.eq(n, 2)
            expect.table_eq(column(out, '_from', n), {1, 2})
            expect.table_eq(column(out, '_index', n), {5, 32})
            expect.table_eq(column(out, 'des.flow_size', n), {7, 4})
            expect.table_eq(column(out, 't', n), {0, 9})
            expect.error_match("no container named", function()
                df.readFields({{des=block.designation, t=block.temperature_1}, {des=other.designation}})
            end)
            expect.error_match('table of named containers', function()
                df.readFields({{des=block.designation}, other.designation})
            end)
        end)
    end)
end

function test.prepared_reads()
    with_job(function(job)
        with_job(function(other)
            local a, b = job.job_items.elements, other.job_items.elements
            b[2].quantity = 50
            local where = {{'quantity', '>', 4}}
            local options = {fields={'_from', '_index', 'quantity'}, where=where}
            local read = df.prepareReadFields(a, options)
            expect.eq(type(read), 'function')

            local out, n = read(a)
            expect.table_eq(column(out, '_index', n), {2, 3})
            expect.table_eq(column(out, 'quantity', n), {7, 5})

            -- the options were taken in when the read was prepared
            where[1][3] = 0
            options.fields = {}
            local again, m = read(b, out)
            expect.eq(again, out)
            expect.table_eq(column(out, '_index', m), {2, 3})
            expect.table_eq(column(out, 'quantity', m), {50, 5})

            out, n = read({a, b, a})
            expect.table_eq(column(out, '_from', n), {1, 1, 2, 2, 3, 3})
            expect.table_eq(column(out, 'quantity', n), {7, 5, 50, 5, 7, 5})

            out, n = read({})
            expect.eq(n, 0)

            -- the same answers as an unprepared read
            local plain, count = df.readFields({b, a}, {fields={'_from', '_index', 'quantity'}, where={{'quantity', '>', 4}}})
            out, n = read({b, a})
            expect.eq(n, count)
            for _, name in ipairs{'_from', '_index', 'quantity'} do
                expect.table_eq(column(out, name, n), column(plain, name, count), name)
            end

            -- a list can stand in for the container when preparing
            local from_list = df.prepareReadFields({a, b}, {fields={'quantity'}})
            out, n = from_list(b)
            expect.eq(n, 5)

            local calls = 0
            local tested = df.prepareReadFields(a, {fields={'_index'}, test=function(index)
                calls = calls + 1
                return index % 2 == 0
            end})
            out, n = tested(a)
            expect.table_eq(column(out, '_index', n), {0, 2, 4})
            out, n = tested({a, b})
            expect.eq(n, 6)
            expect.eq(calls, 15)
            -- a prepared read can be used from inside its own test function
            local nested = 0
            local outer
            outer = df.prepareReadFields(a, {test=function(index)
                if index == 0 and nested < 3 then
                    nested = nested + 1
                    local _, inner = outer(b)
                    expect.eq(inner, 5)
                end
                return true
            end})
            out, n = outer(a)
            expect.eq(n, 5)

            expect.error_match('not of the kind', function() read(job.items) end)
            expect.error_match('expected a container', function() read(5) end)
            expect.error_match('out must be a table', function() read(a, 5) end)
            expect.error_match('Usage', function() read() end)
            expect.error_match('Usage', function() df.prepareReadFields() end)
            expect.error_match('no containers', function() df.prepareReadFields({}) end)
            expect.error_match("no field 'nope'", function() df.prepareReadFields(a, {fields={'nope'}}) end)
            expect.error_match('options must be a table', function() df.prepareReadFields(a, 5) end)
        end)
    end)

    with_block(function(block)
        with_block(function(other)
            block.designation[0][5].flow_size = 7
            other.designation[2][0].flow_size = 4
            local read = df.prepareReadFields({des=block.designation, tt=block.tiletype},
                {fields={'_from', '_index', 'des.flow_size'}, where={{'des.flow_size', '>', 0}}})
            local out, n = read({des=other.designation, tt=other.tiletype})
            expect.table_eq(column(out, '_index', n), {32})
            out, n = read({{des=other.designation, tt=other.tiletype}, {des=block.designation, tt=block.tiletype}})
            expect.table_eq(column(out, '_from', n), {1, 2})
            expect.table_eq(column(out, '_index', n), {32, 5})
            expect.error_match('not of the kind', function() read({des=other.tiletype, tt=other.tiletype}) end)
        end)
    end)
end
