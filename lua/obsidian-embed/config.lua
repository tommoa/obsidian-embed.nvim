local M = {}

---@class ObsidianEmbedsConfig
---@field presentation table Normalized public presentation options.
---@field trim boolean Trim leading and trailing blank lines from rendered embeds.
---@field virt_lines_leftcol? boolean
---@field priority integer Extmark priority for render and conceal marks.

M.namespace = "obsidian-embed"
M.ns_id = vim.api.nvim_create_namespace(M.namespace)

---@type ObsidianEmbedsConfig
local defaults = {
  presentation = {
    frontmatter = false,
    source = "reveal_cursor",
    rail = "│ ",
    highlights = {
      text = "ObsidianEmbedText",
      rail = "ObsidianEmbedRail",
      warning = "ObsidianEmbedWarning",
    },
    nowrap_overflow = "trunc",
  },
  trim = true,
  virt_lines_leftcol = false,
  priority = 110,
}

local opts = vim.deepcopy(defaults)
local configured = false

local presentation_keys = {
  frontmatter = true,
  source = true,
  rail = true,
  highlights = true,
  nowrap_overflow = true,
}

local highlight_keys = { text = true, rail = true, warning = true }

local function reject_unknown(value, allowed, prefix)
  for key in pairs(value or {}) do
    if not allowed[key] then
      error("unknown obsidian embeds option: " .. prefix .. key, 3)
    end
  end
end

---Validate and install the public presentation configuration.
---@param user_opts? table
function M.setup(user_opts)
  if user_opts == nil and configured then return end
  user_opts = user_opts or {}
  reject_unknown(user_opts, { presentation = true }, "")
  local presentation = user_opts.presentation or {}
  if type(presentation) ~= "table" then
    error("presentation must be a table", 2)
  end
  reject_unknown(presentation, presentation_keys, "presentation.")
  local highlights = presentation.highlights or {}
  if type(highlights) ~= "table" then
    error("presentation.highlights must be a table", 2)
  end
  reject_unknown(highlights, highlight_keys, "presentation.highlights.")
  if presentation.source ~= nil
    and presentation.source ~= "reveal_cursor"
    and presentation.source ~= "conceal"
    and presentation.source ~= "show"
  then
    error("presentation.source must be 'reveal_cursor', 'conceal', or 'show'", 2)
  end
  if presentation.nowrap_overflow ~= nil and presentation.nowrap_overflow ~= "trunc" then
    error("presentation.nowrap_overflow must be 'trunc'", 2)
  end
  if presentation.frontmatter ~= nil and type(presentation.frontmatter) ~= "boolean" then
    error("presentation.frontmatter must be a boolean", 2)
  end
  if presentation.rail ~= nil and type(presentation.rail) ~= "string" then
    error("presentation.rail must be a string", 2)
  end
  for key, value in pairs(highlights) do
    if type(value) ~= "string" or value == "" then
      error("presentation.highlights." .. key .. " must be a non-empty string", 2)
    end
  end

  opts = vim.deepcopy(defaults)
  opts.presentation = {
    frontmatter = presentation.frontmatter == true,
    source = presentation.source or defaults.presentation.source,
    rail = presentation.rail or defaults.presentation.rail,
    highlights = {
      text = highlights.text or defaults.presentation.highlights.text,
      rail = highlights.rail or defaults.presentation.highlights.rail,
      warning = highlights.warning or defaults.presentation.highlights.warning,
    },
    nowrap_overflow = presentation.nowrap_overflow or defaults.presentation.nowrap_overflow,
  }
  configured = true
end

---Return the immutable runtime presentation configuration.
---@return ObsidianEmbedsConfig
function M.get()
  return opts
end

return M
