-- Run with:
--   nvim --headless -l tests/obsidian-embeds-state-smoke.lua

local test = dofile(vim.fs.joinpath(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h"), "testlib.lua"))
test.setup_runtime()

local state = require("obsidian-embed.render_context")
local dependency_model = require("obsidian-embed.dependencies")

local bufnr = vim.api.nvim_create_buf(false, true)
local dependencies = dependency_model.new()
local buffer_state = state.new_buffer_state({
  bufnr = bufnr,
  workspace_root = "/tmp/vault",
  lines = { "![[Target]]" },
  cursor_row = 0,
  requirements = { needed = false },
})

test.assert_true(buffer_state.line_count == 1, "buffer state should record line count")
test.assert_true(buffer_state.rows == nil, "execution context must not duplicate committed rows")
test.assert_true(buffer_state.analysis_cache == nil, "execution context must not duplicate workspace caches")
test.assert_true(type(buffer_state.resolution_requests) == "table", "buffer state should initialize resolution request store")
test.assert_true(buffer_state.dependencies == nil, "buffer context must not aggregate committed dependencies")

local root_ctx = state.new_row_context(buffer_state, dependencies)
root_ctx.propagation_sentinel = "preserved"
local child_ctx = state.derive(root_ctx, { depth = 2 })
test.assert_true(child_ctx.depth == 2, "child context should apply overrides")
test.assert_true(child_ctx.propagation_sentinel == "preserved", "derived contexts should preserve arbitrary fields")
test.assert_true(child_ctx.stack == root_ctx.stack, "child context should share stack")
test.assert_true(child_ctx.resolution_requests == root_ctx.resolution_requests, "child context should share resolution requests")
test.assert_true(child_ctx.dependencies == root_ctx.dependencies, "child context should share dependencies")

local index = dependency_model.new_index()
local workspace, path = "/tmp/vault", "/tmp/vault/Target.md"
local path_dependency = dependency_model.new()
path_dependency.paths[workspace] = { [path] = true }
index:apply(bufnr, workspace, nil, path_dependency)
index:apply(bufnr, workspace, nil, path_dependency)
index:apply(bufnr, workspace, path_dependency, nil)
test.assert_true(index:has_path_dependents(workspace, path), "duplicate row dependencies should be reference counted")
index:apply(bufnr, workspace, path_dependency, nil)
test.assert_true(not index:has_path_dependents(workspace, path), "removing the final row dependency should remove its index")

local external_path, other_workspace = "/tmp/shared-provider-input", "/tmp/other-vault"
local external_dependency = dependency_model.new()
external_dependency.paths[workspace] = { [external_path] = true }
local other_dependency = dependency_model.new()
other_dependency.paths[other_workspace] = { [external_path] = true }
index:apply(bufnr, workspace, nil, external_dependency)
index:apply(bufnr + 1, other_workspace, nil, other_dependency)
local owners = index:workspace_keys_for_path(external_path)
test.assert_true(owners[workspace] and owners[other_workspace], "external paths should retain every owning workspace")
index:apply(bufnr, workspace, external_dependency, nil)
owners = index:workspace_keys_for_path(external_path)
test.assert_true(not owners[workspace] and owners[other_workspace], "removing a dependency should remove only its workspace association")

local cross_workspace_dependency = dependency_model.new()
cross_workspace_dependency.paths[other_workspace] = { [external_path] = true }
index:apply(bufnr, workspace, nil, cross_workspace_dependency)
local affected_cross_workspace = index:affected({ workspace_key = other_workspace, paths = { external_path } })
test.assert_true(
  affected_cross_workspace[bufnr],
  "dependencies in another workspace should index the source buffer under that workspace"
)
index:apply(bufnr, workspace, cross_workspace_dependency, nil)

local query_dependency = dependency_model.new()
query_dependency.queries[workspace] = { target = true }
index:apply(bufnr, workspace, nil, query_dependency)
local affected = index:affected({ workspace_key = workspace, old_keys_known = false })
test.assert_true(affected[bufnr], "unknown previous keys should conservatively refresh query dependents")
index:remember_note(workspace, path, { target = true })
local renamed = "/tmp/vault/Renamed.md"
index:remember_note(workspace, renamed, { renamed = true }, path)
test.assert_true(index:keys_for_note(workspace, path) == nil, "renaming a note should remove remembered old keys")
test.assert_true(index:keys_for_note(workspace, renamed).renamed, "renaming a note should retain new keys")

print("obsidian embeds state smoke test passed")
