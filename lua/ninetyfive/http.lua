local uv = vim.uv or vim.loop

local M = {
    using_libcurl = false,
    reason = nil,
}

local ok_ffi, ffi = pcall(require, "ffi")

-- Try loading libcurl via LuaJIT FFI so we can reuse TLS sessions between requests.
-- Uses curl_multi for async non-blocking I/O integrated with libuv.
-- Falls back to spawning the curl CLI if FFI/libcurl is unavailable.
local curl
local curl_state

if ok_ffi then
    local lib_names = {
        "libcurl.so.4",
        "libcurl.so",
        "libcurl.4.dylib",
        "libcurl.dylib",
        "libcurl.dll",
        "libcurl-4.dll",
        "libcurl-x64.dll",
        "curl",
    }

    pcall(
        ffi.cdef,
        [[
    typedef void CURL;
    typedef void CURLM;
    typedef void CURLSH;
    typedef int CURLcode;
    typedef int CURLMcode;
    typedef int CURLINFO;
    typedef int CURLSHcode;
    typedef int CURLSHoption;
    typedef int curl_socket_t;
    typedef size_t (*curl_write_callback)(char *ptr, size_t size, size_t nmemb, void *userdata);
    typedef int (*curl_socket_callback)(CURL *easy, curl_socket_t s, int what, void *userp, void *socketp);
    typedef int (*curl_multi_timer_callback)(CURLM *multi, long timeout_ms, void *userp);

    struct curl_slist {
        char *data;
        struct curl_slist *next;
    };

    struct CURLMsg {
        int msg;
        CURL *easy_handle;
        union {
            void *whatever;
            CURLcode result;
        } data;
    };

    CURLcode curl_global_init(long flags);
    void curl_global_cleanup(void);
    const char *curl_easy_strerror(CURLcode);

    CURL *curl_easy_init(void);
    void curl_easy_reset(CURL *curl);
    CURLcode curl_easy_setopt(CURL *curl, int option, ...);
    CURLcode curl_easy_perform(CURL *curl);
    CURLcode curl_easy_getinfo(CURL *curl, CURLINFO info, ...);
    void curl_easy_cleanup(CURL *curl);

    struct curl_slist *curl_slist_append(struct curl_slist *list, const char *data);
    void curl_slist_free_all(struct curl_slist *list);

    CURLSH *curl_share_init(void);
    CURLSHcode curl_share_setopt(CURLSH *sh, CURLSHoption option, ...);
    CURLSHcode curl_share_cleanup(CURLSH *sh);

    CURLM *curl_multi_init(void);
    CURLMcode curl_multi_cleanup(CURLM *multi);
    CURLMcode curl_multi_add_handle(CURLM *multi, CURL *easy);
    CURLMcode curl_multi_remove_handle(CURLM *multi, CURL *easy);
    CURLMcode curl_multi_setopt(CURLM *multi, int option, ...);
    CURLMcode curl_multi_socket_action(CURLM *multi, curl_socket_t s, int ev_bitmask, int *running_handles);
    CURLMcode curl_multi_assign(CURLM *multi, curl_socket_t s, void *sockp);
    struct CURLMsg *curl_multi_info_read(CURLM *multi, int *msgs_in_queue);
    ]]
    )

    local function try_load()
        for _, name in ipairs(lib_names) do
            local ok, lib = pcall(ffi.load, name)
            if ok then
                return lib
            end
        end
        return nil, "libcurl not found in search paths"
    end

    curl, M.reason = try_load()

    if curl then
        -- Constants from curl/curl.h
        local CURL_GLOBAL_DEFAULT = 3

        local CURLOPT_URL = 10002
        local CURLOPT_COPYPOSTFIELDS = 10165
        local CURLOPT_HTTPHEADER = 10023
        local CURLOPT_USERAGENT = 10018
        local CURLOPT_FOLLOWLOCATION = 52
        local CURLOPT_NOSIGNAL = 99
        local CURLOPT_TCP_KEEPALIVE = 213
        local CURLOPT_WRITEFUNCTION = 20011
        local CURLOPT_WRITEDATA = 10001
        local CURLOPT_ACCEPT_ENCODING = 10102
        local CURLOPT_SHARE = 10100
        local CURLOPT_TIMEOUT = 13
        local CURLOPT_CONNECTTIMEOUT = 78

        local CURLMOPT_SOCKETFUNCTION = 20001
        local CURLMOPT_TIMERFUNCTION = 20004

        local CURLINFO_RESPONSE_CODE = 0x200002

        local CURLSHOPT_SHARE = 1
        local CURL_LOCK_DATA_SSL_SESSION = 4

        local CURL_SOCKET_TIMEOUT = -1
        local CURL_POLL_IN = 1
        local CURL_POLL_OUT = 2
        local CURL_POLL_REMOVE = 4

        local CURLMSG_DONE = 1

        local global_inited = curl.curl_global_init(CURL_GLOBAL_DEFAULT) == 0
        if not global_inited then
            M.reason = "curl_global_init failed"
        else
            local shared_handle = curl.curl_share_init()
            if not shared_handle then
                M.reason = "failed to init curl share handle"
            else
                curl.curl_share_setopt(shared_handle, CURLSHOPT_SHARE, CURL_LOCK_DATA_SSL_SESSION)

                local multi = curl.curl_multi_init()
                if not multi then
                    M.reason = "failed to init curl multi handle"
                else
                    -- State for async operations
                    curl_state = {
                        multi = multi,
                        shared = shared_handle,
                        timer = nil,
                        sockets = {}, -- fd -> { poll }
                        requests = {}, -- easy ptr -> { callback, response_buffer, header_list, write_cb, easy }
                        running = ffi.new("int[1]"),
                    }

                    -- Timer callback from curl telling us when to call socket_action
                    local timer_cb = ffi.cast(
                        "curl_multi_timer_callback",
                        function(_, timeout_ms_cdata, _)
                            local timeout_ms = tonumber(timeout_ms_cdata)
                            if curl_state.timer then
                                curl_state.timer:stop()
                            end

                            if timeout_ms < 0 then
                                return 0
                            end

                            if not curl_state.timer then
                                curl_state.timer = uv.new_timer()
                            end

                            curl_state.timer:start(math.max(1, timeout_ms), 0, function()
                                if curl_state and curl_state.multi then
                                    curl.curl_multi_socket_action(
                                        curl_state.multi,
                                        CURL_SOCKET_TIMEOUT,
                                        0,
                                        curl_state.running
                                    )
                                    M._check_completed()
                                end
                            end)

                            return 0
                        end
                    )

                    -- Socket callback from curl for socket state changes
                    local socket_cb = ffi.cast("curl_socket_callback", function(_, s, what, _, _)
                        if not curl_state then
                            return 0
                        end

                        local fd = tonumber(s)

                        if what == CURL_POLL_REMOVE then
                            local sock_data = curl_state.sockets[fd]
                            if sock_data and sock_data.poll then
                                pcall(function()
                                    sock_data.poll:stop()
                                    if not sock_data.poll:is_closing() then
                                        sock_data.poll:close()
                                    end
                                end)
                            end
                            curl_state.sockets[fd] = nil
                            return 0
                        end

                        local sock_data = curl_state.sockets[fd]
                        if not sock_data then
                            local ok_poll, poll = pcall(uv.new_poll, fd)
                            if not ok_poll or not poll then
                                return 0
                            end
                            sock_data = { poll = poll }
                            curl_state.sockets[fd] = sock_data
                        end

                        local events = ""
                        if bit.band(what, CURL_POLL_IN) ~= 0 then
                            events = events .. "r"
                        end
                        if bit.band(what, CURL_POLL_OUT) ~= 0 then
                            events = events .. "w"
                        end

                        if events ~= "" then
                            pcall(function()
                                sock_data.poll:start(events, function(err, evts)
                                    if err or not curl_state or not curl_state.multi then
                                        return
                                    end
                                    local ev_bitmask = 0
                                    if evts and evts:find("r") then
                                        ev_bitmask = bit.bor(ev_bitmask, CURL_POLL_IN)
                                    end
                                    if evts and evts:find("w") then
                                        ev_bitmask = bit.bor(ev_bitmask, CURL_POLL_OUT)
                                    end
                                    curl.curl_multi_socket_action(
                                        curl_state.multi,
                                        s,
                                        ev_bitmask,
                                        curl_state.running
                                    )
                                    M._check_completed()
                                end)
                            end)
                        end

                        return 0
                    end)

                    curl.curl_multi_setopt(multi, CURLMOPT_TIMERFUNCTION, timer_cb)
                    curl.curl_multi_setopt(multi, CURLMOPT_SOCKETFUNCTION, socket_cb)

                    -- Keep references to prevent GC
                    curl_state.timer_cb = timer_cb
                    curl_state.socket_cb = socket_cb

                    M.using_libcurl = true
                    M.reason = nil
                end
            end
        end
    end
