local M = {}

---@class ObsidianEmbedsWorkspace
---@field root string

---Decode a URI-encoded embed target into its lookup form.
---@param target? string
---@return string
function M.decode_target(target)
  return vim.uri_decode(target or "")
end

---Normalize a filesystem path for use as an identity key.
---@param path? string
---@return string?
function M.path_key(path)
  if not path or path == "" then
    return nil
  end
  return vim.fs.normalize(tostring(path))
end

---Resolve an existing filesystem path to the identity Neovim uses for buffers.
---@param path? string
---@return string?
function M.real_path_key(path)
  path = M.path_key(path)
  return path and (vim.uv.fs_realpath(path) or path) or nil
end

---Find a loaded Neovim buffer whose normalized name matches a path.
---@param path string
---@return integer?
function M.loaded_buf_for_path(path)
  path = M.real_path_key(path)
  if not path then
    return nil
  end

  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) then
      local name = M.real_path_key(vim.api.nvim_buf_get_name(bufnr))
      if name == path then
        return bufnr
      end
    end
  end
  return nil
end

---Find the configured Obsidian workspace root containing a path.
---@param path? string
---@param required boolean
---@return string?
function M.workspace_root_for_path(path, required)
  path = M.path_key(path)
  if not path then
    if required then
      error("Obsidian embeds requires a valid path for workspace lookup", 2)
    end
    return nil
  end

  local workspace = require("obsidian.api").find_workspace(path)
  if workspace and workspace.root then
    return M.path_key(tostring(workspace.root))
  end

  if required then
    error("Obsidian embeds requires an Obsidian workspace for path: " .. path, 2)
  end
  return nil
end

---Find the Obsidian workspace root for a buffer's current filename.
---@param bufnr integer
---@param required boolean
---@return string?
function M.workspace_root_for_buffer(bufnr, required)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    if required then
      error("Obsidian embeds requires a valid buffer for workspace lookup", 2)
    end
    return nil
  end
  return M.workspace_root_for_path(vim.api.nvim_buf_get_name(bufnr), required)
end

---Canonicalize an unresolved target for dependency-index matching.
---@param target? string
---@return string?
function M.unresolved_key(target)
  target = M.decode_target(target)
  if target == "" then
    return nil
  end
  return (target:gsub("%.md$", "")):lower()
end

---Add a canonical unresolved value to a set when it is meaningful.
---@param keys table<string, true>
---@param value? string
local function add_key(keys, value)
  local key = M.unresolved_key(value)
  if key then
    keys[key] = true
  end
end

---Return every reference key that could satisfy an unresolved embed for a note:
---id/title/alias plus obsidian.nvim's own reference ids and encoded paths.
---@param note? ObsidianEmbedsNote
---@return table<string, true>
function M.note_reference_keys(note)
  local keys = {}
  if not note then
    return keys
  end

  add_key(keys, note.id)
  add_key(keys, note.title)
  if note.display_name then
    add_key(keys, note:display_name())
  end

  for _, alias in ipairs(note.aliases or {}) do
    add_key(keys, alias)
  end

  if type(note.reference_ids) == "table" then
    for _, ref in ipairs(note.reference_ids) do
      add_key(keys, ref)
    end
  elseif note.reference_ids then
    for _, ref in ipairs(note:reference_ids({ lowercase = false }) or {}) do
      add_key(keys, ref)
    end
  end

  if type(note.reference_paths) == "table" then
    for _, ref in ipairs(note.reference_paths) do
      add_key(keys, ref)
    end
  elseif note.get_reference_paths then
    for _, ref in ipairs(note:get_reference_paths({ urlencode = true }) or {}) do
      add_key(keys, ref)
    end
  end

  return keys
end

---Return reference keys derived from a path before a note object is available.
---@param path? string
---@return table<string, true>
function M.path_reference_keys(path)
  local keys = {}
  path = M.path_key(path)
  if not path then
    return keys
  end

  add_key(keys, path)
  add_key(keys, vim.fs.basename(path))
  add_key(keys, (vim.fs.basename(path):gsub("%.md$", "")))

  local root = M.workspace_root_for_path(path, false)
  if root and vim.startswith(path, root .. "/") then
    local rel = path:sub(#root + 2)
    add_key(keys, rel)
    add_key(keys, rel:gsub("%.md$", ""))
  end

  return keys
end

---Return the normalized path identity for a note object.
---@param note? ObsidianEmbedsNote
---@return string?
function M.note_path_key(note)
  return note and note.path and M.path_key(tostring(note.path)) or nil
end

---Signature used in render-cache keys. Loaded buffers use changedtick so unsaved
---target edits invalidate cached renders before the file is written.
---@param note? ObsidianEmbedsNote
---@return string
function M.note_signature(note)
  if note and note.signature then return note.signature end
  local path = M.note_path_key(note)
  local loaded_buf = path and M.loaded_buf_for_path(path) or nil
  if loaded_buf then
    return "buf:" .. tostring(loaded_buf) .. ":" .. tostring(vim.b[loaded_buf].changedtick or 0)
  end

  if note and note.bufnr and vim.api.nvim_buf_is_valid(note.bufnr) then
    return "buf:" .. tostring(note.bufnr) .. ":" .. tostring(vim.b[note.bufnr].changedtick or 0)
  end

  if not path then
    return "path:"
  end

  return "path:" .. path
end

return M
