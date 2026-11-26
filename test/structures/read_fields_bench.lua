config.target = 'core'

-- Not a test of behaviour: times three ways of reading the same data and prints the result.
local N = 200000

local function best(fn)
    local t = math.huge
    local result
    for _ = 1, 7 do
        local t0 = os.clock()
        result = fn()
        t = math.min(t, os.clock() - t0)
    end
    return t * 1000, result
end

local function report(name, rows)
    for _, row in ipairs(rows) do
        local line = ('READBENCH %-28s %-22s %8.3f ms  result=%s'):format(name, row[1], row[2], tostring(row[3]))
        print(line)
        dfhack.printerr(line)
    end
end

function test.bench()
    local path = df.coord_path:new()
    dfhack.with_finalize(function() path:delete() end, function()
        path.x:resize(N) path.y:resize(N)
        for i = 0, N - 1 do
            path.x[i] = i % 100
            path.y[i] = i % 7
        end
        local px, py = path.x, path.y
        local src = {x=px, y=py}
        local out = {}

        -- 1. every entry is wanted
        local rows = {}
        rows[1] = {'lua loop', best(function()
            local s = 0
            for i = 0, N - 1 do s = s + px[i] + py[i] end
            return s
        end)}
        rows[2] = {'arrays', best(function()
            local o, n = df.readFields(src, {fields={'x', 'y'}}, out)
            local xs, ys, s = o.x, o.y, 0
            for i = 1, n do s = s + xs[i] + ys[i] end
            return s
        end)}
        rows[3] = {'each', best(function()
            local s = 0
            df.readFields(src, {fields={'x', 'y'}, each=function(x, y) s = s + x + y end})
            return s
        end)}
        report('all of 200000', rows)

        -- 2. one entry in a hundred is wanted
        rows = {}
        rows[1] = {'lua loop', best(function()
            local s = 0
            for i = 0, N - 1 do if px[i] == 42 then s = s + py[i] end end
            return s
        end)}
        rows[2] = {'arrays', best(function()
            local o, n = df.readFields(src, {fields={'y'}, where={{'x', '==', 42}}}, out)
            local ys, s = o.y, 0
            for i = 1, n do s = s + ys[i] end
            return s
        end)}
        rows[3] = {'each', best(function()
            local s = 0
            df.readFields(src, {fields={'y'}, where={{'x', '==', 42}}, each=function(y) s = s + y end})
            return s
        end)}
        report('1 in 100 of 200000', rows)

        -- 3. Lua decides which entry ends the search (here: the 50th match, a tenth of the way in at most)
        rows = {}
        rows[1] = {'lua loop', best(function()
            local c = 0
            for i = 0, N - 1 do
                if px[i] == 42 then c = c + 1 if c == 50 then return i end end
            end
        end)}
        rows[2] = {'arrays, then stop', best(function()
            local o, n = df.readFields(src, {fields={'_index'}, where={{'x', '==', 42}}}, out)
            return o._index[50]
        end)}
        rows[3] = {'each, return false', best(function()
            local c, at = 0
            df.readFields(src, {fields={'_index'}, where={{'x', '==', 42}}, each=function(i)
                c = c + 1
                if c == 50 then at = i return false end
            end})
            return at
        end)}
        report('stop at 50th match', rows)

        -- 4. the first match only, where limit does the same without a function
        rows = {}
        rows[1] = {'arrays, limit=1', best(function()
            local o = df.readFields(src, {fields={'_index'}, where={{'x', '==', 99}}, limit=1}, out)
            return o._index[1]
        end)}
        rows[2] = {'each, return false', best(function()
            local at
            df.readFields(src, {fields={'_index'}, where={{'x', '==', 99}}, each=function(i) at = i return false end})
            return at
        end)}
        report('first match', rows)
        expect.true_(true)
    end)
end