else
    M.reason = "LuaJIT FFI unavailable"
end

-- Clean up a completed request
local function cleanup_request(req)
    if req.header_list then
        curl.curl_slist_free_all(req.header_list)
        req.header_list = nil
    end
    if req.write_cb then
        req.write_cb:free()
        req.write_cb = nil
    end
    if req.easy then
        curl.curl_easy_cleanup(req.easy)
        req.easy = nil
    end
end

-- Check for completed transfers
function M._check_completed()
    if not curl_state then
        return
    end

    local msgs_left = ffi.new("int[1]")
    while true do
        local msg = curl.curl_multi_info_read(curl_state.multi, msgs_left)
        if msg == nil then
            break
        end

        if msg.msg == 1 then -- CURLMSG_DONE
            local easy = msg.easy_handle
            local easy_ptr = tostring(easy)
            local req = curl_state.requests[easy_ptr]

            if req then
                local status = ffi.new("long[1]")
                curl.curl_easy_getinfo(easy, 0x200002, status) -- CURLINFO_RESPONSE_CODE

                curl.curl_multi_remove_handle(curl_state.multi, easy)

                local ok = msg.data.result == 0
                local err_msg = nil
                if not ok then
                    err_msg = ffi.string(curl.curl_easy_strerror(msg.data.result))
                end

                local response_body = table.concat(req.response_buffer)
                local status_code = tonumber(status[0])
                local callback = req.callback

                -- Clean up before callback to avoid issues if callback errors
                curl_state.requests[easy_ptr] = nil
                cleanup_request(req)

                -- Call the callback
                vim.schedule(function()
                    if ok then
                        callback(true, status_code, response_body)
                    else
                        callback(false, status_code, err_msg)
                    end
                end)
            end
        end
    end
