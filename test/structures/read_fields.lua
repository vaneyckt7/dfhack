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

-- an array of arrays of pointers: each object is reached through one pointer, not two
function test.arrays_of_arrays_of_pointers()
    local site = df.world_site_realization:new()
    local cross = df.site_realization_crossroads:new()
    cross.idx_x = 7
    -- the first 8 bytes of cross stay 0, so a read that takes them for a pointer finds null
    dfhack.with_finalize(
        function() site.road_map[2][3] = nil site:delete() cross:delete() end,
        function()
            site.road_map[2][3] = cross

            -- one row of the grid
            local out, n = df.read_fields(site.road_map[2], {fields={'_index', 'idx_x'}})
            expect.eq(n, 1)
            expect.eq(out._index[1], 3)
            expect.eq(out.idx_x[1], 7)

            -- the grid as a field of an object
            out, n = df.read_fields({site}, {fields={'road_map.2.3.idx_x'}})
            expect.eq(n, 1)
            expect.eq(out['road_map.2.3.idx_x'][1], 7)

            -- the whole grid, one entry per object
            out, n = df.read_fields(site.road_map, {fields={'_index', 'idx_x'}})
            expect.eq(n, 1)
            expect.eq(out._index[1], 2 * 51 + 3)
            expect.eq(out.idx_x[1], 7)
        end)
end

-- a __gc function that changes the entries must not run halfway through a read
function test.finalizers_wait_for_the_end_of_a_read()
    with_job(function(job)
        local items, alive = job.job_items.elements, true
        for i = 0, #items - 1 do
            items[i].reaction_class = ('x'):rep(500)
            items[i].quantity = 0
        end
        -- a collector that never rests and finishes a cycle in a step or two, so that finalizers
        -- come due inside the reads, where nearly all the memory of the loop is asked for
        local pause, stepmul = collectgarbage('setpause', 100), collectgarbage('setstepmul', 1000000)
        collectgarbage()
        dfhack.with_finalize(function()
            alive = false
            collectgarbage('setpause', pause)
            collectgarbage('setstepmul', stepmul)
        end, function()
            for round = 1, 100 do
                setmetatable({}, {__gc=function()
                    if not alive then return end
                    for i = 0, #items - 1 do items[i].quantity = round end
                end})
                local out, n = df.read_fields(items, {fields={'reaction_class', 'quantity'}})
                for i = 2, n do
                    if out.quantity[i] ~= out.quantity[1] then
                        expect.fail('a finalizer ran during the read of round ' .. round)
                        return
                    end
                end
            end
        end)
    end)
end

