local test = dofile(vim.fs.joinpath(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h"), "testlib.lua"))
test.setup_runtime()

local presenter = require("obsidian-embed.presenter")
local redraw_opts
local original_redraw = vim.api.nvim__redraw
vim.api.nvim__redraw = function(opts) redraw_opts = opts end
local redraw_buf = vim.api.nvim_create_buf(false, true)
presenter.request_redraw(redraw_buf)
vim.wait(100, function() return redraw_opts ~= nil end, 5)
vim.api.nvim__redraw = original_redraw
test.assert_true(
  redraw_opts and redraw_opts.buf == redraw_buf and redraw_opts.valid == false,
  "presentation commits must force redraws even when buffer text is unchanged"
)
vim.api.nvim_buf_delete(redraw_buf, { force = true })

local config = require("obsidian-embed.config")
local source_buf = vim.api.nvim_create_buf(false, true)
local winid, previous_buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, { "![[Target]]", "cursor row" })
vim.api.nvim_win_set_buf(winid, source_buf)
local presentation = {
  line_count = 2,
  rows = {
    [0] = {
      row = 0,
      exact = true,
      refs = { { range = { start_col = 0, end_col = 11 } } },
      blocks = {
        {
          ref = { range = { start_col = 0, end_col = 11 } },
          lines = { { { "target body", "Normal" } } },
        },
      },
    },
  },
}
local function conceals_source(marks)
  for _, mark in ipairs(marks) do
    local details = mark[4]
    if details.conceal == "" or details.conceal_lines == "" then return true end
  end
  return false
end

config.setup({ presentation = { source = "show" } })
vim.api.nvim_win_set_cursor(winid, { 2, 0 })
test.assert_true(not conceals_source(presenter.project(presentation, winid)), "show mode should never conceal embed source")

config.setup({ presentation = { source = "conceal" } })
vim.api.nvim_win_set_cursor(winid, { 1, 0 })
local concealed_marks = presenter.project(presentation, winid)
test.assert_true(conceals_source(concealed_marks), "conceal mode should hide source on the cursor row")
local saw_overlay_replacement = false
for _, projected in ipairs(concealed_marks) do
  if projected[4].virt_text_pos == "overlay" then saw_overlay_replacement = true end
end
test.assert_true(
  saw_overlay_replacement,
  "concealed exact embeds should overlay their source without participating in Neovim's line wrapping"
)

config.setup({ presentation = { source = "reveal_cursor" } })
vim.api.nvim_win_set_cursor(winid, { 2, 0 })
test.assert_true(conceals_source(presenter.project(presentation, winid)), "reveal_cursor should conceal source off the cursor row")
local projected_width
local projector_presentation = vim.deepcopy(presentation)
projector_presentation.rows[0].blocks = {
  {
    ref = { range = { start_col = 0, end_col = 11 } },
    project = function(width)
      projected_width = width
      return { { { "provider body", "Normal" } } }
    end,
  },
}
local ok, projector_marks = pcall(presenter.project, projector_presentation, winid)
test.assert_true(ok, "reveal_cursor should accept projector-only blocks")
test.assert_true(conceals_source(projector_marks), "projector-only blocks should conceal source off the cursor row")
test.assert_true(projected_width and projected_width > 0, "projector-only blocks should receive the available width")
vim.api.nvim_win_set_cursor(winid, { 1, 0 })
test.assert_true(not conceals_source(presenter.project(presentation, winid)), "reveal_cursor should show source on the cursor row")
config.setup({})
vim.api.nvim_win_set_buf(winid, previous_buf)
vim.api.nvim_buf_delete(source_buf, { force = true })

local analyzer = require("obsidian-embed.analyzer")

local lines = {
  "---",
  "example: '![[Frontmatter]]'",
  "---",
  "# Heading",
  "![[Visible]]",
  "Inline `![[InlineCode]]` remains literal.",
  "```lua",
  "local example = '![[Fence]]'",
  "```",
  "> [!note] Callout",
  "> ![[CalloutEmbed]]",
  "A [[Wiki|label]] and **bold** text.",
  "",
  "    ![[IndentedCode]]",
}

local analysis = analyzer.analyze(lines)
test.assert_true(analysis.error == nil, "contextual analysis should parse fixture: " .. tostring(analysis.error))
test.assert_true(#analysis.rows == #lines, "analysis should preserve source rows")
local analysis_bufnr = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(analysis_bufnr, 0, -1, false, lines)
vim.bo[analysis_bufnr].filetype = "markdown"
local buffer_analysis = analyzer.analyze_buffer(analysis_bufnr, lines)
test.assert_true(buffer_analysis.error == nil, "live-buffer analysis should parse fixture: " .. tostring(buffer_analysis.error))
test.assert_true(
  vim.deep_equal(buffer_analysis.rows, analysis.rows),
  "string and live-buffer parser frontends should share identical row projection"
)
vim.api.nvim_buf_delete(analysis_bufnr, { force = true })
test.assert_true(#analysis.rows[2].refs == 0, "frontmatter should not activate embeds")
test.assert_true(
  #analysis.rows[5].refs == 1 and analysis.rows[5].exact_embed,
  "normal exact embed should remain active"
)
test.assert_true(#analysis.rows[6].refs == 0, "inline code should not activate embeds")
test.assert_true(#analysis.rows[8].refs == 0, "fenced code should not activate embeds")
test.assert_true(#analysis.rows[14].refs == 0, "indented code should not activate embeds")
test.assert_true(
  #analysis.rows[11].refs == 1
    and analysis.rows[11].host.exact
    and analysis.rows[11].host.kind == "quote"
    and analysis.rows[11].host.continuation == "> ",
  "callout embeds should activate and retain their continuation quote marker"
)

local host_analysis = analyzer.analyze({
  "![[Body]]",
  "- ![[List]]",
  "  - ![[NestedList]]",
  "- [ ] ![[Task]]",
  "> ![[Quote]]",
  "- Intro ![[Mixed]]",
  "",
  "| Cell |",
  "| --- |",
  "| ![[Table]] |",
})
test.assert_true(host_analysis.rows[1].host.exact and host_analysis.rows[1].host.prefix == "", "body embeds should replace the whole content position")
test.assert_true(
  host_analysis.rows[2].host.exact
    and host_analysis.rows[2].host.kind == "list"
    and host_analysis.rows[2].host.prefix == "- "
    and host_analysis.rows[2].host.continuation == "  ",
  "list embeds should retain their marker and align continuations"
)
test.assert_true(
  host_analysis.rows[3].host.exact
    and host_analysis.rows[3].host.prefix == "  - "
    and host_analysis.rows[3].host.continuation == "    ",
  "nested list embeds should retain their indentation"
)
test.assert_true(
  host_analysis.rows[4].host.exact
    and host_analysis.rows[4].host.kind == "task"
    and host_analysis.rows[4].host.prefix == "- [ ] "
    and host_analysis.rows[4].host.continuation == "      ",
  "task embeds should retain their checkbox"
)
test.assert_true(
  host_analysis.rows[5].host.exact
    and host_analysis.rows[5].host.kind == "quote"
    and host_analysis.rows[5].host.continuation == "> ",
  "quoted embeds should repeat the blockquote marker"
)
test.assert_true(
  not host_analysis.rows[6].host.exact and host_analysis.rows[6].host.continuation == "  ",
  "mixed list content should keep its text and align the embed beneath it"
)
test.assert_true(
  host_analysis.rows[10].host.kind == "table" and not host_analysis.rows[10].host.exact,
  "table embeds should use compact cell presentation"
)

-- A table preview must occupy exactly the token's display cells, including
-- when multiple embeds share a row, or the following pipes appear to move.
local table_lines = { "| First | Second |", "| --- | --- |", "| ![[First]] | ![[Second]] |" }
local table_analysis = analyzer.analyze(table_lines)
test.assert_true(table_analysis.error == nil, "table analysis should parse fixture")
local table_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(table_buf, 0, -1, false, table_lines)
vim.api.nvim_win_set_buf(winid, table_buf)
local table_refs = {}
for _, ref in ipairs(table_analysis.rows[3].refs) do
  table_refs[#table_refs + 1] = { range = { start_col = ref.start_col, end_col = ref.end_col } }
end
test.assert_true(#table_refs == 2, "both table-cell embeds should be analyzed")
local function token_for(ref)
  return table_lines[3]:sub(ref.range.start_col + 1, ref.range.end_col)
end
local provider_width
local table_state = {
  rows = {
    [2] = {
      host = table_analysis.rows[3].host,
      exact = false,
      refs = table_refs,
      blocks = {
        { ref = table_refs[1], source_token = token_for(table_refs[1]), lines = { { { "", "Normal" } }, { { "A long first preview", "Normal" } } } },
        { ref = table_refs[2], source_token = token_for(table_refs[2]), project = function(width)
          provider_width = width
          return require("obsidian-embed.highlight").with_rail(
            { { { "第二 | cell", "Normal" } } }, config.get()
          )
        end },
      },
    },
  },
}
config.setup({ presentation = { source = "conceal" } })
local table_marks = presenter.project(table_state, winid)
local previews = {}
for _, projected in ipairs(table_marks) do
  local details = projected[4]
  test.assert_true(not details.virt_lines and details.conceal == nil, "table previews must not add rows or collapse cells")
  test.assert_true(details.virt_text_pos == "overlay", "table previews should overlay their source tokens")
  previews[projected[3]] = details.virt_text[1][1]
end
test.assert_true(#table_marks == 2, "each table embed should have one preview")
for _, ref in ipairs(table_refs) do
  test.assert_true(
    vim.fn.strdisplaywidth(previews[ref.range.start_col]) == vim.fn.strdisplaywidth(token_for(ref)),
    "table preview should preserve the token's display width"
  )
end
test.assert_true(previews[table_refs[1].range.start_col]:find("…", 1, true) ~= nil, "long previews should be marked as truncated")
test.assert_true(previews[table_refs[2].range.start_col]:find("¦", 1, true) ~= nil, "preview pipes should not look like cell separators")
test.assert_true(previews[table_refs[2].range.start_col]:find("│", 1, true) == nil, "compact table previews should omit the editorial rail")
test.assert_true(provider_width == vim.fn.strdisplaywidth("![[Second]]"), "providers should receive the cell preview width")
vim.api.nvim_buf_set_lines(table_buf, 2, 3, false, { "| ![[New]] | ![[Second]] |" })
local stale_marks = presenter.project(table_state, winid)
test.assert_true(#stale_marks == 0, "old previews should not cover table cells after a source edit")
vim.api.nvim_buf_set_lines(table_buf, 2, 3, false, { table_lines[3] })
config.setup({ presentation = { source = "show" } })
test.assert_true(#presenter.project(table_state, winid) == 0, "show mode should keep table source visible")
config.setup({ presentation = { source = "reveal_cursor" } })
vim.api.nvim_win_set_cursor(winid, { 3, 0 })
test.assert_true(#presenter.project(table_state, winid) == 0, "cursor row should reveal table source")
vim.api.nvim_win_set_cursor(winid, { 1, 0 })
test.assert_true(#presenter.project(table_state, winid) == 2, "off-cursor table cells should show previews")
local tabbed_line = "| ![[A\tB]] | tail |"
vim.api.nvim_buf_set_lines(table_buf, 2, 3, false, { tabbed_line })
local tabbed_analysis = analyzer.analyze({ table_lines[1], table_lines[2], tabbed_line })
test.assert_true(tabbed_analysis.rows[3].host.kind == "table" and #tabbed_analysis.rows[3].refs == 1, "tabbed token should remain a table embed")
local tabbed_ref = tabbed_analysis.rows[3].refs[1]
local tabbed_token = tabbed_line:sub(tabbed_ref.start_col + 1, tabbed_ref.end_col)
local tabbed_state = {
  rows = { [2] = {
    host = tabbed_analysis.rows[3].host,
    blocks = { { ref = { range = { start_col = tabbed_ref.start_col, end_col = tabbed_ref.end_col } },
      source_token = tabbed_token, lines = { { { "short", "Normal" } } } } },
  } },
}
local tabbed_marks = presenter.project(tabbed_state, winid)
local tabbed_start_width = vim.fn.strdisplaywidth(tabbed_line:sub(1, tabbed_ref.start_col))
test.assert_true(#tabbed_marks == 1, "tabbed table embed should show one preview")
test.assert_true(
  vim.fn.strdisplaywidth(tabbed_marks[1][4].virt_text[1][1]) == vim.fn.strdisplaywidth(tabbed_token, tabbed_start_width),
  "tabbed token preview should fit its width at the cell's actual display column"
)
config.setup({})
vim.api.nvim_win_set_buf(winid, previous_buf)
vim.api.nvim_buf_delete(table_buf, { force = true })

local function has_group(row, group)
  for _, chunk in ipairs(analysis.rows[row].chunks) do
    if chunk.group == group then
      return true
    end
  end
  return false
end

test.assert_true(has_group(4, "@markup.heading.1"), "heading should use document-context capture")
test.assert_true(has_group(12, "@markup.link.label"), "wikilink label should retain inline capture")
test.assert_true(has_group(12, "@markup.strong"), "inline emphasis should retain capture")
test.assert_true(
  has_group(8, "@string") or has_group(8, "@markup.raw"),
  "fenced code should use injection or raw fallback"
)

local resolver = require("obsidian-embed.resolver")
local state = require("obsidian-embed.render_context")
local dependency_model = require("obsidian-embed.dependencies")
local requests = {}
local request_count = 0
local original_search = package.loaded["obsidian.search"]
local original_obsidian = _G.Obsidian
_G.Obsidian = { opts = { notes_subdir = nil, daily_notes = {} } }
package.loaded["obsidian.search"] = {
  search_async = function(_, target, _, _, done)
    request_count = request_count + 1
    if target == "Failure" then
      error("resolution failed")
    end
    done(0)
  end,
  find_async = function(_, _, _, _, done) done(0) end,
}

local function resolution_context(base_dir)
  return state.new_render_context({
    depth = 1,
    stack = {},
    workspace_root = "/vault",
    base_dir = base_dir,
    dependencies = dependency_model.new(),
    resolution_requests = requests,
  })
end

resolver.resolve_notes_async({ target = "Target" }, resolution_context("/vault/one"), function() end)
resolver.resolve_notes_async({ target = "Target" }, resolution_context("/vault/two"), function() end)
resolver.resolve_notes_async({ target = "Target" }, resolution_context("/vault/two"), function() end)
local first_error
local cached_error
resolver.resolve_notes_async({ target = "Failure" }, resolution_context("/vault/two"), function(_, err)
  first_error = err
end)
resolver.resolve_notes_async({ target = "Failure" }, resolution_context("/vault/two"), function(_, err)
  cached_error = err
end)
test.assert_true(vim.wait(1000, function()
  return request_count == 3 and cached_error ~= nil
end, 10), "asynchronous resolution requests should complete")
package.loaded["obsidian.search"] = original_search
_G.Obsidian = original_obsidian
test.assert_true(request_count == 3, "resolution requests should share within, but not across, source directories")
test.assert_true(first_error and first_error:find("resolution failed", 1, true), "initial failures should reach waiters")
test.assert_true(cached_error == first_error, "cached requests should preserve the original resolver error")

local providers = require("obsidian-embed.providers")
local sync_error
providers.render_async({ name = "empty_sync", render_async = function(_, _, done) done() end }, {}, {}, function(_, err)
  sync_error = err
end)
test.assert_true(sync_error and sync_error:find("returned no result", 1, true),
  "synchronous empty provider completions should become validation errors")
local async_error
providers.render_async({
  name = "empty_async",
  render_async = function(_, _, done) vim.schedule(done) end,
}, {}, {}, function(_, err) async_error = err end)
test.assert_true(vim.wait(1000, function() return async_error ~= nil end, 10)
  and async_error:find("returned no result", 1, true),
  "asynchronous empty provider completions should become validation errors")

print("obsidian embeds context smoke test passed")