end

local function post_with_libcurl(url, headers, body, callback)
    if not curl_state then
        vim.schedule(function()
            callback(false, nil, "libcurl not initialized")
        end)
        return
    end

    local easy = curl.curl_easy_init()
    if not easy then
        vim.schedule(function()
            callback(false, nil, "failed to create curl easy handle")
        end)
        return
    end

    local response_buffer = {}

    -- Create write callback for this request
    local write_cb = ffi.cast("curl_write_callback", function(ptr, size, nmemb, _)
        local bytes = tonumber(size * nmemb)
        if bytes > 0 then
            table.insert(response_buffer, ffi.string(ptr, bytes))
        end
        return bytes
    end)

    local header_list = nil
    for _, h in ipairs(headers) do
        header_list = curl.curl_slist_append(header_list, h)
    end

    curl.curl_easy_setopt(easy, 99, 1) -- CURLOPT_NOSIGNAL
    curl.curl_easy_setopt(easy, 213, 1) -- CURLOPT_TCP_KEEPALIVE
    curl.curl_easy_setopt(easy, 52, 1) -- CURLOPT_FOLLOWLOCATION
    curl.curl_easy_setopt(easy, 10002, url) -- CURLOPT_URL
    curl.curl_easy_setopt(easy, 10018, "ninetyfive.nvim") -- CURLOPT_USERAGENT
    curl.curl_easy_setopt(easy, 10023, header_list) -- CURLOPT_HTTPHEADER
    curl.curl_easy_setopt(easy, 10102, "") -- CURLOPT_ACCEPT_ENCODING
    curl.curl_easy_setopt(easy, 10165, body) -- CURLOPT_COPYPOSTFIELDS
    curl.curl_easy_setopt(easy, 20011, write_cb) -- CURLOPT_WRITEFUNCTION
    curl.curl_easy_setopt(easy, 10001, nil) -- CURLOPT_WRITEDATA
    curl.curl_easy_setopt(easy, 10100, curl_state.shared) -- CURLOPT_SHARE
    curl.curl_easy_setopt(easy, 78, 30) -- CURLOPT_CONNECTTIMEOUT = 30s
    curl.curl_easy_setopt(easy, 13, 60) -- CURLOPT_TIMEOUT = 60s

    -- Store request state
    local easy_ptr = tostring(easy)
    curl_state.requests[easy_ptr] = {
        callback = callback,
        response_buffer = response_buffer,
        header_list = header_list,
        write_cb = write_cb,
        easy = easy,
    }

    -- Add to multi handle
    local add_result = curl.curl_multi_add_handle(curl_state.multi, easy)
    if add_result ~= 0 then
        curl_state.requests[easy_ptr] = nil
        cleanup_request({
            header_list = header_list,
            write_cb = write_cb,
            easy = easy,
        })
        vim.schedule(function()
            callback(false, nil, "failed to add handle to multi")
        end)
        return
    end

    -- Kick off the request
    curl.curl_multi_socket_action(curl_state.multi, -1, 0, curl_state.running)
    M._check_completed()
