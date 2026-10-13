-- Run: nvim --headless -u NONE -i NONE -l tests/obsidian-embeds-benchmark-observer-smoke.lua
local directory = vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))
local observers = dofile(directory .. "/benchmark-observer.lua")
local buf = vim.api.nvim_create_buf(false, true)
local source = {}
for index = 1, 100 do source[index] = "source" end
vim.api.nvim_buf_set_lines(buf, 0, -1, false, source)
local ns = vim.api.nvim_create_namespace("benchmark-observer-test")
local rows = { 1, 21, 41 }
local function install(selected, continuations)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, row in ipairs(selected) do
    vim.api.nvim_buf_set_extmark(buf, ns, row, 0, { virt_text = { { "BENCH_MARKER" } } })
    if continuations then
      vim.api.nvim_buf_set_extmark(buf, ns, row, 0, { virt_lines = { { { "continuation" } } } })
    end
  end
end
local function rejects(selected, continuations, expected)
  install(selected, continuations)
  local observer = observers.new(buf, ns, rows, true, "BENCH_MARKER")
  local ok, err = pcall(observer.observe, true)
  assert(not ok and tostring(err):find(expected, 1, true), tostring(err))
end
rejects({ 1 }, true, "missing installed virt_text at source row 22")
rejects({ 1, 21 }, true, "missing installed virt_text at source row 42")
rejects(rows, false, "missing installed virt_lines at source row 2")

-- Real large payloads must never cross the sampling API boundary. Record the
-- actual queries and reject detail reads except the bounded marker query.
install(rows, true)
local large = {}
for index = 1, 4999 do large[index] = { { "large continuation " .. index } } end
vim.api.nvim_buf_set_extmark(buf, ns, 1, 0, { virt_lines = large })
local original = vim.api.nvim_buf_get_extmarks
local detail_reads, position_reads = 0, 0
vim.api.nvim_buf_get_extmarks = function(bufnr, namespace, first, last, opts)
  if opts.details then
    assert(opts.type == "virt_text" and opts.limit == 1, "unbounded detail query")
    detail_reads = detail_reads + 1
  else
    assert(opts.type == "virt_text" or opts.type == "virt_lines", "unfiltered coverage query")
    position_reads = position_reads + 1
  end
  local marks = original(bufnr, namespace, first, last, opts)
  for _, mark in ipairs(marks) do
    assert(not mark[4] or not mark[4].virt_lines, "virtual-line payload copied during observation")
  end
  return marks
end
local observer = observers.new(buf, ns, rows, true, "BENCH_MARKER")
assert(observer.observe(false), "marker should be installed")
assert(not observer.coverage_seen, "coverage must await the final pass")
local marker, complete = observer.observe(true)
assert(marker and complete, "complete installed output should pass")
for _ = 1, 10 do observer.observe(true) end
assert(detail_reads == 1 and position_reads == 2, "successful observations must be cached")
vim.api.nvim_buf_get_extmarks = original
vim.api.nvim_buf_delete(buf, { force = true })
print("benchmark observer test passed")
