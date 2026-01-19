local log = require("ninetyfive.util.log")
local Completion = require("ninetyfive.completion")
local util = require("ninetyfive.util")
local config = require("ninetyfive.config")

local Source = {}
Source.__index = Source

local function label_text(text)
    if not text or text == "" then
        return ""
    end

    text = text:gsub("^%s*", "")

    if #text <= 40 then
        return text
    end

    local short_prefix = string.sub(text, 1, 20)
    local short_suffix = string.sub(text, #text - 15, #text)
    return string.format("%s ... %s", short_prefix, short_suffix)
end

local function completion_result(items, is_incomplete)
    return {
        items = items or {},
        isIncomplete = is_incomplete or false,
    }
end

local function completion_text(chunks)
    if type(chunks) ~= "table" then
        return ""
    end

    local parts = {}
    local has_content = false
    for i = 1, #chunks do
        local item = chunks[i]
        if item == vim.NIL then
            if has_content then
                break
            end
        else
            parts[#parts + 1] = tostring(item)
            has_content = true
        end
    end

    return table.concat(parts)
end

local function has_flush_marker(chunks)
    if type(chunks) ~= "table" then
        return false
    end
    for i = 1, #chunks do
        if chunks[i] == vim.NIL then
            return true
        end
    end
    return false
end

function Source.new(opts)
    local self = setmetatable({}, Source)
    self.opts = opts or {}
    return self
end

function Source:get_trigger_characters()
    return { "*" }
end

function Source:get_keyword_pattern()
    return "."
end

function Source:is_available()
    return vim ~= nil and vim.fn ~= nil and config.should_use_cmp_mode()
end

function Source:_prepare_context(params)
    params = params or {}
    local bufnr = params.context and params.context.bufnr or vim.api.nvim_get_current_buf()
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return nil
    end

    local cursor = vim.api.nvim_win_get_cursor(0)
    local cursor_line = cursor[1] - 1
    local cursor_col = cursor[2]
    local line_text = vim.api.nvim_buf_get_lines(bufnr, cursor_line, cursor_line + 1, false)[1]
        or ""
    local before_cursor = line_text:sub(1, cursor_col)
    local cursor_prefix = util.get_cursor_prefix(bufnr, cursor)

    return {
        bufnr = bufnr,
        cursor_line = cursor_line,
        cursor_col = cursor_col,
        cursor_prefix = cursor_prefix,
        line_text = line_text,
        before_cursor = before_cursor,
        filetype = vim.bo[bufnr].filetype,
    }
end

function Source:_build_items(context, text)
    text = text or context.result_text or ""
    if text == "" then
        return {}
    end

    local before_cursor = context.before_cursor or ""
    local display_text = before_cursor .. text
    local display_line = display_text:match("([^\n]*)") or display_text
    local lsp_util = vim.lsp.util
    local line_text = context.line_text or ""
    local encoding = "utf-8"
    local ok_start, start_character =
        pcall(lsp_util.character_offset, context.bufnr, context.cursor_line, 0, encoding)
    if not ok_start then
        log.debug("cmp", "failed to compute start character offset: %s", tostring(start_character))
        return {}
    end

    local ok_end, end_character =
        pcall(lsp_util.character_offset, context.bufnr, context.cursor_line, #line_text, encoding)
    if not ok_end then
        log.debug("cmp", "failed to compute end character offset: %s", tostring(end_character))
        return {}
    end

    local range = {
        start = { line = context.cursor_line, character = start_character },
        ["end"] = { line = context.cursor_line, character = end_character },
    }

    local documentation = string.format("```%s\n%s\n```", context.filetype or "", display_text)

    local item = {
        label = label_text(display_line),
        filterText = null,
        kind = 1,
        score = 100,
        insertTextFormat = 1,
        cmp = {
            kind_text = "NinetyFive",
        },
        textEdit = {
            newText = display_line,
            insert = range,
            replace = range,
        },
        documentation = {
            kind = "markdown",
            value = documentation,
        },
        dup = 0,
    }

    return { item }
end

function Source:_matching_completion(context)
    local completion = Completion.get()
    if not completion then
        return nil
    end

    if completion.buffer and completion.buffer ~= context.bufnr then
        return nil
    end

    if completion.prefix and context.cursor_prefix then
        local cursor_prefix = context.cursor_prefix
        if cursor_prefix:sub(1, #completion.prefix) ~= completion.prefix then
            return nil
        end
    end

    return completion
end

function Source:complete(params, callback)
    if not self:is_available() then
        callback(completion_result({}, false))
        return
    end

    self:abort()
    local context = self:_prepare_context(params)
    if not context then
        callback(completion_result({}, false))
        return
    end

    local completion = self:_matching_completion(context)
    if not completion then
        callback(completion_result({}, false))
        return
    end

    if not completion.completion or not has_flush_marker(completion.completion) then
        callback(completion_result({}, false))
        return
    end

    local text = completion_text(completion.completion)
    local inserted_text = ""
    if completion.prefix and context.cursor_prefix then
        inserted_text = context.cursor_prefix:sub(#completion.prefix + 1)
        if inserted_text ~= "" then
            if text:sub(1, #inserted_text) ~= inserted_text then
                callback(completion_result({}, false))
                return
            end
            text = text:sub(#inserted_text + 1)
        end
    end

    if text == "" then
        callback(completion_result({}, false))
        return
    end

    context.result_text = text
    callback(completion_result(self:_build_items(context, text), false))
end

function Source:abort() end

function Source:resolve(completion_item, callback)
    callback(completion_item)
end

function Source:execute(completion_item, callback)
    callback(completion_item)
end

return Source
