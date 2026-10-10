-- Run with:
--   nvim --headless -l tests/obsidian-embeds-performance-smoke.lua

local test = dofile(vim.fs.joinpath(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h"), "testlib.lua"))
test.setup_runtime()

local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
vim.fn.mkdir(root .. "/.obsidian", "p")

local target = { "Repeated **bold** [link](Target.md) `code`" }
test.write_file(root .. "/Target.md", target)

local main = {}
for index = 1, 10000 do
  main[index] = index % 20 == 1 and "![[Target]]" or ("plain row " .. index)
end
test.write_file(root .. "/Main.md", main)

require("obsidian").setup {
  legacy_commands = false,
  workspaces = {
    {
      name = "performance-smoke",
      path = root,
    },
  },
  ui = {
    enable = false,
  },
}

vim.treesitter.get_string_parser("# sample", "markdown")
vim.treesitter.get_string_parser("**sample**", "markdown_inline")
assert(vim.treesitter.query.get("markdown", "highlights"), "missing markdown highlight query")
assert(vim.treesitter.query.get("markdown_inline", "highlights"), "missing markdown_inline highlight query")

local embeds = require("obsidian-embed")

vim.cmd.edit(root .. "/Main.md")
local bufnr = vim.api.nvim_get_current_buf()
vim.b[bufnr].obsidian_buffer = true
local heartbeat = assert(vim.uv.new_timer())
local heartbeat_count, max_ready_gap, last_heartbeat, was_rendering = 0, 0, vim.uv.hrtime(), false
heartbeat:start(10, 10, vim.schedule_wrap(function()
  local now = vim.uv.hrtime()
  local phase = embeds.inspect(bufnr).phase
  if was_rendering then max_ready_gap = math.max(max_ready_gap, now - last_heartbeat) end
  was_rendering = phase == "rendering"
  if was_rendering then heartbeat_count = heartbeat_count + 1 end
  last_heartbeat = now
end))
embeds.setup()
test.wait_complete(embeds, bufnr, 5000)
heartbeat:stop()
heartbeat:close()

-- Scenario: the public surface stays small and a large repeated render is
-- completed through explicit row units without exposing scheduler controls.
local api = vim.tbl_keys(embeds)
table.sort(api)
test.assert_true(
  vim.deep_equal(api, { "inspect", "refresh", "register_provider", "setup", "toggle" }),
  "unexpected public API: " .. vim.inspect(api)
)
local status = embeds.inspect(bufnr)
test.assert_true(status.units.ready == 500, "every embed row in the 10,000-line fixture should reach ready state")
test.assert_true(heartbeat_count > 0 and max_ready_gap <= 100000000, "ready work should preserve a heartbeat within 100 ms")
test.assert_true(status.phase == "settled", "large repeated renders should settle")

local generation = status.generation
vim.api.nvim_buf_set_lines(bufnr, #main - 1, #main, false, { "plain edit row changed" })
embeds.refresh(bufnr)
test.wait_complete(embeds, bufnr, 5000)
test.assert_true(embeds.inspect(bufnr).generation == generation + 1, "refresh should create a new render generation")

local burst_generation = embeds.inspect(bufnr).generation
for index = 1, 100 do
  vim.api.nvim_buf_set_lines(bufnr, #main - 1, #main, false, { "burst " .. index })
end
test.assert_true(vim.wait(5000, function()
  local current = embeds.inspect(bufnr)
  return current.generation == burst_generation + 1 and current.phase == "settled"
end, 10), "100 edits should coalesce into one accepted final revision")

print("obsidian embeds performance smoke test passed")
