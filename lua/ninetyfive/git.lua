local uv = vim.uv or vim.loop
local git = {}
local log = require("ninetyfive.util.log")
local http = require("ninetyfive.http")

---@alias Callback fun(...)
local noop = function(...) end

---@param cb Callback|nil
---@return Callback
local function ensure_cb(cb)
    return type(cb) == "function" and cb or noop
end

local CHUNK_SIZE = 25

---@param callback Callback|nil
---@return Callback|nil
local function uv_run_async(cmd, cwd, callback)
    callback = (type(callback) == "function") and callback or function() end

    local stdout = uv.new_pipe(false)
    local stderr = uv.new_pipe(false)
    local out = {}
    local proc
    -- The exit callback can run before stdout has been drained, so only report
    -- once the process has exited and stdout has hit EOF.
    local exit_code, stdout_done

    local function finish()
        if exit_code == nil or not stdout_done then
            return
        end
        if exit_code == 0 then
            callback((table.concat(out):gsub("\n$", "")))
        else
            callback(nil)
        end
    end

    proc = uv.spawn(
        "sh",
        { args = { "-c", cmd }, cwd = cwd, stdio = { nil, stdout, stderr } },
        function(code)
            stderr:read_stop()
            stderr:close()

            if proc then
                proc:close()
            end
            exit_code = code
            finish()
        end
    )

    if not proc then
        callback(nil)
        return
    end

    stdout:read_start(function(_, data)
        if data then
            out[#out + 1] = data
            return
        end
        stdout:read_stop()
        stdout:close()
        stdout_done = true
        finish()
    end)

    stderr:read_start(function() end)
end

local function get_buffer_dir_async(cb)
    cb = ensure_cb(cb)

    local function compute()
        local name = vim.api.nvim_buf_get_name(0)
        local dir = (vim.fs and vim.fs.dirname and vim.fs.dirname(name)) or name:match("(.*)[/\\]")
        cb(dir and dir ~= "" and dir or uv.cwd())
    end

    if vim.in_fast_event() then
        vim.schedule(compute)
    else
        compute()
    end
end

git.get_repo_root = function(callback)
    callback = ensure_cb(callback)

    get_buffer_dir_async(function(buffer_dir)
        uv_run_async("git rev-parse --show-toplevel", buffer_dir, function(result)
            callback(result and result ~= "" and result or nil)
        end)
    end)
end

local function run_git_command(cmd, callback)
    callback = ensure_cb(callback)

    git.get_repo_root(function(repo_root)
        if not repo_root then
            callback(nil)
            return
        end
        uv_run_async(cmd, repo_root, function(result)
            if not result then
                callback(nil)
                return
            end
            callback(result:gsub("\n$", ""))
        end)
    end)
end

git.get_head = function(callback)
    callback = ensure_cb(callback)
    run_git_command("git rev-parse HEAD", function(hash)
        if not hash then
            callback(nil)
            return
        end
        run_git_command("git rev-parse --abbrev-ref HEAD", function(branch)
            if not branch then
                callback(nil)
                return
            end
            callback({ hash = hash, branch = branch })
        end)
    end)
end

local function parse_diff_numstat(raw)
    local diff = {}
    for line in raw:gmatch("[^\r\n]+") do
        local additions, deletions, file = line:match("^(%d+)%s+(%d+)%s+(.*)$")
        if additions and deletions and file then
            local from, to = file:match("(.*) => (.*)")
            if from and to then
                table.insert(diff, {
                    from = from,
                    to = to,
                    additions = tonumber(additions),
                    deletions = tonumber(deletions),
                })
            else
                table.insert(diff, {
                    from = file,
                    to = file,
                    additions = tonumber(additions),
                    deletions = tonumber(deletions),
                })
            end
        end
    end
    return diff
end

local function parse_ls_tree(raw)
    local ls_tree = {}

    for line in raw:gmatch("[^\r\n]+") do
        local mode, type, object, size, file = line:match("^(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(.*)$")
        if mode and type and object and size and file then
            table.insert(ls_tree, {
                mode = mode,
                type = type,
                object = object,
                size = size,
                file = file,
            })
        end
    end

    return ls_tree
end

function git.get_commit(hash, callback)
    callback = ensure_cb(callback)
    run_git_command(string.format("git show --numstat %s", hash), function(diff_stdout)
        if not diff_stdout then
            callback(nil)
            return
        end

        local diff = parse_diff_numstat(diff_stdout)

        run_git_command(
            string.format("git log -1 --pretty=format:%%P%%n%%B %s", hash),
            function(commit_info)
                if not commit_info then
                    callback(nil)
                    return
                end

                local parents, message = commit_info:match("([^\n]*)\n(.*)")
                local parent_hashes = {}
                for parent in (parents or ""):gmatch("%S+") do
                    table.insert(parent_hashes, parent)
                end

                run_git_command(
                    string.format("git ls-tree -r -l --full-tree %s", hash),
                    function(ls_tree_stdout)
                        if not ls_tree_stdout then
                            callback(nil)
                            return
                        end

                        local ls_tree = parse_ls_tree(ls_tree_stdout)
                        local files = {}
                        for _, file in ipairs(diff) do
                            if file.additions ~= nil and file.deletions ~= nil then
                                local ls_tree_file = nil

                                for _, tree_file in ipairs(ls_tree) do
                                    if tree_file.file == file.to then
                                        ls_tree_file = tree_file
                                        break
                                    end
                                end

                                if ls_tree_file then
                                    local combined_file =
                                        vim.tbl_extend("force", file, ls_tree_file)
                                    table.insert(files, combined_file)
                                end
                            end
                        end

                        callback({ parents = parent_hashes, message = message, files = files })
                    end
                )
            end
        )
    end)
end

function git.get_blob(hash, file, callback)
    callback = ensure_cb(callback)
    local blob_command = string.format("git show %s:%s", hash, file)

    run_git_command(blob_command, function(blob)
        if not blob then
            callback(nil)
            return
        end

        run_git_command(string.format("git rev-list --parents -n 1 %s", hash), function(parent_line)
            if not parent_line then
                callback(nil)
                return
            end

            local parents = vim.split(parent_line, "%s+")
            local parent = parents[2]

            local function finish(encoded_diff)
                local encoded_blob = vim.base64.encode(blob)
                callback({ blob = encoded_blob, diff = encoded_diff or "" })
            end

            if parent then
                local diff_command = string.format("git diff %s %s -- %s", parent, hash, file)
                run_git_command(diff_command, function(diff)
                    if diff then
                        finish(vim.base64.encode(diff))
                    else
                        finish("")
                    end
                end)
            else
                finish("")
            end
        end)
    end)
end

-- `git check-ignore` is asked about the current file on every edit, so instead of
-- spawning git each time, keep one `git check-ignore --stdin` process per repo
-- root and stream paths through it. git only reads ignore rules when it starts,
-- so processes (and cached repo roots) are replaced once they are older than
-- CHECK_IGNORE_MAX_AGE_MS, or when a .gitignore or .git/info/exclude is saved.
local CHECK_IGNORE_MAX_AGE_MS = 60 * 1000
local check_ignore_procs = {}
local repo_root_cache = {}

local function shell_quote(s)
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function check_ignore_once(root, file_path, callback)
    uv_run_async("git check-ignore " .. shell_quote(file_path), root, function(result)
        callback(result ~= nil and result ~= "")
    end)
end

local function retire_check_ignore(proc)
    if check_ignore_procs[proc.root] == proc then
        check_ignore_procs[proc.root] = nil
    end
    -- Closing stdin lets git answer whatever is already queued, then exit.
    if not proc.stdin:is_closing() then
        proc.stdin:close()
    end
end

local function spawn_check_ignore(root)
    local stdin = uv.new_pipe(false)
    local stdout = uv.new_pipe(false)
    local proc =
        { root = root, stdin = stdin, started = uv.now(), pending = {}, fields = {}, buf = "" }

    local handle
    handle = uv.spawn("git", {
        args = { "check-ignore", "--stdin", "-z", "--verbose", "--non-matching" },
        cwd = root,
        stdio = { stdin, stdout, nil },
    }, function()
        handle:close()
    end)

    if not handle then
        stdin:close()
        stdout:close()
        return nil
    end

    stdout:read_start(function(_, data)
        if not data then
            -- EOF or error: anything still unanswered goes through a one-shot check.
            retire_check_ignore(proc)
            stdout:read_stop()
            stdout:close()
            local pending = proc.pending
            proc.pending = {}
            for _, req in ipairs(pending) do
                check_ignore_once(root, req.path, req.callback)
            end
            return
        end

        proc.buf = proc.buf .. data
        while true do
            local nul = proc.buf:find("\0", 1, true)
            if not nul then
                break
            end
            proc.fields[#proc.fields + 1] = proc.buf:sub(1, nul - 1)
            proc.buf = proc.buf:sub(nul + 1)

            -- Each answer is <source> NUL <linenum> NUL <pattern> NUL <pathname> NUL;
            -- source is empty when no pattern matched, and a matching pattern
            -- starting with "!" means the path is explicitly not ignored.
            if #proc.fields == 4 then
                local source, pattern = proc.fields[1], proc.fields[3]
                proc.fields = {}
                local req = table.remove(proc.pending, 1)
                if req then
                    req.callback(source ~= "" and pattern:sub(1, 1) ~= "!")
                end
            end
        end
    end)

    return proc
end

local function check_ignore(root, file_path, callback)
    local proc = check_ignore_procs[root]
    if proc and uv.now() - proc.started > CHECK_IGNORE_MAX_AGE_MS then
        retire_check_ignore(proc)
        proc = nil
    end
    if not proc then
        proc = spawn_check_ignore(root)
        if not proc then
            check_ignore_once(root, file_path, callback)
            return
        end
        check_ignore_procs[root] = proc
    end

    table.insert(proc.pending, { path = file_path, callback = callback })
    if not proc.stdin:write(file_path .. "\0") then
        table.remove(proc.pending)
        retire_check_ignore(proc)
        check_ignore_once(root, file_path, callback)
    end
end

local function get_repo_root_cached(callback)
    get_buffer_dir_async(function(buffer_dir)
        local hit = repo_root_cache[buffer_dir]
        if hit and uv.now() - hit.at <= CHECK_IGNORE_MAX_AGE_MS then
            callback(hit.root or nil)
            return
        end
        uv_run_async("git rev-parse --show-toplevel", buffer_dir, function(result)
            local root = result and result ~= "" and result or nil
            repo_root_cache[buffer_dir] = { root = root or false, at = uv.now() }
            callback(root)
        end)
    end)
end

local is_windows = package.config:sub(1, 1) == "\\"

local function is_absolute(path)
    return path:sub(1, 1) == "/" or path:match("^%a:[/\\]") ~= nil
end

local function normalize_path(path)
    path = path:gsub("\\", "/")
    return is_windows and path:lower() or path
end

function git.reset_ignore_cache()
    for _, proc in pairs(check_ignore_procs) do
        retire_check_ignore(proc)
    end
    repo_root_cache = {}
end

vim.api.nvim_create_autocmd("BufWritePost", {
    pattern = { ".gitignore", "*/.git/info/exclude" },
    callback = git.reset_ignore_cache,
})

function git.is_ignored(file_path, callback)
    callback = ensure_cb(callback)

    if not file_path or file_path == "" then
        callback(false) -- allow completions for unnamed buffers
        return
    end

    get_repo_root_cached(function(root)
        if not root then
            callback(false)
            return
        end

        -- git exits on a path outside the repository, so leave those (and any
        -- path whose spelling doesn't obviously match the root) to a one-shot check.
        if is_absolute(file_path) then
            local norm_root = normalize_path(root):gsub("/$", "") .. "/"
            if normalize_path(file_path):sub(1, #norm_root) ~= norm_root then
                check_ignore_once(root, file_path, callback)
                return
            end
        end

        check_ignore(root, file_path, callback)
    end)
end

local function run_git_command_at_root(cmd, callback)
    callback = ensure_cb(callback)

    git.get_repo_root(function(repo_root)
        if not repo_root then
            callback(nil)
            return
        end
        uv_run_async(cmd, repo_root, function(res)
            callback(res and res:gsub("\n$", "") or nil)
        end)
    end)
end

local function get_commit_hashes(max_entries, callback)
    max_entries = max_entries or 100

    local function parse(output)
        if not output or output == "" then
            return {}
        end
        local commits = {}
        for line in output:gmatch("[^\r\n]+") do
            if line ~= "" then
                local hash, message = line:match("^(%w+)%s+(.+)$")
                if hash then
                    table.insert(commits, { hash = hash, message = message or "Commit message" })
                end
            end
        end
        return commits
    end

    local cmd = string.format(
        "git log --format=%%H --oneline --no-merges origin/HEAD..HEAD -%d",
        max_entries
    )

    run_git_command_at_root(cmd, function(output)
        if not output or output == "" then
            log.debug(
                "git",
                "No unpushed commits found, getting recent commits from current branch..."
            )
            local fallback =
                string.format("git log --format=%%H --oneline --no-merges -%d", max_entries)
            run_git_command_at_root(fallback, function(output2)
                callback(parse(output2))
            end)
        else
            callback(parse(output))
        end
    end)
end

function git.get_git_blobs(commit_hash, callback)
    callback = ensure_cb(callback)

    git.get_repo_root(function(repo_root)
        if not repo_root then
            callback({})
            return
        end

        git.get_commit(commit_hash, function(commit_info)
            if not commit_info then
                callback({})
                return
            end

            local files = commit_info.files or {}
            local blobs, idx = {}, 1

            local function step()
                local file_info = files[idx]

                if not file_info then
                    callback(blobs)
                    return
                end
                local file_path = file_info.to or file_info.file

                git.is_ignored(file_path, function(ignored)
                    if not ignored then
                        git.get_blob(commit_hash, file_path, function(blob_data)
                            if blob_data then
                                table.insert(blobs, {
                                    object_hash = file_info.object,
                                    commit_hash = commit_hash,
                                    path = file_path,
                                    next = blob_data.blob,
                                    diff = blob_data.diff ~= "" and blob_data.diff or nil,
                                })
                            else
                                log.debug("git", "failed to get blob for file: " .. file_path)
                            end
                            idx = idx + 1
                            step()
                        end)
                    else
                        idx = idx + 1
                        step()
                    end
                end)
            end

            step()
        end)
    end)
end

function git.get_all_commits_and_blobs(max_entries, callback)
    callback = ensure_cb(callback)
    local commits, blobs = {}, {}

    git.get_repo_root(function(root)
        if not root then
            callback({ commits = commits, blobs = blobs })
            return
        end
        log.debug("git", "fetching commit/blob info...")

        get_commit_hashes(max_entries, function(cs)
            commits = cs or {}

            if #commits == 0 then
                log.debug("git", "no commits found for current branch")
                callback({ commits = commits, blobs = blobs })
                return
            end

            local i = 1
            local function next_commit()
                local c = commits[i]
                if not c then
                    callback({ commits = commits, blobs = blobs })
                    return
                end

                git.get_git_blobs(c.hash, function(commit_blobs)
                    for _, b in ipairs(commit_blobs) do
                        table.insert(blobs, b)
                    end
                    i = i + 1
                    next_commit()
                end)
            end

            next_commit()
        end)
    end)
end

function git.send_blobs_to_endpoint(job_data, api_key, endpoint_url, callback)
    callback = ensure_cb(callback)
    local blobs = job_data.blobs
    local total_chunks = math.ceil(#blobs / CHUNK_SIZE)
    local i = 1
    local function send_next()
        if i > #blobs then
            callback(true)
            return
        end

        local chunk = {}
        local end_idx = math.min(i + CHUNK_SIZE - 1, #blobs)

        for j = i, end_idx do
            table.insert(chunk, blobs[j])
        end

        local chunk_number = math.floor((i - 1) / CHUNK_SIZE) + 1
        local chunk_blobs = {}

        for _, blob in ipairs(chunk) do
            table.insert(chunk_blobs, {
                object_hash = blob.object_hash,
                commit_hash = blob.commit_hash,
                path = blob.path,
                next = blob.next,
                diff = blob.diff or vim.NIL,
            })
        end

        local chunk_commits = {}
        for _, commit in ipairs(job_data.commits) do
            table.insert(chunk_commits, {
                hash = type(commit) == "string" and commit or commit.hash,
                message = type(commit) == "string" and "Commit message"
                    or (commit.message or "Commit message"),
            })
        end

        local payload = {
            blobs = chunk_blobs,
            commits = chunk_commits,
            branch_name = job_data.branch_name,
            repo_name = job_data.repo_name,
        }
        local json_payload = vim.json.encode(payload)
        local headers = {
            "Content-Type: application/json",
            "x-api-key: " .. api_key,
        }

        http.post_json(endpoint_url, headers, json_payload, function(ok, status, err_or_body)
            if not ok or (status and status >= 400) then
                log.debug(
                    "git",
                    "request failed for chunk %d/%d (status=%s, err=%s)",
                    chunk_number,
                    total_chunks,
                    tostring(status),
                    tostring(err_or_body)
                )
                callback(false)
                return
            end

            i = end_idx + 1
            if i <= #blobs then
                vim.defer_fn(send_next, 100)
            else
                callback(true)
            end
        end)
    end

    send_next()
end

function git.sync_repo_data(api_key, endpoint_url, branch_name, repo_name, max_entries, callback)
    callback = ensure_cb(callback)
    max_entries = max_entries or 100

    git.get_head(function(head_info)
        if not head_info then
            callback(false)
            return
        end
        branch_name = branch_name or head_info.branch
        local function proceed(resolved_repo_name)
            git.get_all_commits_and_blobs(max_entries, function(result)
                if #result.commits == 0 and #result.blobs == 0 then
                    log.debug("git", "no commits or blobs found")
                    callback(false)
                    return
                end
                local job_data = {
                    commits = result.commits,
                    blobs = result.blobs,
                    branch_name = branch_name,
                    repo_name = resolved_repo_name or "unknown",
                }
                git.send_blobs_to_endpoint(job_data, api_key, endpoint_url, function(ok)
                    callback(ok)
                end)
            end)
        end
        if not repo_name then
            git.get_repo_root(function(repo_root)
                if repo_root then
                    proceed(repo_root:match("([^/]+)$") or "unknown")
                else
                    proceed("unknown")
                end
            end)
        else
            proceed(repo_name)
        end
    end)
end

function git.sync_current_repo(api_key, endpoint_url, max_entries, callback)
    callback = ensure_cb(callback)

    git.sync_repo_data(api_key, endpoint_url, nil, nil, max_entries, callback)
end

return git
