local log = require("ninetyfive.util.log")
local Completion = require("ninetyfive.completion")

local Ninetyfive = {}

local function normalize_use_cmp(value)
    if value == nil then
        return "auto"
    end

    if type(value) == "boolean" then
        return value
    end

    if type(value) == "string" then
        local normalized = value:lower()
        if normalized == "auto" then
            return "auto"
        elseif normalized == "true" then
            return true
        elseif normalized == "false" then
            return false
        end
    end

    error('`use_cmp` must be one of: true, false, or "auto".')
end

local function get_runtime_config()
    if _G.Ninetyfive and _G.Ninetyfive.config then
        return _G.Ninetyfive.config
    end
    return Ninetyfive.options or {}
end

local function contains_ninetyfive_source(sources)
    if type(sources) ~= "table" then
        return false
    end

    for _, source in ipairs(sources) do
        if type(source) == "table" then
            if source.name == "ninetyfive" then
                return true
            end

            if contains_ninetyfive_source(source) then
                return true
            end
        end
    end

    return false
end

local function has_configured_cmp_source()
    local ok, cmp = pcall(require, "cmp")
    if not ok or not cmp then
        return false
    end

    if type(cmp.get_config) ~= "function" then
        return false
    end

    local ok_config, cmp_config = pcall(cmp.get_config)
    if not ok_config or type(cmp_config) ~= "table" then
        return false
    end

    local sources = cmp_config.sources
    if type(sources) == "function" then
        local ok_sources, resolved_sources = pcall(sources)
        if ok_sources then
            sources = resolved_sources
        else
            sources = nil
        end
    end

    return contains_ninetyfive_source(sources)
end

--- Ninetyfive configuration with its default values.
---
---@type table
--- Default values:
---@eval return MiniDoc.afterlines_to_code(MiniDoc.current.eval_section)
Ninetyfive.options = {
    -- Prints useful logs about what event are triggered, and reasons actions are executed.
    debug = false,
    -- When `true`, enables the plugin on NeoVim startup
    enable_on_startup = true,
    -- Update server URI, mostly for debugging
    server = "wss://api.ninetyfive.gg",
    -- Controls cmp integration: "auto" (default), true, or false
    use_cmp = "auto",
    mappings = {
        -- Sets a global mapping to accept a suggestion
        accept = "<Tab>",
        -- Mapping to accept the next word
        accept_word = "<C-h>",
        -- Mapping to accep the next line
        accept_line = "<C-j>",
        -- Sets a global mapping to reject a suggestion
        reject = "<C-w>",
    },

    indexing = {
        -- Possible values: "ask" | "on" | "off"
        mode = "ask",
        -- Whether to cache the user's answer in /tmp per project
        cache_consent = true,
    },
}

---@private
local defaults = vim.deepcopy(Ninetyfive.options)

--- Defaults Ninetyfive options by merging user provided options with the default plugin values.
---
---@param options table Module config table. See |Ninetyfive.options|.
---
---@private
function Ninetyfive.defaults(options)
    Ninetyfive.options = vim.deepcopy(vim.tbl_deep_extend("keep", options or {}, defaults or {}))

    Ninetyfive.options.use_cmp = normalize_use_cmp(Ninetyfive.options.use_cmp)

    -- let your user know that they provided a wrong value, this is reported when your plugin is executed.
    assert(
        type(Ninetyfive.options.debug) == "boolean",
        "`debug` must be a boolean (`true` or `false`)."
    )

    return Ninetyfive.options
end

--- Registers the plugin mappings.
---
---@param options table The mappins provided by the user.
---@param mappings table A key value map of the mapping name and its command.
---
---@private
local function register_mappings(options, mappings)
    for name, command in pairs(mappings) do
        local key = options[name]
        if not key then
            goto continue
        end

        assert(type(key) == "string", string.format("`%s` must be a string", name))

        local opts = { noremap = true, silent = true }

        -- conditional tab behavior, ensure we don't completely hijack the tab key.
        if name == "accept" then
            opts.expr = true
            vim.keymap.set("i", key, function()
                if Completion.has_active_completion() then
                    return "<Cmd>NinetyFiveAccept<CR>"
                else
                    return vim.fn.pumvisible() == 1 and "<C-n>" or "<Tab>"
                end
            end, opts)
        else
            vim.keymap.set({ "n", "i" }, key, command, opts)
        end

        ::continue::
    end
end

--- Define your ninetyfive setup.
---
---@param options table Module config table. See |Ninetyfive.options|.
---
---@usage `require("ninetyfive").setup()` (add `{}` with your |Ninetyfive.options| table)
function Ninetyfive.setup(options)
    Ninetyfive.options = Ninetyfive.defaults(options or {})

    log.warn_deprecation(Ninetyfive.options)

    register_mappings(Ninetyfive.options.mappings, {
        accept = "<Cmd>NinetyFiveAccept<CR>",
        accept_word = "<Cmd>NinetyFiveAcceptWord<CR>",
        accept_line = "<Cmd>NinetyFiveAcceptLine<CR>",
        reject = "<Cmd>NinetyFiveReject<CR>",
    })

    local ok, cmp = pcall(require, "cmp")
    if ok then
        local Source = require("ninetyfive.cmp")
        cmp.register_source("ninetyfive", Source.new())
    end

    return Ninetyfive.options
end

function Ninetyfive.should_use_cmp_mode()
    local cfg = get_runtime_config()
    local use_cmp = cfg.use_cmp

    if use_cmp == true then
        return true
    elseif use_cmp == false then
        return false
    elseif type(use_cmp) == "string" and use_cmp:lower() == "true" then
        return true
    elseif type(use_cmp) == "string" and use_cmp:lower() == "false" then
        return false
    end

    return has_configured_cmp_source()
end

return Ninetyfive
