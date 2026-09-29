-- Run with:
--   nvim --headless -l tests/obsidian-embeds-command-contract-smoke.lua

local test = dofile(vim.fs.joinpath(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h"), "testlib.lua"))
test.setup_runtime()

-- The minimum-version error must precede plugin setup and name the remedy.
local embeds = require("obsidian-embed")
local original_has = vim.fn.has
vim.fn.has = function(feature)
  if feature == "nvim-0.11" then return 0 end
  return original_has(feature)
end
local supported, version_error = pcall(embeds.setup)
vim.fn.has = original_has
test.assert_true(not supported and tostring(version_error):find("requires Neovim 0.11 or newer", 1, true),
  "setup should reject unsupported Neovim before configuring the plugin")

local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
vim.fn.mkdir(root .. "/.obsidian", "p")
test.write_file(root .. "/Main.md", { "![[Target]]" })
test.write_file(root .. "/Target.md", { "target body" })

require("obsidian").setup {
  legacy_commands = false,
  workspaces = {
    {
      name = "command-contract-smoke",
      path = root,
    },
  },
  picker = {
    name = false,
  },
  ui = {
    enable = false,
  },
}

require("obsidian-embed.obsidian_port").assert_available()
require("obsidian").register_command("embed", {
  nargs = "*",
  note_action = true,
  complete = function(arg_lead)
    return vim.tbl_filter(function(item)
      return vim.startswith(item, arg_lead)
    end, { "toggle", "refresh", "inspect" })
  end,
})
vim.cmd.runtime("plugin/obsidian.lua")

vim.cmd.edit(root .. "/Main.md")
local bufnr = vim.api.nvim_get_current_buf()
vim.b[bufnr].obsidian_buffer = true

embeds.setup()
test.wait_complete(embeds, bufnr)

local ns = require("obsidian-embed.config").ns_id
test.assert_contains(test.rendered_text(bufnr, ns), "target body", "fixture should render before command checks")
vim.cmd("redraw")
test.assert_true(
  #vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true }) == 0,
  "window-scoped presentation must not leak marks into the shared namespace"
)

vim.cmd("Obsidian embed refresh")
test.wait_complete(embeds, bufnr)
test.assert_contains(test.rendered_text(bufnr, ns), "target body", "Obsidian embeds refresh should refresh the buffer")

vim.cmd("Obsidian embed toggle")
test.assert_true(#test.projected_marks(bufnr) == 0, "Obsidian embed toggle should disable and clear presentation")

vim.cmd("Obsidian embed toggle")
test.wait_complete(embeds, bufnr)
test.assert_contains(test.rendered_text(bufnr, ns), "target body", "Obsidian embeds toggle should re-enable rendering")

local completions = require("obsidian.commands").get_completions("", "Obsidian embed ", #"Obsidian embed ")
test.assert_true(vim.tbl_contains(completions, "toggle"), "embeds command should complete toggle")
test.assert_true(vim.tbl_contains(completions, "refresh"), "embeds command should complete refresh")
test.assert_true(vim.tbl_contains(completions, "inspect"), "embed command should complete inspect")

local search = require("obsidian.search")
local original_search_async = search.search_async
search.search_async = nil
local ok, err = pcall(require("obsidian-embed.obsidian_port").assert_available)
search.search_async = original_search_async
test.assert_true(not ok and tostring(err):find("obsidian.search.search_async", 1, true), "contract should name missing APIs")

local invalid_ok = pcall(embeds.setup, { presentation = { source = "sometimes" } })
test.assert_true(not invalid_ok, "setup should reject invalid enum values")
local config = require("obsidian-embed.config")
for _, source in ipairs({ "show", "conceal", "reveal_cursor" }) do
  config.setup({ presentation = { source = source } })
  test.assert_true(config.get().presentation.source == source, "config should retain the public source enum: " .. source)
end
config.setup({ presentation = { rail = "┆ ", highlights = { rail = "TestEmbedRail" } } })
test.assert_true(config.get().presentation.rail == "┆ ", "config should retain the global embed rail")
test.assert_true(
  config.get().presentation.highlights.rail == "TestEmbedRail",
  "config should retain the rail highlight group"
)
test.assert_true(
  not pcall(config.setup, { presentation = { nested_marker = "> " } }),
  "removed nested_marker configuration should be rejected"
)
local inspected = embeds.inspect(bufnr)
test.assert_true(
  inspected.attached and inspected.phase == "settled" and type(inspected.units) == "table",
  "inspect should return the stable lifecycle summary"
)

print("obsidian embeds command/contract smoke test passed")
