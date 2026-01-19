local suggestion = {}
local ninetyfive_ns = vim.api.nvim_create_namespace("ninetyfive_ghost_ns")
local Completion = require("ninetyfive.completion")
local config = require("ninetyfive.config")
local highlighting = require("ninetyfive.highlighting")
local diff = require("ninetyfive.diff")

local completion_id = ""
local completion_extmark_ids = {} -- Track multiple extmarks for inline mode
local completion_bufnr = nil

local log = require("ninetyfive.util.log")
local lsp_util = vim.lsp.util

local function trigger_cmp_complete()
    local ok, cmp = pcall(require, "cmp")
    if ok and cmp and type(cmp.complete) == "function" then
        cmp.complete()
    end
end

-- Check if we can use inline virtual text (Neovim 0.10+)
local has_inline_virt_text = vim.fn.has("nvim-0.10") == 1

-- Highlight group for text to be deleted (red + strikethrough)
local function setup_delete_highlight()
    vim.api.nvim_set_hl(0, "NinetyFiveDelete", {
        strikethrough = true,
        fg = "#ff6666",
        bg = "#3d1f1f",
    })
end

-- Clear all extmarks in the namespace
local function clear_all_extmarks(bufnr)
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
        return
    end
    -- Clear by ID if we have them
    if completion_id ~= "" then
        pcall(vim.api.nvim_buf_del_extmark, bufnr, ninetyfive_ns, 1)
    end
    for _, id in ipairs(completion_extmark_ids) do
        pcall(vim.api.nvim_buf_del_extmark, bufnr, ninetyfive_ns, id)
    end
    completion_extmark_ids = {}
    completion_id = ""
end

-- Extract match positions and delete text from diff result
local function process_diff_result(diff_result)
    local match_positions = {}
    local delete_text = ""
    local comp_idx = 1

    for _, edit in ipairs(diff_result.edits) do
        if edit.type == "ghost" then
            comp_idx = comp_idx + #edit.text
        elseif edit.type == "match" then
            for _ = 1, #edit.text do
                match_positions[comp_idx] = true
                comp_idx = comp_idx + 1
            end
        elseif edit.type == "delete" then
            delete_text = delete_text .. edit.text
        end
    end

    return match_positions, delete_text
end

