local log = require("ninetyfive.util.log")
local websocket = require("ninetyfive.websocket")
local sse = require("ninetyfive.sse")
local Completion = require("ninetyfive.completion")
local git = require("ninetyfive.git")
local util = require("ninetyfive.util")
local delta = require("ninetyfive.delta")

local Communication = {}
Communication.__index = Communication

local active_bufnr = nil
local active_content = nil

local function repo_name_from_path(path)
    if not path or path == "" then
        return nil
    end

    local trimmed = path:gsub("[/\\]+$", "")
    return trimmed:match("([^/\\]+)$")
end

local function buffer_content(bufnr)
    if not bufnr or bufnr == 0 or not vim.api.nvim_buf_is_valid(bufnr) then
        return ""
    end
    return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
end

-- Make path relative to cwd if it's a prefix
local function relative_path(path)
    if not path or path == "" then
        return path
    end
    local cwd = vim.fn.getcwd()
    if path:sub(1, #cwd) == cwd then
        return path:sub(#cwd + 2) -- +2 to skip trailing slash
    end
    return path
end

local function content_to_cursor(bufnr, cursor)
    cursor = cursor or vim.api.nvim_win_get_cursor(0)
    local line = math.max((cursor[1] or 1) - 1, 0)
    local col = cursor[2] or 0

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, line + 1, false)
    if #lines > 0 then
        lines[#lines] = string.sub(lines[#lines], 1, col)
    end

    return table.concat(lines, "\n")
end

function Communication.new(opts)
    local instance = setmetatable({}, Communication)
    instance.mode = nil
    instance.last_error = nil
    instance.preferred = "websocket"
    instance.allow_fallback = true
    instance:configure(opts or {})
    return instance
end

function Communication:configure(opts)
    opts = opts or {}
    self.server_uri = opts.server_uri or self.server_uri
    self.user_id = opts.user_id or self.user_id
    self.api_key = opts.api_key or self.api_key
    self.preferred = opts.preferred or self.preferred or "websocket"
    if opts.allow_fallback ~= nil then
        self.allow_fallback = opts.allow_fallback
    elseif self.allow_fallback == nil then
        self.allow_fallback = true
    end
    return self
end

function Communication:connect()
    if not self.server_uri then
        return false, "missing_server_uri"
    end

    local preferred = self.preferred or "websocket"
    local order
    if self.allow_fallback == false then
        order = { preferred }
    elseif preferred == "sse" then
        order = { "sse", "websocket" }
    else
        order = { "websocket", "sse" }
    end

    for _, target in ipairs(order) do
        if target == "websocket" then
            local ok, err = websocket.setup_connection(self.server_uri, self.user_id, self.api_key)
            if ok then
                self.mode = "websocket"
                self.last_error = nil
                return true, self.mode
            end
            self.last_error = err or "websocket_failed"
        else
            local ok = sse.setup({
                server_uri = self.server_uri,
                user_id = self.user_id,
                api_key = self.api_key,
            })
            if ok then
                self.mode = "sse"
                self.last_error = nil
                return true, self.mode
            end
            self.last_error = "sse_failed"
        end
    end

    return false, self.last_error
end

function Communication:shutdown()
    websocket.shutdown()
    sse.shutdown()
    self.mode = nil
end

function Communication:current_mode()
    return self.mode
end

function Communication:is_websocket()
    return self.mode == "websocket"
end

function Communication:is_sse()
    return self.mode == "sse"
end

function Communication:_git_metadata(bufnr, callback)
    local pending = 2
    local result = { bufnr = bufnr }

    local function maybe_complete()
        pending = pending - 1
        if pending > 0 then
            return
        end

        local repo = repo_name_from_path(result.git_root)
        result.repo = repo or "unknown"
        callback(result)
    end

    git.get_head(function(head)
        result.head = head
        maybe_complete()
    end)

    git.get_repo_root(function(root)
        result.git_root = root
        maybe_complete()
    end)
end

function Communication:_send_workspace(payload)
    local ok, message = pcall(vim.json.encode, payload)
    if not ok then
        log.debug("comm", "failed to encode set-workspace payload: %s", tostring(message))
        return
    end

    vim.schedule(function()
        -- Check connection is still valid before sending
        if not websocket.is_connected() then
            log.debug("comm", "skipping set-workspace - websocket not connected")
            return
        end
        if not websocket.send_message(message) then
            log.debug("comm", "failed to send set-workspace message")
        end
    end)
end

function Communication:_sync_buffer_state(bufnr)
    if vim.in_fast_event() then
        vim.schedule(function()
            self:_sync_buffer_state(bufnr)
        end)
        return
    end

    bufnr = bufnr or vim.api.nvim_get_current_buf()
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return
    end

    local curr_text = buffer_content(bufnr)
    local completion = Completion.get()
    if completion and completion.active_text ~= curr_text then
        completion.active_text = curr_text
        self:send_file_content({ bufnr = bufnr })
        Completion.clear()
    end
end

function Communication:set_workspace(opts)
    if not self:is_websocket() then
        return false, "websocket_only"
    end

    opts = opts or {}
    local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()

    self:_git_metadata(bufnr, function(meta)
        local head = meta.head
        if head and head.hash and head.hash ~= "" then
            self:_send_workspace({
                type = "set-workspace",
                commitHash = head.hash,
                path = meta.git_root,
                name = string.format("%s/%s", meta.repo, head.branch or "unknown"),
                features = { "edits" },
            })
        else
            self:_send_workspace({
                type = "set-workspace",
                features = { "edits" },
            })
            self:_sync_buffer_state(meta.bufnr)
        end
    end)

    return true
end

function Communication:send_file_content(opts)
    if not self:is_websocket() then
        return false, "websocket_only"
    end

    opts = opts or {}
    local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return false, "invalid_buffer"
    end

    local bufname = vim.api.nvim_buf_get_name(bufnr)
    local is_unnamed = not bufname or bufname == ""

    git.is_ignored(bufname, function(ignored)
        if ignored and not is_unnamed then
            log.debug("comm", "skipping file-content; git ignored: %s", bufname)
            return
        end

        git.get_repo_root(function(git_root)
            vim.schedule(function()
                local path
                if is_unnamed then
                    path = string.format("Untitled-%d", bufnr)
                elseif git_root and bufname:sub(1, #git_root) == git_root then
                    -- Make path relative to git root
                    path = bufname:sub(#git_root + 2) -- +2 to skip the trailing slash
                else
                    path = bufname
                end

                local content = buffer_content(bufnr)
                local payload = {
                    type = "file-content",
                    path = path,
                    text = content,
                }

                local ok, message = pcall(vim.json.encode, payload)
                if not ok then
                    log.debug(
                        "comm",
                        "failed to encode file-content payload: %s",
                        tostring(message)
                    )
                    return
                end

                log.debug(
                    "comm",
                    "-> [file-content] path=%s, len=%d, text=%q",
                    path,
                    #content,
                    content
                )

                if not websocket.send_message(message) then
                    log.debug("comm", "failed to send file-content for %s", bufname)
                else
                    active_bufnr = bufnr
                    active_content = content
                end
            end)
        end)
    end)

    return true
end

-- Send incremental file delta instead of full content (synchronous)
function Communication:send_file_delta(opts)
    if not self:is_websocket() then
        return false, "websocket_only"
    end

    opts = opts or {}
    local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return false, "invalid_buffer"
    end

    local new_content = buffer_content(bufnr)

    if active_bufnr ~= bufnr then
        local bufname = vim.api.nvim_buf_get_name(bufnr)
        local path = bufname ~= "" and relative_path(bufname) or string.format("Untitled-%d", bufnr)

        local payload = {
            type = "file-content",
            path = path,
            text = new_content,
        }

        local ok, message = pcall(vim.json.encode, payload)
        if not ok then
            log.debug("comm", "failed to encode file-content payload: %s", tostring(message))
            return false, "encode_error"
        end

        log.debug("comm", "-> [file-content] path=%s, len=%d", path, #new_content)

        if not websocket.send_message(message) then
            log.debug("comm", "failed to send file-content")
            return false, "send_error"
        end

        active_bufnr = bufnr
        active_content = new_content
        return true
    end

    if active_content == new_content then
        return true
    end

    local start, end_pos, insert_text = delta.compute_delta(active_content, new_content)

    local payload = {
        type = "file-delta",
        start = start,
        ["end"] = end_pos,
        text = insert_text,
    }

    local ok, message = pcall(vim.json.encode, payload)
    if not ok then
        log.debug("comm", "failed to encode file-delta payload: %s", tostring(message))
        return false, "encode_error"
    end

    log.debug("comm", "-> [file-delta] start=%d, end=%d, text=%q", start, end_pos, insert_text)

    if not websocket.send_message(message) then
        log.debug("comm", "failed to send file-delta")
        return false, "send_error"
    end

    active_content = new_content
    return true
end

function Communication:_request_websocket_completion(opts)
    opts = opts or {}

    local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return false, "invalid_buffer"
    end

    if Completion.get() ~= nil then
        return false, "completion_in_progress"
    end

    local cursor = opts.cursor or vim.api.nvim_win_get_cursor(0)
    local bufname = vim.api.nvim_buf_get_name(bufnr)

    local curr_text = buffer_content(bufnr)
    local current_prefix = util.get_cursor_prefix(bufnr, cursor)
    local content_prefix = content_to_cursor(bufnr, cursor)
    local pos = #content_prefix
    local cwd = vim.fn.getcwd()

    git.is_ignored(bufname, function(ignored)
        if ignored then
            log.debug("comm", "Skipping completion - file ignored: %s", bufname)
            return
        end

        git.get_repo_root(function(git_root)
            local repo = repo_name_from_path(git_root) or repo_name_from_path(cwd) or "unknown"
            local request_id = string.format("%d_%04d", os.time(), math.random(0, 9999))
            local payload = {
                type = "delta-completion-request",
                requestId = request_id,
                repo = repo,
                pos = pos,
            }

            local ok, message = pcall(vim.json.encode, payload)
            if not ok then
                log.debug("comm", "failed to encode completion payload: %s", tostring(message))
                return
            end

            log.debug("comm", "-> [delta-completion-request] %s %s %d", request_id, repo, pos)

            vim.schedule(function()
                -- Send file delta first to ensure server has latest content
                self:send_file_delta({ bufnr = bufnr })

                if not websocket.send_message(message) then
                    log.debug("comm", "failed to send completion request")
                    return
                end

                local current_completion = Completion.new(request_id)
                current_completion.active_text = curr_text
                current_completion.prefix = current_prefix
                current_completion.buffer = bufnr
            end)
        end)
    end)

    return true
end

function Communication:_request_sse_completion(opts)
    opts = opts or {}
    local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return false, "invalid_buffer"
    end

    sse.request_completion({ buf = bufnr })
    return true
end

function Communication:request_completion(opts)
    if self:is_websocket() then
        return self:_request_websocket_completion(opts)
    elseif self:is_sse() then
        return self:_request_sse_completion(opts)
    end
    return false, "not_connected"
end

-- Resync file-content for all open buffers (used after reconnection)
function Communication:resync_all_buffers()
    if not self:is_websocket() then
        return
    end

    active_bufnr = nil
    active_content = nil

    local buffers = vim.api.nvim_list_bufs()
    for _, bufnr in ipairs(buffers) do
        if vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].buftype == "" then
            self:send_file_content({ bufnr = bufnr })
        end
    end
end

return Communication
