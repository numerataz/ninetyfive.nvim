local websocket = require("ninetyfive.websocket")
local eq = MiniTest.expect.equality

-- Ensure the global table exists
_G.Ninetyfive = _G.Ninetyfive or {}

-- Using the 'busted' style ad it looks nicer imo
-- See: https://github.com/echasnovski/mini.nvim/blob/main/TESTING.md
describe("websocket", function()
    before_each(function()
        -- Make sure the global table exists before accessing its properties
        _G.Ninetyfive = _G.Ninetyfive or {}
        _G.Ninetyfive.websocket_job = nil

        -- Check if reset_completion function exists before calling it
        if websocket.reset_completion then
            websocket.reset_completion()
        end
    end)

    it("should return false when sending message without connection", function()
        -- Don't connect: websocket.setup_connection("wss://echo.websocket.org")
        local result = websocket.send_message("1")

        eq(result, false)
    end)
end)

-- Feeds the go-ws-proxy job's on_stdout handler directly. setup_connection is
-- run with jobstart stubbed so the real handler can be captured without
-- starting the proxy binary.
describe("websocket proxy stdout", function()
    local Completion = require("ninetyfive.completion")
    local suggestion = require("ninetyfive.suggestion")

    local original_show
    local original_config
    local shown
    local on_stdout

    local function capture_on_stdout()
        local captured
        local fn = vim.fn
        local orig_jobstart, orig_readable, orig_executable =
            fn.jobstart, fn.filereadable, fn.executable
        fn.jobstart = function(_, opts)
            captured = opts.on_stdout
            return 1
        end
        fn.filereadable = function()
            return 1
        end
        fn.executable = function()
            return 1
        end
        local ok, err = pcall(websocket.setup_connection, "ws://localhost/ws", "test-user", "")
        fn.jobstart, fn.filereadable, fn.executable = orig_jobstart, orig_readable, orig_executable
        assert(ok, err)
        _G.Ninetyfive.websocket_job = nil
        return captured
    end

    local function msg(tbl)
        return vim.json.encode(tbl)
    end

    before_each(function()
        _G.Ninetyfive = _G.Ninetyfive or {}
        original_config = _G.Ninetyfive.config
        _G.Ninetyfive.config = { debug = false, indexing = { mode = "off" } }

        shown = {}
        original_show = suggestion.show
        suggestion.show = function(completion)
            table.insert(shown, vim.deepcopy(completion))
        end

        Completion.clear()
        on_stdout = capture_on_stdout()
    end)

    after_each(function()
        suggestion.show = original_show
        Completion.clear()
        _G.Ninetyfive.config = original_config
        _G.Ninetyfive.websocket_job = nil
    end)

    it("reassembles a JSON message split across two callbacks", function()
        local c = Completion.new("req-1")
        local line = msg({ r = "req-1", v = "hello" })
        local cut = math.floor(#line / 2)

        on_stdout(1, { line:sub(1, cut) }, "stdout")
        eq(c.completion, {})

        on_stdout(1, { line:sub(cut + 1), "" }, "stdout")
        eq(c.completion, { "hello" })
        eq(c.is_active, true)
        eq(#shown, 1)
    end)

    it("skips a stale-request message without dropping the rest of the batch", function()
        local c = Completion.new("req-new")

        on_stdout(1, {
            msg({ r = "req-old", v = "stale" }),
            msg({ r = "req-new", v = "fresh" }),
            msg({ r = "req-new", flush = true }),
            msg({ r = "req-old", ["end"] = true }),
            msg({ r = "req-new", v = "more" }),
            msg({ r = "req-new", ["end"] = true }),
            "",
        }, "stdout")

        eq(c.completion, { "fresh", vim.NIL, "more", vim.NIL })
        eq(c.is_active, false)
    end)

    it("holds a trailing partial line until a later callback completes it", function()
        local c = Completion.new("req-1")
        local first = msg({ r = "req-1", v = "a" })
        local last = msg({ r = "req-1", ["end"] = true })
        local cut = 5

        -- First message is complete; the end marker is cut off mid-line.
        on_stdout(1, { first, last:sub(1, cut) }, "stdout")
        eq(c.completion, { "a" })
        eq(c.is_active, true)

        -- The next chunk finishes the end marker and starts another partial line.
        local extra = msg({ r = "req-1", v = "b" })
        on_stdout(1, { last:sub(cut + 1), extra:sub(1, 3) }, "stdout")
        eq(c.completion, { "a", vim.NIL })
        eq(c.is_active, false)

        on_stdout(1, { extra:sub(4), "" }, "stdout")
        eq(c.completion, { "a", vim.NIL, "b" })
    end)

    it("processes an unterminated last line at EOF", function()
        local c = Completion.new("req-1")
        on_stdout(1, { msg({ r = "req-1", v = "tail" }) }, "stdout")
        eq(c.completion, {})
        on_stdout(1, { "" }, "stdout")
        eq(c.completion, { "tail" })
    end)

    describe("git requests", function()
        local git = require("ninetyfive.git")
        local original_get_commit, original_get_blob, original_send
        local sent

        before_each(function()
            original_get_commit, original_get_blob = git.get_commit, git.get_blob
            original_send = websocket.send_message
            sent = {}
            websocket.send_message = function(message)
                table.insert(sent, vim.json.decode(message))
                return true
            end
            -- Like the real functions, these only report through the (optional) callback.
            git.get_commit = function(hash, callback)
                vim.schedule(function()
                    if callback then
                        callback({ parents = { "p1" }, message = "msg " .. hash, files = {} })
                    end
                end)
            end
            git.get_blob = function(_, _, callback)
                vim.schedule(function()
                    if callback then
                        callback({ blob = "YmxvYg==", diff = "" })
                    end
                end)
            end
        end)

        after_each(function()
            git.get_commit, git.get_blob = original_get_commit, original_get_blob
            websocket.send_message = original_send
        end)

        it("replies to get-commit once git reports the commit", function()
            on_stdout(1, { msg({ type = "get-commit", commitHash = "abc" }), "" }, "stdout")
            vim.wait(1000, function()
                return #sent > 0
            end)
            eq(sent, {
                {
                    type = "commit",
                    commitHash = "abc",
                    commit = { parents = { "p1" }, message = "msg abc", files = {} },
                },
            })
        end)

        it("replies to get-blob once git reports the blob", function()
            on_stdout(1, {
                msg({ type = "get-blob", commitHash = "abc", objectHash = "def", path = "a.lua" }),
                "",
            }, "stdout")
            vim.wait(1000, function()
                return #sent > 0
            end)
            eq(sent, {
                {
                    type = "blob",
                    commitHash = "abc",
                    objectHash = "def",
                    path = "a.lua",
                    blobBytes = "YmxvYg==",
                    diffBytes = "",
                },
            })
        end)
    end)
end)
