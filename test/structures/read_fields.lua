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
        expect.table_eq(out.quantity, {7, 5})
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
        expect.error_match('not a single value', function() df.readFields(job.items, {where={{'_value', '==', 1}}}) end)
        expect.error_match('no readable attribute', function() df.readFields(items, {fields={'item_type.nope'}}) end)
        expect.error_match('has no attributes', function() df.readFields(items, {fields={'quantity.nope'}}) end)
        expect.error_match('must be a string or', function() df.readFields(items, {fields={5}}) end)
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
        expect.error_match('not a single value', function() df.readFields(job.items, {where={{'_value', '==', 1}}}) end)
    end)
end

function test.null_test_behind_a_null_pointer()
    local handler = df.job_handler:new()
    local job = df.job:new()
    local link = df.job_list_link:new()
    local postings = handler.postings
    dfhack.with_finalize(
        function()
            job.list_link = nil
            for i = #postings - 1, 0, -1 do
                postings[i].job = nil
                postings[i]:delete()
            end
            postings:resize(0)
            link:delete()
            job:delete()
            handler:delete()
        end,
        function()
            for _ = 1, 3 do postings:insert('#', {new=true}) end
            postings[1].job = job
            postings[2].job = job
            local function matching(cond)
                local out, n = df.readFields(postings, {fields={'_index'}, where={cond}})
                return column(out, '_index', n)
            end
            -- entry 0 has no job, so nothing can be said about its job's pointer
            expect.table_eq(matching{'job.list_link', '==', df.NULL}, {1, 2})
            expect.table_eq(matching{'job.list_link', '~=', df.NULL}, {})
            expect.table_eq(matching{'not', {'job.list_link', '==', df.NULL}}, {0})
            job.list_link = link
            expect.table_eq(matching{'job.list_link', '==', df.NULL}, {})
            expect.table_eq(matching{'job.list_link', '~=', df.NULL}, {1, 2})
            expect.table_eq(matching{'job.list_link.next', '==', df.NULL}, {1, 2})
            expect.table_eq(matching{'job.list_link.next', '~=', df.NULL}, {})
            expect.table_eq(matching{'job', '==', df.NULL}, {0})
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

        -- a flag field that lies across two bytes, with its neighbours set
        for x = 0, 15 do
            for y = 0, 15 do
                local des = block.designation[x][y]
                des.dig = (x + 2 * y) % 7
                des.smooth = (x * 3 + y) % 4
                des.hidden = (x + y) % 2 == 0
            end
        end
        for value = 0, 3 do
            check({{'des.smooth', '==', value}}, function(des) return des.smooth == value end)
        end
        check({{'des.smooth', 'in', {1, 2}}}, function(des) return des.smooth == 1 or des.smooth == 2 end)
        check({{'des.smooth', '>=', 2}, {'des.hidden', '==', true}},
              function(des) return des.smooth >= 2 and des.hidden end)
        check({{'des.dig', '~=', 0}, {'des.smooth', '<', 3}}, function(des) return des.dig ~= 0 and des.smooth < 3 end)

        -- enum attributes of numbers that are in the enum and of numbers that are not
        local types = {df.tiletype.OpenSpace, df.tiletype.StoneFloor1, 60000, df.tiletype.StoneWall,
                       df.tiletype._last_item + 1, df.tiletype.Void}
        for x = 0, 15 do
            for y = 0, 15 do block.tiletype[x][y] = types[(x * 16 + y) % #types + 1] end
        end
        local function check_types(cond, want)
            local out, n = df.readFields({tt=block.tiletype}, {fields={'_index'}, where={cond}})
            local expected = {}
            for index = 0, 255 do
                if want(df.tiletype.attrs[block.tiletype[index // 16][index % 16]]) then
                    expected[#expected + 1] = index
                end
            end
            expect.table_eq(column(out, '_index', n), expected)
        end
        for _, shape in ipairs{df.tiletype_shape.FLOOR, df.tiletype_shape.WALL, df.tiletype_shape.NONE,
                               df.tiletype.attrs[60000].shape} do
            check_types({'tt.shape', '==', shape}, function(attrs) return attrs.shape == shape end)
            check_types({'tt.shape', '~=', shape}, function(attrs) return attrs.shape ~= shape end)
        end
        check_types({'tt.shape', 'in', {df.tiletype_shape.FLOOR, df.tiletype.attrs[60000].shape}},
                    function(attrs)
                        return attrs.shape == df.tiletype_shape.FLOOR or attrs.shape == df.tiletype.attrs[60000].shape
                    end)
        check_types({'tt.material', '==', df.tiletype.attrs[60000].material},
                    function(attrs) return attrs.material == df.tiletype.attrs[60000].material end)
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
            -- '_from' in a condition
            out, n = df.readFields({a, b}, {fields={'_from', '_index'}, where={{'_from', '==', 2}, {'quantity', '>', 4}}})
            expect.table_eq(column(out, '_from', n), {2, 2, 2})
            expect.table_eq(column(out, '_index', n), {0, 2, 3})
            out, n = df.readFields({a, b}, {fields={'_index'},
                where={{'or', {'and', {'_from', '==', 1}, {'_index', '==', 4}},
                              {'and', {'_from', 'in', {2}}, {'_index', '<', 1}}}}})
            expect.table_eq(column(out, '_index', n), {4, 0})
            out, n = df.readFields(a, {where={{'_from', '==', 1}}})
            expect.eq(n, 5)
            expect.error_match("'_from' cannot be used in the conditions of any or all", function()
                df.readFields({job}, {where={{'job_items.elements', 'any', {{'_from', '==', 1}}}}})
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
            -- the first table says which names are read; others in later tables are left alone
            out, n = df.readFields({{des=block.designation}, {des=other.designation, t=other.temperature_1}},
                                   {fields={'_from'}, where={{'des.flow_size', '>', 0}}})
            expect.table_eq(column(out, '_from', n), {1, 2})
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
            b[4]:delete()
            b:erase(4)
            local nested = 0
            local outer
            outer = df.prepareReadFields(a, {fields={'_from', '_index', 'quantity'}, where={{'quantity', '>', 2}},
                test=function(index)
                    if nested < 3 then
                        nested = nested + 1
                        local inner, count = outer({b, b})
                        expect.table_eq(column(inner, '_from', count), {1, 1, 1, 2, 2, 2})
                        expect.table_eq(column(inner, '_index', count), {0, 2, 3, 0, 2, 3})
                        expect.table_eq(column(inner, 'quantity', count), {3, 50, 5, 3, 50, 5})
                    end
                    return true
                end})
            out, n = outer(a)
            expect.eq(nested, 3)
            expect.table_eq(column(out, '_from', n), {1, 1, 1})
            expect.table_eq(column(out, '_index', n), {0, 2, 3})
            expect.table_eq(column(out, 'quantity', n), {3, 7, 5})

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

-- the 0-based indexes of the entries of a 16x16 grid in the rectangle x1..x2, y1..y2
local function rectangle(x1, x2, y1, y2)
    local indexes = {}
    for x = math.max(x1, 0), math.min(x2, 15) do
        for y = math.max(y1, 0), math.min(y2, 15) do
            indexes[#indexes + 1] = x * 16 + y
        end
    end
    return indexes
end

local function seq(first, last)
    local values = {}
    for i = first, last do values[#values + 1] = i end
    return values
end

function test.range_on_a_vector()
    with_job(function(job)
        local items = job.job_items.elements
        local function read(range, where)
            local out, n = df.readFields({items=items, _range=range},
                {fields={'_index', 'items.quantity'}, where=where})
            return column(out, '_index', n), column(out, 'items.quantity', n)
        end
        local indexes, quantities = read{1, 3}
        expect.table_eq(indexes, {1, 2, 3})
        expect.table_eq(quantities, {1, 7, 5})
        expect.table_eq(read{0, 0}, {0})
        expect.table_eq(read{4, 4}, {4})
        expect.table_eq(read{0, 4}, {0, 1, 2, 3, 4})

        -- whole numbers that are stored as decimals are fine
        expect.table_eq(read{1.0, 2.0}, {1, 2})

        -- values outside the container are clamped to it
        expect.table_eq(read{3, 100}, {3, 4})
        expect.table_eq(read{-5, 1}, {0, 1})
        expect.table_eq(read{-100, 100}, {0, 1, 2, 3, 4})
        expect.table_eq(read{math.mininteger, math.maxinteger}, {0, 1, 2, 3, 4})

        -- an empty range reads nothing
        expect.table_eq(read{3, 1}, {})
        expect.table_eq(read{5, 9}, {})
        expect.table_eq(read{-9, -1}, {})
        expect.table_eq(read{math.maxinteger, math.mininteger}, {})

        -- the conditions only see entries in the range
        indexes, quantities = read({1, 3}, {{'items.quantity', '>', 2}})
        expect.table_eq(indexes, {2, 3})
        expect.table_eq(quantities, {7, 5})
        expect.table_eq(read({1, 4}, {{'_index', '>=', 2}}), {2, 3, 4})
        expect.table_eq(read({0, 1}, {{'items.quantity', '>', 5}}), {})

        -- the test function is only called for entries in the range
        local seen = {}
        df.readFields({items=items, _range={2, 3}}, {test=function(index)
            seen[#seen + 1] = index
            return true
        end})
        expect.table_eq(seen, {2, 3})

        -- a single container, with the range given on its own
        local out, n = df.readFields(items, {fields={'_index'}}, nil, {{1, 2}})
        expect.table_eq(column(out, '_index', n), {1, 2})
        out, n = df.readFields(items, {fields={'_index'}}, {}, {{4, 9}})
        expect.table_eq(column(out, '_index', n), {4})

        -- the range is only a part of the reading: the name '_range' is not a container
        out, n = df.readFields({items=items, _range={0, 1}})
        expect.eq(n, 2)
    end)
end

function test.range_on_a_grid()
    with_block(function(block)
        local function read(range, where)
            local out, n = df.readFields({des=block.designation, _range=range},
                {fields={'_index'}, where=where})
            return column(out, '_index', n)
        end
        expect.table_eq(read{2, 4, 3, 5}, rectangle(2, 4, 3, 5))
        expect.table_eq(read{0, 15, 0, 15}, seq(0, 255))
        expect.table_eq(read{0, 0, 0, 0}, {0})
        expect.table_eq(read{15, 15, 15, 15}, {255})
        expect.table_eq(read{7, 7, 0, 15}, seq(112, 127))
        expect.table_eq(read{0, 15, 5, 5}, rectangle(0, 15, 5, 5))

        -- two numbers limit the first index only
        expect.table_eq(read{3, 4}, seq(48, 79))
        expect.table_eq(read{14, 100}, seq(224, 255))

        -- clamped
        expect.table_eq(read{-3, 1, 14, 40}, rectangle(0, 1, 14, 15))
        expect.table_eq(read{-100, 100, -100, 100}, seq(0, 255))
        expect.table_eq(read{15, 100, 15, 100}, {255})
        expect.table_eq(read{math.mininteger, math.maxinteger, math.mininteger, math.maxinteger}, seq(0, 255))

        -- empty
        expect.table_eq(read{5, 2, 0, 15}, {})
        expect.table_eq(read{0, 15, 9, 3}, {})
        expect.table_eq(read{16, 20, 0, 15}, {})
        expect.table_eq(read{0, 15, 16, 20}, {})
        expect.table_eq(read{-5, -1, 0, 15}, {})
        expect.table_eq(read{0, 15, -5, -1}, {})
        expect.table_eq(read{6, 2}, {})

        -- grids read together share the range
        block.tiletype[2][3] = df.tiletype.StoneFloor1
        block.tiletype[2][9] = df.tiletype.StoneFloor1
        block.tiletype[6][3] = df.tiletype.StoneFloor1
        block.tiletype[3][4] = df.tiletype.StoneFloor1
        block.designation[2][3].flow_size = 7
        block.designation[2][9].flow_size = 7
        block.designation[6][3].flow_size = 7
        block.designation[3][4].flow_size = 5
        local grids = {tt=block.tiletype, des=block.designation, _range={2, 4, 3, 5}}
        local out, n = df.readFields(grids, {fields={'_index', 'des.flow_size'},
            where={{'des.flow_size', '>', 0}}})
        expect.table_eq(column(out, '_index', n), {2 * 16 + 3, 3 * 16 + 4})
        expect.table_eq(column(out, 'des.flow_size', n), {7, 5})

        out, n = df.readFields(grids, {fields={'_index'}, where={{'tt.shape', '==', df.tiletype_shape.FLOOR}}})
        expect.table_eq(column(out, '_index', n), {2 * 16 + 3, 3 * 16 + 4})

        -- the index conditions work on the full-grid index
        out, n = df.readFields(grids, {fields={'_index'}, where={{'_index', '>=', 3 * 16}}})
        expect.table_eq(column(out, '_index', n), rectangle(3, 4, 3, 5))

        -- only the range is looked at, and in the order of the index
        local seen = {}
        df.readFields(grids, {test=function(index)
            seen[#seen + 1] = index
            return false
        end})
        expect.table_eq(seen, rectangle(2, 4, 3, 5))

        -- without a range, nothing changes
        out, n = df.readFields({tt=block.tiletype, des=block.designation}, {fields={'_index'},
            where={{'des.flow_size', '>', 0}}})
        expect.table_eq(column(out, '_index', n), {2 * 16 + 3, 2 * 16 + 9, 3 * 16 + 4, 6 * 16 + 3})

        -- a grid with the range given on its own
        out, n = df.readFields(block.designation, {fields={'_index'}, where={{'flow_size', '>', 0}}}, nil,
            {{2, 3, 4, 15}})
        expect.table_eq(column(out, '_index', n), {2 * 16 + 9, 3 * 16 + 4})
    end)
end

function test.range_in_lists()
    with_block(function(a)
        with_block(function(b)
            local function read(items, ranges)
                local out, n = df.readFields(items, {fields={'_from', '_index'}}, nil, ranges)
                return column(out, '_from', n), column(out, '_index', n)
            end

            local from, index = read{
                {des=a.designation, _range={0, 0, 0, 1}},
                {des=b.designation, _range={15, 15, 14, 15}},
                {des=a.designation},
                {des=b.designation, _range={20, 30, 0, 15}},
                {des=a.designation, _range={1, 1, 0, 0}},
            }
            local expected_from, expected_index = {1, 1, 2, 2}, {0, 1, 254, 255}
            for i = 0, 255 do
                expected_from[#expected_from + 1] = 3
                expected_index[#expected_index + 1] = i
            end
            expected_from[#expected_from + 1] = 5
            expected_index[#expected_index + 1] = 16
            expect.table_eq(from, expected_from)
            expect.table_eq(index, expected_index)

            -- the first item may have no range while the others do
            from, index = read{{des=a.designation}, {des=b.designation, _range={0, 0, 3, 3}}}
            expect.eq(#from, 257)
            expect.eq(from[256], 1)
            expect.eq(from[257], 2)
            expect.eq(index[257], 3)

            -- ranges given apart from the items, by place
            from, index = read({a.designation, b.designation, a.designation}, {{0, 0, 0, 0}, {15, 15, 15, 15}, {3, 3, 3, 4}})
            expect.table_eq(from, {1, 2, 3, 3})
            expect.table_eq(index, {0, 255, 3 * 16 + 3, 3 * 16 + 4})

            -- a place without a range reads everything
            from, index = read({a.designation, b.designation}, {nil, {1, 1, 0, 0}})
            expect.eq(#from, 257)
            expect.eq(from[257], 2)
            expect.eq(index[257], 16)

            -- ranges of named containers, and in a list of ranges, on the same read
            from, index = read({{des=a.designation, _range={0, 0, 0, 0}}, {des=b.designation}}, {nil, {2, 2, 0, 1}})
            expect.table_eq(from, {1, 2, 2})
            expect.table_eq(index, {0, 32, 33})

            -- an empty range in the middle
            from, index = read{
                {des=a.designation, _range={0, 0, 0, 0}},
                {des=b.designation, _range={5, 1, 0, 0}},
                {des=a.designation, _range={0, 0, 15, 15}},
            }
            expect.table_eq(from, {1, 3})
            expect.table_eq(index, {0, 15})
        end)
    end)
end

function test.range_with_prepared_reads()
    with_block(function(a)
        with_block(function(b)
            a.designation[1][2].flow_size = 3
            a.designation[8][8].flow_size = 4
            b.designation[1][3].flow_size = 5

            local read = df.prepareReadFields({des=a.designation},
                {fields={'_from', '_index'}, where={{'des.flow_size', '>', 0}}})
            local out, n = read({des=a.designation})
            expect.table_eq(column(out, '_index', n), {1 * 16 + 2, 8 * 16 + 8})

            -- the same read, with a different range every time
            local ranges = {{0, 7, 0, 15}, {8, 15, 0, 15}, {1, 1, 3, 3}, {1, 1, 2, 2}, {9, 9, 0, 15}}
            local expected = {{18}, {136}, {}, {18}, {}}
            for i, range in ipairs(ranges) do
                out = {}
                out, n = read({des=a.designation, _range=range}, out)
                expect.table_eq(column(out, '_index', n), expected[i], 'range ' .. i)
            end

            out, n = read({{des=a.designation, _range={0, 0, 0, 15}}, {des=b.designation, _range={1, 1, 3, 3}},
                           {des=a.designation, _range={8, 8, 8, 8}}})
            expect.table_eq(column(out, '_from', n), {2, 3})
            expect.table_eq(column(out, '_index', n), {1 * 16 + 3, 8 * 16 + 8})

            -- the same prepared read with the ranges apart from the containers
            local plain = df.prepareReadFields(a.designation,
                {fields={'_from', '_index'}, where={{'flow_size', '>', 0}}})
            out, n = plain(a.designation, nil, {{0, 15, 0, 15}})
            expect.table_eq(column(out, '_index', n), {1 * 16 + 2, 8 * 16 + 8})
            out, n = plain(a.designation, nil, {{2, 15, 0, 15}})
            expect.table_eq(column(out, '_index', n), {8 * 16 + 8})
            out, n = plain(a.designation, nil, {{0, 15, 3, 15}})
            expect.table_eq(column(out, '_index', n), {8 * 16 + 8})
            out, n = plain({a.designation, b.designation}, nil, {{0, 1, 0, 15}, {1, 1, 0, 15}})
            expect.table_eq(column(out, '_from', n), {1, 2})
            expect.table_eq(column(out, '_index', n), {1 * 16 + 2, 1 * 16 + 3})
            out, n = plain({a.designation, b.designation})
            expect.eq(n, 3)

            -- the reuse of the output table works with ranges
            local keep = {}
            out, n = plain(a.designation, keep, {{0, 15, 0, 15}})
            expect.eq(out, keep)
            expect.eq(n, 2)
            out, n = plain(a.designation, keep, {{0, 0, 0, 0}})
            expect.eq(n, 0)
        end)
    end)
end

function test.range_errors()
    with_job(function(job)
        with_block(function(block)
            local items = job.job_items.elements
            local function range(value)
                return function() df.readFields({items=items, _range=value}) end
            end
            expect.error_match('range must be a table', range(5))
            expect.error_match('range must be a table', range('0,1'))
            expect.error_match('range must be a table', range(true))
            expect.error_match('range must be a table', range({}))
            expect.error_match('range must be a table', range({1}))
            expect.error_match('range must be a table', range({1, 2, 3}))
            expect.error_match('range must be a table', range({1, 2, 3, 4, 5}))
            expect.error_match('range must be a table', range({first=1, last=2}))
            expect.error_match('whole numbers', range({0.5, 2}))
            expect.error_match('whole numbers', range({0, 1.5}))
            expect.error_match('whole numbers', range({'0', 1}))
            expect.error_match('whole numbers', range({0, '1'}))
            expect.error_match('whole numbers', range({0, true}))
            expect.error_match('whole numbers', range({0, math.huge}))
            expect.error_match('whole numbers', range({-math.huge, 1}))
            expect.error_match('whole numbers', range({0, 0 / 0}))
            expect.error_match('whole numbers', range({0, 2 ^ 70}))
                expect.error_match('whole numbers', range({df.NULL, 2}))
            expect.error_match('container of containers', range({0, 1, 0, 1}))

            expect.error_match('ranges must be a table', function() df.readFields(items, {}, nil, 5) end)
            expect.error_match('ranges must be a table', function() df.readFields(items, {}, nil, 'a') end)
            expect.error_match('range must be a table', function() df.readFields(items, {}, nil, {5}) end)
            expect.error_match('range must be a table', function() df.readFields(items, {}, nil, {{1}}) end)
            expect.error_match('whole numbers', function() df.readFields(items, {}, nil, {{0.5, 1}}) end)
            expect.error_match('container of containers', function() df.readFields(items, {}, nil, {{0, 1, 0, 1}}) end)
            expect.error_match('Usage', function() df.readFields(items, {}, nil, {}, {}) end)
            expect.error_match('both', function()
                df.readFields({items=items, _range={0, 1}}, {}, nil, {{0, 1}})
            end)
            expect.error_match('both', function()
                df.readFields({{items=items}, {items=items, _range={0, 1}}}, {}, nil, {nil, {0, 1}})
            end)

            -- a bad range anywhere in a list is an error, whatever comes before it
            expect.error_match('range must be a table', function()
                df.readFields({{des=block.designation}, {des=block.designation, _range={1}}})
            end)
            expect.error_match('whole numbers', function()
                df.readFields({block.designation, block.designation}, nil, nil, {{0, 1, 0, 1}, {0.5, 1, 0, 1}})
            end)

            local read = df.prepareReadFields({items=items}, {fields={'_index'}})
            expect.error_match('range must be a table', function() read({items=items, _range={1}}) end)
            expect.error_match('ranges must be a table', function() read({items=items}, nil, 5) end)
            expect.error_match('Usage', function() read({items=items}, nil, {}, {}) end)
            expect.error_match('both', function() read({items=items, _range={0, 1}}, nil, {{0, 1}}) end)

            -- nothing was left on the stack or half-done: reads still work
            local out, n = read({items=items, _range={1, 2}})
            expect.table_eq(column(out, '_index', n), {1, 2})
        end)
    end)
end


-- two materials, a kind of object with arrays, flag arrays and vectors in it
local function with_materials(fn)
    local a, b = df.material:new(), df.material:new()
    a.id, b.id = 'IRON', 'IRONWOOD'
    a.state_name.Solid, a.state_name.Liquid = 'iron', 'molten iron'
    b.state_name.Solid, b.state_name.Liquid = 'ironwood', 'n/a'
    a.state_color.Solid, a.state_color.Liquid = 4, 9
    b.state_color.Solid, b.state_color.Liquid = 6, 6
    a.flags.IS_METAL = true
    b.flags.IS_STONE = true
    a.strength.yield.IMPACT, b.strength.yield.IMPACT = 500, 20
    for _, v in ipairs{df.item_type.BAR, df.item_type.WEAPON, df.item_type.ARMOR} do
        a.reaction_product.item_type:insert('#', v)
    end
    b.reaction_product.item_type:insert('#', df.item_type.WOOD)
    dfhack.with_finalize(function() a:delete() b:delete() end, fn, a, b)
end

function test.lists_of_objects()
    with_materials(function(a, b)
        local out, n = df.readFields({a, b}, {fields={'_index', '_from', 'id'}})
        expect.eq(n, 2)
        expect.table_eq(column(out, '_index', n), {1, 2})
        expect.table_eq(column(out, '_from', n), {1, 1})
        expect.table_eq(column(out, 'id', n), {'IRON', 'IRONWOOD'})

        -- '_from' is 1 for every object, in a condition as well, and can be set against a field
        out, n = df.readFields({a, b}, {where={{'_from', '==', 1}}})
        expect.eq(n, 2)
        out, n = df.readFields({a, b}, {where={{'_from', '~=', 1}}})
        expect.eq(n, 0)
        out, n = df.readFields({a, b}, {fields={'_index'}, where={{'_index', '>', {field='_from'}}}})
        expect.table_eq(column(out, '_index', n), {2})

        out, n = df.readFields({a, b, a}, {fields={'_index'}, where={{'id', '==', 'IRON'}}})
        expect.table_eq(column(out, '_index', n), {1, 3})

        -- the test function is given the place in the list
        local seen = {}
        out, n = df.readFields({a, b}, {test=function(i) seen[#seen + 1] = i return i == 2 end, fields={'id'}})
        expect.table_eq(seen, {1, 2})
        -- and, second, the place of the container in the list that was passed in
        local froms = {}
        with_job(function(job)
            local items = job.job_items.elements
            df.readFields({items, items}, {test=function(i, from) froms[#froms + 1] = from end, limit=1},
                          nil, {{0, 0}, {0, 1}})
        end)
        expect.table_eq(froms, {1, 2, 2})
        expect.table_eq(column(out, 'id', n), {'IRONWOOD'})

        out, n = df.readFields({})
        expect.eq(n, 0)

        expect.error_match('entry 2 of the list is not a material', function() df.readFields({a, 5}) end)
        expect.error_match('entry 2 of the list is not a material', function()
            with_job(function(job) df.readFields({a, job}) end)
        end)
        expect.error_match('ranges can only be given for containers', function()
            df.readFields({a, b}, nil, nil, {{0, 1}})
        end)
        expect.error_match('not a container', function() df.readFields(a) end)
    end)
end

function test.objects_of_derived_classes()
    local worker = df.general_ref_unit_workerst:new()
    worker.unit_id = 7
    local holder = df.general_ref_building_holderst:new()
    holder.building_id = 9
    dfhack.with_finalize(
        function() worker:delete() holder:delete() end,
        function()
            -- objects of different classes are read as the class they all derive from
            local out, n = df.readFields({worker, holder}, {fields={'unit_id', 'general_ref_building:building_id'}})
            expect.eq(n, 2)
            expect.eq(out.unit_id[1], 7)
            expect.eq(out.unit_id[2], nil)
            expect.eq(out['general_ref_building:building_id'][2], 9)

            local read = df.prepareReadFields(df.general_ref, {fields={'_index'}, where={{'unit_id', '==', 7}}})
            out, n = read({holder, worker, holder})
            expect.table_eq(column(out, '_index', n), {2})
            out, n = read({})
            expect.eq(n, 0)
            with_materials(function(a)
                expect.error_match('entry 1 of the list is not a general_ref', function() read({a}) end)
            end)
            expect.error_match('set up for a list of objects', function() read(worker) end)

            -- one set up from a list takes objects of the nearest class the objects of that list share
            read = df.prepareReadFields({worker}, {fields={'unit_id'}})
            expect.error_match('entry 1 of the list is not a general_ref_unit_workerst', function() read({holder}) end)
            read = df.prepareReadFields({worker, holder}, {fields={'unit_id'}})
            out, n = read({holder, worker})
            expect.eq(n, 2)

            -- a read set up from a type takes only objects of that type
            read = df.prepareReadFields(df.general_ref_unit_workerst, {fields={'unit_id'}})
            out, n = read({worker})
            expect.table_eq(column(out, 'unit_id', n), {7})
            expect.error_match('entry 1 of the list is not a general_ref_unit_workerst', function() read({holder}) end)
        end)
end

function test.linked_lists()
    local jobs, links = {}, {}
    for i = 1, 4 do
        jobs[i] = df.job:new()
        jobs[i].completion_timer = i * 10
        links[i] = df.job_list_link:new()
        links[i].item = jobs[i]
    end
    -- the first link of a list holds no item, and neither does the third here
    local head = df.job_list_link:new()
    links[3].item = nil
    head.next = links[1]
    for i = 1, 3 do links[i].next = links[i + 1] end
    dfhack.with_finalize(
        function()
            head:delete()
            for i = 1, 4 do links[i]:delete() jobs[i]:delete() end
        end,
        function()
            local out, n = df.readFields(head, {fields={'_index', 'completion_timer'}})
            expect.eq(n, 3)
            expect.table_eq(column(out, '_index', n), {0, 1, 2})
            expect.table_eq(column(out, 'completion_timer', n), {10, 20, 40})

            out, n = df.readFields(head, {fields={'completion_timer'}, where={{'completion_timer', '>', 10}}, limit=1})
            expect.table_eq(column(out, 'completion_timer', n), {20})

            local read = df.prepareReadFields(head, {fields={'completion_timer'}})
            out, n = read(links[2])
            expect.table_eq(column(out, 'completion_timer', n), {20, 40})
            expect.error_match('set up for a linked list', function() read(jobs[1]) end)
            expect.error_match('set up for a linked list', function() read({head}) end)
            expect.error_match('ranges can only be given for containers', function() read(head, nil, {{0, 1}}) end)

            -- an empty list
            links[1].item = nil
            head.next = nil
            out, n = df.readFields(head, {fields={'completion_timer'}})
            expect.eq(n, 0)
        end)
end

function test.limit()
    with_job(function(job, specs)
        local items = job.job_items.elements
        local out, n = df.readFields(items, {fields={'_index'}, limit=2})
        expect.table_eq(column(out, '_index', n), {0, 1})
        out, n = df.readFields(items, {fields={'_index'}, where={{'item_type', '==', df.item_type.BAR}}, limit=1})
        expect.table_eq(column(out, '_index', n), {0})
        out, n = df.readFields(items, {fields={'_index'}, where={{'quantity', '>=', 5}}, limit=10})
        expect.table_eq(column(out, '_index', n), {2, 3})

        -- nothing after the last entry that is kept is looked at
        local seen = 0
        out, n = df.readFields(items, {test=function() seen = seen + 1 return true end, limit=3})
        expect.eq(n, 3)
        expect.eq(seen, 3)

        -- the limit is on the whole call, not on each container
        out, n = df.readFields({items, items}, {fields={'_from', '_index'}, limit=7})
        expect.eq(n, 7)
        expect.table_eq(column(out, '_from', n), {1, 1, 1, 1, 1, 2, 2})
        out, n = df.readFields({items, items}, {fields={'_from'}, limit=5})
        expect.table_eq(column(out, '_from', n), {1, 1, 1, 1, 1})
        out, n = df.readFields(items, {fields={'_index'}, limit=2}, nil, {{1, 4}})
        expect.table_eq(column(out, '_index', n), {1, 2})

        local read = df.prepareReadFields(items, {fields={'_index'}, limit=2})
        for _ = 1, 2 do
            out, n = read(items)
            expect.table_eq(column(out, '_index', n), {0, 1})
        end

        for _, bad in ipairs{0, -1, 1.5, '2', true} do
            expect.error_match('limit must be a whole number', function() df.readFields(items, {limit=bad}) end)
        end
        expect.error_match("unknown option 'feilds'", function() df.readFields(items, {feilds={'quantity'}}) end)
        expect.error_match('unknown option', function() df.readFields(items, {[1]='quantity'}) end)
    end)
end

function test.entries_of_arrays_and_vectors()
    with_materials(function(a, b)
        local list = {a, b}
        -- an entry of an array is named by its number or by the name the array is indexed with
        local out, n = df.readFields(list, {fields={'state_name.Solid', 'state_name.1', 'state_color.Liquid',
                                                   'strength.yield.IMPACT'}})
        expect.eq(n, 2)
        expect.table_eq(column(out, 'state_name.Solid', n), {'iron', 'ironwood'})
        expect.table_eq(column(out, 'state_name.1', n), {'molten iron', 'n/a'})
        expect.table_eq(column(out, 'state_color.Liquid', n), {9, 6})
        expect.table_eq(column(out, 'strength.yield.IMPACT', n), {500, 20})

        out, n = df.readFields(list, {fields={'id'}, where={{'state_color.Solid', '<', 5}}})
        expect.table_eq(column(out, 'id', n), {'IRON'})
        out, n = df.readFields(list, {fields={'id'}, where={{'state_name.Liquid', '==', 'n/a'}}})
        expect.table_eq(column(out, 'id', n), {'IRONWOOD'})

        -- an entry that a vector does not have is nil, and no condition on it holds
        out, n = df.readFields(list, {fields={'reaction_product.item_type.0', 'reaction_product.item_type.2',
                                             'reaction_product.item_type._size'}})
        expect.table_eq(column(out, 'reaction_product.item_type.0', n), {df.item_type.BAR, df.item_type.WOOD})
        expect.eq(out['reaction_product.item_type.2'][1], df.item_type.ARMOR)
        expect.eq(out['reaction_product.item_type.2'][2], nil)
        expect.table_eq(column(out, 'reaction_product.item_type._size', n), {3, 1})
        out, n = df.readFields(list, {fields={'id'}, where={{'reaction_product.item_type.2', '~=', df.item_type.BAR}}})
        expect.table_eq(column(out, 'id', n), {'IRON'})
        out, n = df.readFields(list, {fields={'id'}, where={{'reaction_product.item_type._size', '<', 2}}})
        expect.table_eq(column(out, 'id', n), {'IRONWOOD'})
        out, n = df.readFields(list, {fields={'id'}, where={{'reaction_product.item_type._size', '==',
                                                            {field='state_color.Solid'}}}})
        expect.eq(n, 0)

        expect.error_match('outside the array', function() df.readFields(list, {fields={'state_name.99'}}) end)
        expect.error_match('outside the array', function() df.readFields(list, {fields={'state_name.None'}}) end)
        expect.error_match('must be the index of an entry', function()
            df.readFields(list, {fields={'state_name.nope'}})
        end)
        expect.error_match('not a single value', function() df.readFields(list, {where={{'state_name', '==', 'x'}}}) end)
    end)

    with_job(function(job, specs)
        -- through a vector of pointers, and on to what an entry points to
        local out, n = df.readFields({job}, {fields={'job_items.elements.1.quantity', 'job_items.elements.9.quantity',
                                                    'items.0.job_item_idx', 'items._size', 'items.0.item'}})
        expect.eq(n, 1)
        expect.eq(out['job_items.elements.1.quantity'][1], specs[2].quantity)
        expect.eq(out['job_items.elements.9.quantity'][1], nil)
        expect.eq(out['items.0.job_item_idx'][1], 4)
        expect.eq(out['items._size'][1], 2)
        expect.eq(out['items.0.item'][1], nil)
    end)

    with_block(function(block)
        -- entries of a grid that is a field
        block.designation[3][5].flow_size = 6
        local out, n = df.readFields({block}, {fields={'designation.3.5.flow_size', 'designation.3.4.flow_size'}})
        expect.eq(out['designation.3.5.flow_size'][1], 6)
        expect.eq(out['designation.3.4.flow_size'][1], 0)
        out, n = df.readFields({block}, {where={{'designation.3.5.flow_size', '==', 6}}})
        expect.eq(n, 1)
        expect.error_match('outside the array', function() df.readFields({block}, {fields={'designation.16.0.flow_size'}}) end)
    end)
end

function test.flag_arrays()
    with_materials(function(a, b)
        local list = {a, b}
        local out, n = df.readFields(list, {fields={'flags.IS_METAL', 'flags.IS_STONE'}})
        expect.table_eq(column(out, 'flags.IS_METAL', n), {true, false})
        expect.table_eq(column(out, 'flags.IS_STONE', n), {false, true})
        out, n = df.readFields(list, {fields={'id'}, where={{'flags.IS_METAL', '==', true}}})
        expect.table_eq(column(out, 'id', n), {'IRON'})
        out, n = df.readFields(list, {fields={'id'}, where={{'flags.IS_METAL', '==', false}}})
        expect.table_eq(column(out, 'id', n), {'IRONWOOD'})
        out, n = df.readFields(list, {fields={'id'}, where={{'or', {'flags.IS_METAL', '==', true},
                                                            {'flags.IS_STONE', '==', true}}}})
        expect.eq(n, 2)
        -- by number, as Lua reads them too
        out, n = df.readFields(list, {fields={'flags.' .. df.material_flags.IS_METAL}})
        expect.table_eq(column(out, 'flags.' .. df.material_flags.IS_METAL, n), {true, false})
        expect.error_match("no flag 'NOPE'", function() df.readFields(list, {fields={'flags.NOPE'}}) end)
    end)
end

function test.same_as_lua()
    with_materials(function(a, b)
        with_job(function(job)
            -- anything that is not a single value comes back as reading it in Lua gives it
            local out, n = df.readFields({a}, {fields={'_value', 'heat', 'state_name', 'flags', 'reaction_product.item_type'}})
            expect.eq(n, 1)
            expect.eq(out._value[1], a)
            expect.eq(out.heat[1], a.heat)
            expect.eq(out.state_name[1], a.state_name)
            expect.eq(out.state_name[1].Solid, 'iron')
            expect.eq(out.flags[1], a.flags)
            expect.true_(out.flags[1].IS_METAL)
            expect.eq(out['reaction_product.item_type'][1], a.reaction_product.item_type)
            expect.eq(#out['reaction_product.item_type'][1], 3)

            out, n = df.readFields(job.job_items.elements, {fields={'_value'}, where={{'quantity', '==', 7}}})
            expect.eq(n, 1)
            expect.eq(out._value[1], job.job_items.elements[2])
            out, n = df.readFields({items=job.job_items.elements}, {fields={'items'}, limit=1})
            expect.eq(out.items[1], job.job_items.elements[0])

            -- a pointer gives the object it points to, or nil
            out, n = df.readFields(job.items, {fields={'item'}})
            expect.eq(n, 2)
            expect.eq(out.item[1], nil)
            expect.eq(out.item[2], nil)
            out, n = df.readFields({job}, {fields={'job_items.elements.0', 'job_items.elements.7'}})
            expect.eq(out['job_items.elements.0'][1], job.job_items.elements[0])
            expect.eq(out['job_items.elements.7'][1], nil)
        end)
    end)
end

function test.types()
    with_job(function(job)
        local refs = job.general_refs
        local worker = df.general_ref_unit_workerst:new()
        local holder = df.general_ref_building_holderst:new()
        refs:insert('#', worker)
        refs:insert('#', holder)
        dfhack.with_finalize(
            function()
                refs:resize(0)
                worker:delete()
                holder:delete()
            end,
            function()
                local out, n = df.readFields(refs, {fields={'_type'}})
                expect.eq(n, 2)
                expect.eq(out._type[1], df.general_ref_unit_workerst)
                expect.eq(out._type[2], df.general_ref_building_holderst)

                local function matching(cond)
                    local found, count = df.readFields(refs, {fields={'_index'}, where={cond}})
                    return column(found, '_index', count)
                end
                expect.table_eq(matching{'_type', '==', df.general_ref_unit_workerst}, {0})
                expect.table_eq(matching{'_type', '~=', df.general_ref_unit_workerst}, {1})
                expect.table_eq(matching{'_type', '==', df.general_ref_unit}, {})
                expect.table_eq(matching{'_type', 'is_instance', df.general_ref_unit}, {0})
                expect.table_eq(matching{'_type', 'is_instance', df.general_ref_building}, {1})
                expect.table_eq(matching{'_type', 'is_instance', df.general_ref}, {0, 1})
                expect.table_eq(matching{'not', {'_type', 'is_instance', df.general_ref_unit}}, {1})
                expect.table_eq(matching{'_type', 'is_instance', df.job}, {})

                expect.error_match('needs a type', function() matching{'_type', '==', 5} end)
                expect.error_match('needs a type', function() matching{'_type', 'is_instance', worker} end)
                expect.error_match('can only be tested with', function() matching{'_type', '<', df.general_ref} end)
                expect.error_match("ends in '_type'", function() matching{'_index', 'is_instance', df.general_ref} end)
            end)
    end)
end

function test.methods()
    with_job(function(job)
        local refs = job.general_refs
        local worker = df.general_ref_unit_workerst:new()
        local holder = df.general_ref_building_holderst:new()
        refs:insert('#', worker)
        refs:insert('#', holder)
        dfhack.with_finalize(
            function()
                refs:resize(0)
                worker:delete()
                holder:delete()
            end,
            function()
                -- a method that takes no arguments can end a path
                local out, n = df.readFields(refs, {fields={'getType()'}})
                expect.eq(n, 2)
                expect.eq(out['getType()'][1], df.general_ref_type.UNIT_WORKER)
                expect.eq(out['getType()'][2], df.general_ref_type.BUILDING_HOLDER)
                expect.eq(out['getType()'][1], worker:getType())

                out, n = df.readFields(refs, {fields={'_index'},
                                              where={{'getType()', '==', df.general_ref_type.BUILDING_HOLDER}}})
                expect.table_eq(column(out, '_index', n), {1})
                out, n = df.readFields(refs, {fields={'_index'},
                    where={{'getType()', 'in', {df.general_ref_type.UNIT_WORKER, df.general_ref_type.ITEM}}}})
                expect.table_eq(column(out, '_index', n), {0})
                out, n = df.readFields({job}, {where={{'general_refs.1.getType()', '==',
                                                      df.general_ref_type.BUILDING_HOLDER}}})
                expect.eq(n, 1)

                expect.error_match('is a method; write it with %(%)', function()
                    df.readFields(refs, {fields={'getType'}})
                end)
                expect.error_match('is not a method', function()
                    df.readFields(job.job_items.elements, {fields={'quantity()'}})
                end)
                expect.error_match('must be the last step', function()
                    df.readFields(refs, {fields={'getType().x'}})
                end)
                expect.error_match('takes arguments', function() df.readFields(refs, {fields={'setID()'}}) end)
            end)
    end)
end

function test.ids_followed_to_their_objects()
    with_job(function(job)
        local refs = job.general_refs
        local all = df.global.world.entities.all
        local entity = df.historical_entity:new()
        entity.id = #all > 0 and all[#all - 1].id + 1000 or 1000
        entity.type = df.historical_entity_type.MerchantCompany
        local to_entity, to_nothing = df.general_ref_entity:new(), df.general_ref_entity:new()
        to_entity.entity_id = entity.id
        to_nothing.entity_id = entity.id + 1
        refs:insert('#', to_entity)
        refs:insert('#', to_nothing)
        all:insert('#', entity)
        dfhack.with_finalize(
            function()
                all:erase(#all - 1)
                entity:delete()
                refs:resize(0)
                to_entity:delete()
                to_nothing:delete()
            end,
            function()
                -- '_target' goes from an id to the object that has it, as the type's find() does
                local out, n = df.readFields(refs, {fields={'general_ref_entity:entity_id._target.id', 'general_ref_entity:entity_id._target.type',
                                                           'general_ref_entity:entity_id._target'}})
                expect.eq(n, 2)
                expect.eq(out['general_ref_entity:entity_id._target.id'][1], entity.id)
                expect.eq(out['general_ref_entity:entity_id._target.id'][2], nil)
                expect.eq(out['general_ref_entity:entity_id._target.type'][1], df.historical_entity_type.MerchantCompany)
                expect.eq(out['general_ref_entity:entity_id._target'][1], entity)
                expect.eq(out['general_ref_entity:entity_id._target'][2], nil)

                out, n = df.readFields(refs, {fields={'_index'}, where={{'general_ref_entity:entity_id._target.type', '==',
                                                                        df.historical_entity_type.MerchantCompany}}})
                expect.table_eq(column(out, '_index', n), {0})
                out, n = df.readFields(refs, {fields={'_index'}, where={{'general_ref_entity:entity_id._target.type', '~=',
                                                                        df.historical_entity_type.MerchantCompany}}})
                expect.eq(n, 0)

                expect.error_match('not the id of', function()
                    df.readFields(job.job_items.elements, {fields={'quantity._target'}})
                end)
            end)
    end)
end

function test.conditions_on_two_fields()
    with_job(function(job, specs)
        local items = job.job_items.elements
        local function matching(cond)
            local out, n = df.readFields(items, {fields={'_index'}, where={cond}})
            return column(out, '_index', n)
        end
        -- quantities are 3 1 7 5 2 and mat_index is 10 20 30 40 50
        items[1].mat_index = 1
        items[2].mat_index = 6
        expect.table_eq(matching{'quantity', '==', {field='mat_index'}}, {1})
        expect.table_eq(matching{'quantity', '~=', {field='mat_index'}}, {0, 2, 3, 4})
        expect.table_eq(matching{'quantity', '>', {field='mat_index'}}, {2})
        expect.table_eq(matching{'quantity', '>=', {field='mat_index'}}, {1, 2})
        expect.table_eq(matching{'quantity', '<', {field='mat_index'}}, {0, 3, 4})
        expect.table_eq(matching{'quantity', '<=', {field='mat_index'}}, {0, 1, 3, 4})
        expect.table_eq(matching{'_index', '==', {field='quantity'}}, {1})
        expect.table_eq(matching{'reaction_class', '==', {field='has_material_reaction_product'}}, {0, 1, 2, 3, 4})
        items[0].reaction_class = 'x'
        expect.table_eq(matching{'reaction_class', '>', {field='has_material_reaction_product'}}, {0})

        expect.error_match("no field 'nope'", function() matching{'quantity', '==', {field='nope'}} end)
        expect.error_match('no usable value', function() matching{'quantity', '~=', {feild='mat_index'}} end)
        expect.error_match('no usable value', function() matching{'quantity', '==', {}} end)
    end)
end

function test.sets_and_text()
    with_job(function(job, specs)
        local items = job.job_items.elements
        local function matching(cond)
            local out, n = df.readFields(items, {fields={'_index'}, where={cond}})
            return column(out, '_index', n)
        end
        -- a set as Lua code keeps one, with the values as keys
        expect.table_eq(matching{'item_type', 'in_keys', {[df.item_type.BAR]=true, [df.item_type.SEEDS]=true}}, {0, 3, 4})
        expect.table_eq(matching{'item_type', 'in_keys', {[df.item_type.BAR]=false, [df.item_type.SEEDS]=1}}, {4})
        expect.table_eq(matching{'item_type', 'in_keys', {}}, {})
        expect.table_eq(matching{'not', {'quantity', 'in_keys', {[3]=true, [7]=true}}}, {1, 3, 4})
        expect.error_match('values as keys', function() matching{'quantity', 'in_keys', 3} end)

        items[0].reaction_class = 'FLUX_STONE'
        items[1].reaction_class = 'FLUX'
        items[2].reaction_class = 'STONE_FLUX'
        expect.table_eq(matching{'reaction_class', 'in_keys', {FLUX=true, [''] = true}}, {1, 3, 4})
        expect.table_eq(matching{'reaction_class', 'startswith', 'FLUX'}, {0, 1})
        expect.table_eq(matching{'reaction_class', 'endswith', 'FLUX'}, {1, 2})
        expect.table_eq(matching{'reaction_class', 'contains', 'X_S'}, {0})
        expect.table_eq(matching{'reaction_class', 'contains', 'E_F'}, {2})
        expect.table_eq(matching{'reaction_class', 'contains', ''}, {0, 1, 2, 3, 4})
        expect.table_eq(matching{'reaction_class', 'startswith', 'FLUX_STONE_AND_MORE'}, {})
        -- with an i in front, the case of letters does not matter
        expect.table_eq(matching{'reaction_class', 'icontains', 'x_s'}, {0})
        expect.table_eq(matching{'reaction_class', 'contains', 'x_s'}, {})
        expect.table_eq(matching{'reaction_class', 'istartswith', 'Flux'}, {0, 1})
        expect.table_eq(matching{'reaction_class', 'iendswith', 'fLUX'}, {1, 2})
        -- the text is looked for as it stands, not as a pattern
        expect.table_eq(matching{'reaction_class', 'contains', '.'}, {})
        expect.table_eq(matching{'not', {'reaction_class', 'contains', 'FLUX'}}, {3, 4})

        expect.error_match('needs a field that holds text', function() matching{'quantity', 'contains', '3'} end)
        expect.error_match('needs a field that holds text', function() matching{'reaction_class', 'contains', 3} end)
    end)
end

function test.any_and_all()
    with_materials(function(a, b)
        with_job(function(job, specs)
            local function matching(list, cond)
                local out, n = df.readFields(list, {fields={'_index'}, where={cond}})
                return column(out, '_index', n)
            end
            -- over a vector of values, where '_value' is the entry
            local list = {a, b}
            local products = 'reaction_product.item_type'
            expect.table_eq(matching(list, {products, 'any', {{'_value', '==', df.item_type.WEAPON}}}), {1})
            expect.table_eq(matching(list, {products, 'any', {{'_value', '==', df.item_type.WOOD}}}), {2})
            expect.table_eq(matching(list, {products, 'any', {{'_value', '==', df.item_type.SEEDS}}}), {})
            expect.table_eq(matching(list, {products, 'all', {{'_value', '~=', df.item_type.WOOD}}}), {1})
            expect.table_eq(matching(list, {products, 'any', {{'_index', '==', 2}}}), {1})
            expect.table_eq(matching(list, {products, 'any', {}}), {1, 2})
            expect.table_eq(matching(list, {'not', {products, 'any', {{'_value', '==', df.item_type.BAR}}}}), {2})
            -- over an array of a fixed size
            expect.table_eq(matching(list, {'state_color', 'any', {{'_value', '==', 9}}}), {1})
            expect.table_eq(matching(list, {'state_name', 'any', {{'_value', 'startswith', 'iron'}}}), {1, 2})
            expect.table_eq(matching(list, {'state_name', 'all', {{'_value', '~=', 'iron'}}}), {2})
            -- every condition must hold for one and the same entry
            expect.table_eq(matching(list, {products, 'any', {{'_value', '==', df.item_type.BAR},
                                                              {'_index', '==', 1}}}), {})

            -- over a vector of pointers to structures
            local other = df.job:new()
            dfhack.with_finalize(function() other:delete() end, function()
                local jobs = {job, other}
                local elements = 'job_items.elements'
                expect.table_eq(matching(jobs, {elements, 'any', {{'quantity', '>', 6}}}), {1})
                expect.table_eq(matching(jobs, {elements, 'any', {{'quantity', '>', 7}}}), {})
                expect.table_eq(matching(jobs, {elements, 'all', {{'quantity', '>', 0}}}), {1, 2})
                expect.table_eq(matching(jobs, {elements, 'all', {{'quantity', '>', 1}}}), {2})
                expect.table_eq(matching(jobs, {elements, 'any', {{'item_type', '==', df.item_type.BAR},
                                                                 {'quantity', '==', 5}}}), {1})
                expect.table_eq(matching(jobs, {elements, 'any', {{'item_type', '==', df.item_type.WOOD},
                                                                 {'quantity', '==', 5}}}), {})
                expect.table_eq(matching(jobs, {elements, 'any', {{'or', {'quantity', '==', 2},
                                                                         {'quantity', '==', 100}}}}), {1})
                expect.table_eq(matching(jobs, {elements, 'any', {{'flags1.improvable', '==', true},
                                                                 {'_index', '>', 2}}}), {1})
                -- one inside another
                expect.table_eq(matching(jobs, {elements, 'any', {{'contains', 'any', {{'_value', '==', 4}}}}}), {})
                job.job_items.elements[3].contains:insert('#', 4)
                expect.table_eq(matching(jobs, {elements, 'any', {{'contains', 'any', {{'_value', '==', 4}}}}}), {1})
                expect.table_eq(matching(jobs, {elements, 'any', {{'contains._size', '==', 1}}}), {1})

                -- entries that are null pointers are passed over
                job.items:insert('#', df.NULL)
                expect.table_eq(matching(jobs, {'items', 'all', {{'job_item_idx', '>=', 2}}}), {1, 2})
                expect.table_eq(matching(jobs, {'items', 'any', {{'job_item_idx', '==', 2}}}), {1})
                job.items:erase(#job.items - 1)

                local read = df.prepareReadFields(df.job, {fields={'_index'},
                                                           where={{elements, 'any', {{'quantity', '==', 7}}}}})
                for _ = 1, 2 do
                    local out, n = read(jobs)
                    expect.table_eq(column(out, '_index', n), {1})
                end
            end)

            expect.error_match('not a container or an array', function() matching(list, {'id', 'any', {}}) end)
            expect.error_match('needs a list of conditions', function() matching(list, {products, 'any', 5}) end)
            expect.error_match('must be a table', function()
                matching(list, {products, 'any', {'_value', '==', 1}})
            end)
            expect.error_match("no field 'nope'", function() matching({job}, {'job_items.elements', 'any', {{'nope', '==', 1}}}) end)
        end)
    end)
end

function test.pointers_compared_with_objects()
    with_job(function(job)
        local other = df.job:new()
        local link = df.job_list_link:new()
        job.list_link = link
        dfhack.with_finalize(
            function()
                job.list_link = nil
                link:delete()
                other:delete()
            end,
            function()
                local function matching(cond)
                    local out, n = df.readFields({job, other}, {fields={'_index'}, where={cond}})
                    return column(out, '_index', n)
                end
                expect.table_eq(matching{'list_link', '==', link}, {1})
                expect.table_eq(matching{'list_link', '~=', link}, {2})
                expect.table_eq(matching{'list_link', '==', df.NULL}, {2})
                expect.table_eq(matching{'list_link', '==', job}, {})
                expect.error_match('or an object', function() matching{'list_link', '==', 5} end)
                expect.error_match('or an object', function() matching{'list_link', '<', link} end)
            end)
    end)
end

function test.each()
    with_job(function(job)
        local items = job.job_items.elements
        -- the values of the fields arrive as arguments, entry by entry, and nothing is stored
        local got = {}
        local out, n = df.readFields(items, {fields={'_index', 'quantity'}, where={{'quantity', '>', 2}},
            each=function(index, quantity) got[#got + 1] = index * 100 + quantity end})
        expect.eq(n, 3)
        expect.table_eq(got, {3, 207, 305})
        expect.nil_(out._index)
        expect.nil_(out.quantity)

        -- arrays of an earlier read are left alone
        local kept = {quantity={99, 98}}
        df.readFields(items, {fields={'quantity'}, where={{'quantity', '==', 7}}, each=function() end}, kept)
        expect.table_eq(kept.quantity, {99, 98})

        -- a name given twice is passed twice
        got = {}
        df.readFields(items, {fields={'quantity', '_index', 'quantity'}, limit=1,
            each=function(...) got = {...} end})
        expect.table_eq(got, {3, 0, 3})

        -- the call that ends the read may change the number of entries
        local path = df.coord_path:new()
        dfhack.with_finalize(function() path:delete() end, function()
            for _, v in ipairs{5, 6, 7} do path.x:insert('#', v) end
            local _, count = df.readFields(path.x, {fields={'_index'}, where={{'_value', '==', 6}},
                each=function(index) path.x:erase(index) return false end})
            expect.eq(count, 1)
            expect.eq(#path.x, 2)
        end)

        -- false ends the read, nil does not
        local seen = 0
        out, n = df.readFields(items, {fields={'_index'}, each=function(index)
            seen = seen + 1
            if index == 1 then return false end
        end})
        expect.eq(seen, 2)
        expect.eq(n, 2)

        -- after test, with limit, and without fields
        got = {}
        out, n = df.readFields(items, {fields={'_index'},
            test=function(index) return index % 2 == 0 end, limit=2,
            each=function(index) got[#got + 1] = index end})
        expect.table_eq(got, {0, 2})
        local calls = 0
        out, n = df.readFields(items, {each=function(...) calls = calls + select('#', ...) + 1 end})
        expect.eq(calls, 5)

        -- over a list of containers, with the place in it
        got = {}
        df.readFields({items, items}, {fields={'_from', '_index'},
            each=function(from, index) got[#got + 1] = from * 10 + index end}, nil, {{0, 0}, {1, 2}})
        expect.table_eq(got, {10, 21, 22})

        -- prepared
        got = {}
        local read = df.prepareReadFields(items, {fields={'quantity'}, where={{'quantity', '>=', 5}},
            each=function(quantity) got[#got + 1] = quantity end})
        read(items)
        read(items)
        expect.table_eq(got, {7, 5, 7, 5})

        -- the entries may be moved, but their number must stay
        expect.error_match('changed size', function()
            df.readFields(job.items, {each=function() job.items:insert('#', {new=true}) end})
        end)
        expect.error_match('each must be a function', function() df.readFields(items, {each=1}) end)
    end)
end

function test.fields_under_other_names()
    with_job(function(job)
        local items = job.job_items.elements
        local out, n = df.readFields(items, {fields={{path='quantity', as='q'}, '_index', {path='flags1.improvable', as='imp'}},
                                             where={{'quantity', '>', 2}}})
        expect.eq(n, 3)
        expect.table_eq(column(out, 'q', n), {3, 7, 5})
        expect.table_eq(column(out, '_index', n), {0, 2, 3})
        expect.table_eq(column(out, 'imp', n), {false, false, true})
        expect.nil_(out.quantity)

        -- the same field under two names, and the same name twice for the same field
        out, n = df.readFields(items, {fields={'quantity', {path='quantity', as='again'}, {path='quantity', as='again'}}, limit=2})
        expect.table_eq(column(out, 'quantity', n), {3, 1})
        expect.table_eq(column(out, 'again', n), {3, 1})

        -- prepared, and into a table that is reused
        local read = df.prepareReadFields(items, {fields={{path='mat_index', as='mat'}}})
        local reused = {}
        out, n = read(items, reused)
        expect.eq(out, reused)
        expect.table_eq(column(out, 'mat', n), {10, 20, 30, 40, 50})

        expect.error_match("two different fields would be stored as 'q'", function()
            df.readFields(items, {fields={{path='quantity', as='q'}, {path='mat_index', as='q'}}})
        end)
        expect.error_match("two different fields would be stored as 'quantity'", function()
            df.readFields(items, {fields={'quantity', {path='mat_index', as='quantity'}}})
        end)
        expect.error_match("must be {path=", function() df.readFields(items, {fields={{path='quantity'}}}) end)
        expect.error_match("must be {path=", function() df.readFields(items, {fields={{path='quantity', as='q', x=1}}}) end)
        expect.error_match("must be {path=", function() df.readFields(items, {fields={{'quantity', 'q'}}}) end)
        expect.error_match("empty name", function() df.readFields(items, {fields={{path='quantity', as=''}}}) end)
        expect.error_match("must be a string or", function() df.readFields(items, {fields={5}}) end)
    end)
end

function test.ids_in_vectors_followed_to_their_objects()
    local all = df.global.world.entities.all
    local entity = df.historical_entity:new()
    entity.id = #all > 0 and all[#all - 1].id + 1000 or 1000
    entity.type = df.historical_entity_type.MerchantCompany
    local first, second = df.agreement_party:new(), df.agreement_party:new()
    first.entity_ids:insert('#', entity.id + 1)
    first.entity_ids:insert('#', entity.id)
    second.entity_ids:insert('#', entity.id + 1)
    all:insert('#', entity)
    dfhack.with_finalize(
        function()
            all:erase(#all - 1)
            entity:delete()
            first:delete()
            second:delete()
        end,
        function()
            local parties = {first, second}
            -- an entry of a vector of ids, picked by its index
            local out, n = df.readFields(parties, {fields={'entity_ids.1._target.type', 'entity_ids.0._target',
                                                           'entity_ids.1._target'}})
            expect.eq(n, 2)
            expect.eq(out['entity_ids.1._target.type'][1], df.historical_entity_type.MerchantCompany)
            expect.eq(out['entity_ids.1._target.type'][2], nil)
            expect.eq(out['entity_ids.0._target'][1], nil)
            expect.eq(out['entity_ids.1._target'][1], entity)

            -- any and all of the entries
            local function matching(cond)
                local o, count = df.readFields(parties, {fields={'_index'}, where={cond}})
                return column(o, '_index', count)
            end
            local is_company = {'_value._target.type', '==', df.historical_entity_type.MerchantCompany}
            expect.table_eq(matching{'entity_ids', 'any', {is_company}}, {1})
            expect.table_eq(matching{'entity_ids', 'all', {is_company}}, {})
            expect.table_eq(matching{'entity_ids', 'any', {{'_value._target.id', '==', entity.id}}}, {1})
            expect.table_eq(matching{'entity_ids', 'any', {{'_value', '==', entity.id + 1}}}, {1, 2})

            -- a vector that does not say what its numbers are ids of
            expect.error_match('not the id of', function()
                df.readFields(parties, {where={{'complaint', 'any', {{'year._target.id', '==', 1}}}}})
            end)
            expect.error_match('not the id of', function()
                df.readFields(first.entity_ids, {fields={'_value._target'}})
            end)
        end)
end
