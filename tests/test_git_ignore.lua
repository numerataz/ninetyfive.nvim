local Helpers = dofile("tests/helpers.lua")

local child = Helpers.new_child_neovim()

local T = MiniTest.new_set({
    hooks = {
        pre_case = function()
            child.restart({ "-u", "scripts/minimal_init.lua" })
            child.lua([[
                _G.git = require("ninetyfive.git")
                _G.repo = vim.fn.tempname()
                vim.fn.mkdir(repo, "p")
                repo = (vim.uv or vim.loop).fs_realpath(repo)
                vim.fn.mkdir(repo .. "/sub/build", "p")
                vim.fn.system({ "git", "init", "-q", repo })
                vim.fn.writefile({ "*.log", "!keep.log", "build/" }, repo .. "/.gitignore")
                vim.fn.writefile({ "*.tmp" }, repo .. "/sub/.gitignore")
                vim.cmd.edit(repo .. "/main.lua")

                -- Asks about every path at once, so answers come back through
                -- the same process in order.
                _G.check = function(paths)
                    local results, done = {}, 0
                    for i, path in ipairs(paths) do
                        git.is_ignored(path, function(ignored)
                            results[i] = ignored
                            done = done + 1
                        end)
                    end
                    vim.wait(5000, function()
                        return done == #paths
                    end)
                    return results
                end
            ]])
        end,
        post_once = child.stop,
    },
})

local function check(paths)
    return child.lua_get("check({" .. table.concat(paths, ", ") .. "})")
end

T["matches git's own answers"] = function()
    local results = check({
        'repo .. "/main.lua"',
        'repo .. "/debug.log"',
        'repo .. "/keep.log"',
        'repo .. "/sub/a.tmp"',
        'repo .. "/a.tmp"',
        'repo .. "/sub/build/out.lua"',
        '"sub/a.tmp"',
        '"main.lua"',
    })
    MiniTest.expect.equality(results, { false, true, false, true, false, true, true, false })
end

T["unnamed buffers and paths outside the repo are not ignored"] = function()
    local results = check({ '""', '"/definitely/not/in/repo.log"', 'repo .. "/after.log"' })
    MiniTest.expect.equality(results, { false, false, true })
end

T["picks up .gitignore changes once it is saved"] = function()
    MiniTest.expect.equality(check({ 'repo .. "/notes.md"' }), { false })

    child.lua([[
        vim.cmd.edit(repo .. "/.gitignore")
        vim.api.nvim_buf_set_lines(0, -1, -1, false, { "*.md" })
        vim.cmd.write()
        vim.cmd.edit(repo .. "/main.lua")
    ]])

    MiniTest.expect.equality(check({ 'repo .. "/notes.md"' }), { true })
end

T["reuses one process across checks"] = function()
    check({ 'repo .. "/main.lua"' })
    local elapsed = child.lua_get([[(function()
        local start = vim.uv and vim.uv.hrtime() or vim.loop.hrtime()
        for _ = 1, 200 do
            check({ repo .. "/debug.log" })
        end
        return ((vim.uv and vim.uv.hrtime() or vim.loop.hrtime()) - start) / 1e6
    end)()]])
    -- 200 git spawns take well over a second; streaming through one process doesn't.
    MiniTest.expect.equality(elapsed < 1000, true)
end

return T