suggestion.show = function(completion)
    if vim.fn.mode() ~= "i" then
        return
    end
    local cmp_mode = config.should_use_cmp_mode()

    -- Build text up to the next flush
    local parts = {}
    local is_complete = false
    if type(completion) == "table" then
        for i = 1, #completion do
            local item = completion[i]
            if item == vim.NIL then
                is_complete = true
                break
            end
            table.insert(parts, tostring(item))
        end
    end

    local text = table.concat(parts)
    log.debug("suggestion", "show() - text: %q, is_complete: %s", text, tostring(is_complete))
    if cmp_mode then
        if is_complete then
            trigger_cmp_complete()
        end
        return
    end

    local bufnr = vim.api.nvim_get_current_buf()
    -- Clear any existing extmarks
    clear_all_extmarks(bufnr)

    local cursor_line = vim.fn.line(".") - 1
    local cursor_col = vim.fn.col(".") - 1

    -- Split completion into first line and remaining lines
    local lines = vim.split(text, "\n", { plain = true })
    local first_line_text = lines[1] or ""
    local remaining_lines = {}
    for i = 2, #lines do
        table.insert(remaining_lines, lines[i])
    end

    -- Get text after cursor to calculate padding and matches
    local current_line = vim.api.nvim_buf_get_lines(bufnr, cursor_line, cursor_line + 1, false)[1]
        or ""
    local buffer_after_cursor = current_line:sub(cursor_col + 1)

    -- Calculate diff to find matches and deletions
    local diff_result = diff.calculate_diff(first_line_text, buffer_after_cursor, is_complete)

    -- Build virtual lines for remaining lines (same for both modes)
    local virt_lines = {}
    if #remaining_lines > 0 then
        local remaining_text = table.concat(remaining_lines, "\n")
        virt_lines = highlighting.highlight_completion(remaining_text, bufnr)
    end

    if has_inline_virt_text then
        -- Neovim 0.10+: Use inline extmarks for each ghost chunk
        -- This makes matchparen and other position-based features work correctly
        for _, edit in ipairs(diff_result.edits) do
            if edit.type == "ghost" then
                local col = cursor_col + edit.offset
                local highlighted_text = highlighting.highlight_ghost_text(edit.text, bufnr)
                local extmark_id =
                    vim.api.nvim_buf_set_extmark(bufnr, ninetyfive_ns, cursor_line, col, {
                        virt_text = highlighted_text,
                        virt_text_pos = "inline",
                        hl_mode = "combine",
                    })
                table.insert(completion_extmark_ids, extmark_id)
            end
        end

        -- Handle delete text at end of line (use overlay at end)
        local _, delete_text = process_diff_result(diff_result)
        if delete_text ~= "" and is_complete then
            setup_delete_highlight()
            local end_col = #current_line
            local extmark_id =
                vim.api.nvim_buf_set_extmark(bufnr, ninetyfive_ns, cursor_line, end_col, {
                    virt_text = { { delete_text, "NinetyFiveDelete" } },
                    virt_text_pos = "overlay",
                    hl_mode = "combine",
                })
            table.insert(completion_extmark_ids, extmark_id)
        end

        -- Add virt_lines for multiline completions
        if #virt_lines > 0 then
            local extmark_id =
                vim.api.nvim_buf_set_extmark(bufnr, ninetyfive_ns, cursor_line, cursor_col, {
                    virt_lines = virt_lines,
                })
            table.insert(completion_extmark_ids, extmark_id)
        end
    else
        -- Neovim < 0.10: Use overlay mode (original approach)

        local match_positions, delete_text = process_diff_result(diff_result)

        -- Build virtual text for first line with matched portions in normal style
        local first_line_virt_text =
            highlighting.highlight_completion_with_matches(first_line_text, bufnr, match_positions)

        -- Append delete text with strikethrough if there's text to delete
        if delete_text ~= "" and is_complete then
            setup_delete_highlight()
            table.insert(first_line_virt_text, { delete_text, "NinetyFiveDelete" })
        else
            -- Pad with spaces to cover remaining buffer text (during streaming)
            local ghost_text_len = vim.fn.strdisplaywidth(first_line_text)
            local buffer_len = vim.fn.strdisplaywidth(buffer_after_cursor)
            local padding_needed = buffer_len - ghost_text_len
            if padding_needed > 0 then
                table.insert(first_line_virt_text, { string.rep(" ", padding_needed), "Normal" })
            end
        end

        -- Handle empty first line
        if #first_line_virt_text == 0 then
            first_line_virt_text = { { "", "NinetyFiveGhost" } }
        end

        local extmark_opts = {
            id = 1,
            virt_text = first_line_virt_text,
            virt_lines = virt_lines,
            virt_text_win_col = vim.fn.virtcol(".") - 1,
            hl_mode = "combine",
            ephemeral = false,
        }

        completion_id = vim.api.nvim_buf_set_extmark(
            bufnr,
            ninetyfive_ns,
            cursor_line,
            cursor_col,
            extmark_opts
        )
    end

    completion_bufnr = bufnr
    log.debug("suggestion", "show() - extmark set at line=%d, col=%d", cursor_line, cursor_col)
end

function suggestion.get_current_extmark_position(bufnr)
    bufnr = bufnr or completion_bufnr

    if not bufnr or bufnr == 0 then
        return nil
    end

    -- Check inline mode first (0.10+)
    if #completion_extmark_ids > 0 then
        local mark = vim.api.nvim_buf_get_extmark_by_id(
            bufnr,
            ninetyfive_ns,
            completion_extmark_ids[1],
            { details = false }
        )
        if mark and #mark >= 2 then
            return { row = mark[1], col = mark[2] }
        end
    end

    -- Fallback to overlay mode
    if completion_id ~= "" then
        local mark = vim.api.nvim_buf_get_extmark_by_id(
            bufnr,
            ninetyfive_ns,
            completion_id,
            { details = false }
        )
        if mark and #mark >= 2 then
            return { row = mark[1], col = mark[2] }
        end
    end

    return nil
end

