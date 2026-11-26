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
        expect.error_match('string names', function() df.readFields({items}) end)
        expect.error_match('no containers', function() df.readFields({}) end)
    end)
end
