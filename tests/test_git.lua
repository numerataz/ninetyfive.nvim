local Helpers = dofile("tests/helpers.lua")

local child = Helpers.new_child_neovim()

local T = MiniTest.new_set({
    hooks = {
        pre_case = function()
            child.restart({ "-u", "scripts/minimal_init.lua" })
        end,
        post_once = child.stop,
    },
})

T["git output isn't dropped when the process exits before stdout is read"] = function()
    -- Thousands of concurrent `sh` spawns are too slow on Windows runners.
    if child.lua_get("vim.fn.has('win32')") == 1 then
        MiniTest.skip("too slow on Windows")
    end
    local missing = child.lua_get([[(function()
        local git = require("ninetyfive.git")
        vim.cmd.edit(vim.fn.getcwd() .. "/README.md")
        local missing, done, total = 0, 0, 2000
        for _ = 1, total do
            git.get_repo_root(function(root)
                if not root then
                    missing = missing + 1
                end
                done = done + 1
            end)
        end
        vim.wait(30000, function()
            return done == total
        end)
        return missing
    end)()]])
    MiniTest.expect.equality(missing, 0)
end

return T
