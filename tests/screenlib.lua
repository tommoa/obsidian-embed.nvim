-- Read Neovim's rendered grid, rather than reconstructing it from extmarks.
-- Run the caller with -u NONE -i NONE -n to isolate configuration and state.
local M = {}

function M.setup()
  vim.o.columns = 80
  vim.o.lines = 24
  vim.o.laststatus = 0
  vim.o.showtabline = 0
  vim.o.cmdheight = 1
  vim.o.equalalways = false
  vim.o.splitright = true
  vim.o.ambiwidth = "single"
  vim.o.breakat = " "
  vim.o.shortmess = "aI"
end

function M.window(winid)
  vim.api.nvim_win_call(winid, function()
    vim.wo.number = false
    vim.wo.relativenumber = false
    vim.wo.signcolumn = "no"
    vim.wo.foldcolumn = "0"
    vim.wo.foldenable = false
    vim.wo.list = false
    vim.wo.wrap = true
    vim.wo.linebreak = false
    vim.wo.breakindent = false
    vim.wo.showbreak = ""
    vim.wo.conceallevel = 2
    vim.wo.concealcursor = "nc"
    vim.wo.scrolloff = 0
    vim.wo.sidescrolloff = 0
  end)
end

-- screenstring() includes combining marks in the base cell. The trailing
-- cell of a wide character is empty, so retain cells separately for column
-- assertions, and concatenate them for human-readable row assertions.
function M.capture(winid, count)
  vim.cmd("redraw!")
  local info = assert(vim.fn.getwininfo(winid)[1])
  local rows, cells = {}, {}
  for row = 1, math.min(count, info.height) do
    cells[row] = {}
    for col = 1, info.width do
      cells[row][col] = vim.fn.screenstring(info.winrow + row - 1, info.wincol + col - 1)
    end
    rows[row] = table.concat(cells[row]):gsub(" +$", "")
  end
  return rows, cells
end

-- Poll observable output, not a fixed sleep or the projected marks. Full
-- redraws also let the presenter's layout observer react to window changes.
function M.expect(winid, expected, label)
  local actual
  local ok = vim.wait(5000, function()
    actual = M.capture(winid, #expected)
    return vim.deep_equal(actual, expected)
  end, 10)
  assert(ok, label .. "\nexpected rows: " .. vim.inspect(expected)
    .. "\nrendered rows: " .. vim.inspect(actual))
end

return M