local function collect_completion_text(completion)
    if type(completion) ~= "table" then
        return ""
    end

    local parts = {}
    for i = 1, #completion do
        local item = completion[i]
        if item == vim.NIL then
            break
        end
        parts[#parts + 1] = tostring(item)
    end

    return table.concat(parts)
end

local function apply_completion_text(bufnr, line, col, text)
    if text == "" then
        return false
    end

    local end_line = line
    local end_col = col
    local has_newline = string.find(text, "\n", 1, true) ~= nil

    if not has_newline then
        -- Replace from cursor to end of line
        local line_text = vim.api.nvim_buf_get_lines(bufnr, line, line + 1, false)[1] or ""
        end_col = #line_text
    end

    local offset_encoding = "utf-8"
    local start_character = lsp_util.character_offset(bufnr, line, col, offset_encoding)
    local end_character = lsp_util.character_offset(bufnr, end_line, end_col, offset_encoding)

    local ok, err = pcall(lsp_util.apply_text_edits, {
        {
            range = {
                start = { line = line, character = start_character },
                ["end"] = { line = end_line, character = end_character },
            },
            newText = text,
        },
    }, bufnr, offset_encoding)

    if not ok then
        log.error("Failed to apply suggestion: " .. tostring(err))
        vim.b[bufnr].ninetyfive_accepting = false
        return false
    end

    local lines = vim.split(text, "\n", { plain = true, trimempty = false })
    local new_line = line
    local new_col = col

    if #lines > 0 then
        if #lines > 1 then
            new_line = line + #lines - 1
            new_col = #lines[#lines]
        else
            new_col = col + #lines[1]
        end
    end

    vim.api.nvim_win_set_cursor(0, { new_line + 1, new_col })
    return true
end

local function accept_with_selector(selector)
    local current_completion = Completion.get()
    if
        current_completion == nil
        or #current_completion.completion == 0
        or current_completion.buffer ~= vim.api.nvim_get_current_buf()
    then
        return
    end

    -- Check if we have any extmarks (either inline mode or overlay mode)
    if completion_id == "" and #completion_extmark_ids == 0 then
        return
    end

    local bufnr = vim.api.nvim_get_current_buf()
    vim.b[bufnr].ninetyfive_accepting = true

    local completion_text = collect_completion_text(current_completion.completion)
    if completion_text == "" then
        vim.b[bufnr].ninetyfive_accepting = false
        return
    end

    local accepted_text = selector(completion_text)
    if not accepted_text or accepted_text == "" then
        vim.b[bufnr].ninetyfive_accepting = false
        return
    end

    clear_all_extmarks(bufnr)

    local line = vim.fn.line(".") - 1
    local col = vim.fn.col(".") - 1
    vim.b[bufnr].ninetyfive_accepting = true
    local applied = apply_completion_text(bufnr, line, col, accepted_text)
    if not applied then
        return
    end

    current_completion.last_accepted = accepted_text
end

local function select_next_word(text)
    if text == "" then
        return ""
    end

    local newline_idx = string.find(text, "\n", 1, true)
    local limit = newline_idx and (newline_idx - 1) or #text
    if limit <= 0 then
        return ""
    end

    local idx = 1
    while idx <= limit and string.match(text:sub(idx, idx), "%s") do
        idx = idx + 1
    end

    if idx > limit then
        return string.sub(text, 1, limit)
    end

    local word_end = idx
    while word_end <= limit and not string.match(text:sub(word_end, word_end), "%s") do
        word_end = word_end + 1
    end

    while word_end <= limit and string.match(text:sub(word_end, word_end), "%s") do
        word_end = word_end + 1
    end

    return string.sub(text, 1, word_end - 1)
end

local function select_line(text)
    if text == "" then
        return ""
    end

    local newline_idx = string.find(text, "\n", 1, true)
    if newline_idx then
        return string.sub(text, 1, newline_idx)
    end

    return text
end

local function select_all(text)
    return text or ""
end

suggestion.accept = function()
    accept_with_selector(select_all)
end

suggestion.accept_word = function()
    accept_with_selector(select_next_word)
end

suggestion.accept_line = function()
    accept_with_selector(select_line)
end

suggestion.clear = function()
    local buffer = vim.api.nvim_get_current_buf()
    clear_all_extmarks(buffer)
    completion_bufnr = nil
end

return suggestion
