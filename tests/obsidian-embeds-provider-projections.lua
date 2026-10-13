-- Also run by the context smoke test so the standard suite covers this boundary.
local test = dofile(vim.fs.joinpath(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h"), "testlib.lua"))
test.setup_runtime()

local renderer = require("obsidian-embed.renderer")
local presenter = require("obsidian-embed.presenter")
local providers = require("obsidian-embed.providers")
local analyzer = require("obsidian-embed.analyzer")
local state = require("obsidian-embed.render_context")
local dependencies = require("obsidian-embed.dependencies")
local config = require("obsidian-embed.config")
local highlight = require("obsidian-embed.highlight")
local resolver = require("obsidian-embed.resolver")
local api = {}
api.safe_render_ref_async = function(...) return renderer.safe_render_ref_async(api, ...) end

local projection, calls = nil, 0
local unregister = providers.register({
  name = "projection-test",
  match = function(ref) return ref.target == "Bad.provider" or ref.target == "Good.provider" end,
  render_async = function(ref, _, done)
    vim.schedule(function()
      done({ project = function(width)
        calls = calls + 1
        if ref.target == "Good.provider" then return { { { "healthy " .. width, "Normal" } } } end
        return projection(width)
      end })
    end)
  end,
})

local function context()
  return state.new_render_context({
    depth = 1, stack = {}, workspace_root = "/vault",
    resolution_requests = {}, dependencies = dependencies.new(),
  })
end

local function render_ref(target)
  local rendered, count, completions
  completions = 0
  api.safe_render_ref_async({ target = target }, context(), function(value, line_count)
    rendered, count, completions = value, line_count, completions + 1
  end)
  test.assert_true(vim.wait(1000, function() return rendered ~= nil end, 5), "provider should complete")
  test.assert_true(completions == 1 and count >= 1, "deferred provider should complete once with a scheduler count")
  test.assert_true(type(rendered) == "function", "provider projection should remain deferred: " .. vim.inspect(rendered))
  return rendered
end

local function text_for_lines(lines)
  local out = {}
  for _, line in ipairs(lines) do
    local chunks = {}
    for _, chunk in ipairs(line) do chunks[#chunks + 1] = chunk[1] end
    out[#out + 1] = table.concat(chunks)
  end
  return table.concat(out, "\n")
end

local winid, previous_buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
local bufnr = vim.api.nvim_create_buf(false, true)
vim.api.nvim_win_set_buf(winid, bufnr)
local previous_wrap = vim.wo[winid].wrap
vim.wo[winid].wrap = true
config.setup({ presentation = { source = "conceal" } })

local function render_row(lines, row)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  local buffer = state.new_buffer_state({
    bufnr = bufnr, workspace_root = "/vault", lines = lines, requirements = { needed = false },
  })
  local rendered, render_error
  renderer.render_analyzed_row_state_async(api, buffer, row, analyzer.analyze(lines).rows[row + 1], function(value, err)
    rendered, render_error = value, err
  end)
  test.assert_true(vim.wait(1000, function() return rendered ~= nil or render_error ~= nil end, 5), "row should complete")
  test.assert_true(render_error == nil, "projection must not fail the row render: " .. tostring(render_error))
  return { rows = { [row] = rendered } }
end

local ns = vim.api.nvim_create_namespace("obsidian-embed.projection-test")
local function project(presentation)
  local ok, marks = pcall(presenter.project, presentation, winid)
  test.assert_true(ok, "malformed provider output should not throw in the presenter: " .. tostring(marks))
  local out = {}
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  for _, mark in ipairs(marks) do
    local details = mark[4]
    -- Exercise Neovim too: an invalid highlight can survive text wrapping.
    vim.api.nvim_buf_set_extmark(bufnr, ns, mark[2], mark[3], details)
    if details.virt_text then out[#out + 1] = text_for_lines({ details.virt_text }) end
    if details.virt_lines then out[#out + 1] = text_for_lines(details.virt_lines) end
  end
  return table.concat(out, "\n"), marks
end

local malformed = {
  { "numeric text", { { { 42, "Normal" } } }, "text must be a string" },
  { "nil lines", nil, "lines must be a list" },
  { "scalar lines", 42, "lines must be a list" },
  { "map lines", { body = {} }, "lines must be a list" },
  { "sparse lines", { [2] = {} }, "lines must be a list" },
  { "scalar line", { 42 }, "line 1 must be a list" },
  { "map line", { { body = {} } }, "line 1 must be a list" },
  { "sparse line", { { [2] = { "lost" } } }, "line 1 must be a list" },
  { "scalar chunk", { { 42 } }, "line 1 chunk 1 must be a list" },
  { "map chunk", { { { text = "bad" } } }, "line 1 chunk 1 must be a list" },
  { "empty chunk", { { {} } }, "must contain text" },
  { "missing text", { { { [2] = "Normal" } } }, "chunk 1 must be a list" },
  { "extra chunk field", { { { "bad", "Normal", true } } }, "must contain text" },
  { "boolean text", { { { false } } }, "text must be a string" },
  { "table text", { { { {} } } }, "text must be a string" },
  { "late invalid text", { { { "discard partial output" } }, { { "ok" }, { 42 } } }, "line 2 chunk 2 text" },
  { "boolean highlight", { { { "bad", true } } }, "highlight must be a name" },
  { "fractional highlight", { { { "bad", 1.5 } } }, "highlight must be a name" },
  { "infinite highlight", { { { "bad", math.huge } } }, "highlight must be a name" },
  { "NaN highlight", { { { "bad", 0 / 0 } } }, "highlight must be a name" },
  { "out of range highlight", { { { "bad", 1e30 } } }, "highlight must be a name" },
  { "map highlights", { { { "bad", { group = "Normal" } } } }, "highlights must be a list" },
  { "sparse highlights", { { { "bad", { [2] = "Normal" } } } }, "highlights must be a list" },
  { "invalid stacked highlight", { { { "bad", { "Normal", false } } } }, "highlight 2 must be a name" },
  { "nested highlight list", { { { "bad", { { "Normal" } } } } }, "highlight 1 must be a name" },
}

for _, case in ipairs(malformed) do
  projection = function() return case[2] end
  local before = calls
  local deferred = render_ref("Bad.provider")
  test.assert_true(calls == before, "rendering should not project before width is known")
  local warning = deferred(80)
  local presented = project(render_row({ "![[Bad.provider]] ![[Good.provider]]" }, 0))
  local text = text_for_lines(warning)
  test.assert_contains(text, "Embed provider projection-test error: invalid projection:", case[1])
  test.assert_contains(text, case[3], "warning should identify the invalid field: " .. case[1])
  test.assert_true(#warning == 1 and #warning[1].presentation_prefix == 1, "warnings should have one editorial rail")
  test.assert_contains(presented, "invalid projection", "presenter should display the warning: " .. case[1])
  test.assert_contains(presented, "healthy", "another provider on the row should remain usable: " .. case[1])
  test.assert_true(not presented:find("discard partial output", 1, true), "invalid projections should be rejected as a whole")
end

-- All native highlight representations, empty output, and blank lines survive.
local normal_id = vim.api.nvim_get_hl_id_by_name("Normal")
local valid = { {}, { {} }, { { { "" }, { "plain" }, { "empty group", "" }, { "ID", normal_id },
  { "zero", 0 }, { "signed ID", -1 }, { "stack", { "Normal", normal_id } }, { "empty stack", {} },
  { string.rep("wrapped α\t", 30), { "Normal", normal_id } } } } }
for _, lines in ipairs(valid) do
  projection = function() return lines end
  local deferred = render_ref("Bad.provider")
  local returned = deferred(80)
  for index, line in ipairs(lines) do
    test.assert_true(vim.deep_equal(returned[index], highlight.with_rail({ line }, config.get())[1]),
      "valid chunks should retain their text and highlight representation")
  end
  project(render_row({ "![[Bad.provider]]" }, 0))
  vim.wo[winid].wrap = false
  project(render_row({ "![[Bad.provider]]" }, 0))
  vim.wo[winid].wrap = true
end

-- Every deferred call is checked anew, allowing recovery at another width.
projection = function(width)
  if width < 20 then error("projection exploded", 0) end
  if width < 40 then return { { { 42 } } } end
  return { { { "recovered " .. width, { "Normal", normal_id } } } }
end
local deferred = render_ref("Bad.provider")
test.assert_contains(text_for_lines(deferred(10)), "projection exploded", "thrown projections should become warnings")
test.assert_contains(text_for_lines(deferred(30)), "text must be a string", "changed output must be revalidated")
test.assert_contains(text_for_lines(deferred(80)), "recovered 80", "the same projection should recover at a valid width")

-- Real nested renderer composition, with only note lookup and slicing stubbed.
local original_resolve, original_lines = resolver.resolve_notes_async, resolver.lines_for_ref
resolver.resolve_notes_async = function(_, _, done) done({ {} }) end
resolver.lines_for_ref = function()
  return { "before nested", "- ![[Bad.provider]]", "inline ![[Bad.provider]] and ![[Good.provider]]", "after nested" }
end
for _, throwing in ipairs({ false, true }) do
  projection = function()
    if throwing then error("nested projection exploded", 0) end
    return { { { 42, "Normal" } } }
  end
  local nested = render_ref("Nested")
  local text = text_for_lines(nested(80))
  test.assert_contains(text, throwing and "nested projection exploded" or "text must be a string", "nested failures should be contained")
  test.assert_contains(text, "before nested", "surrounding note text should survive")
  test.assert_contains(text, "after nested", "note rendering should continue after an invalid child")
  test.assert_contains(text, "healthy", "valid nested siblings should survive")
  project(render_row({ "![[Nested]]" }, 0))
  local table_text, marks = project(render_row({
    "| first | second |", "| --- | --- |", "| ![[Bad.provider]] | ![[Good.provider]] |",
  }, 2))
  test.assert_true(#marks == 2, "both table previews should survive provider failures")
  test.assert_contains(table_text, "Embed provider", "table preview should display a compact warning")
  test.assert_contains(table_text, "healthy", "valid table siblings should survive")
end
resolver.resolve_notes_async, resolver.lines_for_ref = original_resolve, original_lines

-- Cancellation still suppresses late asynchronous provider completions.
local late_done, cancelled, completed = nil, 0, 0
local owner = {}
providers.render_async({ name = "cancelled-projection", render_async = function(_, _, done)
  late_done = done
  return function() cancelled = cancelled + 1 end
end }, {}, {}, function() completed = completed + 1 end, owner)
providers.cancel_owner(owner)
late_done({ project = function() error("cancelled projection must not run") end })
test.assert_true(cancelled == 1 and completed == 0, "cancelled provider completions must remain ignored")

unregister()
config.setup({})
vim.wo[winid].wrap = previous_wrap
vim.api.nvim_win_set_buf(winid, previous_buf)
vim.api.nvim_buf_delete(bufnr, { force = true })
print("obsidian embeds provider projection tests passed")
