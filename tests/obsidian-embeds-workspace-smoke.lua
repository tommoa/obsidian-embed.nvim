-- Run with:
--   nvim --headless -l tests/obsidian-embeds-workspace-smoke.lua

local test = dofile(vim.fs.joinpath(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h"), "testlib.lua"))
test.setup_runtime()

local root = vim.fn.tempname()
local vault_a = root .. "/A"
local vault_b = root .. "/B"
vim.fn.mkdir(vault_a .. "/.obsidian", "p")
vim.fn.mkdir(vault_b .. "/.obsidian", "p")
vim.fn.mkdir(vault_a .. "/Move", "p")
vim.fn.mkdir(vault_b .. "/Move", "p")
test.write_file(vault_a .. "/Main.md", { "![[SharedName]]", "![[CreatedLater]]", "![[SharedAlias]]" })
test.write_file(vault_b .. "/Main.md", { "![[SharedName]]", "![[CreatedLater]]" })
test.write_file(vault_a .. "/SharedName.md", { "workspace A shared" })
test.write_file(vault_b .. "/SharedName.md", { "workspace B shared" })
test.write_file(vault_a .. "/AliasOne.md", { "---", "aliases: [SharedAlias]", "---", "first alias candidate" })
test.write_file(vault_a .. "/Move/Main.md", { "![[./Target]]" })
test.write_file(vault_a .. "/Move/Target.md", { "relative target in workspace A" })
test.write_file(vault_b .. "/Move/Target.md", { "relative target in workspace B" })

require("obsidian").setup {
  legacy_commands = false,
  workspaces = {
    {
      name = "workspace-a",
      path = vault_a,
    },
    {
      name = "workspace-b",
      path = vault_b,
    },
  },
  picker = {
    name = false,
  },
  ui = {
    enable = false,
  },
}
local active_workspace_root = tostring(_G.Obsidian.workspace.root)

local embeds = require("obsidian-embed")
local ns = require("obsidian-embed.config").ns_id

-- Scenario: dependency and unresolved indexes are keyed by workspace root, so
-- matching note names in different vaults do not refresh or render each other.
vim.cmd.edit(vault_a .. "/Main.md")
local a_bufnr = vim.api.nvim_get_current_buf()
vim.b[a_bufnr].obsidian_buffer = true
embeds.setup()
test.wait_complete(embeds, a_bufnr)

vim.cmd.edit(vault_b .. "/Main.md")
local b_bufnr = vim.api.nvim_get_current_buf()
vim.b[b_bufnr].obsidian_buffer = true
embeds.setup()
test.wait_complete(embeds, b_bufnr)

test.assert_contains(test.rendered_text(a_bufnr, ns), "workspace A shared", "workspace A should render its own SharedName")
test.assert_contains(test.rendered_text(b_bufnr, ns), "workspace B shared", "workspace B should render its own SharedName")
test.assert_true(tostring(_G.Obsidian.workspace.root) == active_workspace_root,
  "embed rendering must not switch obsidian.nvim's active workspace")
test.assert_contains(test.rendered_text(a_bufnr, ns), "first alias candidate", "alias fixture should populate a successful query")
test.assert_contains(test.rendered_text(a_bufnr, ns), "Embed not found: CreatedLater", "workspace A missing fixture should render warning")
test.assert_contains(test.rendered_text(b_bufnr, ns), "Embed not found: CreatedLater", "workspace B missing fixture should render warning")

-- Scenario: renaming an attached source refreshes its base directory and
-- workspace, then migrates its dependency index to the new context.
vim.cmd.edit(vault_a .. "/Move/Main.md")
local moved_bufnr = vim.api.nvim_get_current_buf()
vim.b[moved_bufnr].obsidian_buffer = true
embeds.setup()
test.wait_complete(embeds, moved_bufnr)
test.assert_contains(test.rendered_text(moved_bufnr, ns), "relative target in workspace A",
  "relative source should initially resolve beside its workspace A path")
local generation_before_move = embeds.inspect(moved_bufnr).generation
vim.cmd("saveas " .. vim.fn.fnameescape(vault_b .. "/Move/Main.md"))
test.wait_refresh(embeds, moved_bufnr, generation_before_move)
test.assert_contains(test.rendered_text(moved_bufnr, ns), "relative target in workspace B",
  "renaming an attached source should refresh its path and workspace snapshot")

local generation_after_move = embeds.inspect(moved_bufnr).generation
vim.cmd.edit(vault_a .. "/Move/Target.md")
vim.api.nvim_buf_set_lines(vim.api.nvim_get_current_buf(), 0, -1, false, { "old target changed" })
vim.wait(250, function() return embeds.inspect(moved_bufnr).generation > generation_after_move end, 20)
test.assert_true(embeds.inspect(moved_bufnr).generation == generation_after_move,
  "old-workspace dependencies should be removed after moving a source")

vim.cmd.edit(vault_b .. "/Move/Target.md")
local generation_before_new_dependency = embeds.inspect(moved_bufnr).generation
vim.api.nvim_buf_set_lines(vim.api.nvim_get_current_buf(), 0, -1, false, { "new target changed" })
test.wait_refresh(embeds, moved_bufnr, generation_before_new_dependency)
test.assert_contains(test.rendered_text(moved_bufnr, ns), "new target changed",
  "new-workspace dependencies should refresh the moved source")

local outside_path = vim.fn.tempname() .. ".md"
vim.cmd.buffer(moved_bufnr)
vim.cmd("saveas " .. vim.fn.fnameescape(outside_path))
local detached_outside = vim.wait(1000, function() return not embeds.inspect(moved_bufnr).attached end, 20)
test.assert_true(detached_outside, "renaming an attached source outside every workspace should detach it: "
  .. vim.inspect({ path = vim.api.nvim_buf_get_name(moved_bufnr), state = embeds.inspect(moved_bufnr),
    workspace = require("obsidian-embed.util").workspace_root_for_buffer(moved_bufnr, false) }))
test.assert_true(#test.projected_marks(moved_bufnr) == 0,
  "renaming an attached source outside every workspace should clear its presentation")

-- Scenario: a new matching candidate invalidates successful cached queries,
-- not just cached misses or queries that already contained the changed path.
vim.cmd.edit(vault_a .. "/AliasTwo.md")
vim.b[vim.api.nvim_get_current_buf()].obsidian_buffer = true
local generation_before_duplicate = embeds.inspect(a_bufnr).generation
vim.api.nvim_buf_set_lines(
  vim.api.nvim_get_current_buf(),
  0,
  -1,
  false,
  { "---", "aliases: [SharedAlias]", "---", "second alias candidate" }
)
vim.cmd.write()
test.wait_refresh(embeds, a_bufnr, generation_before_duplicate)
test.assert_contains(test.rendered_text(a_bufnr, ns), "Multiple matches for: SharedAlias",
  "creating a second candidate should invalidate cached successful queries")

vim.cmd.edit(vault_a .. "/CreatedLater.md")
vim.b[vim.api.nvim_get_current_buf()].obsidian_buffer = true
local generation_before_create = embeds.inspect(a_bufnr).generation
vim.api.nvim_buf_set_lines(vim.api.nvim_get_current_buf(), 0, -1, false, { "created later in workspace A" })
vim.cmd.write()
test.wait_refresh(embeds, a_bufnr, generation_before_create)
test.assert_contains(test.rendered_text(a_bufnr, ns), "created later in workspace A",
  "creating a missing note in workspace A should refresh workspace A dependents")
test.assert_true(
  not test.rendered_text(b_bufnr, ns):find("created later in workspace A", 1, true),
  "creating a note in workspace A should not refresh workspace B unresolved refs"
)
test.assert_contains(test.rendered_text(b_bufnr, ns), "Embed not found: CreatedLater", "workspace B should remain unresolved")

vim.cmd.edit(vault_b .. "/SharedName.md")
vim.b[vim.api.nvim_get_current_buf()].obsidian_buffer = true
local generation_before_shared_change = embeds.inspect(b_bufnr).generation
vim.api.nvim_buf_set_lines(vim.api.nvim_get_current_buf(), 0, -1, false, { "workspace B shared changed" })
vim.cmd.write()
test.wait_refresh(embeds, b_bufnr, generation_before_shared_change)
test.assert_contains(test.rendered_text(b_bufnr, ns), "workspace B shared changed",
  "editing workspace B target should refresh workspace B dependents")
test.assert_true(
  not test.rendered_text(a_bufnr, ns):find("workspace B shared changed", 1, true),
  "editing workspace B target should not alter workspace A dependents"
)

local runtime = require("obsidian-embed.runtime")
runtime.detach(a_bufnr)
runtime.detach(b_bufnr)
runtime.detach(moved_bufnr)
test.assert_true(not embeds.inspect(a_bufnr).attached and not embeds.inspect(b_bufnr).attached
    and not embeds.inspect(moved_bufnr).attached,
  "detaching sources should release their state-machine sessions")

print("obsidian embeds workspace smoke test passed")
