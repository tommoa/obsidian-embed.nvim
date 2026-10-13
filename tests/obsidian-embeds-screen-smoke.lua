-- nvim --headless -u NONE -i NONE -n -l tests/obsidian-embeds-screen-smoke.lua
local test_dir = vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))
local test = dofile(vim.fs.joinpath(test_dir, "testlib.lua"))
local screen = dofile(vim.fs.joinpath(test_dir, "screenlib.lua"))
test.setup_runtime()
screen.setup()

local root = vim.fn.tempname()
vim.fn.mkdir(root .. "/.obsidian", "p")
test.write_file(root .. "/Target.md", { "body", "tail" })
test.write_file(root .. "/Long.md", { "abcdefghijABCDEFGHIJ0123456789uvwxyz" })
test.write_file(root .. "/Words.md", { "alpha beta gamma delta epsilon zeta" })
test.write_file(root .. "/Unicode.md", { "123456789界éXYZ界Q" })
test.write_file(root .. "/Cell.md", { "界é | cell with more text" })

require("obsidian").setup({
  legacy_commands = false,
  workspaces = { { name = "screen", path = root } },
  ui = { enable = false },
})
local embeds = require("obsidian-embed")

local function open(name, lines, source)
  vim.cmd("silent only")
  test.write_file(root .. "/" .. name .. ".md", lines)
  vim.cmd("silent edit " .. vim.fn.fnameescape(root .. "/" .. name .. ".md"))
  local buf, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  vim.b[buf].obsidian_buffer = true
  screen.window(win)
  vim.api.nvim_win_set_cursor(win, { #lines, 0 })
  embeds.setup({ presentation = { source = source or "reveal_cursor" } })
  return buf, win
end

local function cursor(win, row)
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_win_set_cursor(win, { row, 0 })
  -- API cursor changes do not consistently emit CursorMoved during -l.
  -- Exercise the same public event used for an interactive cursor move.
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = vim.api.nvim_win_get_buf(win) })
end

-- The visible token and row count change with the cursor, and toggle removes
-- both concealment and virtual lines. Assertions include the following host
-- row so a duplicate source row or a blank gap cannot silently pass.
local buf, win = open("Reveal", { "![[Target]]", "after" })
screen.expect(win, { "│ body", "│ tail", "after" }, "off-cursor source is concealed")
cursor(win, 1)
screen.expect(win, { "![[Target]]", "│ body", "│ tail", "after" }, "cursor reveals the editable source")
cursor(win, 2)
screen.expect(win, { "│ body", "│ tail", "after" }, "leaving source restores concealment")
embeds.toggle(buf)
screen.expect(win, { "![[Target]]", "after" }, "toggle clears rendered output")
embeds.toggle(buf)
screen.expect(win, { "│ body", "│ tail", "after" }, "toggle recovers rendered output")

-- Editing through normal commands also exercises source reveal and automatic
-- refresh. Undo must restore the preview without an explicit refresh call.
cursor(win, 1)
vim.cmd("normal! ccplain replacement")
screen.expect(win, { "plain replacement", "after" }, "editing removes the old preview")
vim.cmd("silent undo")
screen.expect(win, { "![[Target]]", "│ body", "│ tail", "after" }, "undo restores revealed source and preview")
cursor(win, 2)
screen.expect(win, { "│ body", "│ tail", "after" }, "undo recovers concealed source")

buf, win = open("Show", { "![[Target]]", "after" }, "show")
screen.expect(win, { "![[Target]]", "│ body", "│ tail", "after" }, "show mode keeps source off the cursor row")
cursor(win, 1)
screen.expect(win, { "![[Target]]", "│ body", "│ tail", "after" }, "show mode keeps source on the cursor row")

