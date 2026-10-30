local log = require("ninetyfive.util.log")
local suggestion = require("ninetyfive.suggestion")
local Completion = require("ninetyfive.completion")
local git = require("ninetyfive.git")
local ignored_filetypes = require("ninetyfive.ignored_filetypes")
local global_state = require("ninetyfive.state")
local util = require("ninetyfive.util")
local LineBuffer = require("ninetyfive.util.line_buffer")

local Sse = {}

local state = {
    server_uri = nil,
    sse_uri = nil,
    user_id = nil,
    api_key = nil,
    current_job = nil,
}

local path_sep = package.config:sub(1, 1)

local function build_relative_path(bufname, git_root)
    if not bufname or bufname == "" then
        return ""
    end

    local escaped_sep = vim.pesc(path_sep)

    if git_root and git_root ~= "" and bufname:sub(1, #git_root) == git_root then
        local rel = bufname:sub(#git_root + 1)
        rel = rel:gsub("^" .. escaped_sep, "")
        if rel ~= "" then
            return rel
        end
    end

    local cwd = vim.fn.getcwd()
    if cwd and cwd ~= "" and bufname:sub(1, #cwd) == cwd then
        local rel = bufname:sub(#cwd + 1)
        rel = rel:gsub("^" .. escaped_sep, "")
        if rel ~= "" then
            return rel
        end
    end

    local tail = vim.fn.fnamemodify(bufname, ":t")
    if tail and tail ~= "" then
        return tail
    end

    return bufname
end

function Sse.is_enabled()
    return state.sse_uri ~= nil
end

local function handle_message(parsed)
    if not parsed or type(parsed) ~= "table" then
        return
    end

    if parsed.error then
        log.notify("sse", vim.log.levels.ERROR, true, tostring(parsed.error))
        return
    end

    local current_completion = Completion.get()
    if not current_completion then
        return
    end

    if parsed.id and parsed.id ~= current_completion.request_id then
        return
    end

    if parsed.content ~= nil and parsed.content ~= vim.NIL then
        table.insert(current_completion.completion, parsed.content)
        current_completion.is_active = true
    end

    if parsed.flush == true or parsed["end"] == true then
        table.insert(current_completion.completion, vim.NIL)
        if parsed["end"] == true then
            current_completion.is_active = false
        end
    end

    suggestion.show(current_completion.completion)
end

local function start_request(payload)
    local ok, encoded = pcall(vim.json.encode, payload)
    if not ok then
        log.notify(
            "sse",
            vim.log.levels.ERROR,
            true,
            "failed to encode SSE payload: " .. tostring(encoded)
        )
        return false
    end

    if state.current_job and state.current_job > 0 then
        vim.fn.jobstop(state.current_job)
        state.current_job = nil
    end

    local body = encoded
    local use_gzip = false

    local function try_gzip()
        if vim.fn.executable("gzip") ~= 1 then
            log.debug("sse", "gzip executable not found; sending plain payload")
            return
        end

        if not vim.system then
            log.debug("sse", "vim.system unavailable; sending plain payload")
            return
        end

        local ok, result = pcall(function()
            return vim.system({ "gzip", "-c" }, { stdin = encoded, text = false }):wait()
        end)

        if not ok or not result or result.code ~= 0 or not result.stdout then
            local err_msg = (not ok and tostring(result))
                or (result and result.stderr)
                or "unknown gzip error"
            log.debug("sse", "gzip failed, falling back to plain payload: %s", err_msg)
            return
        end

        body = result.stdout
        use_gzip = true
        log.debug("sse", "gzip enabled for payload")
    end

    try_gzip()

    log.debug("sse", "payload (json): %s", encoded)

    local curl_cmd = {
        "curl",
        "-sS",
        "-N",
        "-X",
        "POST",
        state.sse_uri,
        "-H",
        "Accept: text/event-stream",
        "-H",
        "Content-Type: application/json",
    }

    if state.api_key and state.api_key ~= "" then
        table.insert(curl_cmd, "-H")
        table.insert(curl_cmd, "x-api-key: " .. state.api_key)
    end

    if use_gzip then
        table.insert(curl_cmd, "-H")
        table.insert(curl_cmd, "Content-Encoding: gzip")
    end

    table.insert(curl_cmd, "--data-binary")
    table.insert(curl_cmd, "@-")

    log.debug("sse", "payload bytes: %d (gzip=%s)", #body, tostring(use_gzip))

    local stdout_lines = LineBuffer.new()

    local job_opts = {
        on_stdout = function(_, data, _)
            for _, line in ipairs(stdout_lines(data)) do
                if type(line) ~= "string" then
                    goto continue
                end

                local trimmed = vim.trim(line)
                log.debug("sse", "curl stdout: %s", trimmed)
                if trimmed == "" then
                    goto continue
                end

                local payload_match = trimmed:match("^data:%s*(.+)$")
                if payload_match then
                    local ok_json, parsed = pcall(vim.json.decode, payload_match)
                    if ok_json then
                        handle_message(parsed)
                    else
                        log.debug("sse", "failed to decode SSE message", payload_match)
                    end
                end

                ::continue::
            end
        end,
        on_stderr = function(_, data, _)
            if not data then
                return
            end

            local message = vim.trim(table.concat(data, "\n"))
            if message ~= "" then
                log.debug("sse", "curl stderr: %s", message)
            end
        end,
        on_exit = function(_, code, _)
            state.current_job = nil
            if code ~= 0 then
                log.notify(
                    "sse",
                    vim.log.levels.WARN,
                    true,
                    "SSE request exited with code " .. tostring(code)
                )
                suggestion.clear()
                Completion.clear()
            end
        end,
        stdout_buffered = false,
        stderr_buffered = false,
        stdin = "pipe",
    }

    state.current_job = vim.fn.jobstart(curl_cmd, job_opts)

    if state.current_job <= 0 then
        log.notify("sse", vim.log.levels.ERROR, true, "failed to start curl for SSE request")
        state.current_job = nil
        return false
    end

    local ok_send, err_send = pcall(function()
        vim.fn.chansend(state.current_job, body)
        vim.fn.chanclose(state.current_job, "stdin")
    end)

    if not ok_send then
        log.notify(
            "sse",
            vim.log.levels.ERROR,
            true,
            "failed to send request body: " .. tostring(err_send)
        )
        vim.fn.jobstop(state.current_job)
        state.current_job = nil
        return false
    end

    return true
end

function Sse.request_completion(args)
    if not state.sse_uri then
        log.debug("sse", "SSE endpoint not configured")
        return
    end

    if vim.fn.executable("curl") ~= 1 then
        log.notify("sse", vim.log.levels.ERROR, true, "curl is required for SSE requests")
        return
    end

    local current_completion = Completion.get()
    if current_completion ~= nil then
        return
    end

    local bufnr = args.buf
    local bufname = vim.api.nvim_buf_get_name(bufnr)
    local is_unnamed = not bufname or bufname == ""

    git.is_ignored(bufname, function(ignored)
        if ignored and not is_unnamed then
            log.debug("sse", "skipping file-content; git ignored: %s", bufname)
            return
        end

        vim.schedule(function()
            local cursor = vim.api.nvim_win_get_cursor(0)
            local line = cursor[1] - 1
            local col = cursor[2]

            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, line + 1, false)
            if #lines > 0 then
                lines[#lines] = string.sub(lines[#lines], 1, col)
            end

            local content_to_cursor = table.concat(lines, "\n")
            local pos = #content_to_cursor

            local git_root = git.get_repo_root()
            local repo = "unknown"
            if git_root then
                local repo_match = string.match(git_root, "/([^/]+)$")
                if repo_match then
                    repo = repo_match
                end
            else
                local cwd = vim.fn.getcwd()
                local repo_match = string.match(cwd, "/([^/]+)$")
                if repo_match then
                    repo = repo_match
                end
            end

            local filepath = build_relative_path(bufname, git_root)
            local content = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")

            local request_id = tostring(os.time()) .. "_" .. tostring(math.random(1000, 9999))

            local new_completion = Completion.new(request_id)
            local curr_text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
            local current_prefix = util.get_cursor_prefix(bufnr, cursor) -- maybe just pass it? and maybe add them to the "constructor" lol
            new_completion.buffer = bufnr
            new_completion.active_text = curr_text
            new_completion.prefix = current_prefix

            local payload = {
                user_id = state.user_id,
                id = request_id,
                repo = repo,
                filepath = filepath,
                content = content,
                cursor = pos,
            }

            if not start_request(payload) then
                Completion.clear()
            end
        end)
    end)
end

function Sse.shutdown()
    if state.current_job and state.current_job > 0 then
        log.debug("sse", "Shutting down SSE request")
        vim.fn.jobstop(state.current_job)
        state.current_job = nil
    end
    suggestion.clear()
    Completion.clear()
end

function Sse.setup(opts)
    opts = opts or {}

    state.server_uri = opts.server_uri
    state.user_id = opts.user_id
    state.api_key = opts.api_key

    if not state.server_uri or state.server_uri == "" then
        log.notify("sse", vim.log.levels.ERROR, true, "Missing server URI for SSE setup")
        state.sse_uri = nil
        return false
    end

    if vim.fn.executable("curl") ~= 1 then
        log.notify("sse", vim.log.levels.ERROR, true, "curl is required for SSE fallback")
        state.sse_uri = nil
        return false
    end

    local base_url = state.server_uri:gsub("^ws://", "http://"):gsub("^wss://", "https://")
    base_url = base_url:gsub("/ws$", "")
    base_url = base_url:gsub("/+$", "")
    state.sse_uri = base_url .. "/completions"

    return true
end

return Sse
