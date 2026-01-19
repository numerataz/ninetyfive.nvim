local M = {}

local highlight_cache = {}
local bg_color_cache = nil

local GHOST_OPACITY = 0.6

local function get_bg_color()
    if bg_color_cache then
        return bg_color_cache
    end
    local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = "Normal", link = false })
    bg_color_cache = (ok and hl and hl.bg) or 0x1e1e2e
    return bg_color_cache
end

local function blend_color(fg, opacity)
    local bg = get_bg_color()
    local inv = 1 - opacity

    local r = math.floor(
        (math.floor(fg / 0x10000) % 0x100) * opacity + (math.floor(bg / 0x10000) % 0x100) * inv
    )
    local g = math.floor(
        (math.floor(fg / 0x100) % 0x100) * opacity + (math.floor(bg / 0x100) % 0x100) * inv
    )
    local b = math.floor((fg % 0x100) * opacity + (bg % 0x100) * inv)

    return r * 0x10000 + g * 0x100 + b
end

local function resolve_hl_group(name)
    local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
    return ok and hl or nil
end

function M.setup()
    local comment_hl = resolve_hl_group("Comment")
    local fg = (comment_hl and comment_hl.fg) or 0x6c7086
    local ctermfg = (comment_hl and comment_hl.ctermfg) or 243

    vim.api.nvim_set_hl(0, "NinetyFiveGhost", {
        fg = blend_color(fg, GHOST_OPACITY),
        ctermfg = ctermfg,
        italic = true,
    })
end

local function ensure_setup()
    local existing = vim.api.nvim_get_hl(0, { name = "NinetyFiveGhost" })
    if not existing or (not existing.fg and not existing.ctermfg) then
        M.setup()
    end
end

local function get_ghost_highlight(hl_group)
    if not hl_group or hl_group == "" then
        ensure_setup()
        return "NinetyFiveGhost"
    end

    local safe_name = hl_group:gsub("[^%w]", "_")
    local ghost_name = "NinetyFiveGhost_" .. safe_name

    if highlight_cache[ghost_name] then
        return ghost_name
    end

    local hl = resolve_hl_group(hl_group)
    if not hl or not hl.fg then
        -- Try without language suffix (e.g., @keyword instead of @keyword.lua)
        local generic = hl_group:match("^(@[^.]+)")
        if generic and generic ~= hl_group then
            hl = resolve_hl_group(generic)
        end
    end

    if not hl or (not hl.fg and not hl.ctermfg) then
        ensure_setup()
        return "NinetyFiveGhost"
    end

    vim.api.nvim_set_hl(0, ghost_name, {
        fg = hl.fg and blend_color(hl.fg, GHOST_OPACITY) or nil,
        ctermfg = hl.ctermfg,
        italic = true,
    })
    highlight_cache[ghost_name] = true

    return ghost_name
end

-- Get a "matched" highlight (normal style, no italic/dimming) for pre-0.10 fallback
local function get_matched_highlight(hl_group)
    if not hl_group or hl_group == "" then
        return "Normal"
    end

    local safe_name = hl_group:gsub("[^%w]", "_")
    local matched_name = "NinetyFiveMatched_" .. safe_name

    if highlight_cache[matched_name] then
        return matched_name
    end

    local hl = resolve_hl_group(hl_group)
    if not hl or not hl.fg then
        local generic = hl_group:match("^(@[^.]+)")
        if generic and generic ~= hl_group then
            hl = resolve_hl_group(generic)
        end
    end

    if not hl or (not hl.fg and not hl.ctermfg) then
        return "Normal"
    end

    vim.api.nvim_set_hl(0, matched_name, {
        fg = hl.fg,
        ctermfg = hl.ctermfg,
    })
    highlight_cache[matched_name] = true

    return matched_name
end

local function make_fallback_result(completion_text)
    local ghost_hl = get_ghost_highlight(nil)
    local result = {}
    for _, line in ipairs(vim.split(completion_text, "\n", { plain = true })) do
        table.insert(result, { { line, ghost_hl } })
    end
    return result
end

-- Get TreeSitter language for buffer, or nil if not available
local function get_ts_lang(bufnr)
    local filetype = vim.bo[bufnr].filetype
    if not filetype or filetype == "" then
        return nil
    end
    local lang = vim.treesitter.language.get_lang(filetype) or filetype
    if not pcall(vim.treesitter.language.inspect, lang) then
        return nil
    end
    return lang
end

local TS_CONTEXT_LINES = 32