function test.all_entries()
    with_job(function(job, specs)
        local out, n = df.read_fields(job.job_items.elements,
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
        local out, n = df.read_fields(job.job_items.elements)
        expect.eq(n, #specs)
        expect.eq(next(out), nil)
        out, n = df.read_fields(job.job_items.elements, {where={}})
        expect.eq(n, #specs)
        out, n = df.read_fields(job.job_items.elements, {where={{'quantity', '>', 100}}})
        expect.eq(n, 0)
    end)
end

function test.enum_attributes()
    with_job(function(job, specs)
        local out, n = df.read_fields(job.job_items.elements, {fields={'item_type.caption', 'item_type.is_rawable'}})
        for i, spec in ipairs(specs) do
            expect.eq(out['item_type.caption'][i], df.item_type.attrs[spec.item_type].caption)
            expect.eq(out['item_type.is_rawable'][i], df.item_type.attrs[spec.item_type].is_rawable)
        end
        out, n = df.read_fields(job.job_items.elements,
            {fields={'_index'}, where={{'item_type.caption', '==', df.item_type.attrs.BAR.caption}}})
        expect.table_eq(column(out, '_index', n), {0, 3})
    end)
end

function test.null_pointer_on_the_path()
    with_job(function(job)
        local out, n = df.read_fields(job.items, {fields={'job_item_idx', 'item.id'}})
        expect.eq(n, 2)
        expect.table_eq(column(out, 'job_item_idx', n), {4, 2})
        expect.eq(out['item.id'][1], nil)
        expect.eq(out['item.id'][2], nil)
        out, n = df.read_fields(job.items, {where={{'item.id', '~=', 5}}})
        expect.eq(n, 0)
        out, n = df.read_fields(job.items, {where={{'not', {'item.id', '==', 5}}}})
        expect.eq(n, 2)
    end)
end

function test.plain_values()
    local path = df.coord_path:new()
    dfhack.with_finalize(function() path:delete() end, function()
        for _, v in ipairs{5, -2, 9, 0} do path.x:insert('#', v) end
        local out, n = df.read_fields(path.x, {fields={'_value', '_index'}, where={{'_value', '>', 0}}})
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
            local out, n = df.read_fields(path.x, {fields={'_index'}, where=where})
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
            local out, n = df.read_fields(job.job_items.elements, {fields={'_index'}, where=where})
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
            local out, n = df.read_fields(source, {fields={'_index'}, where=where})
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

        local out, n = df.read_fields(grids, {fields={'tt', 'des.flow_size', 'des'}})
        expect.eq(n, 256)
        for x = 0, 15 do
            for y = 0, 15 do
                local i = x * 16 + y + 1
                expect.eq(out.tt[i], block.tiletype[x][y])
                expect.eq(out['des.flow_size'][i], block.designation[x][y].flow_size)
                expect.eq(out.des[i], block.designation[x][y].whole)
            end
        end

        out, n = df.read_fields(grids, {fields={'_index', 'des.flow_size'},
            where={{'tt.shape', '==', df.tiletype_shape.FLOOR}, {'des.hidden', '==', false}}})
        expect.eq(n, 1)
        expect.eq(out._index[1], 2 * 16 + 3)
        expect.eq(out['des.flow_size'][1], 7)

        out, n = df.read_fields(grids, {fields={'_index'}, where={{'des.flow_size', '>', 0}}})
        expect.table_eq(column(out, '_index', n), {2 * 16 + 3, 4 * 16})

        out, n = df.read_fields(grids, {fields={'_index'},
            where={{'tt.shape.basic_shape', '==', df.tiletype_shape_basic.Wall}}})
        expect.table_eq(column(out, '_index', n), {4 * 16})

        expect.error_match('same number of entries', function()
            df.read_fields({tt=block.tiletype, row=block.tiletype[0]})
        end)
        -- the containers a read is set up from only show their kind, so they may differ in size
        local path = df.coord_path:new()
        dfhack.with_finalize(function() path:delete() end, function()
            path.x:insert('#', 1)
            local read = df.prepare_read_fields({x=path.x, y=path.y}, {fields={'x'}})
            path.y:insert('#', 2)
            expect.eq(select(2, read({x=path.x, y=path.y})), 1)
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
                local out, n = df.read_fields(refs, {fields={'unit_id', 'general_ref_building:building_id'}})
                expect.eq(n, 2)
                expect.eq(out.unit_id[1], 7)
                expect.eq(out.unit_id[2], nil)
                expect.eq(out['general_ref_building:building_id'][1], nil)
                expect.eq(out['general_ref_building:building_id'][2], 9)

                out, n = df.read_fields(refs, {fields={'_index'}, where={{'general_ref_building:building_id', '==', 9}}})
                expect.table_eq(column(out, '_index', n), {1})
                out, n = df.read_fields(refs, {where={{'unit_id', '~=', 100}}})
                expect.eq(n, 1)

                -- two unrelated reference classes have a building_id, so the class must be named
                expect.error_match('several classes', function() df.read_fields(refs, {fields={'building_id'}}) end)
                out, n = df.read_fields(refs, {fields={'general_ref_unit:unit_id'}})
                expect.eq(out['general_ref_unit:unit_id'][1], 7)
                expect.eq(out['general_ref_unit:unit_id'][2], nil)
                expect.error_match('does not name a class', function()
                    df.read_fields(refs, {fields={'job_item:quantity'}})
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
            local out, n = df.read_fields(items, {fields={'_index', 'quantity'}})
            expect.eq(n, 4)
            expect.table_eq(column(out, '_index', n), {0, 2, 3, 4})
            expect.table_eq(column(out, 'quantity', n), {3, 7, 5, 2})
        end)
    end)
end

function test.many_conditions()
    with_job(function(job)
        local where, fields = {}, {}
        for i = 1, 60 do
            where[i] = {'quantity', '>', -i}
            fields[i] = i % 2 == 0 and 'quantity' or 'mat_index'
        end
        local out, n = df.read_fields(job.job_items.elements, {fields=fields, where=where})
        expect.eq(n, 5)
        expect.table_eq(column(out, 'mat_index', n), {10, 20, 30, 40, 50})
    end)
end

function test.empty_groups()
    with_job(function(job)
        local out, n = df.read_fields(job.job_items.elements, {where={{'and'}}})
        expect.eq(n, 5)
        out, n = df.read_fields(job.job_items.elements, {where={{'or'}}})
        expect.eq(n, 0)
    end)
end

function test.out_is_reused()
    with_job(function(job)
        local out = {quantity={99, 98, 97, 96, 95, 94}, other={1}}
        local quantity = out.quantity
        local same, n = df.read_fields(job.job_items.elements, {fields={'quantity'}, where={{'quantity', '>', 4}}}, out)
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
        local out, n = df.read_fields(job.job_items.elements, {fields=fields})
        expect.eq(n, 5)
        expect.table_eq(column(out, 'quantity', n), {3, 1, 7, 5, 2})
    end)
end

function test.errors()
    with_job(function(job)
        local items = job.job_items.elements
        expect.error_match('Usage', function() df.read_fields() end)
        expect.error_match('expected a container', function() df.read_fields(5) end)
        expect.error_match('not a container', function() df.read_fields(job) end)
        expect.error_match('options must be a table', function() df.read_fields(items, 5) end)
        expect.error_match('out must be a table', function() df.read_fields(items, {}, 5) end)
        expect.error_match("no field 'nope'", function() df.read_fields(items, {fields={'nope'}}) end)
        expect.error_match("no flag 'nope'", function() df.read_fields(items, {fields={'flags1.nope'}}) end)
        expect.error_match('not a single value', function() df.read_fields(job.items, {where={{'_value', '==', 1}}}) end)
        expect.error_match('no readable attribute', function() df.read_fields(items, {fields={'item_type.nope'}}) end)
        expect.error_match('has no attributes', function() df.read_fields(items, {fields={'quantity.nope'}}) end)
        expect.error_match('fields must be a table', function() df.read_fields(items, {fields='quantity'}) end)
        expect.error_match('where must be a table', function() df.read_fields(items, {where='quantity'}) end)
        expect.error_match('list of conditions', function() df.read_fields(items, {where={quantity=3}}) end)
        expect.error_match('must be a table', function() df.read_fields(items, {where={'quantity'}}) end)
        expect.error_match('unknown comparison', function() df.read_fields(items, {where={{'quantity', '=', 1}}}) end)
        expect.error_match('no comparison', function() df.read_fields(items, {where={{'quantity'}}}) end)
        expect.error_match('no usable value', function() df.read_fields(items, {where={{'quantity', '<', true}}}) end)
        expect.error_match('no usable value', function() df.read_fields(items, {where={{'quantity', '=='}}}) end)
        expect.error_match('needs a list', function() df.read_fields(items, {where={{'quantity', 'in', 3}}}) end)
        expect.error_match('exactly one', function()
            df.read_fields(items, {where={{'not', {'quantity', '==', 1}, {'quantity', '==', 2}}}})
        end)
        expect.error_match('unknown option', function() df.read_fields(items, {test=5}) end)
        expect.error_match('no usable value', function() df.read_fields(items, {where={{'quantity', '==', {}}}}) end)
        expect.error_match('name of a container', function() df.read_fields({a=items}, {fields={'quantity'}}) end)
        expect.error_match('string names', function() df.read_fields({a=items, [2]=items}) end)
        expect.error_match('cannot be used as a container name', function() df.read_fields({_from=items}) end)
    end)
end

function test.null_pointers()
    with_job(function(job)
        local out, n = df.read_fields(job.items, {fields={'_index'}, where={{'item', '==', df.NULL}}})
        expect.eq(n, 2)
        out, n = df.read_fields(job.items, {where={{'item', '~=', df.NULL}}})
        expect.eq(n, 0)

        local item = df.item_boulderst:new()
        dfhack.with_finalize(
            function()
                job.items[1].item = nil
                item:delete()
            end,
            function()
                job.items[1].item = item
                out, n = df.read_fields(job.items, {fields={'_index'}, where={{'item', '==', df.NULL}}})
                expect.eq(n, 1)
                expect.eq(out._index[1], 0)
                out, n = df.read_fields(job.items, {fields={'_index'}, where={{'item', '~=', df.NULL}}})
                expect.eq(n, 1)
                expect.eq(out._index[1], 1)
                out, n = df.read_fields(job.items, {fields={'_index'}, where={{'not', {'item', '==', df.NULL}}}})
                expect.eq(n, 1)
                expect.eq(out._index[1], 1)
                out, n = df.read_fields(job.items, {where={{'or', {'item', '==', df.NULL}, {'job_item_idx', '==', 2}}}})
                expect.eq(n, 2)
                out, n = df.read_fields(job.items, {fields={'item'}})
                expect.eq(out.item[1], nil)
                expect.eq(out.item[2], item)
            end)

        expect.error_match('only be compared with df.NULL', function()
            df.read_fields(job.items, {where={{'item', '==', 5}}})
        end)
        expect.error_match('only be compared with df.NULL', function()
            df.read_fields(job.items, {where={{'item', '<', df.NULL}}})
        end)
        expect.error_match('only be compared with df.NULL', function()
            df.read_fields(job.items, {where={{'item', 'in', {df.NULL}}}})
        end)
        -- a pointer is still not something to hand back
        expect.error_match('not a single value', function() df.read_fields(job.items, {where={{'_value', '==', 1}}}) end)
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
                local out, n = df.read_fields(postings, {fields={'_index'}, where={cond}})
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
            local out, n = df.read_fields(items, {fields={'_index'}, where={cond}})
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
            local out, n = df.read_fields(mat.mat_rgb, {fields={'_index'}, where={cond}})
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
            local out, n = df.read_fields(pile.quality_core, {fields={'_index'}, where={cond}})
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
            local out, n = df.read_fields(source, {fields={'_index'}, where=where})
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
            local out, n = df.read_fields({tt=block.tiletype}, {fields={'_index'}, where={cond}})
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

            local out, n = df.read_fields({a, b}, {fields={'_from', '_index', 'quantity'}})
            expect.eq(n, 9)
            expect.table_eq(column(out, '_from', n), {1, 1, 1, 1, 1, 2, 2, 2, 2})
            expect.table_eq(column(out, '_index', n), {0, 1, 2, 3, 4, 0, 1, 2, 3})
            expect.table_eq(column(out, 'quantity', n), {3, 1, 7, 5, 2, 100, 1, 7, 5})

            out, n = df.read_fields({b, a, b}, {fields={'_from', '_index'}, where={{'quantity', '>=', 5}}})
            expect.table_eq(column(out, '_from', n), {1, 1, 1, 2, 2, 3, 3, 3})
            expect.table_eq(column(out, '_index', n), {0, 2, 3, 2, 3, 0, 2, 3})

            -- one container reads as a list of one
            out, n = df.read_fields(a, {fields={'_from'}})
            expect.table_eq(column(out, '_from', n), {1, 1, 1, 1, 1})
            out, n = df.read_fields({a})
            expect.eq(n, 5)

            -- nothing to read from
            out, n = df.read_fields({}, {fields={'quantity'}}, {quantity={1, 2}})
            expect.eq(n, 0)
            expect.table_eq(out.quantity, {1, 2})

            expect.error_match('not of the kind', function() df.read_fields({a, job.items}) end)
            expect.error_match('expected a container', function() df.read_fields({a, 5}) end)
            expect.error_match('expected a container', function() df.read_fields({a, {x=b}}) end)
            -- '_from' in a condition
            out, n = df.read_fields({a, b}, {fields={'_from', '_index'}, where={{'_from', '==', 2}, {'quantity', '>', 4}}})
            expect.table_eq(column(out, '_from', n), {2, 2, 2})
            expect.table_eq(column(out, '_index', n), {0, 2, 3})
            out, n = df.read_fields({a, b}, {fields={'_index'},
                where={{'or', {'and', {'_from', '==', 1}, {'_index', '==', 4}},
                              {'and', {'_from', 'in', {2}}, {'_index', '<', 1}}}}})
            expect.table_eq(column(out, '_index', n), {4, 0})
            out, n = df.read_fields(a, {where={{'_from', '==', 1}}})
            expect.eq(n, 5)
        end)
    end)

    with_block(function(block)
        with_block(function(other)
            block.designation[0][5].flow_size = 7
            other.designation[2][0].flow_size = 4
            block.temperature_1[0][5] = 0
            other.temperature_1[2][0] = 9
            local out, n = df.read_fields(
                {{des=block.designation, t=block.temperature_1}, {des=other.designation, t=other.temperature_1}},
                {fields={'_from', '_index', 'des.flow_size', 't'}, where={{'des.flow_size', '>', 0}}})
            expect.eq(n, 2)
            expect.table_eq(column(out, '_from', n), {1, 2})
            expect.table_eq(column(out, '_index', n), {5, 32})
            expect.table_eq(column(out, 'des.flow_size', n), {7, 4})
            expect.table_eq(column(out, 't', n), {0, 9})
            expect.error_match("no container named", function()
                df.read_fields({{des=block.designation, t=block.temperature_1}, {des=other.designation}})
            end)
            -- the first table says which names are read; others in later tables are left alone
            out, n = df.read_fields({{des=block.designation}, {des=other.designation, t=other.temperature_1}},
                                   {fields={'_from'}, where={{'des.flow_size', '>', 0}}})
            expect.table_eq(column(out, '_from', n), {1, 2})
            expect.error_match('table of named containers', function()
                df.read_fields({{des=block.designation}, other.designation})
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
            local read = df.prepare_read_fields(a, options)
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
            local plain, count = df.read_fields({b, a}, {fields={'_from', '_index', 'quantity'}, where={{'quantity', '>', 4}}})
            out, n = read({b, a})
            expect.eq(n, count)
            for _, name in ipairs{'_from', '_index', 'quantity'} do
                expect.table_eq(column(out, name, n), column(plain, name, count), name)
            end

            -- a list can stand in for the container when preparing
            local from_list = df.prepare_read_fields({a, b}, {fields={'quantity'}})
            out, n = from_list(b)
            expect.eq(n, 5)

            expect.error_match('not of the kind', function() read(job.items) end)
            expect.error_match('expected a container', function() read(5) end)
            expect.error_match('out must be a table', function() read(a, 5) end)
            expect.error_match('Usage', function() read() end)
            expect.error_match('Usage', function() df.prepare_read_fields() end)
            expect.error_match('no containers', function() df.prepare_read_fields({}) end)
            expect.error_match("no field 'nope'", function() df.prepare_read_fields(a, {fields={'nope'}}) end)
            expect.error_match('options must be a table', function() df.prepare_read_fields(a, 5) end)
        end)
    end)

    with_block(function(block)
        with_block(function(other)
            block.designation[0][5].flow_size = 7
            other.designation[2][0].flow_size = 4
            local read = df.prepare_read_fields({des=block.designation, tt=block.tiletype},
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
            local out, n = df.read_fields({items=items, _range=range},
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

        -- a range that runs past the end
        local out, n = df.read_fields({items=items, _range={4, 9}}, {fields={'_index'}}, {})
        expect.table_eq(column(out, '_index', n), {4})

        -- the range is only a part of the reading: the name '_range' is not a container
        out, n = df.read_fields({items=items, _range={0, 1}})
        expect.eq(n, 2)
    end)
end

function test.range_in_the_wrong_place()
    with_block(function(block)
        local des = block.designation
        local opts = {fields={'_index'}}
        -- on the list around the containers instead of on a table of named containers
        expect.error_match("'_range' was given on the list", function()
            df.read_fields({des, des, _range={0, 1}}, opts)
        end)
        expect.error_match("'_range' was given on the list", function()
            df.read_fields({{des=des}, {des=des}, _range={0, 0, 0, 0}}, opts)
        end)
        local read = df.prepare_read_fields({{des=des}}, opts)
        expect.error_match("'_range' was given on the list", function()
            read({{des=des}, _range={0, 0, 0, 0}})
        end)
        -- on a list of objects
        local a, b = df.coord:new(), df.coord:new()
        dfhack.with_finalize(
            function() a:delete() b:delete() end,
            function()
                expect.error_match("'_range' was given on the list", function()
                    df.read_fields({a, b, _range={0, 0}}, {fields={'x'}})
                end)
                local _, n = df.read_fields({a, b}, {fields={'x'}})
                expect.eq(n, 2)
            end)
        -- where it belongs
        local _, n = df.read_fields({{des=des, _range={0, 0, 0, 0}}, {des=des}}, opts)
        expect.eq(n, 257)
    end)
end

function test.range_on_a_grid()
    with_block(function(block)
        local function read(range, where)
            local out, n = df.read_fields({des=block.designation, _range=range},
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
        local out, n = df.read_fields(grids, {fields={'_index', 'des.flow_size'},
            where={{'des.flow_size', '>', 0}}})
        expect.table_eq(column(out, '_index', n), {2 * 16 + 3, 3 * 16 + 4})
        expect.table_eq(column(out, 'des.flow_size', n), {7, 5})

        out, n = df.read_fields(grids, {fields={'_index'}, where={{'tt.shape', '==', df.tiletype_shape.FLOOR}}})
        expect.table_eq(column(out, '_index', n), {2 * 16 + 3, 3 * 16 + 4})

        -- the index conditions work on the full-grid index
        out, n = df.read_fields(grids, {fields={'_index'}, where={{'_index', '>=', 3 * 16}}})
        expect.table_eq(column(out, '_index', n), rectangle(3, 4, 3, 5))

        -- without a range, nothing changes
        out, n = df.read_fields({tt=block.tiletype, des=block.designation}, {fields={'_index'},
            where={{'des.flow_size', '>', 0}}})
        expect.table_eq(column(out, '_index', n), {2 * 16 + 3, 2 * 16 + 9, 3 * 16 + 4, 6 * 16 + 3})

        -- a grid on its own, given a name so that it can have a range
        out, n = df.read_fields({des=block.designation, _range={2, 3, 4, 15}},
            {fields={'_index'}, where={{'des.flow_size', '>', 0}}})
        expect.table_eq(column(out, '_index', n), {2 * 16 + 9, 3 * 16 + 4})
    end)
end

function test.range_in_lists()
    with_block(function(a)
        with_block(function(b)
            local function read(items)
                local out, n = df.read_fields(items, {fields={'_from', '_index'}})
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

            local read = df.prepare_read_fields({des=a.designation},
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

            -- the reuse of the output table works with ranges
            local keep = {}
            out, n = read({des=a.designation, _range={0, 15, 0, 15}}, keep)
            expect.eq(out, keep)
            expect.eq(n, 2)
            out, n = read({des=a.designation, _range={0, 0, 0, 0}}, keep)
            expect.eq(n, 0)
        end)
    end)
end

function test.range_errors()
    with_job(function(job)
        with_block(function(block)
            local items = job.job_items.elements
            local function range(value)
                return function() df.read_fields({items=items, _range=value}) end
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

            -- there is no other way to give a range
            expect.error_match('Usage', function() df.read_fields(items, {}, nil, {{0, 1}}) end)

            -- a bad range anywhere in a list is an error, whatever comes before it
            expect.error_match('range must be a table', function()
                df.read_fields({{des=block.designation}, {des=block.designation, _range={1}}})
            end)
            expect.error_match('whole numbers', function()
                df.read_fields({{des=block.designation, _range={0, 1, 0, 1}}, {des=block.designation, _range={0.5, 1, 0, 1}}})
            end)

            local read = df.prepare_read_fields({items=items}, {fields={'_index'}})
            expect.error_match('range must be a table', function() read({items=items, _range={1}}) end)
            expect.error_match('Usage', function() read({items=items}, nil, {{0, 1}}) end)

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
        local out, n = df.read_fields({a, b}, {fields={'_index', '_from', 'id'}})
        expect.eq(n, 2)
        expect.table_eq(column(out, '_index', n), {1, 2})
        expect.table_eq(column(out, '_from', n), {1, 1})
        expect.table_eq(column(out, 'id', n), {'IRON', 'IRONWOOD'})

        -- '_from' is 1 for every object, in a condition as well
        out, n = df.read_fields({a, b}, {where={{'_from', '==', 1}}})
        expect.eq(n, 2)
        out, n = df.read_fields({a, b}, {where={{'_from', '~=', 1}}})
        expect.eq(n, 0)

        out, n = df.read_fields({a, b, a}, {fields={'_index'}, where={{'id', '==', 'IRON'}}})
        expect.table_eq(column(out, '_index', n), {1, 3})

        out, n = df.read_fields({})
        expect.eq(n, 0)

        expect.error_match('entry 2 of the list is not a material', function() df.read_fields({a, 5}) end)
        expect.error_match('entry 2 of the list is not a material', function()
            with_job(function(job) df.read_fields({a, job}) end)
        end)
        expect.error_match('not a container', function() df.read_fields(a) end)

        -- a fixed-size array of pointers: the objects are read, null entries are skipped
        local tbl = df.special_mat_table:new()
        dfhack.with_finalize(function() tbl.builtin[1] = nil tbl:delete() end, function()
            tbl.builtin[1] = a
            out, n = df.read_fields(tbl.builtin, {fields={'_index', 'id'}})
            expect.eq(n, 1)
            expect.eq(out._index[1], 1)
            expect.eq(out.id[1], 'IRON')
        end)
        -- a read that stops halfway with an error leaves the collector running
        expect.true_(collectgarbage('isrunning'))
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
            local out, n = df.read_fields({worker, holder}, {fields={'unit_id', 'general_ref_building:building_id'}})
            expect.eq(n, 2)
            expect.eq(out.unit_id[1], 7)
            expect.eq(out.unit_id[2], nil)
            expect.eq(out['general_ref_building:building_id'][2], 9)

            local read = df.prepare_read_fields(df.general_ref, {fields={'_index'}, where={{'unit_id', '==', 7}}})
            out, n = read({holder, worker, holder})
            expect.table_eq(column(out, '_index', n), {2})
            out, n = read({})
            expect.eq(n, 0)
            with_materials(function(a)
                expect.error_match('entry 1 of the list is not a general_ref', function() read({a}) end)
            end)
            expect.error_match('set up for a list of objects', function() read(worker) end)

            -- one set up from a list takes objects of the nearest class the objects of that list share
            read = df.prepare_read_fields({worker}, {fields={'unit_id'}})
            expect.error_match('entry 1 of the list is not a general_ref_unit_workerst', function() read({holder}) end)
            read = df.prepare_read_fields({worker, holder}, {fields={'unit_id'}})
            out, n = read({holder, worker})
            expect.eq(n, 2)

            -- a read set up from a type takes only objects of that type
            read = df.prepare_read_fields(df.general_ref_unit_workerst, {fields={'unit_id'}})
            out, n = read({worker})
            expect.table_eq(column(out, 'unit_id', n), {7})
            expect.error_match('entry 1 of the list is not a general_ref_unit_workerst', function() read({holder}) end)
        end)
end

function test.limit()
    with_job(function(job, specs)
        local items = job.job_items.elements
        local out, n = df.read_fields(items, {fields={'_index'}, limit=2})
        expect.table_eq(column(out, '_index', n), {0, 1})
        out, n = df.read_fields(items, {fields={'_index'}, where={{'item_type', '==', df.item_type.BAR}}, limit=1})
        expect.table_eq(column(out, '_index', n), {0})
        out, n = df.read_fields(items, {fields={'_index'}, where={{'quantity', '>=', 5}}, limit=10})
        expect.table_eq(column(out, '_index', n), {2, 3})

        -- the limit is on the whole call, not on each container
        out, n = df.read_fields({items, items}, {fields={'_from', '_index'}, limit=7})
        expect.eq(n, 7)
        expect.table_eq(column(out, '_from', n), {1, 1, 1, 1, 1, 2, 2})
        out, n = df.read_fields({items, items}, {fields={'_from'}, limit=5})
        expect.table_eq(column(out, '_from', n), {1, 1, 1, 1, 1})
        out, n = df.read_fields({items=items, _range={1, 4}}, {fields={'_index'}, limit=2})
        expect.table_eq(column(out, '_index', n), {1, 2})

        local read = df.prepare_read_fields(items, {fields={'_index'}, limit=2})
        for _ = 1, 2 do
            out, n = read(items)
            expect.table_eq(column(out, '_index', n), {0, 1})
        end

        for _, bad in ipairs{0, -1, 1.5, '2', true} do
            expect.error_match('limit must be a whole number', function() df.read_fields(items, {limit=bad}) end)
        end
        expect.error_match("unknown option 'feilds'", function() df.read_fields(items, {feilds={'quantity'}}) end)
        expect.error_match('unknown option', function() df.read_fields(items, {[1]='quantity'}) end)
    end)
end

function test.entries_of_arrays_and_vectors()
    with_materials(function(a, b)
        local list = {a, b}
        -- an entry of an array is named by its number or by the name the array is indexed with
        local out, n = df.read_fields(list, {fields={'state_name.Solid', 'state_name.1', 'state_color.Liquid',
                                                   'strength.yield.IMPACT'}})
        expect.eq(n, 2)
        expect.table_eq(column(out, 'state_name.Solid', n), {'iron', 'ironwood'})
        expect.table_eq(column(out, 'state_name.1', n), {'molten iron', 'n/a'})
        expect.table_eq(column(out, 'state_color.Liquid', n), {9, 6})
        expect.table_eq(column(out, 'strength.yield.IMPACT', n), {500, 20})

        out, n = df.read_fields(list, {fields={'id'}, where={{'state_color.Solid', '<', 5}}})
        expect.table_eq(column(out, 'id', n), {'IRON'})
        out, n = df.read_fields(list, {fields={'id'}, where={{'state_name.Liquid', '==', 'n/a'}}})
        expect.table_eq(column(out, 'id', n), {'IRONWOOD'})

        -- an entry that a vector does not have is nil, and no condition on it holds
        out, n = df.read_fields(list, {fields={'reaction_product.item_type.0', 'reaction_product.item_type.2',
                                             'reaction_product.item_type._size'}})
        expect.table_eq(column(out, 'reaction_product.item_type.0', n), {df.item_type.BAR, df.item_type.WOOD})
        expect.eq(out['reaction_product.item_type.2'][1], df.item_type.ARMOR)
        expect.eq(out['reaction_product.item_type.2'][2], nil)
        expect.table_eq(column(out, 'reaction_product.item_type._size', n), {3, 1})
        out, n = df.read_fields(list, {fields={'id'}, where={{'reaction_product.item_type.2', '~=', df.item_type.BAR}}})
        expect.table_eq(column(out, 'id', n), {'IRON'})
        out, n = df.read_fields(list, {fields={'id'}, where={{'reaction_product.item_type._size', '<', 2}}})
        expect.table_eq(column(out, 'id', n), {'IRONWOOD'})

        expect.error_match('outside the array', function() df.read_fields(list, {fields={'state_name.99'}}) end)
        expect.error_match('outside the array', function() df.read_fields(list, {fields={'state_name.None'}}) end)
        expect.error_match('must be the index of an entry', function()
            df.read_fields(list, {fields={'state_name.nope'}})
        end)
        expect.error_match('not a single value', function() df.read_fields(list, {where={{'state_name', '==', 'x'}}}) end)
    end)

    with_job(function(job, specs)
        -- through a vector of pointers, and on to what an entry points to
        local out, n = df.read_fields({job}, {fields={'job_items.elements.1.quantity', 'job_items.elements.9.quantity',
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
        local out, n = df.read_fields({block}, {fields={'designation.3.5.flow_size', 'designation.3.4.flow_size'}})
        expect.eq(out['designation.3.5.flow_size'][1], 6)
        expect.eq(out['designation.3.4.flow_size'][1], 0)
        out, n = df.read_fields({block}, {where={{'designation.3.5.flow_size', '==', 6}}})
        expect.eq(n, 1)
        expect.error_match('outside the array', function() df.read_fields({block}, {fields={'designation.16.0.flow_size'}}) end)
    end)
end

function test.flag_arrays()
    with_materials(function(a, b)
        local list = {a, b}
        local out, n = df.read_fields(list, {fields={'flags.IS_METAL', 'flags.IS_STONE'}})
        expect.table_eq(column(out, 'flags.IS_METAL', n), {true, false})
        expect.table_eq(column(out, 'flags.IS_STONE', n), {false, true})
        out, n = df.read_fields(list, {fields={'id'}, where={{'flags.IS_METAL', '==', true}}})
        expect.table_eq(column(out, 'id', n), {'IRON'})
        out, n = df.read_fields(list, {fields={'id'}, where={{'flags.IS_METAL', '==', false}}})
        expect.table_eq(column(out, 'id', n), {'IRONWOOD'})
        out, n = df.read_fields(list, {fields={'id'}, where={{'or', {'flags.IS_METAL', '==', true},
                                                            {'flags.IS_STONE', '==', true}}}})
        expect.eq(n, 2)
        -- by number, as Lua reads them too
        out, n = df.read_fields(list, {fields={'flags.' .. df.material_flags.IS_METAL}})
        expect.table_eq(column(out, 'flags.' .. df.material_flags.IS_METAL, n), {true, false})
        expect.error_match("no flag 'NOPE'", function() df.read_fields(list, {fields={'flags.NOPE'}}) end)
    end)
end

function test.same_as_lua()
    with_materials(function(a, b)
        with_job(function(job)
            -- anything that is not a single value comes back as reading it in Lua gives it
            local out, n = df.read_fields({a}, {fields={'_value', 'heat', 'state_name', 'flags', 'reaction_product.item_type'}})
            expect.eq(n, 1)
            expect.eq(out._value[1], a)
            expect.eq(out.heat[1], a.heat)
            expect.eq(out.state_name[1], a.state_name)
            expect.eq(out.state_name[1].Solid, 'iron')
            expect.eq(out.flags[1], a.flags)
            expect.true_(out.flags[1].IS_METAL)
            expect.eq(out['reaction_product.item_type'][1], a.reaction_product.item_type)
            expect.eq(#out['reaction_product.item_type'][1], 3)

            out, n = df.read_fields(job.job_items.elements, {fields={'_value'}, where={{'quantity', '==', 7}}})
            expect.eq(n, 1)
            expect.eq(out._value[1], job.job_items.elements[2])
            out, n = df.read_fields({items=job.job_items.elements}, {fields={'items'}, limit=1})
            expect.eq(out.items[1], job.job_items.elements[0])

            -- a pointer gives the object it points to, or nil
            out, n = df.read_fields(job.items, {fields={'item'}})
            expect.eq(n, 2)
            expect.eq(out.item[1], nil)
            expect.eq(out.item[2], nil)
            out, n = df.read_fields({job}, {fields={'job_items.elements.0', 'job_items.elements.7'}})
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
                local out, n = df.read_fields(refs, {fields={'_type'}})
                expect.eq(n, 2)
                expect.eq(out._type[1], df.general_ref_unit_workerst)
                expect.eq(out._type[2], df.general_ref_building_holderst)

                local function matching(cond)
                    local found, count = df.read_fields(refs, {fields={'_index'}, where={cond}})
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

function test.methods_are_not_called()
    with_job(function(job)
        local refs = job.general_refs
        expect.error_match('is a method, which a path cannot call', function()
            df.read_fields(refs, {fields={'getType'}})
        end)
        expect.error_match("no field 'getType%(%)'", function()
            df.read_fields(refs, {where={{'getType()', '==', 1}}})
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
                    local out, n = df.read_fields({job, other}, {fields={'_index'}, where={cond}})
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

function test.fields_under_other_names()
    with_job(function(job)
        local items = job.job_items.elements
        local out, n = df.read_fields(items, {fields={{path='quantity', as='q'}, '_index', {path='flags1.improvable', as='imp'}},
                                             where={{'quantity', '>', 2}}})
        expect.eq(n, 3)
        expect.table_eq(column(out, 'q', n), {3, 7, 5})
        expect.table_eq(column(out, '_index', n), {0, 2, 3})
        expect.table_eq(column(out, 'imp', n), {false, false, true})
        expect.nil_(out.quantity)

        -- the same field under two names, and the same name twice for the same field
        out, n = df.read_fields(items, {fields={'quantity', {path='quantity', as='again'}, {path='quantity', as='again'}}, limit=2})
        expect.table_eq(column(out, 'quantity', n), {3, 1})
        expect.table_eq(column(out, 'again', n), {3, 1})

        -- prepared, and into a table that is reused
        local read = df.prepare_read_fields(items, {fields={{path='mat_index', as='mat'}}})
        local reused = {}
        out, n = read(items, reused)
        expect.eq(out, reused)
        expect.table_eq(column(out, 'mat', n), {10, 20, 30, 40, 50})

        expect.error_match("two different fields would be stored as 'q'", function()
            df.read_fields(items, {fields={{path='quantity', as='q'}, {path='mat_index', as='q'}}})
        end)
        expect.error_match("two different fields would be stored as 'quantity'", function()
            df.read_fields(items, {fields={'quantity', {path='mat_index', as='quantity'}}})
        end)
        expect.error_match("must be {path=", function() df.read_fields(items, {fields={{path='quantity'}}}) end)
        expect.error_match("must be {path=", function() df.read_fields(items, {fields={{path='quantity', as='q', x=1}}}) end)
        expect.error_match("must be {path=", function() df.read_fields(items, {fields={{'quantity', 'q'}}}) end)
        expect.error_match("empty name", function() df.read_fields(items, {fields={{path='quantity', as=''}}}) end)
        expect.error_match("must be a string or {path=", function() df.read_fields(items, {fields={5}}) end)
    end)
end

function test.options_and_out_that_change_the_container_as_they_are_looked_up()
    -- the container is measured after the last of the Lua code that a lookup can run
    with_materials(function(a)
        local types = a.reaction_product.item_type
        expect.eq(#types, 3)
        local out = setmetatable({}, {__index=function() types:resize(1) end})
        local _, n = df.read_fields(types, {fields={'_index', '_value'}}, out)
        expect.eq(n, 1)
        expect.table_eq(rawget(out, '_value'), {df.item_type.BAR})
    end)
    with_materials(function(a)
        local types = a.reaction_product.item_type
        local options = setmetatable({fields={'_value'}}, {__index=function() types:resize(2) end})
        local out, n = df.read_fields(types, options)
        expect.eq(n, 2)
        expect.table_eq(out._value, {df.item_type.BAR, df.item_type.WEAPON})
    end)
end

function test.more_errors()
    with_job(function(job)
        local items = job.job_items.elements
        local function fails(message, options, containers)
            expect.error_match(message, function() df.read_fields(containers or items, options) end, message)
        end
        fails('empty field name', {fields={''}})
        fails('empty field name', {fields={'.quantity'}})
        fails('a condition must start with', {where={{5, '==', 1}}})
        fails('a condition must start with', {where={{}}})
        fails('no usable value', {where={{'quantity', '==', nil}}})
        fails("'_index.x' does not start with the name", {fields={'_index.x'}}, {a=items})
        fails("'_from.x' does not start with the name", {fields={'_from.x'}}, {a=items})
        fails("'' cannot be used as a container name", nil, {['']=items})
        fails("'_index' cannot be used as a container name", nil, {_index=items})
        fails("'a.b' cannot be used as a container name", nil, {['a.b']=items})
        fails("is_instance needs a path that ends in '_type'", {where={{'quantity', 'is_instance', df.job_item}}})

        local nested = {'quantity', '>', 4}
        for _ = 1, 32 do nested = {'not', nested} end
        local _, n = df.read_fields(items, {where={nested}})
        expect.eq(n, 2)
        nested = {'not', nested}
        fails('nested too deeply', {where={nested}})
    end)
    with_block(function(block)
        local path = df.coord_path:new()
        dfhack.with_finalize(function() path:delete() end, function()
            path.x:resize(256)
            expect.error_match('arranged the same way', function()
                df.read_fields({a=block.designation, b=path.x, _range={0, 1}})
            end)
        end)
    end)
    with_materials(function(a)
        expect.error_match('not a container it can read', function() df.read_fields(a.flags) end)
    end)
    -- nothing to read is not an error, but there is nothing to set a read up for
    local _, n = df.read_fields({})
    expect.eq(n, 0)
    expect.error_match('no containers or objects given', function() df.prepare_read_fields({}) end)
end

function test.fixed_text_and_untyped_pointers()
    local line = df.color_text_linest:new()
    dfhack.with_finalize(function() line:delete() end, function()
        line.text = 'hello'
        -- text in a fixed-size array is handed back
        local out, n = df.read_fields({line}, {fields={'text', 'color'}})
        expect.eq(n, 1)
        expect.eq(out.text[1], 'hello')
        expect.eq(out.color[1], '')
        -- and nothing else can be done with it
        expect.error_match("'text' in 'text' is a fixed piece of text", function()
            df.read_fields({line}, {where={{'text', '==', 'hello'}}})
        end)
        expect.error_match("'text' in 'text.0' is a fixed piece of text", function()
            df.read_fields({line}, {fields={'text.0'}})
        end)
    end)

    -- a pointer to something of no known type can be checked for being null, and that is all
    local entry = df.global_table_entry:new()
    dfhack.with_finalize(function() entry:delete() end, function()
        local out, n = df.read_fields({entry}, {fields={'size', 'name'}, where={{'address', '==', df.NULL}}})
        expect.eq(n, 1)
        expect.eq(out.size[1], 0)
        expect.eq(out.name[1], nil)
        out, n = df.read_fields({entry}, {where={{'address', '~=', df.NULL}}})
        expect.eq(n, 0)
        expect.error_match("cannot follow the pointer 'address' in 'address'", function()
            df.read_fields({entry}, {fields={'address'}})
        end)
        expect.error_match("cannot follow the pointer 'address' in 'address.x'", function()
            df.read_fields({entry}, {fields={'address.x'}})
        end)
        expect.error_match('can only be compared with df.NULL', function()
            df.read_fields({entry}, {where={{'address', '==', 1}}})
        end)
    end)
end

function test.text_that_is_not_there()
    -- the type NONE has no caption
    expect.eq(df.item_type.attrs.NONE.caption, nil)
    with_job(function(job)
        local items = job.job_items.elements
        items[1].item_type = df.item_type.NONE
        local bar = df.item_type.attrs.BAR.caption
        local function matching(cond)
            local out, n = df.read_fields(items, {fields={'_index'}, where={cond}})
            return column(out, '_index', n)
        end
        local out, n = df.read_fields(items, {fields={'item_type.caption'}})
        expect.eq(n, 5)
        expect.eq(out['item_type.caption'][1], bar)
        expect.eq(out['item_type.caption'][2], nil)
        -- and it passes no comparison, as with anything else that is not there
        expect.table_eq(matching{'item_type.caption', '==', bar}, {0, 3})
        expect.table_eq(matching{'item_type.caption', '~=', bar}, {2, 4})
        expect.table_eq(matching{'not', {'item_type.caption', '==', bar}}, {1, 2, 4})
        expect.table_eq(matching{'item_type.caption', '>=', ''}, {0, 2, 3, 4})
        expect.table_eq(matching{'item_type.caption', '<', 'zzzz'}, {0, 2, 3, 4})
        expect.table_eq(matching{'item_type.caption', 'in', {bar, ''}}, {0, 3})
    end)
end

function test.unions_know_which_member_is_in_use()
    -- another field of the structure says which member of the union holds something, and a
    -- reference to the union shows that member alone, as it does when Lua reads the field
    local function members(union)
        local names = {}
        for name in pairs(union) do names[#names + 1] = tostring(name) end
        table.sort(names)
        return names
    end
    local change = df.site_architecture_changest:new()
    dfhack.with_finalize(function() change:delete() end, function()
        local seen = {}
        for _, kind in ipairs{'GENERALIZED_DAMAGE', 'GENERALIZED_DEATH', 'NONE'} do
            change.type = df.site_architecture_change_type[kind]
            local out, n = df.read_fields({change}, {fields={'spec_flag', {path='spec_flag', as='again'}}})
            expect.eq(n, 1)
            local expected = members(change.spec_flag)
            expect.table_eq(members(out.spec_flag[1]), expected, kind)
            expect.table_eq(members(out.again[1]), expected, kind)
            seen[kind] = #expected
        end
        expect.eq(seen.GENERALIZED_DAMAGE, 1)
        expect.eq(seen.GENERALIZED_DEATH, 1)
        expect.eq(seen.NONE, 0)
    end)
end

-- Reads made up at random, each checked against the same read written as a loop in Lua. The
-- numbers come from a generator of their own, set anew for each round, so that a run is the
-- same everywhere and a round that fails can be run again alone (the third argument).
local function random_source()
    local state = 0
    local function rnd(n)
        state = state * 6364136223846793005 + 1442695040888963407
        return (state >> 33) % n + 1
    end
    local function reseed(to)
        state = to * 2862933555777941757 + 3037000493
        rnd(2)
    end
    return rnd, reseed
end

local function describe(v, depth)
    if type(v) == 'string' then return ('%q'):format(v) end
    if type(v) ~= 'table' then return tostring(v) end
    if (depth or 0) > 6 then return '...' end
    local parts = {}
    for key, item in pairs(v) do
        local name = type(key) == 'number' and '' or tostring(key) .. '='
        parts[#parts + 1] = name .. describe(item, (depth or 0) + 1)
    end
    table.sort(parts)
    return '{' .. table.concat(parts, ', ') .. '}'
end

-- a value and the kind of number it is; 1 and 1.0 are not the same answer
local function same(a, b) return a == b and math.type(a) == math.type(b) end

local function random_reads(seed, rounds, only)
    local rnd, reseed = random_source()
    local function pick(list) return list[rnd(#list)] end
    local function chance(percent) return rnd(100) <= percent end
    reseed(seed)

    local quantities = {-2147483648, -1, 0, 1, 2, 5, 2147483647}
    local big = {0, 1, 0x7FFFFFFF, 0x80000000, 0xFFFFFFFF}
    local types = {df.item_type.NONE, df.item_type.BAR, df.item_type.WOOD, df.item_type.BOULDER,
                   df.item_type.WEAPON}
    local texts = {'', 'a', 'ab', 'AB', 'abc', 'b c', 'Zab', 'bars', 'LOGS', 'A@[', 'a`{', '\xC4b', '\xE4B'}
    local small = {-1, 0, 1, 7}

    -- pairs of vectors of the same length, with gaps in different places
    local jobs, made = {}, {}
    local function fill(vec, size)
        for i = 1, size do
            if chance(15) then
                vec:insert('#', nil)
            else
                vec:insert('#', {new=true, quantity=pick(quantities), mat_index=pick(small), mat_type=pick(small),
                                 flags4=pick(big), item_type=pick(types), reaction_class=pick(texts),
                                 has_material_reaction_product=pick(texts)})
                local entry = vec[i - 1]
                made[#made + 1] = entry
                entry.flags1.improvable = chance(50)
                entry.flags1.glass = chance(50)
                for _ = 1, rnd(4) - 1 do entry.contains:insert('#', pick(small)) end
            end
        end
    end
    for i = 1, 8, 2 do
        local size = i == 1 and 40 or rnd(13) - 1
        for j = i, i + 1 do
            jobs[j] = df.job:new()
            fill(jobs[j].job_items.elements, size)
        end
    end
    local function vector(i) return jobs[i].job_items.elements end

    -- what can be read from an entry, and how Lua reads it
    local leaves = {
        {'quantity', 'number', function(e) return e.quantity end},
        {'mat_index', 'number', function(e) return e.mat_index end},
        {'mat_type', 'number', function(e) return e.mat_type end},
        {'flags4', 'number', function(e) return e.flags4 end},
        {'flags1', 'number', function(e) return e.flags1.whole end},
        {'item_type', 'number', function(e) return e.item_type end},
        {'item_type.caption', 'string', function(e) return df.item_type.attrs[e.item_type].caption end},
        {'item_type.is_rawable', 'boolean', function(e) return df.item_type.attrs[e.item_type].is_rawable end},
        {'flags1.improvable', 'boolean', function(e) return e.flags1.improvable end},
        {'flags1.glass', 'boolean', function(e) return e.flags1.glass end},
        {'reaction_class', 'string', function(e) return e.reaction_class end},
        {'has_material_reaction_product', 'string', function(e) return e.has_material_reaction_product end},
        {'contains._size', 'number', function(e) return #e.contains end},
        {'contains.0', 'number', function(e) return #e.contains > 0 and e.contains[0] or nil end},
        {'contains.2', 'number', function(e) return #e.contains > 2 and e.contains[2] or nil end},
    }
    local values = {number={}, string=texts, boolean={true, false}}
    for _, list in ipairs{quantities, big, small, types, {0.5, 1.0, -1.5, 3, 2.0, 2147483648.0, 2^53, math.huge,
                                                           -0.0}} do
        for _, v in ipairs(list) do table.insert(values.number, v) end
    end
    local kinds = {'number', 'string', 'boolean'}

    local function compare(a, op, b)
        if a == nil or b == nil then return false end
        if op == '==' then return a == b end
        if op == '~=' then return a ~= b end
        if type(a) ~= type(b) or type(a) == 'boolean' then return false end
        if op == '<' then return a < b end
        if op == '<=' then return a <= b end
        if op == '>' then return a > b end
        return a >= b
    end
    local function within(a, list)
        for _, v in ipairs(list) do
            if a ~= nil and a == v then return true end
        end
        return false
    end
    local orders = {'==', '~=', '<', '<=', '>', '>='}

    -- one round: a way of passing containers, the options, and the rows a loop in Lua gives
    local function round()
        local names               -- the names of the containers read side by side, or nil
        local container, rows, notes = nil, {}, {}
        local shape = rnd(5)
        local function add_rows(from, item, range)
            local last = #vector(item) - 1
            local low, high = 0, last
            if range then low, high = math.max(math.tointeger(range[1]), 0), math.min(range[2], last) end
            for index = low, high do
                local row = {index=index, from=from, entries={}}
                local present = true
                for k, name in ipairs(names or {''}) do
                    -- the second container of a pair is the next vector, of the same length
                    row.entries[name] = vector(item + k - 1)[index]
                    present = present and row.entries[name] ~= nil
                end
                if present then rows[#rows + 1] = row end
            end
        end
        local function named_item(from, item)
            local range
            if chance(60) then
                local first = rnd(8) - 3
                range = {first, chance(75) and first + rnd(12) - 1 or rnd(16) - 3}
                if item == 1 and chance(50) then range = {range[1] + 20, range[2] + 30} end
                if chance(20) then range[1] = range[1] + 0.0 end
            end
            add_rows(from, item, range)
            notes[#notes + 1] = ('%d%s'):format(item, range and describe(range) or '')
            local t = {_range=range}
            for k, name in ipairs(names) do t[name] = vector(item + k - 1) end
            return t
        end
        local function odd() return rnd(4) * 2 - 1 end
        local other               -- another container of the same kind, for a prepared read
        if shape == 1 then
            local item = rnd(8)
            container, other = vector(item), vector(rnd(8))
            add_rows(1, item)
            notes[1] = 'vector ' .. item
        elseif shape == 2 then
            container, other = {}, {}
            for from = 1, rnd(4) do
                local item = rnd(8)
                container[from] = vector(item)
                add_rows(from, item)
                notes[from] = tostring(item)
            end
            for from = 1, rnd(4) do other[from] = vector(rnd(8)) end
            notes[1] = 'vectors ' .. notes[1]
        elseif shape == 3 then
            names = chance(50) and {'a'} or {'a', 'b'}
            container = named_item(1, odd())
            notes[1] = #names .. ' named, vector ' .. notes[1]
        elseif shape == 4 then
            names = chance(50) and {'a'} or {'a', 'b'}
            container = {}
            for from = 1, rnd(4) do container[from] = named_item(from, odd()) end
            notes[1] = #names .. ' named, vectors ' .. notes[1]
        else
            container = {}
            for place = 1, rnd(10) do
                local number = rnd(#made)
                container[place] = made[number]
                rows[place] = {index=place, from=1, entries={['']=container[place]}}
                notes[place] = tostring(number)
            end
            notes[1] = 'objects ' .. notes[1]
        end

        -- a path with its kind and a function that gives its value for a row
        local function leaf()
            if chance(8) then return '_index', 'number', function(row) return row.index end end
            if chance(8) then return '_from', 'number', function(row) return row.from end end
            local path, kind, get = table.unpack(pick(leaves))
            local name = names and pick(names) or ''
            return (names and name .. '.' or '') .. path, kind, function(row) return get(row.entries[name]) end
        end
        local function value_of(kind, ordered, get)
            -- often a value that one of the rows has, so that conditions pass for some and not all
            if get and #rows > 0 and chance(40) then
                local v = get(pick(rows))
                if v ~= nil and not (ordered and type(v) == 'boolean') then return v end
            end
            local other_kind = pick(kinds)
            if chance(85) or (ordered and other_kind == 'boolean') then other_kind = kind end
            -- '<' and the like take a number or text
            if ordered and other_kind == 'boolean' then other_kind = 'number' end
            return pick(values[other_kind])
        end
        local condition
        function condition(depth)
            local form = rnd(depth > 2 and 3 or 6)
            if form <= 2 then
                local path, kind, get = leaf()
                local op = pick(orders)
                local v = value_of(kind, op ~= '==' and op ~= '~=', get)
                return {path, op, v}, function(row) return compare(get(row), op, v) end
            elseif form == 3 then
                local path, kind, get = leaf()
                local list = {}
                for i = 1, rnd(5) - 1 do list[i] = value_of(kind, false, get) end
                return {path, 'in', list}, function(row) return within(get(row), list) end
            elseif form == 4 then
                local c, check = condition(depth + 1)
                return {'not', c}, function(row) return not check(row) end
            end
            -- with nothing in it, 'and' passes and 'or' does not
            local list, checks = {form == 5 and 'and' or 'or'}, {}
            for i = 1, rnd(3) - 1 do list[i + 1], checks[i] = condition(depth + 1) end
            return list, function(row)
                for _, check in ipairs(checks) do
                    if check(row) ~= (form == 5) then return form ~= 5 end
                end
                return form == 5
            end
        end

        local options, columns, checks = {fields={}}, {}, {}
        for i = 1, rnd(5) - 1 do
            local path, _, get = leaf()
            if chance(10) then
                options.fields[i] = {path=path, as='column' .. i}
                columns[i] = {'column' .. i, get}
            else
                options.fields[i] = path
                columns[i] = {path, get}
            end
        end
        -- which rows came back, and not only how many
        if chance(90) then
            table.insert(options.fields, {path='_index', as='row'})
            table.insert(columns, {'row', function(row) return row.index end})
            table.insert(options.fields, {path='_from', as='item'})
            table.insert(columns, {'item', function(row) return row.from end})
        end
        if chance(70) then
            options.where = {}
            for i = 1, rnd(3) do options.where[i], checks[i] = condition(1) end
        end
        if chance(25) then options.limit = rnd(6) end

        local kept = {}
        for _, row in ipairs(rows) do
            local passes = true
            for _, check in ipairs(checks) do
                if not check(row) then
                    passes = false
                    break
                end
            end
            if passes then kept[#kept + 1] = row end
            if #kept == options.limit then break end
        end
        return container, options, columns, kept, table.concat(notes, ', '), other
    end

    local failures = 0
    local reused, reused_too = {}, {}
    local function one_round(number)
        reseed(seed * 100003 + number)
        local container, options, columns, kept, notes, other = round()
        local label = ('seed %d round %d: %s, %s'):format(seed, number, notes, describe(options))
        -- the first thing that is wrong with what a read gave, if anything is
        local function wrong(out, n, want)
            if n ~= #want then return ('%s entries, %d expected'):format(tostring(n), #want) end
            for _, column in ipairs(columns) do
                local got = rawget(out, column[1])
                if type(got) ~= 'table' then return column[1] .. ' is not there' end
                for i, row in ipairs(want) do
                    local value = column[2](row)
                    if not same(got[i], value) then
                        return ('%s[%d] is %s, %s expected'):format(column[1], i, describe(got[i]), describe(value))
                    end
                end
                if got[#want + 1] ~= nil then return column[1] .. ' goes on after the last entry' end
            end
        end
        local function check(how, read)
            local ok, problem = pcall(read)
            if not ok then problem = tostring(problem) end
            if problem then
                failures = failures + 1
                if failures <= 5 then expect.fail(('%s: %s (%s)'):format(how, problem, label)) end
            end
        end
        check('read_fields', function()
            -- into arrays that still hold what the round before left there
            local out, n = df.read_fields(container, options, reused)
            if out ~= reused then return 'out is another table' end
            return wrong(out, n, kept)
        end)
        check('prepared', function()
            local read = df.prepare_read_fields(container, options)
            read(container, reused_too)
            local out, n = read(container, reused_too)
            local problem = wrong(out, n, kept)
            if problem or not other then return problem end
            -- the read that was set up does what a new one does for another container
            local got, count = read(other)
            local out2, n2 = df.read_fields(other, options)
            if count ~= n2 then return ('other container: %d entries, %d from read_fields'):format(count, n2) end
            for _, column in ipairs(columns) do
                for i = 1, n2 + 1 do
                    if not same(got[column[1]][i], out2[column[1]][i]) then
                        return ('other container: %s[%d] differs'):format(column[1], i)
                    end
                end
            end
            out, n = read(container)
            return wrong(out, n, kept)
        end)
    end
    dfhack.with_finalize(
        function()
            for _, entry in ipairs(made) do entry:delete() end
            for _, job in ipairs(jobs) do
                job.job_items.elements:resize(0)
                job:delete()
            end
        end,
        function()
            for number = only or 1, only or rounds do one_round(number) end
        end)
    return failures
end

-- The same for grids read side by side, each with a rectangle of its own.
local function random_grid_reads(seed, rounds, only)
    local rnd, reseed = random_source()
    local function pick(list) return list[rnd(#list)] end
    reseed(seed)
    local tiles = {df.tiletype.Void, df.tiletype.StoneFloor1, df.tiletype.StoneWall, df.tiletype.OpenSpace,
                   df.tiletype.MurkyPool, df.tiletype.SoilFloor1}
    local temperatures = {0, 1, 10000, 10050, 65535}
    local blocks = {}
    for i = 1, 3 do
        blocks[i] = df.map_block:new()
        for x = 0, 15 do
            for y = 0, 15 do
                blocks[i].tiletype[x][y] = pick(tiles)
                blocks[i].temperature_1[x][y] = pick(temperatures)
                -- every bit of the 32, so that a flag read from the wrong place shows
                blocks[i].designation[x][y].whole = (rnd(65536) - 1) << 16 | (rnd(65536) - 1)
            end
        end
    end
    local function designation(name)
        return {'des.' .. name, function(b, x, y) return b.designation[x][y][name] end}
    end
    local leaves = {
        {'tt', function(b, x, y) return b.tiletype[x][y] end},
        {'tt.shape', function(b, x, y) return df.tiletype.attrs[b.tiletype[x][y]].shape end},
        {'tt.material', function(b, x, y) return df.tiletype.attrs[b.tiletype[x][y]].material end},
        {'temp', function(b, x, y) return b.temperature_1[x][y] end},
        {'des', function(b, x, y) return b.designation[x][y].whole end},
        designation('flow_size'), designation('pile'), designation('dig'), designation('smooth'),
        designation('hidden'), designation('geolayer_index'), designation('light'), designation('biome'),
        designation('liquid_type'), designation('traffic'), designation('feature_local'),
        {'_index', function(_, x, y) return x * 16 + y end},
    }
    local compare = {
        ['=='] = function(a, b) return a == b end,
        ['~='] = function(a, b) return a ~= b end,
        ['<'] = function(a, b) return a < b end,
        ['<='] = function(a, b) return a <= b end,
        ['>'] = function(a, b) return a > b end,
        ['>='] = function(a, b) return a >= b end,
    }
    local failures = 0
    local function one_round(number)
        reseed(seed * 100003 + number)
        local container, cells, notes = {}, {}, {}
        for from = 1, rnd(3) do
            local which = rnd(3)
            local block = blocks[which]
            local item = {tt=block.tiletype, temp=block.temperature_1, des=block.designation}
            local form = rnd(4)
            local x1, x2, y1, y2 = 0, 15, 0, 15
            local function bounds()
                local first = rnd(22) - 4
                if rnd(4) == 1 then return first, rnd(22) - 4 end
                return first, first + rnd(12) - 1
            end
            if form >= 2 then
                item._range = {bounds()}
                x1, x2 = math.max(item._range[1], 0), math.min(item._range[2], 15)
            end
            if form >= 3 then
                item._range[3], item._range[4] = bounds()
                y1, y2 = math.max(item._range[3], 0), math.min(item._range[4], 15)
            end
            container[from] = item
            notes[from] = ('block %d%s'):format(which, item._range and describe(item._range) or '')
            for x = x1, x2 do
                for y = y1, y2 do cells[#cells + 1] = {block, x, y, from} end
            end
        end
        if #container == 1 and rnd(2) == 1 then container = container[1] end

        local options, columns, checks = {fields={'_from'}}, {}, {}
        for i = 1, rnd(4) do
            local leaf = pick(leaves)
            options.fields[i + 1] = {path=leaf[1], as='column' .. i}
            columns[i] = {'column' .. i, leaf[2]}
        end
        if rnd(3) > 1 then
            options.where = {}
            for i = 1, rnd(2) do
                local leaf = pick(leaves)
                -- compared with what one of the cells holds, so that some pass
                local op = pick{'==', '~=', '<', '<=', '>', '>='}
                local value = leaf[2](pick(blocks), rnd(16) - 1, rnd(16) - 1)
                if type(value) == 'boolean' and op ~= '~=' then op = '==' end
                options.where[i] = {leaf[1], op, value}
                checks[i] = function(b, x, y) return compare[op](leaf[2](b, x, y), value) end
            end
        end
        if rnd(4) == 1 then options.limit = rnd(40) end

        local kept = {}
        for _, cell in ipairs(cells) do
            local passes = true
            for _, check in ipairs(checks) do passes = passes and check(cell[1], cell[2], cell[3]) end
            if passes then kept[#kept + 1] = cell end
            if #kept == options.limit then break end
        end

        local function check(how, read)
            local ok, problem = pcall(function()
                local out, n = read()
                if n ~= #kept then return ('%s entries, %d expected'):format(tostring(n), #kept) end
                for i, cell in ipairs(kept) do
                    if out._from[i] ~= cell[4] then return ('_from[%d] is %s'):format(i, tostring(out._from[i])) end
                    for _, column in ipairs(columns) do
                        local got, want = out[column[1]][i], column[2](cell[1], cell[2], cell[3])
                        if not same(got, want) then
                            return ('%s[%d] is %s, %s expected'):format(column[1], i, tostring(got), tostring(want))
                        end
                    end
                end
            end)
            if not ok then problem = tostring(problem) end
            if problem then
                failures = failures + 1
                if failures <= 5 then
                    expect.fail(('grids, %s: %s (seed %d round %d: %s, %s)'):format(
                        how, problem, seed, number, table.concat(notes, ', '), describe(options)))
                end
            end
        end
        check('read_fields', function() return df.read_fields(container, options) end)
        check('prepared', function()
            local read = df.prepare_read_fields(container, options)
            local out = {}
            read(container, out)
            return read(container, out)
        end)
    end
    dfhack.with_finalize(
        function()
            for _, block in ipairs(blocks) do block:delete() end
        end,
        function()
            for number = only or 1, only or rounds do one_round(number) end
        end)
    return failures
end

function test.random_reads_match_plain_lua()
    for seed = 1, 4 do
        expect.eq(random_reads(seed, 250), 0, 'seed ' .. seed)
        expect.eq(random_grid_reads(seed, 100), 0, 'grids, seed ' .. seed)
    end
end

function test.a_name_shared_with_a_parent_is_the_field_of_the_parent()
    -- widget has a set of flags called flag, and so do two classes derived from it, with
    -- other flags or a number. In Lua the plain name is the one of widget
    expect.eq(df.widget_text._fields.flag.type, df.widget_flag)
    expect.eq(df.widget_text._fields['widget_text.flag'].type_name, 'uint32_t')
    df.prepare_read_fields(df.widget_text, {fields={'flag.VISIBILITY_ACTIVE', 'widget_text.flag'},
                                            where={{'widget_text.flag', '>=', 1}}})
    df.prepare_read_fields(df.widget_nineslice_horizontal,
                           {fields={'flag.VISIBILITY_ACTIVE', 'widget_nineslice.flag.OVERRIDE_CHAR'}})
    expect.error_match("no flag 'OVERRIDE_CHAR' in 'flag.OVERRIDE_CHAR'", function()
        df.prepare_read_fields(df.widget_nineslice, {fields={'flag.OVERRIDE_CHAR'}})
    end)
    -- Class.field is only the name of a field that needed one
    expect.error_match("no field 'widget_text' in widget_text", function()
        df.prepare_read_fields(df.widget_text, {fields={'widget_text.str'}})
    end)
    expect.error_match("no field 'widget' in widget_text", function()
        df.prepare_read_fields(df.widget_text, {fields={'widget.flag'}})
    end)
end

function test.every_field_of_every_type_is_taken_or_refused()
    -- a read is set up for each field of each type that there is, which takes the field or
    -- refuses it for one of the reasons below
    local reasons = {
        "cannot follow the pointer '?' in '?'",
        "'?' in '?' is not something that can be read",
        "'?' is not something that can be read",
        "cannot read '?' in '?'",
        "'?' in '?' is a method, which a path cannot call",
    }
    local known = {}
    for _, reason in ipairs(reasons) do known[reason] = true end
    local taken, unknown = 0, {}
    for name, type in pairs(df) do
        if df.isvalid(type) == 'type' and (type._kind == 'struct-type' or type._kind == 'class-type') then
            for field in pairs(type._fields) do
                local ok, err = pcall(df.prepare_read_fields, type, {fields={field}})
                if ok then
                    taken = taken + 1
                else
                    local reason = tostring(err):gsub('^.*df%.read_fields: ', ''):gsub("'[^']*'", "'?'")
                    if not known[reason] and not unknown[reason] then
                        unknown[reason] = name .. '.' .. field
                    end
                end
            end
        end
    end
    expect.gt(taken, 10000)
    for reason, where in pairs(unknown) do
        expect.fail(('%s: %s'):format(where, reason))
    end
end

function test.flags_in_a_vector_of_flags()
    local info = df.burrow_infost:new()
    dfhack.with_finalize(
        function() info:delete() end,
        function()
            local v = info.sel_units
            v:resize(3)
            v[0] = true
            v[2] = true
            local out = df.read_fields({info}, {fields={'sel_units.0', 'sel_units.1', 'sel_units.2', 'sel_units.3',
                                                        'sel_units.70'}})
            expect.eq(out['sel_units.0'][1], true)
            expect.eq(out['sel_units.1'][1], false)
            expect.eq(out['sel_units.2'][1], true)
            expect.eq(out['sel_units.3'][1], nil)
            expect.eq(out['sel_units.70'][1], nil)
            expect.error_match('no flag', function() df.read_fields({info}, {fields={'sel_units.-1'}}) end)
            expect.eq(select(2, df.read_fields({info}, {where={{'sel_units.2', '==', true}}})), 1)
            expect.eq(select(2, df.read_fields({info}, {where={{'sel_units.1', '==', true}}})), 0)
            expect.error_match('not a container it can read', function() df.read_fields(v, {fields={'_index'}}) end)
        end)
end
