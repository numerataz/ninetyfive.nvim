-- Reassembles lines from a job's on_stdout/on_stderr callbacks when the stream
-- is not buffered (`stdout_buffered = false`). Neovim delivers each chunk as a
-- list where the first item continues the previous chunk's last line and the
-- last item is an incomplete line (possibly ""), and signals EOF with { "" }.
local LineBuffer = {}

--- Returns a function that takes a callback's `data` list and returns the
--- lines it completes. The trailing incomplete line is held back until a later
--- chunk completes it, or until EOF flushes it.
---
---@return fun(data: string[]|nil): string[]
function LineBuffer.new()
    local pending = ""

    return function(data)
        if not data or #data == 0 then
            return {}
        end

        local lines = { pending .. data[1] }
        for i = 2, #data do
            lines[i] = data[i]
        end

        if #data == 1 and data[1] == "" then
            pending = ""
        else
            pending = table.remove(lines)
        end

        return lines
    end
end

return LineBuffer
