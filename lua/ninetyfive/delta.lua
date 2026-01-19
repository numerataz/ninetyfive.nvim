local M = {}

---Compute the minimal delta between old_text and new_text.
---Returns start (byte offset), end (byte offset in old text), and the new text to insert.
---@param old_text string
---@param new_text string
---@return number start byte offset where change begins
---@return number end_pos byte offset in old_text where change ends
---@return string insert_text the text to insert at start
function M.compute_delta(old_text, new_text)
    -- Find common prefix (by byte)
    local i = 1
    while i <= #old_text and i <= #new_text and old_text:sub(i, i) == new_text:sub(i, i) do
        i = i + 1
    end

    -- Find common suffix (by byte, don't overlap with prefix)
    local j = 0
    while
        j < #old_text - (i - 1)
        and j < #new_text - (i - 1)
        and old_text:sub(#old_text - j, #old_text - j)
            == new_text:sub(#new_text - j, #new_text - j)
    do
        j = j + 1
    end

    -- Adjust start backward to UTF-8 character boundary
    -- Continuation bytes are 10xxxxxx (0x80-0xBF)
    local start = i - 1
    local b = old_text:byte(start + 1)
    while start > 0 and b and b >= 0x80 and b <= 0xBF do
        start = start - 1
        b = old_text:byte(start + 1)
    end

    -- Adjust end backward to UTF-8 character boundary
    local end_pos = #old_text - j
    b = old_text:byte(end_pos + 1)
    while end_pos > start and b and b >= 0x80 and b <= 0xBF do
        end_pos = end_pos - 1
        b = old_text:byte(end_pos + 1)
    end

    j = #old_text - end_pos
    local insert_text = new_text:sub(start + 1, #new_text - j)

    return start, end_pos, insert_text
end

return M
