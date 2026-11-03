local Helpers = dofile("tests/helpers.lua")
local child = Helpers.new_child_neovim()
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
    hooks = {
        pre_case = function()
            child.restart({ "-u", "scripts/minimal_init.lua" })
            child.lua([[
                _G.messages = {}
                _G.connection_id = 1
                _G.fail_send = false
                _G.send_attempts = 0
                _G.completion_created = false
                package.loaded["ninetyfive.websocket"] = {
                    get_connection_id = function() return _G.connection_id end,
                    send_message = function(message)
                        _G.send_attempts = _G.send_attempts + 1
                        if _G.fail_send then return false end
                        table.insert(_G.messages, vim.json.decode(message))
                        return true
                    end,
                }
                package.loaded["ninetyfive.git"] = {
                    is_ignored = function(_, callback) callback(false) end,
                    get_repo_root = function(callback) callback(nil) end,
                }
                package.loaded["ninetyfive.util.log"] = { debug = function() end }
                package.loaded["ninetyfive.completion"] = {
                    get = function() return nil end,
                    new = function()
                        _G.completion_created = true
                        return {}
                    end,
                }
                package.loaded["ninetyfive.communication"] = nil
                local Communication = require("ninetyfive.communication")
                _G.communication = Communication.new()
                communication.mode = "websocket"
                vim.api.nvim_buf_set_lines(0, 0, -1, false, { "before" })
            ]])
        end,
        post_once = child.stop,
    },
})

T["sends full content before deltas on the same connection"] = function()
    child.lua([[
        assert(communication:send_file_delta())
        vim.api.nvim_buf_set_lines(0, 0, -1, false, { "before!" })
        assert(communication:send_file_delta())
    ]])
    local messages = child.lua_get("messages")
    eq(messages[1].type, "file-content")
    eq(messages[2], { type = "file-delta", start = 6, ["end"] = 6, text = "!" })
end

T["resends full content immediately after reconnect before delayed resync"] = function()
    child.lua([[
        assert(communication:send_file_delta())
        _G.connection_id = 2
        vim.api.nvim_buf_set_lines(0, 0, -1, false, { "after" })
        assert(communication:send_file_delta())
    ]])
    local messages = child.lua_get("messages")
    eq(messages[2].type, "file-content")
    eq(messages[2].text, "after")
end

T["resends unchanged content on a new connection"] = function()
    child.lua([[
        assert(communication:send_file_delta())
        _G.connection_id = 2
        assert(communication:send_file_delta())
    ]])
    eq(child.lua_get("messages[2]"), child.lua_get("messages[1]"))
end

T["asynchronous full content cache belongs to its connection"] = function()
    child.lua([[
        communication:send_file_content()
        vim.wait(100, function() return #messages == 1 end)
        _G.connection_id = 2
        vim.api.nvim_buf_set_lines(0, 0, -1, false, { "after" })
        assert(communication:send_file_delta())
    ]])
    eq(child.lua_get("messages[2].type"), "file-content")
end

T["failed full content send is retried before sending deltas"] = function()
    child.lua([[
        assert(communication:send_file_delta())
        _G.connection_id = 2
        _G.fail_send = true
        assert(not communication:send_file_delta())
        _G.fail_send = false
        vim.api.nvim_buf_set_lines(0, 0, -1, false, { "after" })
        assert(communication:send_file_delta())
    ]])
    eq(child.lua_get("messages[2].type"), "file-content")
    eq(child.lua_get("#messages"), 2)
end

T["disconnected edits do not advance the content cache"] = function()
    child.lua([[
        assert(communication:send_file_delta())
        _G.connection_id = nil
        vim.api.nvim_buf_set_lines(0, 0, -1, false, { "after" })
        local ok, err = communication:send_file_delta()
        assert(not ok and err == "not_connected")
        _G.connection_id = 2
        assert(communication:send_file_delta())
    ]])
    eq(child.lua_get("messages[2].type"), "file-content")
    eq(child.lua_get("messages[2].text"), "after")
end

T["completion request stops when file sync fails"] = function()
    child.lua([[
        _G.fail_send = true
        communication:request_completion()
    ]])
    child.wait(50)
    eq(child.lua_get("#messages"), 0)
    eq(child.lua_get("completion_created"), false)
    eq(child.lua_get("send_attempts"), 1)
end

return T