-- One buffer has independent source reveal and wrapping in differently sized
-- windows. Resizing and changing wrap must reproject without manual refresh.
buf, win = open("Splits", { "![[Long]]", "after" })
vim.cmd("vsplit")
local narrow = vim.api.nvim_get_current_win()
screen.window(narrow)
vim.api.nvim_win_set_width(narrow, 14)
cursor(narrow, 2)
screen.expect(narrow, { "│ abcdefghijAB", "│ CDEFGHIJ0123", "│ 456789uvwxyz", "after" }, "narrow split wraps every character")
screen.expect(win, { "│ abcdefghijABCDEFGHIJ0123456789uvwxyz", "after" }, "wide split stays on one row")
cursor(win, 1)
screen.expect(win, { "![[Long]]", "│ abcdefghijABCDEFGHIJ0123456789uvwxyz", "after" }, "source reveal belongs to the wide window")
screen.expect(narrow, { "│ abcdefghijAB", "│ CDEFGHIJ0123", "│ 456789uvwxyz", "after" }, "other split retains concealment")
vim.api.nvim_win_set_width(narrow, 20)
screen.expect(narrow, { "│ abcdefghijABCDEFGH", "│ IJ0123456789uvwxyz", "after" }, "resize reflows the screen")
vim.wo[narrow].wrap = false
screen.expect(narrow, { "│ abcdefghijABCDEFGH", "after" }, "nowrap truncates without extra rows")
vim.wo[narrow].wrap = true
screen.expect(narrow, { "│ abcdefghijABCDEFGH", "│ IJ0123456789uvwxyz", "after" }, "wrap recovers after nowrap")

buf, win = open("WordWrap", { "![[Words]]", "after" }, "conceal")
vim.cmd("vsplit")
narrow = vim.api.nvim_get_current_win()
screen.window(narrow)
vim.api.nvim_win_set_width(narrow, 14)
cursor(narrow, 2)
screen.expect(narrow, { "│ alpha beta g", "│ amma delta e", "│ psilon zeta", "after" }, "ordinary wrap breaks at the last available cell")
vim.wo[narrow].linebreak = true
screen.expect(narrow, { "│ alpha beta", "│ gamma delta", "│ epsilon zeta", "after" }, "linebreak reflows at word boundaries")
vim.wo[narrow].linebreak = false
screen.expect(narrow, { "│ alpha beta g", "│ amma delta e", "│ psilon zeta", "after" }, "changing linebreak back recovers cell wrapping")

-- A list's marker stays on the first row and its continuation indentation
-- repeats. Wide characters cross a wrapping boundary, combining marks stay
-- with their base, and neither creates a blank screen row.
buf, win = open("UnicodeHost", { "- ![[Unicode]]", "after" }, "conceal")
vim.cmd("vsplit")
narrow = vim.api.nvim_get_current_win()
screen.window(narrow)
vim.api.nvim_win_set_width(narrow, 14)
cursor(narrow, 2)
screen.expect(narrow, { "- │ 123456789", "  │ 界éXYZ界Q", "after" }, "Unicode wraps by display width with list continuation")
local _, cells = screen.capture(narrow, 2)
test.assert_true(cells[2][5] == "界" and cells[2][6] == "", "wide glyph occupies two screen cells")
test.assert_true(cells[2][7] == "é", "combining accent remains in its base screen cell")
cursor(narrow, 1)
screen.expect(narrow, { "- │ 123456789", "  │ 界éXYZ界Q", "after" }, "conceal mode also hides source on the cursor row")

-- Table previews preserve subsequent pipe columns even with wide/combining
-- content and an embedded pipe. Revealing then editing/undoing the row must
-- recover the original columns and leave adjacent cells readable.
local table_row = "| ![[Cell]] | ok |"
buf, win = open("Table", { "| Note | State |", "| --- | --- |", table_row, "after" })
screen.expect(win, { "| Note | State |", "| --- | --- |", "| 界é ¦ ce… | ok |", "after" }, "compact table preview fits the source cell")
local _, preview_cells = screen.capture(win, 3)
cursor(win, 3)
screen.expect(win, { "| Note | State |", "| --- | --- |", table_row, "after" }, "table cursor reveals the source")
local _, source_cells = screen.capture(win, 3)
for col, cell in ipairs(source_cells[3]) do
  if cell == "|" then test.assert_true(preview_cells[3][col] == "|", "table separator moved at column " .. col) end
end
vim.cmd("normal! cc| plain | ok |")
screen.expect(win, { "| Note | State |", "| --- | --- |", "| plain | ok |", "after" }, "table edit removes the old overlay")
vim.cmd("silent undo")
cursor(win, 4)
screen.expect(win, { "| Note | State |", "| --- | --- |", "| 界é ¦ ce… | ok |", "after" }, "table undo recovers the aligned preview")

vim.fn.delete(root, "rf")
print("obsidian embeds screen smoke: ok")
