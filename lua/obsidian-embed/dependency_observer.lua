local config = require("obsidian-embed.config")
local dependencies = require("obsidian-embed.dependencies")
local obsidian_port = require("obsidian-embed.obsidian_port")
local util = require("obsidian-embed.util")

local M = {}
local installed = false
local dependency_buffers, previous_buffer_paths = {}, {}

---@class ObsidianEmbedsDependencyObserver
---@field index table
---@field on_change fun(event: table)

---@type ObsidianEmbedsDependencyObserver?
local observer

---Translate filesystem changes into workspace-relative dependency invalidations.
---@param paths string[]
---@param changed_keys? table<string, true>
---@param old_keys_known boolean
local function notes_changed(paths, changed_keys, old_keys_known)
  local grouped = {}
  changed_keys = vim.deepcopy(changed_keys or {})
  for _, path in ipairs(paths) do
    local canonical = util.real_path_key(path)
    local workspaces = canonical and observer.index:workspace_keys_for_path(canonical) or {}
    local natural_workspace = util.workspace_root_for_path(path, false)
    if natural_workspace then workspaces[natural_workspace] = true end
    for workspace in pairs(workspaces) do
      grouped[workspace] = grouped[workspace] or {}
      grouped[workspace][#grouped[workspace] + 1] = canonical
    end
    for key in pairs(util.path_reference_keys(path)) do changed_keys[key] = true end
  end
  for workspace, workspace_paths in pairs(grouped) do
    observer.on_change({
      workspace_key = workspace,
      paths = workspace_paths,
      changed_keys = changed_keys,
      old_keys_known = old_keys_known,
    })
  end
end

---Observe unsaved edits in a loaded note that an embed currently depends on.
---@param bufnr integer
local function attach_dependency_buffer(bufnr)
  if dependency_buffers[bufnr] or not vim.api.nvim_buf_is_valid(bufnr) then return end
  if not util.path_key(vim.api.nvim_buf_get_name(bufnr)) then return end
  dependency_buffers[bufnr] = true
  local function changed(buffer)
    local path = util.path_key(vim.api.nvim_buf_get_name(buffer))
    if path then notes_changed({ path }, util.path_reference_keys(path), true) end
  end
  vim.api.nvim_buf_attach(bufnr, false, {
    on_lines = function(_, buffer) changed(buffer) end,
    on_reload = function(_, buffer) changed(buffer) end,
    on_detach = function(_, buffer)
      dependency_buffers[buffer] = nil
      changed(buffer)
    end,
  })
end

---Attach observers only for the dependencies introduced by one row commit.
---This avoids rescanning every committed row after each incremental result.
---@param dependency_set? ObsidianEmbedsDependencySet
function M.attach_dependencies(dependency_set)
  dependencies.iter_paths(dependency_set, function(_, path)
    local dependency_bufnr = util.loaded_buf_for_path(path)
    if dependency_bufnr then attach_dependency_buffer(dependency_bufnr) end
  end)
end

---Install process-wide filesystem observers once, using runtime-owned callbacks.
---@param opts ObsidianEmbedsDependencyObserver
function M.setup(opts)
  observer = opts
  if installed then return end
  installed = true
  local group = vim.api.nvim_create_augroup(config.namespace .. "-dependencies", { clear = true })

  -- Note.create emits this before the note is written. Its named buffer can
  -- already satisfy an unresolved embed, so invalidate by the note's complete
  -- reference identity instead of waiting for a filesystem lifecycle event.
  vim.api.nvim_create_autocmd("User", { group = group, pattern = "ObsidianNoteCreate", callback = function(ev)
    local note = ev.data and ev.data.note
    local path = util.note_path_key(note)
    local workspace = path and util.workspace_root_for_path(path, false)
    if not (path and workspace) then return end
    local keys = util.note_reference_keys(note)
    observer.index:remember_note(workspace, path, keys)
    notes_changed({ path }, keys, true)
  end })

  vim.api.nvim_create_autocmd("BufWritePost", { group = group, callback = function(ev)
    local path = vim.api.nvim_buf_get_name(ev.buf)
    local workspace, canonical = util.workspace_root_for_path(path, false), util.path_key(path)
    local previous = workspace and canonical and observer.index:keys_for_note(workspace, canonical)
    local keys = vim.deepcopy(previous or {})
    if workspace and vim.b[ev.buf].obsidian_buffer == true then
      local ok, note = pcall(obsidian_port.note_from_buffer, workspace, ev.buf, { max_lines = math.huge })
      if ok and note then
        local current = util.note_reference_keys(note)
        for key in pairs(current) do keys[key] = true end
        if canonical then observer.index:remember_note(workspace, canonical, current) end
      end
    end
    notes_changed({ path }, next(keys) and keys or nil, previous ~= nil)
  end })

  vim.api.nvim_create_autocmd("BufFilePre", { group = group, callback = function(ev)
    previous_buffer_paths[ev.buf] = vim.api.nvim_buf_get_name(ev.buf)
  end })
  vim.api.nvim_create_autocmd("BufFilePost", { group = group, callback = function(ev)
    local old_path = previous_buffer_paths[ev.buf]
    previous_buffer_paths[ev.buf] = nil
    local new_path = vim.api.nvim_buf_get_name(ev.buf)
    local workspace = util.workspace_root_for_path(new_path, false)
      or (old_path and util.workspace_root_for_path(old_path, false))
    local old_key, new_key = util.path_key(old_path), util.path_key(new_path)
    local previous = workspace and old_key and observer.index:keys_for_note(workspace, old_key)
    local keys = vim.deepcopy(previous or {})
    for key in pairs(util.path_reference_keys(old_path)) do keys[key] = true end
    for key in pairs(util.path_reference_keys(new_path)) do keys[key] = true end
    notes_changed(old_path and { old_path, new_path } or { new_path }, keys, previous ~= nil)
    if workspace and new_key and previous then observer.index:remember_note(workspace, new_key, previous, old_key) end
  end })

  vim.api.nvim_create_autocmd("BufWipeout", { group = group, callback = function(ev)
    previous_buffer_paths[ev.buf] = nil
    local path = vim.api.nvim_buf_get_name(ev.buf)
    if path ~= "" then vim.uv.fs_stat(path, function(_, stat)
      if not stat then vim.schedule(function() notes_changed({ path }, nil, false) end) end
    end) end
  end })
  vim.api.nvim_create_autocmd("FileChangedShellPost", { group = group, callback = function(ev)
    notes_changed({ vim.api.nvim_buf_get_name(ev.buf) }, nil, false)
  end })
  vim.api.nvim_create_autocmd({ "BufEnter", "BufReadPost" }, { group = group, callback = function(ev)
    local path = util.real_path_key(vim.api.nvim_buf_get_name(ev.buf))
    if path and next(observer.index:workspace_keys_for_path(path)) then attach_dependency_buffer(ev.buf) end
  end })
end

return M
