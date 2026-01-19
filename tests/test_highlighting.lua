local Helpers = dofile("tests/helpers.lua")

local child = Helpers.new_child_neovim()

local T = MiniTest.new_set({
    hooks = {
        pre_case = function()
            child.restart({ "-u", "scripts/minimal_init.lua" })
            child.lua([[
                _G.Ninetyfive = { config = { debug = false } }
                _G.highlighting = require("ninetyfive.highlighting")
            ]])
        end,
        post_once = child.stop,
    },
})

local function eval_lua(code)
    return child.lua_get(code)
end

T["setup creates NinetyFiveGhost highlight"] = function()
    child.lua([[
        pcall(vim.api.nvim_set_hl, 0, "NinetyFiveGhost", {})
        highlighting.setup()
        _G.hl = vim.api.nvim_get_hl(0, { name = "NinetyFiveGhost" })
    ]])

    local hl = eval_lua("_G.hl")
    MiniTest.expect.equality(hl.italic, true, "NinetyFiveGhost should be italic")
    -- Should have fg or ctermfg
    local has_fg = hl.fg ~= nil or hl.ctermfg ~= nil
    MiniTest.expect.equality(has_fg, true, "NinetyFiveGhost should have fg color")
end

T["highlight_completion returns correct format"] = function()
    child.lua([[
        _G.result = highlighting.highlight_completion("test", 0)
    ]])

    local result = eval_lua("_G.result")
    MiniTest.expect.equality(type(result), "table", "Result should be a table")
    MiniTest.expect.equality(#result >= 1, true, "Result should have at least one line")
    MiniTest.expect.equality(type(result[1][1]), "table", "Each line should contain segments")
    MiniTest.expect.equality(result[1][1][1], "test", "First segment text should be 'test'")
end

T["highlight_completion handles empty input"] = function()
    child.lua([[
        _G.result = highlighting.highlight_completion("", 0)
    ]])

    local result = eval_lua("_G.result")
    MiniTest.expect.equality(#result, 1, "Result should have one line")
    MiniTest.expect.equality(result[1][1][1], "", "Empty input should return empty text")
end

T["highlight_completion handles multiline input"] = function()
    child.lua([[
        _G.result = highlighting.highlight_completion("a\nb\nc", 0)
    ]])

    local result = eval_lua("_G.result")
    MiniTest.expect.equality(#result, 3, "Should return 3 lines")
    MiniTest.expect.equality(result[1][1][1], "a", "First line")
    MiniTest.expect.equality(result[2][1][1], "b", "Second line")
    MiniTest.expect.equality(result[3][1][1], "c", "Third line")
end

T["extmark integration works"] = function()
    child.lua([[
        local bufnr = vim.api.nvim_create_buf(false, true)
        local ns = vim.api.nvim_create_namespace("test_ns")

        highlighting.setup()
        vim.api.nvim_buf_set_extmark(bufnr, ns, 0, 0, {
            virt_text = { { "ghost", "NinetyFiveGhost" } },
        })

        _G.marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {})
        vim.api.nvim_buf_delete(bufnr, { force = true })
    ]])

    local marks = eval_lua("_G.marks")
    MiniTest.expect.equality(#marks, 1, "Should have one extmark")
end

T["clear_cache does not error"] = function()
    child.lua([[
        highlighting.setup()
        highlighting.clear_cache()
        _G.success = true
    ]])

    local success = eval_lua("_G.success")
    MiniTest.expect.equality(success, true)
end

T["blended color is dimmer than original"] = function()
    child.lua([[
        -- Set a known background
        vim.api.nvim_set_hl(0, "Normal", { bg = 0x000000 })
        -- Set Comment to bright white
        vim.api.nvim_set_hl(0, "Comment", { fg = 0xffffff })

        highlighting.clear_cache()
        highlighting.setup()

        _G.hl = vim.api.nvim_get_hl(0, { name = "NinetyFiveGhost" })
    ]])

    local hl = eval_lua("_G.hl")
    -- With 60% opacity blending white (0xffffff) with black (0x000000),
    -- result should be around 0x999999 (153, 153, 153)
    if hl.fg then
        MiniTest.expect.equality(
            hl.fg < 0xffffff,
            true,
            "Blended color should be dimmer than original"
        )
        MiniTest.expect.equality(hl.fg > 0x000000, true, "Blended color should not be fully black")
    end
end

-- Tests for highlight_ghost_text (used in inline mode for 0.10+)

T["highlight_ghost_text returns correct format"] = function()
    child.lua([[
        _G.result = highlighting.highlight_ghost_text("test", 0)
    ]])

    local result = eval_lua("_G.result")
    MiniTest.expect.equality(type(result), "table", "Result should be a table")
    MiniTest.expect.equality(#result >= 1, true, "Result should have at least one segment")
    -- Each segment should be {text, highlight_group}
    MiniTest.expect.equality(type(result[1][1]), "string", "First element should be text")
    MiniTest.expect.equality(
        type(result[1][2]),
        "string",
        "Second element should be highlight group"
    )
end

T["highlight_ghost_text handles empty input"] = function()
    child.lua([[
        _G.result = highlighting.highlight_ghost_text("", 0)
    ]])

    local result = eval_lua("_G.result")
    MiniTest.expect.equality(#result, 1, "Result should have one segment")
    MiniTest.expect.equality(result[1][1], "", "Empty input should return empty text")
end

T["highlight_ghost_text handles nil input"] = function()
    child.lua([[
        _G.result = highlighting.highlight_ghost_text(nil, 0)
    ]])

    local result = eval_lua("_G.result")
    MiniTest.expect.equality(#result, 1, "Result should have one segment")
    MiniTest.expect.equality(result[1][1], "", "Nil input should return empty text")
end

T["highlight_ghost_text preserves full text"] = function()
    child.lua([[
        local text = "function foo(x, y)"
        _G.result = highlighting.highlight_ghost_text(text, 0)
        -- Concatenate all segment texts
        _G.full_text = ""
        for _, seg in ipairs(_G.result) do
            _G.full_text = _G.full_text .. seg[1]
        end
    ]])

    local full_text = eval_lua("_G.full_text")
    MiniTest.expect.equality(
        full_text,
        "function foo(x, y)",
        "All segments should concatenate to original text"
    )
end

T["highlight_ghost_text uses ghost highlights"] = function()
    child.lua([[
        highlighting.setup()
        _G.result = highlighting.highlight_ghost_text("test", 0)
    ]])

    local result = eval_lua("_G.result")
    -- All highlight groups should start with NinetyFiveGhost
    for _, seg in ipairs(result) do
        local hl = seg[2]
        MiniTest.expect.equality(
            hl:find("^NinetyFiveGhost") ~= nil,
            true,
            "Highlight group should start with NinetyFiveGhost, got: " .. hl
        )
    end
end

T["get_ghost_highlight_group returns NinetyFiveGhost"] = function()
    child.lua([[
        _G.result = highlighting.get_ghost_highlight_group()
    ]])

    local result = eval_lua("_G.result")
    MiniTest.expect.equality(result, "NinetyFiveGhost")
end

return T