-- Get buffer context (prefix before cursor, suffix after cursor)
-- Limited to TS_CONTEXT_LINES to avoid blocking on large files
local function get_buffer_context(bufnr)
    local cursor = vim.api.nvim_win_get_cursor(0)
    local cursor_line = cursor[1]
    local cursor_col = cursor[2]

    -- Limit prefix to TS_CONTEXT_LINES before cursor
    local start_line = math.max(0, cursor_line - TS_CONTEXT_LINES)
    local lines_before = vim.api.nvim_buf_get_lines(bufnr, start_line, cursor_line, false)
    if #lines_before > 0 then
        lines_before[#lines_before] = lines_before[#lines_before]:sub(1, cursor_col)
    end
    local prefix = table.concat(lines_before, "\n")

    -- Limit suffix to TS_CONTEXT_LINES after cursor
    local end_line = cursor_line - 1 + TS_CONTEXT_LINES
    local lines_after = vim.api.nvim_buf_get_lines(bufnr, cursor_line - 1, end_line, false)
    if #lines_after > 0 then
        lines_after[1] = lines_after[1]:sub(cursor_col + 1)
    end
    local suffix = table.concat(lines_after, "\n")

    return prefix, suffix
end

-- Parse text with TreeSitter and return character highlights table
-- char_highlights[i] = highlight_group for character i (1-indexed)
local function get_ts_char_highlights(text, lang, prefix, suffix)
    local char_highlights = {}
    local prefix_len = #prefix
    local full_text = prefix .. text .. suffix

    local ok, parser = pcall(vim.treesitter.get_string_parser, full_text, lang)
    if not ok or not parser then
        return char_highlights
    end

    local trees = parser:parse()
    local query = vim.treesitter.query.get(lang, "highlights")
    if not trees or #trees == 0 or not query then
        return char_highlights
    end

    -- Build line offset table
    local line_offsets = { 0 }
    for i = 1, #full_text do
        if full_text:sub(i, i) == "\n" then
            line_offsets[#line_offsets + 1] = i
        end
    end

    for _, tree in ipairs(trees) do
        for id, node in query:iter_captures(tree:root(), full_text, 0, -1) do
            local start_row, start_col, end_row, end_col = node:range()
            local node_start = (line_offsets[start_row + 1] or 0) + start_col
            local node_end = (line_offsets[end_row + 1] or 0) + end_col

            if node_end > prefix_len then
                local hl_group = "@" .. query.captures[id] .. "." .. lang
                for pos = math.max(node_start, prefix_len), node_end - 1 do
                    local text_pos = pos - prefix_len + 1
                    if text_pos >= 1 and text_pos <= #text then
                        char_highlights[text_pos] = hl_group
                    end
                end
            end
        end
    end

    return char_highlights
end

-- Build segments from character highlights using a highlight function
local function build_segments(text, char_highlights, get_hl)
    local segments = {}
    local current_hl, current_start = nil, 1

    for i = 1, #text do
        local hl = char_highlights[i]
        if i == 1 then
            current_hl = hl
        elseif hl ~= current_hl then
            segments[#segments + 1] = { text:sub(current_start, i - 1), get_hl(current_hl) }
            current_start, current_hl = i, hl
        end
    end

    if current_start <= #text then
        segments[#segments + 1] = { text:sub(current_start), get_hl(current_hl) }
    end

    return segments
end

function M.highlight_completion(completion_text, bufnr)
    if not completion_text or completion_text == "" then
        return { { { "", get_ghost_highlight(nil) } } }
    end

    bufnr = bufnr or vim.api.nvim_get_current_buf()
    local filetype = vim.bo[bufnr].filetype

    if not filetype or filetype == "" then
        return make_fallback_result(completion_text)
    end

    local lang = vim.treesitter.language.get_lang(filetype) or filetype
    if not pcall(vim.treesitter.language.inspect, lang) then
        return make_fallback_result(completion_text)
    end

    local prefix, suffix = get_buffer_context(bufnr)
    local prefix_len = #prefix

    local full_text = prefix .. completion_text .. suffix

    -- Parse with treesitter
    local ok, parser = pcall(vim.treesitter.get_string_parser, full_text, lang)
    if not ok or not parser then
        return make_fallback_result(completion_text)
    end

    local trees = parser:parse()
    if not trees or #trees == 0 then
        return make_fallback_result(completion_text)
    end

    local query = vim.treesitter.query.get(lang, "highlights")
    if not query then
        return make_fallback_result(completion_text)
    end

    -- Build line offset table
    local line_offsets = { 0 }
    for i = 1, #full_text do
        if full_text:sub(i, i) == "\n" then
            line_offsets[#line_offsets + 1] = i
        end
    end

    -- Collect highlights for completion text characters
    local char_highlights = {}
    for _, tree in ipairs(trees) do
        for id, node in query:iter_captures(tree:root(), full_text, 0, -1) do
            local start_row, start_col, end_row, end_col = node:range()
            local node_start = (line_offsets[start_row + 1] or 0) + start_col
            local node_end = (line_offsets[end_row + 1] or 0) + end_col

            if node_end > prefix_len then
                local hl_group = "@" .. query.captures[id] .. "." .. lang
                for pos = math.max(node_start, prefix_len), node_end - 1 do
                    local text_pos = pos - prefix_len + 1
                    if text_pos >= 1 and text_pos <= #completion_text then
                        char_highlights[text_pos] = hl_group
                    end
                end
            end
        end
    end

    -- Build highlighted segments per line
    local completion_lines = vim.split(completion_text, "\n", { plain = true })
    local result = {}
    local char_offset = 0

    for _, line_text in ipairs(completion_lines) do
        local segments = {}
        local current_hl, current_start = nil, 1

        for i = 1, #line_text do
            local hl = char_highlights[char_offset + i]
            if i == 1 then
                current_hl = hl
            elseif hl ~= current_hl then
                segments[#segments + 1] =
                    { line_text:sub(current_start, i - 1), get_ghost_highlight(current_hl) }
                current_start, current_hl = i, hl
            end
        end

        if current_start <= #line_text then
            segments[#segments + 1] =
                { line_text:sub(current_start), get_ghost_highlight(current_hl) }
        end

        result[#result + 1] = #segments > 0 and segments
            or { { line_text, get_ghost_highlight(nil) } }
        char_offset = char_offset + #line_text + 1
    end

    return result
end

function M.clear_cache()
    highlight_cache = {}
end

-- Highlight completion text with matched portions rendered in normal style (for pre-0.10)
-- match_positions is a table where match_positions[i] = true means character i is matched
function M.highlight_completion_with_matches(completion_text, bufnr, match_positions)
    if not completion_text or completion_text == "" then
        return { { "", get_ghost_highlight(nil) } }
    end

    bufnr = bufnr or vim.api.nvim_get_current_buf()
    local filetype = vim.bo[bufnr].filetype

    local lang = nil
    if filetype and filetype ~= "" then
        lang = vim.treesitter.language.get_lang(filetype) or filetype
        if not pcall(vim.treesitter.language.inspect, lang) then
            lang = nil
        end
    end

    -- Build character highlights using treesitter if available
    local char_highlights = {}
    if lang then
        local prefix, suffix = get_buffer_context(bufnr)
        local prefix_len = #prefix
        local full_text = prefix .. completion_text .. suffix

        local ok, parser = pcall(vim.treesitter.get_string_parser, full_text, lang)
        if ok and parser then
            local trees = parser:parse()
            local query = vim.treesitter.query.get(lang, "highlights")
            if trees and #trees > 0 and query then
                local line_offsets = { 0 }
                for i = 1, #full_text do
                    if full_text:sub(i, i) == "\n" then
                        line_offsets[#line_offsets + 1] = i
                    end
                end

                for _, tree in ipairs(trees) do
                    for id, node in query:iter_captures(tree:root(), full_text, 0, -1) do
                        local start_row, start_col, end_row, end_col = node:range()
                        local node_start = (line_offsets[start_row + 1] or 0) + start_col
                        local node_end = (line_offsets[end_row + 1] or 0) + end_col

                        if node_end > prefix_len then
                            local hl_group = "@" .. query.captures[id] .. "." .. lang
                            for pos = math.max(node_start, prefix_len), node_end - 1 do
                                local text_pos = pos - prefix_len + 1
                                if text_pos >= 1 and text_pos <= #completion_text then
                                    char_highlights[text_pos] = hl_group
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    -- Build highlighted segments for first line only (that's what we need for pre-0.10)
    local first_line = vim.split(completion_text, "\n", { plain = true })[1] or ""
    local segments = {}
    local current_hl, current_matched, current_start = nil, nil, 1

    for i = 1, #first_line do
        local hl = char_highlights[i]
        local is_matched = match_positions[i] or false

        if i == 1 then
            current_hl = hl
            current_matched = is_matched
        elseif hl ~= current_hl or is_matched ~= current_matched then
            local segment_text = first_line:sub(current_start, i - 1)
            local segment_hl = current_matched and get_matched_highlight(current_hl)
                or get_ghost_highlight(current_hl)
            segments[#segments + 1] = { segment_text, segment_hl }
            current_start = i
            current_hl = hl
            current_matched = is_matched
        end
    end

    if current_start <= #first_line then
        local segment_text = first_line:sub(current_start)
        local segment_hl = current_matched and get_matched_highlight(current_hl)
            or get_ghost_highlight(current_hl)
        segments[#segments + 1] = { segment_text, segment_hl }
    end

    return #segments > 0 and segments or { { first_line, get_ghost_highlight(nil) } }
end

-- Get the default ghost highlight group name (for inline mode)
function M.get_ghost_highlight_group()
    ensure_setup()
    return "NinetyFiveGhost"
end

-- Highlight a single ghost text chunk for inline mode
-- Returns virt_text format: {{text, hl}, {text, hl}, ...}
function M.highlight_ghost_text(text, bufnr)
    if not text or text == "" then
        return { { "", get_ghost_highlight(nil) } }
    end

    bufnr = bufnr or vim.api.nvim_get_current_buf()
    local lang = get_ts_lang(bufnr)

    -- Without treesitter, return with default ghost highlight
    if not lang then
        return { { text, get_ghost_highlight(nil) } }
    end

    local prefix, suffix = get_buffer_context(bufnr)
    local char_highlights = get_ts_char_highlights(text, lang, prefix, suffix)
    local segments = build_segments(text, char_highlights, get_ghost_highlight)

    return #segments > 0 and segments or { { text, get_ghost_highlight(nil) } }
end

vim.api.nvim_create_autocmd("ColorScheme", {
    callback = function()
        M.clear_cache()
        bg_color_cache = nil
    end,
})

return M
