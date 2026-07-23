local util = require("obsidian-embed.util")

local M = {}
local Index = {}
Index.__index = Index

local function add(index, workspace, key)
  if not (workspace and key) then return end
  index[workspace] = index[workspace] or {}
  index[workspace][key] = true
end

function M.new()
  return { paths = {}, unresolved = {}, queries = {} }
end

function M.merge(target, source)
  for _, kind in ipairs({ "paths", "queries", "unresolved" }) do
    target[kind] = target[kind] or {}
    for workspace, keys in pairs((source or {})[kind] or {}) do
      for key in pairs(keys) do add(target[kind], workspace, key) end
    end
  end
  return target
end

function M.track_note(ctx, note)
  if not (ctx and ctx.dependencies) then return end
  local path = util.note_path_key(note)
  if not path then return end
  local workspace = util.workspace_root_for_path(path, false) or ctx.workspace_root
  add(ctx.dependencies.paths, workspace, path)
end

---Record a provider-declared filesystem dependency using the current workspace.
---@param ctx ObsidianEmbedsRenderContext
---@param path string
function M.track_path(ctx, path)
  if not (ctx and ctx.dependencies) then return end
  path = util.real_path_key(path)
  if not path then return end
  local workspace = util.workspace_root_for_path(path, false) or ctx.workspace_root
  add(ctx.dependencies.paths, workspace, path)
end

function M.track_query(ctx, target)
  if not (ctx and ctx.dependencies) then return end
  add(ctx.dependencies.queries, ctx.workspace_root, util.unresolved_key(target))
end

function M.track_unresolved(ctx, target)
  if not (ctx and ctx.dependencies) then return end
  add(ctx.dependencies.unresolved, ctx.workspace_root, util.unresolved_key(target))
end

function M.iter_paths(dependency_set, callback)
  for workspace, paths in pairs((dependency_set or {}).paths or {}) do
    for path in pairs(paths) do callback(workspace, path) end
  end
end

local function ensure_workspace(index, root)
  local workspace = index.workspaces[root]
  if workspace then return workspace end
  workspace = {
    reverse = { paths = {}, queries = {}, unresolved = {} },
    note_keys = {},
  }
  index.workspaces[root] = workspace
  return workspace
end

---Create the single owner of workspace-keyed reverse dependency state.
function M.new_index()
  return setmetatable({ workspaces = {} }, Index)
end

---Apply one committed row's dependency delta to each dependency workspace.
function Index:apply(bufnr, _, previous, replacement)
  if not bufnr then return end
  for _, kind in ipairs({ "paths", "queries", "unresolved" }) do
    local roots = {}
    for root in pairs(previous and previous[kind] or {}) do roots[root] = true end
    for root in pairs(replacement and replacement[kind] or {}) do roots[root] = true end
    for root in pairs(roots) do
      local index = ensure_workspace(self, root).reverse[kind]
      local old_keys = previous and previous[kind] and previous[kind][root] or {}
      local new_keys = replacement and replacement[kind] and replacement[kind][root] or {}
      for key in pairs(old_keys) do
        local bucket = index[key]
        if bucket then
          local count = (bucket[bufnr] or 1) - 1
          bucket[bufnr] = count > 0 and count or nil
          if not next(bucket) then index[key] = nil end
        end
      end
      for key in pairs(new_keys) do
        index[key] = index[key] or {}
        index[key][bufnr] = (index[key][bufnr] or 0) + 1
      end
    end
  end
end

function Index:remember_note(root, path, keys, previous_path)
  if not (root and path) then return end
  local workspace = ensure_workspace(self, root)
  workspace.note_keys[path] = vim.deepcopy(keys or {})
  if previous_path and previous_path ~= path then workspace.note_keys[previous_path] = nil end
end

function Index:keys_for_note(root, path)
  local workspace = self.workspaces[root]
  return workspace and workspace.note_keys[path] or nil
end

function Index:has_path_dependents(root, path)
  local workspace = self.workspaces[root]
  return workspace ~= nil and workspace.reverse.paths[path] ~= nil
end

---Return every workspace whose reverse index currently owns a path.
---@param path string
---@return table<string, true>
function Index:workspace_keys_for_path(path)
  local roots = {}
  for root, workspace in pairs(self.workspaces) do
    if workspace.reverse.paths[path] then roots[root] = true end
  end
  return roots
end

---Return every buffer affected by a normalized note-change event.
function Index:affected(event)
  local workspace = self.workspaces[event.workspace_key]
  local buffers = {}
  if not workspace then return buffers end
  local function collect(bucket)
    for bufnr in pairs(bucket or {}) do buffers[bufnr] = true end
  end
  for _, path in ipairs(event.paths or {}) do collect(workspace.reverse.paths[path]) end
  for key in pairs(event.changed_keys or {}) do
    collect(workspace.reverse.queries[key])
    collect(workspace.reverse.unresolved[key])
  end
  if event.old_keys_known == false then
    for _, bucket in pairs(workspace.reverse.queries) do collect(bucket) end
  end
  return buffers
end

return M
