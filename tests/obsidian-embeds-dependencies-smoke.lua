-- Run with:
--   nvim --headless -l tests/obsidian-embeds-dependencies-smoke.lua

local testlib = dofile(vim.fs.joinpath(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h"), "testlib.lua"))

local function fail(message)
  error(message, 0)
end

local function assert_true(value, message)
  if not value then
    fail(message)
  end
end

local function assert_contains(haystack, needle, message)
  if not haystack:find(needle, 1, true) then
    fail(message .. "\nexpected to find: " .. needle .. "\nin: " .. haystack)
  end
end

local function write_file(path, lines)
  local file = assert(io.open(path, "w"))
  file:write(table.concat(lines, "\n"))
  file:write("\n")
  file:close()
end

testlib.setup_runtime()

local workspace_parent = vim.fn.tempname()
local root = workspace_parent .. "/A"
vim.fn.mkdir(root .. "/.obsidian", "p")
local external_path = vim.fn.tempname() .. ".txt"
local cross_workspace = workspace_parent .. "/B"
local cross_workspace_path = cross_workspace .. "/CrossWorkspace.md"
write_file(external_path, { "external provider initial" })
vim.fn.mkdir(cross_workspace .. "/.obsidian", "p")
write_file(cross_workspace_path, { "cross workspace provider initial" })

write_file(root .. "/Target.md", {
  "# Target",
  "initial target body",
})

write_file(root .. "/DeleteMe.md", {
  "delete me body",
})

write_file(root .. "/Main.md", {
  "![[DeleteMe]]",
  "![[Target]]",
  "![[CreatedLater]]",
  "![[CreatedLater]]",
  "![[External.provider]]",
  "![[CrossWorkspace.provider]]",
})

require("obsidian").setup {
  legacy_commands = false,
  workspaces = {
    {
      name = "dependency-smoke",
      path = root,
    },
    {
      name = "cross-workspace-dependency-smoke",
      path = cross_workspace,
    },
  },
  ui = {
    enable = false,
  },
}

local embeds = require("obsidian-embed")
local external_render_count = 0
local unregister_external = embeds.register_provider({
  name = "external-dependency-smoke",
  match = function(ref)
    return ref.target == "External.provider" or ref.target == "CrossWorkspace.provider"
  end,
  render_async = function(ref, _, done)
    external_render_count = external_render_count + 1
    local path = ref.target == "CrossWorkspace.provider" and cross_workspace_path or external_path
    local dependency_bufnr = require("obsidian-embed.util").loaded_buf_for_path(path)
    local lines = dependency_bufnr and vim.api.nvim_buf_get_lines(dependency_bufnr, 0, -1, false)
      or vim.fn.readfile(path)
    local body = lines[1] or ""
    done({
      dependencies = { path },
      project = function() return { { { body, "Normal" } } } end,
    })
  end,
})

vim.cmd.edit(root .. "/Main.md")
local main_bufnr = vim.api.nvim_get_current_buf()
vim.b[main_bufnr].obsidian_buffer = true
vim.api.nvim_win_set_cursor(0, { 1, 0 })
embeds.setup()
testlib.wait_complete(embeds, main_bufnr)

local ns = require("obsidian-embed.config").ns_id

-- Scenario: dependency indexes track rendered targets, unsaved loaded buffers,
-- deleted source rows, and unresolved refs that become resolvable later.
local function rendered_text(bufnr)
  local lines = {}
  local marks = testlib.projected_marks(bufnr)
  for _, mark in ipairs(marks) do
    local details = mark[4]
    if details.virt_text then
      local parts = {}
      for _, chunk in ipairs(details.virt_text) do parts[#parts + 1] = chunk[1] end
      lines[#lines + 1] = table.concat(parts, "")
    end
    for _, virt_line in ipairs(details.virt_lines or {}) do
      local parts = {}
      for _, chunk in ipairs(virt_line) do
        parts[#parts + 1] = chunk[1]
      end
      lines[#lines + 1] = table.concat(parts, "")
    end
  end
  return table.concat(lines, "\n")
end

assert_contains(rendered_text(main_bufnr), "delete me body", "deletion regression fixture did not render")
assert_contains(rendered_text(main_bufnr), "initial target body", "initial dependency did not render")
assert_contains(rendered_text(main_bufnr), "Embed not found: CreatedLater", "missing dependency warning did not render")
assert_contains(rendered_text(main_bufnr), "external provider initial", "external provider dependency did not render")
assert_contains(
  rendered_text(main_bufnr),
  "cross workspace provider initial",
  "cross-workspace provider dependency did not render"
)

-- Provider dependencies outside every workspace retain the workspace that owns
-- their rendered row, including when the dependency buffer is opened later.
vim.cmd.edit(external_path)
local external_bufnr = vim.api.nvim_get_current_buf()
local external_generation = embeds.inspect(main_bufnr).generation
vim.api.nvim_buf_set_lines(external_bufnr, 0, -1, false, { "external provider unsaved" })
local external_unsaved_refresh = vim.wait(1000, function()
  return rendered_text(main_bufnr):find("external provider unsaved", 1, true) ~= nil
end, 20)
assert_true(external_unsaved_refresh, "unsaved external provider dependencies should refresh their owning workspace: "
  .. vim.inspect({ generation = embeds.inspect(main_bufnr).generation, before = external_generation, renders = external_render_count }))
vim.api.nvim_buf_set_lines(external_bufnr, 0, -1, false, { "external provider written" })
vim.cmd.write()
local external_write_refresh = vim.wait(1000, function()
  return rendered_text(main_bufnr):find("external provider written", 1, true) ~= nil
end, 20)
assert_true(external_write_refresh, "written external provider dependencies should refresh their owning workspace")

-- A dependency in another configured workspace must still invalidate the
-- source workspace where its rendered row and resolver cache are owned.
vim.cmd.edit(cross_workspace_path)
local cross_workspace_bufnr = vim.api.nvim_get_current_buf()
local cross_workspace_generation = embeds.inspect(main_bufnr).generation
vim.api.nvim_buf_set_lines(cross_workspace_bufnr, 0, -1, false, { "cross workspace provider changed" })
vim.cmd.write()
local cross_workspace_refresh = vim.wait(1000, function()
  return rendered_text(main_bufnr):find("cross workspace provider changed", 1, true) ~= nil
end, 20)
assert_true(cross_workspace_refresh, "cross-workspace provider dependencies should refresh their source workspace: "
  .. vim.inspect({
    before = cross_workspace_generation,
    generation = embeds.inspect(main_bufnr).generation,
    renders = external_render_count,
    text = rendered_text(main_bufnr),
  }))

vim.cmd.buffer(main_bufnr)
vim.api.nvim_buf_set_lines(main_bufnr, 0, 1, false, {})
embeds.refresh(main_bufnr)
testlib.wait_complete(embeds, main_bufnr)
assert_true(
  not rendered_text(main_bufnr):find("delete me body", 1, true),
  "deleting an embed line without replacement should clear its rendered output"
)
vim.api.nvim_buf_set_lines(main_bufnr, 1, 2, false, { "first missing embed removed" })
embeds.refresh(main_bufnr)
testlib.wait_complete(embeds, main_bufnr)
assert_contains(
  rendered_text(main_bufnr),
  "Embed not found: CreatedLater",
  "removing one of two identical rows must retain the buffer's unresolved dependency"
)

vim.cmd.edit(root .. "/Target.md")
local target_bufnr = vim.api.nvim_get_current_buf()
vim.b[target_bufnr].obsidian_buffer = true
vim.api.nvim_buf_set_lines(target_bufnr, 1, 2, false, { "unsaved target body" })
local unsaved_refresh = vim.wait(1000, function()
  return rendered_text(main_bufnr):find("unsaved target body", 1, true) ~= nil
end, 20)
assert_true(unsaved_refresh, "unsaved target buffer edit should refresh dependent embeds")
assert_true(
  not rendered_text(main_bufnr):find("initial target body", 1, true),
  "dependent render should prefer loaded buffer contents over disk"
)

local function assert_discard_refresh(command, discarded_body)
  vim.cmd(command .. " " .. target_bufnr)
  local refreshed = vim.wait(1000, function()
    local text = rendered_text(main_bufnr)
    return text:find("initial target body", 1, true) ~= nil
      and text:find(discarded_body, 1, true) == nil
  end, 20)
  assert_true(refreshed, command .. " should refresh dependents with the target's disk contents")
end

assert_discard_refresh("bdelete!", "unsaved target body")

vim.cmd.edit(root .. "/Target.md")
target_bufnr = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(target_bufnr, 1, 2, false, { "discarded by wipeout" })
local wipeout_unsaved_refresh = vim.wait(1000, function()
  return rendered_text(main_bufnr):find("discarded by wipeout", 1, true) ~= nil
end, 20)
assert_true(wipeout_unsaved_refresh, "second unsaved target edit should refresh dependent embeds")
assert_discard_refresh("bwipeout!", "discarded by wipeout")

vim.cmd.edit(root .. "/Target.md")
target_bufnr = vim.api.nvim_get_current_buf()
local generation_before_rename = embeds.inspect(main_bufnr).generation
local renamed_path = root .. "/RenamedTarget.md"
assert_true(vim.uv.fs_rename(root .. "/Target.md", renamed_path), "rename fixture should move the target file")
vim.cmd.file(vim.fn.fnameescape(renamed_path))
local rename_refresh = vim.wait(1000, function()
  return embeds.inspect(main_bufnr).generation > generation_before_rename
end, 20)
assert_true(rename_refresh, "renaming a target should refresh dependents indexed under its old path")

vim.cmd.edit(root .. "/CreatedLater.md")
local created_bufnr = vim.api.nvim_get_current_buf()
vim.b[created_bufnr].obsidian_buffer = true
vim.api.nvim_buf_set_lines(created_bufnr, 0, -1, false, { "created later body" })
require("obsidian.note").create({ id = "CreatedLater", title = "CreatedLater", verbatim = true })
local created_refresh = vim.wait(1000, function()
  return rendered_text(main_bufnr):find("created later body", 1, true) ~= nil
end, 20)
assert_true(created_refresh, "creating an unsaved target should refresh unresolved embeds")

-- Scenario: an observer event can invalidate a render before that render has
-- committed its dependency. The stale row must be rejected and rerendered.
local stale_target = root .. "/StaleTarget.md"
write_file(stale_target, { "stale target body" })
write_file(root .. "/StaleMain.md", { "![[StaleTarget]]" })
local obsidian_port = require("obsidian-embed.obsidian_port")
local original_note_from_lines = obsidian_port.note_from_lines
local stale_invalidated = false
obsidian_port.note_from_lines = function(workspace, lines, path, opts)
  local note = original_note_from_lines(workspace, lines, path, opts)
  if vim.fs.basename(tostring(path)) == "StaleTarget.md" and not stale_invalidated then
    stale_invalidated = true
    vim.cmd.edit(stale_target)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "fresh target body" })
    vim.cmd.write()
  end
  return note
end

vim.cmd.edit(root .. "/StaleMain.md")
local stale_main_bufnr = vim.api.nvim_get_current_buf()
vim.b[stale_main_bufnr].obsidian_buffer = true
local stale_refreshed = vim.wait(2000, function()
  return stale_invalidated and rendered_text(stale_main_bufnr):find("fresh target body", 1, true) ~= nil
end, 20)
obsidian_port.note_from_lines = original_note_from_lines
assert_true(stale_refreshed, "an invalidated in-flight row should rerender with fresh dependency content: "
  .. vim.inspect({ invalidated = stale_invalidated, rendered = rendered_text(stale_main_bufnr), snapshot = embeds.inspect(stale_main_bufnr) }))

unregister_external()

print("obsidian embeds dependency smoke test passed")