end

local function shell_post(url, headers, body, callback)
    if vim.fn.executable("curl") ~= 1 then
        vim.schedule(function()
            callback(false, nil, "curl executable not found")
        end)
        return
    end

    local args =
        { "-sS", "-X", "POST", url, "-w", "\n%{http_code}", "--connect-timeout", "30", "-m", "60" }
    for _, h in ipairs(headers) do
        table.insert(args, "-H")
        table.insert(args, h)
    end
    table.insert(args, "--data")
    table.insert(args, body)

    local function parse_response(out)
        local lines = vim.split(out, "\n")
        local status = tonumber(lines[#lines])
        if not status then
            return false, nil, "unable to parse curl http status"
        end
        table.remove(lines)
        local resp_body = table.concat(lines, "\n")
        return true, status, resp_body
    end

    -- Use vim.system if available (Neovim 0.10+), otherwise fall back to libuv spawn
    if vim.system then
        local cmd = { "curl" }
        vim.list_extend(cmd, args)
        vim.system(cmd, { text = true }, function(result)
            vim.schedule(function()
                if not result or result.code ~= 0 or not result.stdout then
                    local err = (result and result.stderr) or "curl failed"
                    callback(false, nil, err)
                    return
                end
                local ok, status, resp = parse_response(result.stdout)
                callback(ok, status, resp)
            end)
        end)
    else
        -- Fallback for older Neovim using libuv
        local stdout = uv.new_pipe(false)
        local stderr = uv.new_pipe(false)
        local out_chunks = {}
        local proc

        proc = uv.spawn("curl", {
            args = args,
            stdio = { nil, stdout, stderr },
        }, function(code)
            stdout:read_stop()
            stderr:read_stop()
            stdout:close()
            stderr:close()
            if proc then
                proc:close()
            end

            vim.schedule(function()
                if code ~= 0 then
                    callback(false, nil, "curl failed with code " .. code)
                    return
                end
                local out = table.concat(out_chunks)
                local ok, status, resp = parse_response(out)
                callback(ok, status, resp)
            end)
        end)

        if not proc then
            stdout:close()
            stderr:close()
            vim.schedule(function()
                callback(false, nil, "failed to spawn curl")
            end)
            return
        end

        stdout:read_start(function(_, data)
            if data then
                table.insert(out_chunks, data)
            end
        end)
        stderr:read_start(function() end)
    end
end

--- Async POST JSON to a URL. Calls callback(ok, status_code, body_or_error).
--- Uses libcurl with TLS session reuse when available, falls back to curl CLI.
---@param url string
---@param headers string[]
---@param body string
---@param callback fun(ok: boolean, status: number|nil, body_or_error: string|nil)
function M.post_json(url, headers, body, callback)
    if M.using_libcurl then
        post_with_libcurl(url, headers, body, callback)
    else
        shell_post(url, headers, body, callback)
    end
end

function M.libcurl_available()
    return M.using_libcurl
end

return M
