local util = require("obsidian-embed.util")

local M = {}

local function assert_function(path, value)
  assert(type(value) == "function", "obsidian-embed.nvim requires " .. path)
end

---Verify the subset of obsidian.nvim internals used by the renderer.
function M.assert_available()
  assert(_G.Obsidian ~= nil, "obsidian-embed.nvim requires obsidian.nvim setup before use")
  assert_function("obsidian.parse.refs.extract", require("obsidian.parse.refs").extract)
  assert_function("obsidian.search.search_async", require("obsidian.search").search_async)
  assert_function("obsidian.search.find_async", require("obsidian.search").find_async)
  assert_function("obsidian.note.from_buffer", require("obsidian.note").from_buffer)
  assert_function("obsidian.note.from_lines", require("obsidian.note").from_lines)
  assert_function("obsidian.attachment.is_attachment_path", require("obsidian.attachment").is_attachment_path)
  assert_function("obsidian.util.is_uri", require("obsidian.util").is_uri)
  assert_function("obsidian.api.find_workspace", require("obsidian.api").find_workspace)
  assert_function("obsidian.config.normalize", require("obsidian.config").normalize)
end

function M.is_attachment_path(target)
  return require("obsidian.attachment").is_attachment_path(target)
end

function M.is_uri(target)
  return require("obsidian.util").is_uri(target)
end

function M.standardize_block(block)
  return require("obsidian.util").standardize_block(block)
end

function M.standardize_anchor(anchor)
  return require("obsidian.util").standardize_anchor(anchor)
end

function M.workspace(root, required)
  root = util.path_key(root)
  for _, workspace in ipairs((_G.Obsidian and _G.Obsidian.workspaces) or {}) do
    if util.path_key(tostring(workspace.root)) == root then return workspace end
  end
  if required ~= false then
    error("Obsidian embeds requires a configured workspace for root: " .. tostring(root), 2)
  end
end

function M.options(root)
  local workspace = M.workspace(root, false)
  if not workspace then return assert(_G.Obsidian and _G.Obsidian.opts, "Obsidian options are unavailable") end
  return require("obsidian.config").normalize(workspace.overrides or {}, _G.Obsidian._opts)
end

function M.note_from_buffer(root, bufnr, opts)
  M.workspace(root, true)
  return require("obsidian.note").from_buffer(bufnr, opts)
end

function M.note_from_lines(root, lines, path, opts)
  M.workspace(root, true)
  return require("obsidian.note").from_lines(lines, path, opts)
end

local function search_options(root, overrides)
  local opts = M.options(root)
  local search = opts.search or {}
  local result = { sort_by = search.sort_by, sort_reversed = search.sort_reversed, exclude = {} }
  if opts.templates and opts.templates.folder then result.exclude[#result.exclude + 1] = tostring(opts.templates.folder) end
  for _, pattern in ipairs((opts.file and opts.file.ignore_filters) or {}) do
    result.exclude[#result.exclude + 1] = pattern
  end
  return vim.tbl_extend("force", result, overrides or {})
end

function M.search_async(root, target, overrides, on_match, on_exit)
  return require("obsidian.search").search_async(root, target, search_options(root, overrides), on_match, on_exit)
end

function M.find_async(root, target, overrides, on_match, on_exit)
  return require("obsidian.search").find_async(root, target, search_options(root, overrides), on_match, on_exit)
end

return M
