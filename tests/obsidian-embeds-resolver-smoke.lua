local test = dofile(vim.fs.joinpath(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h"), "testlib.lua"))
test.setup_runtime()

local dependencies = require("obsidian-embed.dependencies")
local resolver = require("obsidian-embed.resolver")
local state = require("obsidian-embed.render_context")

-- Fake only the upstream search boundary so admission, sharing, ordering, and
-- cancellation are tested without coupling the test to reducer bookkeeping.
local original_search, original_obsidian = package.loaded["obsidian.search"], _G.Obsidian
_G.Obsidian = { opts = { notes_subdir = nil, daily_notes = {} }, workspaces = {} }
local exits, exit_runs, started, killed, completed = {}, {}, {}, 0, {}
package.loaded["obsidian.search"] = {
  search_async = function(_, target, _, on_match, on_exit)
    started[#started + 1] = target
    local run = { search = on_exit, search_match = on_match }
    exit_runs[target] = exit_runs[target] or {}
    exit_runs[target][#exit_runs[target] + 1] = run
    exits[target] = run
    return { kill = function() killed = killed + 1 end }
  end,
  find_async = function(_, target, _, on_match, on_exit)
    local run = assert(exits[target], "find should follow search for " .. target)
    run.find = on_exit
    run.find_match = on_match
    return function() killed = killed + 1 end
  end,
}

local io = {
  active = 0, queue = {}, requests = {},
  read_active = 0, read_queue = {},
}
local function context(bufnr, base_dir, cache_epoch)
  return state.new_render_context({
    depth = 1, stack = {}, workspace_root = "/vault", base_dir = base_dir,
    dependencies = dependencies.new(), resolution_requests = io.requests,
    io_runtime = io, cache_epoch = cache_epoch or 0,
    owner = { bufnr = bufnr, generation = 1, row = 0 },
  })
end

for index = 1, 5 do
  local target = "Q" .. index
  resolver.resolve_notes_async({ target = target }, context(index, "/vault"), function() completed[target] = true end)
end
test.assert_true(vim.wait(1000, function() return #started == 4 end, 10), "only four resolver pipelines should be admitted")
exits.Q1.search(0); exits.Q1.find(0)
test.assert_true(vim.wait(1000, function() return #started == 5 end, 10), "completion should admit queued work")
exits.Q2.find(0); vim.wait(20)
test.assert_true(not completed.Q2, "partial search completion must not publish a result")
exits.Q2.search(0)
for index = 3, 5 do exits["Q" .. index].search(0); exits["Q" .. index].find(0) end
test.assert_true(vim.wait(1000, function() return io.active == 0 end, 10), "all resolver pipelines should finish")

resolver.resolve_notes_async({ target = "Shared" }, context(90, "/vault/shared"), function() end)
resolver.resolve_notes_async({ target = "Shared" }, context(91, "/vault/shared"), function() end)
test.assert_true(vim.wait(1000, function() return exits.Shared ~= nil end, 10), "equivalent requests should share one search")
test.assert_true(resolver.cancel_waiters(io, 90, 1) == 1 and killed == 0, "one waiter should keep shared work alive")
test.assert_true(resolver.cancel_waiters(io, 91, 1) == 1 and killed == 2, "the last waiter should cancel both search and discovery")

local old_completed = 0
resolver.resolve_notes_async({ target = "Reset" }, context(92, "/vault/reset", 0), function() old_completed = old_completed + 1 end)
resolver.resolve_notes_async({ target = "Reset" }, context(93, "/vault/reset", 0), function() old_completed = old_completed + 1 end)
test.assert_true(vim.wait(1000, function() return exits.Reset ~= nil end, 10), "old-epoch fixture should start upstream work")
local old_run, killed_before_invalidation = exits.Reset, killed
local fresh_completed = false
resolver.resolve_notes_async({ target = "Reset" }, context(94, "/vault/reset", 1), function() fresh_completed = true end)
test.assert_true(
  vim.wait(1000, function() return #exit_runs.Reset == 2 end, 10),
  "a new cache epoch should start independent work for the same resolution"
)
local fresh_run = exits.Reset
test.assert_true(old_run ~= fresh_run and killed == killed_before_invalidation,
  "epoch invalidation should preserve old request handles")
old_run.search(0); old_run.find(0)
test.assert_true(vim.wait(1000, function() return old_completed == 2 end, 10),
  "every waiter from the old epoch should complete")
fresh_run.search(0); fresh_run.find(0)
test.assert_true(vim.wait(1000, function() return fresh_completed and io.active == 0 end, 10),
  "fresh epoch work should finish normally")

-- A broad semantic lookup may discover many paths, but note hydration remains
-- workspace-bounded and exact reference matching preserves discovery order.
local broad_root = vim.fn.tempname()
vim.fn.mkdir(broad_root, "p")
local broad_paths = {}
for index = 1, 12 do
  broad_paths[index] = broad_root .. string.format("/Candidate%02d.md", index)
  test.write_file(broad_paths[index], { "Broad" })
end
local original_note_from_lines = require("obsidian-embed.obsidian_port").note_from_lines
require("obsidian-embed.obsidian_port").note_from_lines = function(_, lines, path)
  return {
    path = path, contents = lines, aliases = {}, blocks = {}, anchor_links = {},
    reference_ids = function() return { (lines[1] or ""):lower() } end,
  }
end
local original_fs_open, original_fs_close = vim.uv.fs_open, vim.uv.fs_close
local open_fds, active_reads, peak_reads = {}, 0, 0
vim.uv.fs_open = function(path, flags, mode, callback)
  return original_fs_open(path, flags, mode, function(err, fd)
    if fd then
      open_fds[fd] = true
      active_reads = active_reads + 1
      peak_reads = math.max(peak_reads, active_reads)
    end
    callback(err, fd)
  end)
end
vim.uv.fs_close = function(fd, callback)
  return original_fs_close(fd, function(err)
    if open_fds[fd] then
      open_fds[fd] = nil
      active_reads = active_reads - 1
    end
    callback(err)
  end)
end

local broad_notes
resolver.resolve_notes_async({ target = "Broad" }, context(94, broad_root), function(notes) broad_notes = notes end)
test.assert_true(vim.wait(1000, function() return exits.Broad ~= nil end, 10), "broad lookup should start discovery")
for _, path in ipairs(broad_paths) do exits.Broad.search_match({ path = { text = path } }) end
exits.Broad.search(0); exits.Broad.find(0)
test.assert_true(vim.wait(2000, function() return broad_notes ~= nil end, 10), "bounded broad lookup should finish")
vim.uv.fs_open, vim.uv.fs_close = original_fs_open, original_fs_close
local policy = require("obsidian-embed.policy")
test.assert_true(peak_reads <= policy.resolver_note_read_limit, "note hydration should respect its workspace-wide read limit")
test.assert_true(#broad_notes == #broad_paths, "every exact broad candidate should resolve")
for index, note in ipairs(broad_notes) do
  test.assert_true(note.path == broad_paths[index], "bounded note hydration should preserve discovery order")
end

local partial_notes
resolver.resolve_notes_async({ target = "Bro" }, context(95, broad_root), function(notes) partial_notes = notes end)
test.assert_true(vim.wait(1000, function() return exits.Bro ~= nil end, 10), "partial lookup should start discovery")
for _, path in ipairs(broad_paths) do exits.Bro.search_match({ path = { text = path } }) end
exits.Bro.search(0); exits.Bro.find(0)
test.assert_true(vim.wait(2000, function() return partial_notes ~= nil end, 10), "partial lookup should finish")
test.assert_true(#partial_notes == #broad_paths, "partial reference IDs should fall back to fuzzy matches")
for index, note in ipairs(partial_notes) do
  test.assert_true(note.path == broad_paths[index], "fuzzy fallback should preserve discovery order")
end
require("obsidian-embed.obsidian_port").note_from_lines = original_note_from_lines

package.loaded["obsidian.search"], _G.Obsidian = original_search, original_obsidian
print("obsidian embeds resolver smoke test passed")
