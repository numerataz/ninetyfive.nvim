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
        -- Batches keep the number of open pipes under macOS's default fd limit.
        local missing = 0
        for _ = 1, 40 do
            local done, batch = 0, 50
            for _ = 1, batch do
                git.get_repo_root(function(root)
                    if not root then
                        missing = missing + 1
                    end
                    done = done + 1
                end)
            end
            vim.wait(10000, function()
                return done == batch
            end)
        end
        return missing
    end)()]])
    MiniTest.expect.equality(missing, 0)
end

-- get_commit/get_blob take a commit hash and path from the server, so they must
-- never reach a shell. Each case is run in the child: `marker` is a fresh temp
-- path the injected command would create. Spawns whose arguments carry the
-- injected value are counted (the plugin's autocmds spawn unrelated git calls).
local function run_git_request(call_src)
    return child.lua_get(string.format(
        [[(function()
            local git = require("ninetyfive.git")
            vim.cmd.edit(vim.fn.getcwd() .. "/README.md")
            local marker = vim.fn.tempname()
            local tainted_spawns, shell_spawns = 0, 0
            local uv = vim.uv or vim.loop
            local spawn = uv.spawn
            uv.spawn = function(file, opts, ...)
                local args = table.concat((opts and opts.args) or {}, " ")
                if args:find("touch", 1, true) then
                    tainted_spawns = tainted_spawns + 1
                    if file == "sh" then
                        shell_spawns = shell_spawns + 1
                    end
                end
                return spawn(file, opts, ...)
            end
            local done, result = false, nil
            local function cb(r)
                done, result = true, r
            end
            %s
            vim.wait(10000, function()
                return done
            end)
            -- Give any stray background command a moment to run.
            vim.wait(200)
            uv.spawn = spawn
            return {
                done = done,
                is_nil = result == nil,
                marker_created = vim.fn.filereadable(marker) == 1,
                tainted_spawns = tainted_spawns,
                shell_spawns = shell_spawns,
            }
        end)()]],
        call_src
    ))
end

-- `reaches_git`: the value is passed to git as an argv entry (but never a shell).
local function expect_rejected(res, reaches_git)
    MiniTest.expect.equality(res.done, true)
    MiniTest.expect.equality(res.is_nil, true)
    MiniTest.expect.equality(res.marker_created, false)
    MiniTest.expect.equality(res.shell_spawns, 0)
    if not reaches_git then
        MiniTest.expect.equality(res.tainted_spawns, 0)
    end
end

T["get_commit rejects a hash with $() command substitution"] = function()
    expect_rejected(run_git_request([[git.get_commit("$(touch " .. marker .. ")", cb)]]))
end

T["get_commit rejects a hash with ; command chaining"] = function()
    expect_rejected(run_git_request([[git.get_commit("abc; touch " .. marker, cb)]]))
end

T["get_commit rejects anything but a 40-hex SHA"] = function()
    for _, hash in ipairs({ "HEAD", "abc123", string.rep("g", 40), "--no-such-flag" }) do
        expect_rejected(run_git_request(string.format("git.get_commit(%q, cb)", hash)))
    end
end

T["get_blob rejects a hash with shell metacharacters"] = function()
    expect_rejected(run_git_request([[git.get_blob("abc; touch " .. marker, "README.md", cb)]]))
end

T["get_blob does not run shell metacharacters in the path"] = function()
    local paths = {
        [["x; touch " .. marker]],
        [["x$(touch " .. marker .. ")"]],
        [["x`touch " .. marker .. "`"]],
    }
    for _, path in ipairs(paths) do
        -- A valid hash, so git itself is asked and reports the path missing.
        local res = run_git_request(
            string.format(
                [[local head = vim.trim(vim.fn.system({ "git", "rev-parse", "HEAD" }))
            git.get_blob(head, %s, cb)]],
                path
            )
        )
        expect_rejected(res, true)
    end
end

T["get_commit and get_blob still return data for the real HEAD"] = function()
    local res = child.lua_get([[(function()
        local git = require("ninetyfive.git")
        vim.cmd.edit(vim.fn.getcwd() .. "/README.md")
        local head = vim.trim(vim.fn.system({ "git", "rev-parse", "HEAD" }))
        local commit, blob
        local commit_done, blob_done = false, false
        git.get_commit(head, function(c)
            commit, commit_done = c, true
        end)
        git.get_blob(head, "README.md", function(b)
            blob, blob_done = b, true
        end)
        vim.wait(10000, function()
            return commit_done and blob_done
        end)
        local expected_parents = vim.split(
            vim.trim(vim.fn.system({ "git", "rev-list", "--parents", "-n", "1", head })),
            "%s+"
        )
        table.remove(expected_parents, 1)
        -- run_git_command drops one trailing newline from git's output.
        local expected_message =
            vim.fn.system({ "git", "log", "-1", "--pretty=format:%B", head }):gsub("\n$", "")
        local readme = vim.fn.system({ "git", "show", head .. ":README.md" }):gsub("\n$", "")
        return {
            parents_match = commit ~= nil and vim.deep_equal(commit.parents, expected_parents),
            message_match = commit ~= nil and commit.message == expected_message,
            has_files = commit ~= nil and type(commit.files) == "table",
            blob_match = blob ~= nil and vim.base64.decode(blob.blob) == readme,
            diff_is_string = blob ~= nil and type(blob.diff) == "string",
        }
    end)()]])
    MiniTest.expect.equality(res, {
        parents_match = true,
        message_match = true,
        has_files = true,
        blob_match = true,
        diff_is_string = true,
    })
end

T["base64 fallback for Neovim 0.9 matches the standard encoding"] = function()
    local git = require("ninetyfive.git")
    local cases = {
        [""] = "",
        ["f"] = "Zg==",
        ["fo"] = "Zm8=",
        ["foo"] = "Zm9v",
        ["foob"] = "Zm9vYg==",
        ["fooba"] = "Zm9vYmE=",
        ["foobar"] = "Zm9vYmFy",
        ["\0\255\128\1"] = "AP+AAQ==",
    }
    for input, expected in pairs(cases) do
        MiniTest.expect.equality(git._base64_encode_fallback(input), expected)
    end
    if vim.base64 then
        local bytes = {}
        for i = 0, 1023 do
            bytes[#bytes + 1] = string.char((i * 37 + 11) % 256)
        end
        local data = table.concat(bytes)
        for len = 0, 9 do
            local chunk = data:sub(1, #data - len)
            MiniTest.expect.equality(git._base64_encode_fallback(chunk), vim.base64.encode(chunk))
        end
    end
end

return T
