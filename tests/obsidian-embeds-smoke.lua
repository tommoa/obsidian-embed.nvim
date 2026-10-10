-- Run with:
--   nvim --headless -l tests/obsidian-embeds-smoke.lua

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

local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
vim.fn.mkdir(root .. "/.obsidian", "p")

write_file(root .. "/Target.md", {
  "---",
  "id: target",
  "---",
  "Intro line",
  "A [[Wiki target|wiki label]] and [markdown label](Target.md) with `code` and **bold**.",
  "",
  "## Section",
  "Section line",
  "",
  "Block paragraph ^block",
  "",
  "###### 6 ",
  "Level six verse",
})

write_file(root .. "/Nested.md", {
  "before nested",
  "![[Target#Section]]",
  "after nested",
})

vim.fn.mkdir(root .. "/Outer", "p")
vim.fn.mkdir(root .. "/Outer/NestedDir", "p")
write_file(root .. "/Outer/Parent.md", {
  "parent before",
  "![[./NestedDir/Child]]",
  "parent after",
})

write_file(root .. "/Outer/NestedDir/Child.md", {
  "child relative body",
})

write_file(root .. "/NestedProvider.md", { "- ![[Width.provider]]" })
write_file(root .. "/MainNestedProvider.md", { "  - ![[NestedProvider]]" })
write_file(root .. "/NestedProviderCap.md", { "before", "![[Width.provider]]", "after" })
write_file(root .. "/MainNestedProviderCap.md", { "![[NestedProviderCap]]", "![[PlainAlias]]" })
write_file(root .. "/MainDirectProviderCap.md", { "![[Width.provider]]", "![[PlainAlias]]" })

write_file(root .. "/CacheOuter.md", {
  "before cache inner",
  "![[CacheInner]]",
  "after cache inner",
})

write_file(root .. "/CacheInner.md", {
  "cache inner initial",
})

write_file(root .. "/Trimmed.md", {
  "",
  "",
  "Trim first",
  "",
  "Trim last",
  "",
})

write_file(root .. "/AliasNote.md", {
  "# Original Heading",
  "Alias body remains",
  "## Child Heading",
})

write_file(root .. "/PlainAlias.md", {
  "Plain first line",
  "Plain body remains",
})

write_file(root .. "/Empty.md", {})

write_file(root .. "/OrderedFirst.md", {
  "first ordered body",
})

write_file(root .. "/OrderedSecond.md", {
  "second ordered body",
})

write_file(root .. "/CycleA.md", { "![[CycleB]]" })
write_file(root .. "/CycleB.md", { "![[CycleA]]" })
for depth = 1, 10 do
  local lines = { "depth " .. depth .. " body" }
  if depth < 10 then lines[#lines + 1] = "![[Depth" .. (depth + 1) .. "]]" end
  write_file(root .. "/Depth" .. depth .. ".md", lines)
end
write_file(root .. "/image.png", { "not really a png" })
write_file(root .. "/IgnoredChild.md", { "rendered ignored-child body" })
write_file(root .. "/IgnoredNested.md", {
  "![[image.png]]",
  "before ![[image.png]] after",
  "![[https://example.com/image.png]]",
  "mixed ![[IgnoredChild]] and ![[image.png]] tail",
})
write_file(root .. "/MainIgnoredNested.md", { "![[IgnoredNested]]" })
write_file(root .. "/Main.md", {
  "![[Target]]",
  "![[Target#Section]]",
  "![[Target#6|Verse 6 Alias]]",
  "![[Target#Section#6|Nested Verse Alias]]",
  "![[Target#^block]]",
  "![[Nested]]",
  "![[Outer/Parent]]",
  "![[Trimmed]]",
  "![[AliasNote|Display Alias]]",
  "![[PlainAlias|Ignored Alias]]",
  "![[Missing]]",
  "![[Empty]]",
  "![[image.png]]",
  "![[CycleA]]",
  "![[Depth1]]",
  "![[OrderedSecond]] ![[OrderedFirst]]",
  "![[OrderedSecond]]",
  "![[OrderedFirst]]",
  "- ![[PlainAlias]]",
  "  - ![[PlainAlias]]",
  "- [ ] ![[PlainAlias]]",
  "> ![[PlainAlias]]",
  "- Intro ![[PlainAlias]]",
  "After ordered embeds",
  "",
  "| Note | Status |",
  "| --- | --- |",
  "| ![[PlainAlias]] | ready |",
  "",
  "Local block text ^local",
  "![[#^local]]",
})

write_file(root .. "/MainNoLocal.md", {
  "Plain before",
  "![[Target#Section]]",
  "![[Target#^block]]",
  "Plain after",
  "Not an embed yet",
})

write_file(root .. "/MainHtml.md", {
  "HTML boundary placeholder",
  "![[Target#Section]]",
  "</div>",
})

write_file(root .. "/MainHtmlBlank.md", {
  "<div>",
  "",
  "![[Target#Section]]",
})

write_file(root .. "/MainCodeSpan.md", {
  "`opening code span",
  "![[Target#Section]]",
  "closing text",
})

write_file(root .. "/MainBlockContext.md", {
  "- item",
  "",
  "    ![[Target#Section]]",
})

write_file(root .. "/BoundarySelf.md", {
  "# Boundary Section",
  "Boundary original line",
  "## Boundary Next",
  "Boundary next line",
  "![[#Boundary Section]]",
})

write_file(root .. "/NamedSelf.md", {
  "# Named Section",
  "Named original line",
  "## Named Next",
  "Named next line",
  "![[NamedSelf#Named Section]]",
})

write_file(root .. "/MainCache.md", {
  "![[CacheOuter]]",
  "![[CacheOuter]]",
})

write_file(root .. "/MainError.md", {
  "![[Explode]]",
  "![[ErrorAfter]]",
})

write_file(root .. "/ErrorAfter.md", {
  "after error body",
})

write_file(root .. "/MainNestedAnalysis.md", {
  "![[NestedAnalysisTarget]]",
})

write_file(root .. "/NestedAnalysisTarget.md", {
  "nested parser recovery body",
})

write_file(root .. "/MainManualCreate.md", {
  "![[CreatedLater]]",
})

write_file(root .. "/MainExternalCreate.md", {
  "![[CreatedOutsideObserver]]",
})

local long_embed_line = "A deliberately long embedded line " .. string.rep("wrap-me ", 19) .. "wrap-me"
write_file(root .. "/Long.md", { long_embed_line })
write_file(root .. "/MainLong.md", { "![[Long]]" })

vim.fn.mkdir(root .. "/RelativeMissing", "p")
write_file(root .. "/RelativeMissing/Main.md", {
  "![[./Later]]",
})

require("obsidian").setup {
  legacy_commands = false,
  workspaces = {
    {
      name = "smoke",
      path = root,
    },
  },
  ui = {
    enable = false,
  },
}

vim.cmd.edit(root .. "/Main.md")
local bufnr = vim.api.nvim_get_current_buf()
vim.b[bufnr].obsidian_buffer = true
vim.wo.wrap = false
vim.api.nvim_win_set_cursor(0, { 1, 0 })

local embeds = require("obsidian-embed")
embeds.setup()
testlib.wait_complete(embeds, bufnr)

local ns = require("obsidian-embed.config").ns_id
local marks = testlib.projected_marks(bufnr)

-- Scenario: collect rendered virtual lines and their source-row ownership.
local rendered = {}
local rendered_chunks = {}
local rendered_by_row = {}
local rendered_chunk_lines_by_row = {}
local rendered_overlay_by_row = {}
local image_row
local empty_row
local block_row
local local_block_row
local aliased_heading_row
local nested_heading_row
local target_row
local section_row
local nested_row
local relative_nested_row
local trimmed_row
local alias_note_row
local plain_alias_row
local multi_embed_row
local ordered_anchor_row
local ordered_second_row
local ordered_first_row
local list_embed_row
local nested_list_embed_row
local task_embed_row
local quote_embed_row
local mixed_list_embed_row
local table_embed_row
local local_block_definition_row

for row, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
  if line == "![[Target]]" then
    target_row = row - 1
  elseif line == "![[Target#Section]]" then
    section_row = row - 1
  elseif line == "![[image.png]]" then
    image_row = row - 1
  elseif line == "![[Empty]]" then
    empty_row = row - 1
  elseif line == "![[Target#6|Verse 6 Alias]]" then
    aliased_heading_row = row - 1
  elseif line == "![[Target#Section#6|Nested Verse Alias]]" then
    nested_heading_row = row - 1
  elseif line == "![[Target#^block]]" then
    block_row = row - 1
  elseif line == "![[Nested]]" then
    nested_row = row - 1
  elseif line == "![[Outer/Parent]]" then
    relative_nested_row = row - 1
  elseif line == "![[Trimmed]]" then
    trimmed_row = row - 1
  elseif line == "![[AliasNote|Display Alias]]" then
    alias_note_row = row - 1
  elseif line == "![[PlainAlias|Ignored Alias]]" then
    plain_alias_row = row - 1
  elseif line == "![[OrderedSecond]] ![[OrderedFirst]]" then
    multi_embed_row = row - 1
  elseif line == "![[OrderedSecond]]" then
    ordered_second_row = row - 1
  elseif line == "![[OrderedFirst]]" then
    ordered_first_row = row - 1
  elseif line == "- ![[PlainAlias]]" then
    list_embed_row = row - 1
  elseif line == "  - ![[PlainAlias]]" then
    nested_list_embed_row = row - 1
  elseif line == "- [ ] ![[PlainAlias]]" then
    task_embed_row = row - 1
  elseif line == "> ![[PlainAlias]]" then
    quote_embed_row = row - 1
  elseif line == "- Intro ![[PlainAlias]]" then
    mixed_list_embed_row = row - 1
  elseif line == "After ordered embeds" then
    ordered_anchor_row = row - 1
  elseif line == "| ![[PlainAlias]] | ready |" then
    table_embed_row = row - 1
  elseif line == "![[#^local]]" then
    local_block_row = row - 1
  elseif line == "Local block text ^local" then
    local_block_definition_row = row - 1
  end
end

local function append_rendered_line(row, chunks, overlay)
  local rendered_line = {}
  for _, chunk in ipairs(chunks) do
    rendered_line[#rendered_line + 1] = chunk[1]
    rendered_chunks[#rendered_chunks + 1] = chunk
  end
  local line_text = table.concat(rendered_line, "")
  rendered[#rendered + 1] = line_text
  rendered_by_row[row][#rendered_by_row[row] + 1] = line_text
  rendered_chunk_lines_by_row[row][#rendered_chunk_lines_by_row[row] + 1] = chunks
  if overlay then
    rendered_overlay_by_row[row] = line_text
  end
end

local function collect_rendered(extmarks)
  rendered = {}
  rendered_chunks = {}
  rendered_by_row = {}
  rendered_chunk_lines_by_row = {}
  rendered_overlay_by_row = {}

  for _, mark in ipairs(extmarks) do
    local row = mark[2]
    local details = mark[4]
    rendered_by_row[row] = rendered_by_row[row] or {}
    rendered_chunk_lines_by_row[row] = rendered_chunk_lines_by_row[row] or {}
    if details.virt_text then
      append_rendered_line(row, details.virt_text, true)
    end
    for _, virt_line in ipairs(details.virt_lines or {}) do
      append_rendered_line(row, virt_line, false)
    end
  end
end

collect_rendered(marks)

local function assert_chunk(text, hl_group, message)
  for _, chunk in ipairs(rendered_chunks) do
    if chunk[1]:find(text, 1, true) and chunk[2] == hl_group then
      return
    end
  end
  fail(message .. "\nexpected highlighted chunk: " .. text .. " @ " .. hl_group)
end

local function has_conceal_on_row(extmarks, row)
  for _, mark in ipairs(extmarks) do
    local details = mark[4]
    if mark[2] == row and details.conceal == "" then
      return true
    end
  end
  return false
end

local function has_conceal_lines_on_row(extmarks, row)
  for _, mark in ipairs(extmarks) do
    local details = mark[4]
    if mark[2] == row and details.conceal_lines == "" then
      return true
    end
  end
  return false
end

local function overlay_text_on_row(extmarks, row)
  for _, mark in ipairs(extmarks) do
    local details = mark[4]
    if mark[2] == row and details.virt_text then
      local parts = {}
      for _, chunk in ipairs(details.virt_text) do
        parts[#parts + 1] = chunk[1]
      end
      return table.concat(parts, "")
    end
  end
  return nil
end

local function has_virt_lines_above_with_text(extmarks, row, text)
  for _, mark in ipairs(extmarks) do
    local details = mark[4]
    if mark[2] == row and details.virt_lines_above then
      for _, virt_line in ipairs(details.virt_lines or {}) do
        local parts = {}
        for _, chunk in ipairs(virt_line) do
          parts[#parts + 1] = chunk[1]
        end
        if table.concat(parts, ""):find(text, 1, true) then
          return true
        end
      end
    end
  end
  return false
end

local function virt_lines_above_text_on_row(extmarks, row)
  local lines = {}
  for _, mark in ipairs(extmarks) do
    local details = mark[4]
    if mark[2] == row and details.virt_lines_above then
      for _, virt_line in ipairs(details.virt_lines or {}) do
        local parts = {}
        for _, chunk in ipairs(virt_line) do
          parts[#parts + 1] = chunk[1]
        end
        lines[#lines + 1] = table.concat(parts, "")
      end
    end
  end
  return table.concat(lines, "\n")
end

local function assert_extmark_display_options(extmarks)
  local saw_virt_lines = false
  local saw_conceal = false
  for _, mark in ipairs(extmarks) do
    local details = mark[4]
    if details.virt_lines then
      saw_virt_lines = true
      assert_true(details.priority == 110, "virt_lines extmark should use internal priority policy")
      assert_true(details.virt_lines_overflow == "trunc", "virt_lines extmark should use internal overflow policy")
      assert_true(details.virt_lines_leftcol == false, "virt_lines extmark should use internal left-column policy")
    end
    if details.conceal == "" or details.conceal_lines == "" then
      saw_conceal = true
    end
  end
  assert_true(saw_virt_lines, "expected at least one rendered virt_lines extmark")
  assert_true(saw_conceal, "expected at least one conceal extmark")
end

local function source_render_text(extmarks, row)
  local lines = {}
  for _, mark in ipairs(extmarks) do
    local details = mark[4]
    if mark[2] == row and details.virt_lines and not details.virt_lines_above then
      for _, virt_line in ipairs(details.virt_lines) do
        local parts = {}
        for _, chunk in ipairs(virt_line) do
          parts[#parts + 1] = chunk[1]
        end
        lines[#lines + 1] = table.concat(parts, "")
      end
    end
  end
  return table.concat(lines, "\n")
end

local function marks_with_cursor_on_buf(buffer, row)
  if vim.api.nvim_get_current_buf() ~= buffer then
    vim.api.nvim_win_set_buf(0, buffer)
  end
  vim.api.nvim_win_set_cursor(0, { row + 1, 0 })
  vim.cmd("doautocmd <nomodeline> CursorMoved")
  return testlib.projected_marks(buffer)
end

local function marks_with_cursor_on(row)
  return marks_with_cursor_on_buf(bufnr, row)
end

local function assert_nested_heading_marker()
  for _, row_lines in pairs(rendered_chunk_lines_by_row) do
    for _, virt_line in ipairs(row_lines) do
      local rail_count = 0
      local has_heading = false
      for _, chunk in ipairs(virt_line) do
        if chunk[1]:find("│", 1, true) and chunk[2] == "ObsidianEmbedRail" then
          rail_count = rail_count + 1
        elseif chunk[1]:find("## Section", 1, true) and chunk[2] == "@markup.heading.2" then
          has_heading = true
        end
      end
      if rail_count >= 2 and has_heading then
        return
      end
    end
  end
  fail("nested embed should render nested rails while preserving heading highlight")
end

local function without_outer_rail(text)
  return (text:gsub("^%s*│%s?", ""))
end

assert_extmark_display_options(marks)
local rendered_text = table.concat(rendered, "\n")

-- Scenario: whole-note, heading, block, nested, and same-note embeds render
-- the same note slices Obsidian would expose, with frontmatter hidden by default.
assert_contains(rendered_text, "Intro line", "whole-note embed did not render body")
assert_true(not rendered_text:find("id: target", 1, true), "frontmatter should be hidden")
assert_contains(rendered_text, "## Section", "heading embed did not include heading")
assert_contains(rendered_text, "Section line", "heading embed did not include content")
assert_contains(rendered_text, "###### 6", "level-six heading embed did not include heading")
assert_contains(rendered_text, "Level six verse", "level-six heading embed did not include content")
assert_chunk("## Section", "@markup.heading.2", "heading was not highlighted with Tree-sitter")
assert_chunk("###### Verse 6 Alias", "@markup.heading.6", "aliased level-six heading was not highlighted with Tree-sitter")
local aliased_heading_text = source_render_text(marks_with_cursor_on(aliased_heading_row), aliased_heading_row)
assert_contains(aliased_heading_text, "###### Verse 6 Alias", "heading alias did not replace rendered heading")
assert_true(not aliased_heading_text:find("###### 6", 1, true), "original heading should be replaced by alias in rendered heading")
local nested_heading_text = source_render_text(marks_with_cursor_on(nested_heading_row), nested_heading_row)
assert_contains(nested_heading_text, "###### Nested Verse Alias", "nested heading anchor should resolve through the full parent chain")
assert_contains(nested_heading_text, "Level six verse", "nested heading anchor should render the linked section content")
assert_chunk("wiki label", "@markup.link.label", "wiki link label was not highlighted with Tree-sitter")
assert_chunk("markdown label", "@markup.link.label", "markdown link label was not highlighted with Tree-sitter")
assert_chunk("Target.md", "@markup.link.url", "markdown link target was not highlighted with Tree-sitter")
assert_chunk("`code`", "@markup.raw", "inline code was not highlighted with Tree-sitter")
assert_chunk("**bold**", "@markup.strong", "bold text was not highlighted with Tree-sitter")
assert_contains(rendered_text, "Block paragraph", "block embed did not render paragraph")
local block_text = source_render_text(marks_with_cursor_on(block_row), block_row)
assert_true(not block_text:find("^block", 1, true), "block id should be stripped")
assert_contains(rendered_text, "Local block text", "same-note block embed did not render")
local local_block_text = source_render_text(marks_with_cursor_on(local_block_row), local_block_row)
assert_true(not local_block_text:find("^local", 1, true), "same-note block id should be stripped")
assert_contains(rendered_text, "before nested", "nested note did not render")
assert_nested_heading_marker()

-- Scenario: relative refs inside nested embeds resolve from the embedded note's
-- directory, not the original buffer's directory.
local relative_nested_text = source_render_text(marks_with_cursor_on(relative_nested_row), relative_nested_row)
assert_contains(relative_nested_text, "child relative body", "nested relative embed should resolve from embedded note directory")
assert_true(
  not relative_nested_text:find("Embed not found: ./NestedDir/Child", 1, true),
  "nested relative embed should not resolve from the outer note directory"
)
local trimmed_text = source_render_text(marks_with_cursor_on(trimmed_row), trimmed_row)
local trimmed_lines = vim.split(trimmed_text, "\n", { plain = true })
assert_true(without_outer_rail(trimmed_lines[1]) == "Trim first", "leading blank lines should be trimmed from rendered embeds")
assert_true(without_outer_rail(trimmed_lines[#trimmed_lines]) == "Trim last", "trailing blank lines should be trimmed from rendered embeds")
assert_true(without_outer_rail(trimmed_lines[2]) == "", "internal blank lines should be preserved when trimming rendered embeds")

-- Scenario: embed aliases replace only the first rendered heading and never
-- mutate the source note on disk.
local alias_note_text = source_render_text(marks_with_cursor_on(alias_note_row), alias_note_row)
assert_contains(alias_note_text, "# Display Alias", "whole-note alias should replace an initial heading")
assert_contains(alias_note_text, "Alias body remains", "whole-note alias should preserve body content")
assert_contains(alias_note_text, "## Child Heading", "whole-note alias should only replace the first heading")
assert_true(not alias_note_text:find("# Original Heading", 1, true), "original heading should be replaced by whole-note alias")
local alias_note_file = table.concat(vim.fn.readfile(root .. "/AliasNote.md"), "\n")
assert_contains(alias_note_file, "# Original Heading", "whole-note alias should not modify note contents")
local plain_alias_text = source_render_text(marks_with_cursor_on(plain_alias_row), plain_alias_row)
assert_contains(plain_alias_text, "Plain first line", "whole-note alias should not alter non-heading note bodies")
assert_true(not plain_alias_text:find("Ignored Alias", 1, true), "whole-note alias should only apply to initial headings")

-- Scenario: render order follows source order for same-line embeds and for
-- consecutive exact embed lines that are grouped into one concealed run.
local multi_embed_lines = vim.split(source_render_text(marks_with_cursor_on(multi_embed_row), multi_embed_row), "\n", { plain = true })
assert_true(
  without_outer_rail(multi_embed_lines[1]) == "second ordered body",
  "first same-line embed should render first: " .. table.concat(multi_embed_lines, " | ")
)
assert_true(
  without_outer_rail(multi_embed_lines[2]) == "first ordered body",
  "second same-line embed should render second: " .. table.concat(multi_embed_lines, " | ")
)
assert_true(
  without_outer_rail(overlay_text_on_row(marks, ordered_second_row) or "") == "second ordered body",
  "first consecutive embed should replace its own source row"
)
assert_true(
  without_outer_rail(overlay_text_on_row(marks, ordered_first_row) or "") == "first ordered body",
  "second consecutive embed should replace its own source row"
)
assert_true(
  overlay_text_on_row(marks, list_embed_row) == "│ Plain first line",
  "list-only embed should replace the token after the retained bullet"
)
assert_contains(
  source_render_text(marks, list_embed_row),
  "  │ Plain body remains",
  "list embed continuations should align beneath list content"
)
assert_contains(
  source_render_text(marks, nested_list_embed_row),
  "    │ Plain body remains",
  "nested list embed continuations should preserve indentation"
)
assert_true(
  (overlay_text_on_row(marks, table_embed_row) or ""):find("Plain first", 1, true) ~= nil,
  "table embed should render a compact preview on its source row"
)
assert_true(
  source_render_text(marks, table_embed_row) == "" and not has_conceal_on_row(marks, table_embed_row),
  "table embed should leave the row and other cells in place"
)
-- Source edits clear installed table overlays before the debounced generation
-- settles, even if the next character arrives and resets that debounce.
local presenter = require("obsidian-embed.presenter")
presenter.request_redraw(bufnr)
local table_namespace = vim.api.nvim_get_namespaces()["obsidian-embed.window." .. vim.api.nvim_get_current_win()]
local function installed_table_preview()
  if not table_namespace then return nil end
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, table_namespace, { table_embed_row, 0 }, { table_embed_row + 1, 0 }, { details = true })) do
    if mark[4].virt_text then return mark end
  end
end
assert_true(vim.wait(1000, function() return installed_table_preview() ~= nil end, 10), "table preview should be installed")
local source_before_edit = vim.api.nvim_buf_get_lines(bufnr, table_embed_row, table_embed_row + 1, false)[1]
local generation_before_edit = embeds.inspect(bufnr).generation
local policy = require("obsidian-embed.policy")
local previous_debounce = policy.debounce_ms
policy.debounce_ms = 250
local redraw_calls, original_request_redraw = 0, presenter.request_redraw
presenter.request_redraw = function(...)
  redraw_calls = redraw_calls + 1
  return original_request_redraw(...)
end
local unrelated_row = ordered_anchor_row
local unrelated_line = vim.api.nvim_buf_get_lines(bufnr, unrelated_row, unrelated_row + 1, false)[1]
vim.api.nvim_buf_set_lines(bufnr, unrelated_row, unrelated_row + 1, false, { unrelated_line .. " edited" })
assert_true(redraw_calls == 0, "same-line edit above a table should wait for debounced refresh")
vim.api.nvim_buf_set_lines(bufnr, unrelated_row, unrelated_row + 1, false, { unrelated_line })
vim.api.nvim_buf_set_lines(bufnr, table_embed_row, table_embed_row + 1, false, { "| ![[New]] | ready |" })
assert_true(redraw_calls > 0, "editing a table row should request prompt presentation sync")
presenter.request_redraw = original_request_redraw
assert_true(vim.wait(100, function() return installed_table_preview() == nil end, 5), "source edit should clear stale table overlay promptly")
assert_true(embeds.inspect(bufnr).generation == generation_before_edit, "overlay should clear before source refresh")
vim.api.nvim_buf_set_lines(bufnr, table_embed_row, table_embed_row + 1, false, { source_before_edit })
policy.debounce_ms = previous_debounce
testlib.wait_refresh(embeds, bufnr, generation_before_edit)
assert_true(
  overlay_text_on_row(marks, task_embed_row) == "│ Plain first line",
  "task embed should replace only the token after its checkbox"
)
assert_contains(
  source_render_text(marks, task_embed_row),
  "      │ Plain body remains",
  "task embed continuations should align beneath task content"
)
assert_contains(
  source_render_text(marks, quote_embed_row),
  "> │ Plain body remains",
  "quoted embed continuations should repeat the quote marker"
)
assert_true(overlay_text_on_row(marks, mixed_list_embed_row) == nil, "mixed list content should retain its source line")
assert_contains(
  source_render_text(marks, mixed_list_embed_row),
  "  │ Plain first line",
  "mixed list embeds should render beneath the retained item text"
)
assert_contains(rendered_text, "Embed not found: Missing", "missing embed warning did not render")
assert_contains(rendered_text, "Embed skipped: recursion limit reached", "recursive embed guard did not render")
assert_contains(rendered_text, "depth 8 body", "maximum-depth nesting should render through the configured boundary")
assert_true(not rendered_text:find("depth 9 body", 1, true), "nesting beyond the maximum depth must not resolve")

-- Scenario: image/attachment embeds are ignored by this note renderer.
assert_true(not has_conceal_on_row(marks, image_row), "image embed should not get source conceal")
assert_true(not has_conceal_lines_on_row(marks, image_row), "image embed should not get line conceal")
assert_true(source_render_text(marks, image_row) == "", "image embed should not get rendered note lines")

vim.cmd.edit(root .. "/MainIgnoredNested.md")
local ignored_nested_bufnr = vim.api.nvim_get_current_buf()
vim.b[ignored_nested_bufnr].obsidian_buffer = true
embeds.setup()
testlib.wait_complete(embeds, ignored_nested_bufnr)
local ignored_nested_text = source_render_text(marks_with_cursor_on_buf(ignored_nested_bufnr, 0), 0)
assert_contains(ignored_nested_text, "![[image.png]]", "nested attachment-only lines should remain literal")
assert_contains(ignored_nested_text, "before ![[image.png]] after", "mixed attachment markup should remain literal")
assert_contains(
  ignored_nested_text,
  "![[https://example.com/image.png]]",
  "nested URI embeds should remain literal"
)
assert_contains(ignored_nested_text, "mixed  and ![[image.png]] tail", "note rendering should preserve adjacent attachments")
assert_contains(ignored_nested_text, "rendered ignored-child body", "note refs beside attachments should still render")

-- Providers must never see URI or attachment refs, even when their matcher
-- would claim them. Exercise both row dispatch and recursive note rendering.
do
  local matched, provider_renders = {}, {}
  local ignored_targets = { ["image.png"] = true, ["https://example.com/image.png"] = true }
  local unregister = embeds.register_provider({
    name = "smoke_ignored_refs",
    match = function(ref)
      matched[ref.target] = true
      return ignored_targets[ref.target] or ref.target == "Allowed.provider" or ref.target == "IgnoredChild"
    end,
    render_async = function(ref, _, done)
      provider_renders[ref.target] = true
      done({ project = function()
        return { { { "provider body: " .. ref.target, "Normal" } } }
      end })
    end,
  })
  write_file(root .. "/MainIgnoredProviders.md", {
    "![[image.png]]",
    "![[https://example.com/image.png]]",
    "mixed ![[Allowed.provider]] and ![[image.png]] tail",
    "![[IgnoredNested]]",
  })
  vim.cmd.edit(root .. "/MainIgnoredProviders.md")
  local provider_bufnr = vim.api.nvim_get_current_buf()
  vim.b[provider_bufnr].obsidian_buffer = true
  embeds.setup()
  testlib.wait_complete(embeds, provider_bufnr)
  local provider_marks = marks_with_cursor_on_buf(provider_bufnr, 2)
  for target in pairs(ignored_targets) do
    assert_true(not matched[target], "ignored ref should be excluded before provider matching: " .. target)
  end
  assert_true(provider_renders["Allowed.provider"], "eligible top-level refs should still reach providers")
  assert_true(provider_renders.IgnoredChild, "eligible nested refs should still reach providers")
  for row = 0, 1 do
    assert_true(not has_conceal_on_row(provider_marks, row), "ignored source should remain visible to the user")
    assert_true(source_render_text(provider_marks, row) == "", "ignored refs should not produce provider blocks")
  end
  assert_contains(source_render_text(provider_marks, 2), "provider body: Allowed.provider",
    "top-level providers should render beside ignored attachments")
  local nested_text = source_render_text(provider_marks, 3)
  assert_contains(nested_text, "![[image.png]]", "nested attachment source should remain literal with providers registered")
  assert_contains(nested_text, "![[https://example.com/image.png]]",
    "nested URI source should remain literal with providers registered")
  assert_contains(nested_text, "provider body: IgnoredChild", "nested providers should render beside ignored attachments")
  unregister()
end

-- Scenario: an empty note remains editable instead of disappearing without a replacement.
assert_true(not has_conceal_on_row(marks, empty_row), "empty embed source should remain visible")
assert_true(overlay_text_on_row(marks, empty_row) == nil, "empty embeds should not create inline replacement text")
assert_true(source_render_text(marks, empty_row) == "", "empty embeds should not create virtual continuation lines")

-- Scenario: source conceal is cursor-sensitive. The current source line remains
-- visible, while exact embed tokens away from the cursor are replaced inline.
marks = marks_with_cursor_on(target_row)
assert_true(not has_conceal_on_row(marks, target_row), "source link should remain visible on the cursor line")
assert_true(not has_conceal_lines_on_row(marks, target_row), "source line should remain visible on the cursor line")
assert_true(
  has_conceal_on_row(marks, section_row),
  "standalone embed token should be concealed away from the cursor line"
)
assert_true(
  (overlay_text_on_row(marks, section_row) or ""):find("## Section", 1, true) ~= nil,
  "hidden standalone source should be replaced by its first rendered line"
)
local cursor_generation = embeds.inspect(bufnr).generation
vim.api.nvim_win_set_cursor(0, { section_row + 1, 0 })
vim.cmd("doautocmd <nomodeline> CursorMoved")
local moved_marks = testlib.projected_marks(bufnr)
assert_true(embeds.inspect(bufnr).generation == cursor_generation, "cursor movement should not start a render generation")
assert_true(has_conceal_on_row(moved_marks, target_row), "source token should be concealed after the cursor leaves it")
assert_true(not has_conceal_on_row(moved_marks, section_row), "source link should be revealed after the cursor moves to its line")
assert_true(not has_conceal_lines_on_row(moved_marks, section_row), "source line should be revealed after the cursor moves to it")
assert_true((overlay_text_on_row(moved_marks, target_row) or ""):find("Intro line", 1, true) ~= nil, "newly hidden source should render inline")
assert_contains(source_render_text(moved_marks, section_row), "## Section", "newly visible source should render below the source line")

-- Scenario: incremental refresh rerenders only changed embed rows when the edit
-- does not alter line count or same-note structure.
vim.cmd.edit(root .. "/MainNoLocal.md")
local no_local_bufnr = vim.api.nvim_get_current_buf()
vim.b[no_local_bufnr].obsidian_buffer = true
vim.api.nvim_win_set_cursor(0, { 1, 0 })
embeds.setup()
testlib.wait_complete(embeds, no_local_bufnr)

local no_local_section_row
local no_local_block_row
local no_local_plain_row
local no_local_new_embed_row
for row, line in ipairs(vim.api.nvim_buf_get_lines(no_local_bufnr, 0, -1, false)) do
  if line == "![[Target#Section]]" then
    no_local_section_row = row - 1
  elseif line == "![[Target#^block]]" then
    no_local_block_row = row - 1
  elseif line == "Plain before" then
    no_local_plain_row = row - 1
  elseif line == "Not an embed yet" then
    no_local_new_embed_row = row - 1
  end
end

local no_local_block_text = source_render_text(marks_with_cursor_on_buf(no_local_bufnr, no_local_block_row), no_local_block_row)
local function wait_incremental(buffer, previous_revision)
  assert_true(vim.wait(2000, function()
    local current = embeds.inspect(buffer)
    return current.generation == previous_revision + 1 and current.phase == "settled"
  end, 10), "incremental edit did not settle")
end
local revision = embeds.inspect(no_local_bufnr).generation
local analyzer_module = require("obsidian-embed.analyzer")
local original_analyze, largest_analysis = analyzer_module.analyze_buffer, 0
analyzer_module.analyze_buffer = function(buffer, lines)
  largest_analysis = math.max(largest_analysis, #lines)
  return original_analyze(buffer, lines)
end
vim.api.nvim_buf_set_lines(no_local_bufnr, no_local_plain_row, no_local_plain_row + 1, false, { "Plain before changed" })
wait_incremental(no_local_bufnr, revision)
analyzer_module.analyze_buffer = original_analyze
assert_true(
  largest_analysis == #vim.api.nvim_buf_get_lines(no_local_bufnr, 0, -1, false),
  "plain edits should analyze the complete Markdown context"
)
assert_true(
  source_render_text(marks_with_cursor_on_buf(no_local_bufnr, no_local_block_row), no_local_block_row) == no_local_block_text,
  "plain edits should preserve unrelated rendered output"
)

revision = embeds.inspect(no_local_bufnr).generation
vim.api.nvim_buf_set_lines(no_local_bufnr, no_local_section_row, no_local_section_row + 1, false, { "![[Target#6|Incremental Alias]]" })
wait_incremental(no_local_bufnr, revision)
local incremental_section_text = source_render_text(marks_with_cursor_on_buf(no_local_bufnr, no_local_section_row), no_local_section_row)
assert_contains(incremental_section_text, "###### Incremental Alias", "embed edits should update rendered output")
local no_local_block_text_after = source_render_text(marks_with_cursor_on_buf(no_local_bufnr, no_local_block_row), no_local_block_row)
assert_true(no_local_block_text_after == no_local_block_text, "incremental embed edit should leave unrelated rendered rows intact")

revision = embeds.inspect(no_local_bufnr).generation
vim.api.nvim_buf_set_lines(no_local_bufnr, no_local_section_row, no_local_section_row + 1, false, { "No embed here now" })
wait_incremental(no_local_bufnr, revision)
local removed_embed_marks = marks_with_cursor_on_buf(no_local_bufnr, no_local_section_row)
assert_true(source_render_text(removed_embed_marks, no_local_section_row) == "", "changing an embed row to plain text should remove rendered output")
assert_true(not has_conceal_on_row(removed_embed_marks, no_local_section_row), "changing an embed row to plain text should remove conceal marks")
assert_true(not has_conceal_lines_on_row(removed_embed_marks, no_local_section_row), "changing an embed row to plain text should remove line conceal marks")

revision = embeds.inspect(no_local_bufnr).generation
vim.api.nvim_buf_set_lines(no_local_bufnr, no_local_new_embed_row, no_local_new_embed_row + 1, false, { "![[Target#Section]]" })
wait_incremental(no_local_bufnr, revision)
local added_embed_text = source_render_text(marks_with_cursor_on_buf(no_local_bufnr, no_local_new_embed_row), no_local_new_embed_row)
assert_contains(added_embed_text, "## Section", "changing plain text to an embed should render the new embed")

-- Scenario: changing an HTML block boundary fully reanalyzes stable rows whose
-- Tree-sitter context changes without changing their text or row identity.
vim.cmd.edit(root .. "/MainHtml.md")
local html_bufnr = vim.api.nvim_get_current_buf()
vim.b[html_bufnr].obsidian_buffer = true
vim.api.nvim_win_set_cursor(0, { 2, 0 })
embeds.setup()
testlib.wait_complete(embeds, html_bufnr)
assert_contains(
  source_render_text(marks_with_cursor_on_buf(html_bufnr, 1), 1),
  "## Section",
  "embed before opening an HTML block should initially render"
)

revision = embeds.inspect(html_bufnr).generation
largest_analysis = 0
analyzer_module.analyze_buffer = function(buffer, lines)
  largest_analysis = math.max(largest_analysis, #lines)
  return original_analyze(buffer, lines)
end
vim.api.nvim_buf_set_lines(html_bufnr, 0, 1, false, { "<div>" })
wait_incremental(html_bufnr, revision)
analyzer_module.analyze_buffer = original_analyze
assert_true(largest_analysis == 3, "opening an HTML block should analyze the full source")
assert_true(
  source_render_text(marks_with_cursor_on_buf(html_bufnr, 1), 1) == "",
  "unchanged embeds enclosed by a new HTML block should stop rendering"
)

revision = embeds.inspect(html_bufnr).generation
vim.api.nvim_buf_set_lines(html_bufnr, 0, 1, false, { "HTML boundary placeholder" })
wait_incremental(html_bufnr, revision)
assert_contains(
  source_render_text(marks_with_cursor_on_buf(html_bufnr, 1), 1),
  "## Section",
  "removing an HTML block boundary should restore unchanged embeds"
)

-- Scenario: blank lines are structural Markdown boundaries. Removing the
-- blank after an HTML opener moves an unchanged embed into the HTML block.
vim.cmd.edit(root .. "/MainHtmlBlank.md")
local html_blank_bufnr = vim.api.nvim_get_current_buf()
vim.b[html_blank_bufnr].obsidian_buffer = true
vim.api.nvim_win_set_cursor(0, { 3, 0 })
embeds.setup()
testlib.wait_complete(embeds, html_blank_bufnr)
assert_contains(
  source_render_text(marks_with_cursor_on_buf(html_blank_bufnr, 2), 2),
  "## Section",
  "a blank line should initially terminate the HTML block"
)

revision = embeds.inspect(html_blank_bufnr).generation
largest_analysis = 0
analyzer_module.analyze_buffer = function(buffer, lines)
  largest_analysis = math.max(largest_analysis, #lines)
  return original_analyze(buffer, lines)
end
vim.api.nvim_buf_set_lines(html_blank_bufnr, 1, 2, false, {})
wait_incremental(html_blank_bufnr, revision)
analyzer_module.analyze_buffer = original_analyze
assert_true(largest_analysis == 2, "deleting a blank Markdown boundary should analyze the full source")
assert_true(
  source_render_text(marks_with_cursor_on_buf(html_blank_bufnr, 1), 1) == "",
  "deleting the blank HTML boundary should stop rendering the unchanged embed"
)

revision = embeds.inspect(html_blank_bufnr).generation
vim.api.nvim_buf_set_lines(html_blank_bufnr, 1, 1, false, { "" })
wait_incremental(html_blank_bufnr, revision)
assert_contains(
  source_render_text(marks_with_cursor_on_buf(html_blank_bufnr, 2), 2),
  "## Section",
  "restoring the blank HTML boundary should render the embed again"
)

-- Scenario: completing or reopening a multiline code span fully reanalyzes
-- unchanged rows whose embed syntax enters or leaves the span.
vim.cmd.edit(root .. "/MainCodeSpan.md")
local code_span_bufnr = vim.api.nvim_get_current_buf()
vim.b[code_span_bufnr].obsidian_buffer = true
vim.api.nvim_win_set_cursor(0, { 2, 0 })
embeds.setup()
testlib.wait_complete(embeds, code_span_bufnr)
assert_contains(
  source_render_text(marks_with_cursor_on_buf(code_span_bufnr, 1), 1),
  "## Section",
  "an unmatched backtick should initially leave the embed active"
)

local function replace_code_span_boundary(row, line)
  local previous = embeds.inspect(code_span_bufnr).generation
  vim.api.nvim_buf_set_lines(code_span_bufnr, row, row + 1, false, { line })
  wait_incremental(code_span_bufnr, previous)
end

largest_analysis = 0
analyzer_module.analyze_buffer = function(buffer, lines)
  largest_analysis = math.max(largest_analysis, #lines)
  return original_analyze(buffer, lines)
end
replace_code_span_boundary(2, "closing text`")
analyzer_module.analyze_buffer = original_analyze
assert_true(largest_analysis == 3, "editing a backtick delimiter should analyze the full source")
assert_true(
  source_render_text(marks_with_cursor_on_buf(code_span_bufnr, 1), 1) == "",
  "closing a multiline code span should stop rendering its unchanged embed"
)
replace_code_span_boundary(2, "closing text")
assert_contains(
  source_render_text(marks_with_cursor_on_buf(code_span_bufnr, 1), 1),
  "## Section",
  "removing a multiline code-span closer should restore the embed"
)
replace_code_span_boundary(0, "``opening code span")
replace_code_span_boundary(2, "closing text``")
assert_true(
  source_render_text(marks_with_cursor_on_buf(code_span_bufnr, 1), 1) == "",
  "double-backtick multiline code spans should also keep embeds literal"
)
replace_code_span_boundary(2, "closing text")
assert_contains(
  source_render_text(marks_with_cursor_on_buf(code_span_bufnr, 1), 1),
  "## Section",
  "removing a double-backtick closer should restore the embed"
)

-- Scenario: changing an earlier list marker can reclassify an unchanged row
-- as an indented code block. Full analysis must discard its retained embed.
vim.cmd.edit(root .. "/MainBlockContext.md")
local block_context_bufnr = vim.api.nvim_get_current_buf()
vim.b[block_context_bufnr].obsidian_buffer = true
vim.api.nvim_win_set_cursor(0, { 3, 4 })
embeds.setup()
testlib.wait_complete(embeds, block_context_bufnr)
assert_contains(
  source_render_text(marks_with_cursor_on_buf(block_context_bufnr, 2), 2),
  "## Section",
  "the indented embed should initially belong to the list"
)

revision = embeds.inspect(block_context_bufnr).generation
vim.api.nvim_buf_set_lines(block_context_bufnr, 0, 1, false, { "plain" })
wait_incremental(block_context_bufnr, revision)
assert_true(
  source_render_text(marks_with_cursor_on_buf(block_context_bufnr, 2), 2) == "",
  "changing the list marker should reclassify the unchanged embed as code"
)

revision = embeds.inspect(block_context_bufnr).generation
vim.api.nvim_buf_set_lines(block_context_bufnr, 0, 1, false, { "- item" })
wait_incremental(block_context_bufnr, revision)
assert_contains(
  source_render_text(marks_with_cursor_on_buf(block_context_bufnr, 2), 2),
  "## Section",
  "restoring the list marker should reactivate the unchanged embed"
)

vim.api.nvim_buf_set_lines(no_local_bufnr, no_local_new_embed_row, no_local_new_embed_row + 1, false, { "![[Target#6|Attached Alias]]" })
local attached_refresh = vim.wait(1000, function()
  local text = source_render_text(marks_with_cursor_on_buf(no_local_bufnr, no_local_new_embed_row), no_local_new_embed_row)
  return text:find("###### Attached Alias", 1, true) ~= nil
end, 20)
assert_true(attached_refresh, "nvim_buf_attach on_lines should refresh changed embed rows")
vim.api.nvim_buf_set_lines(no_local_bufnr, no_local_new_embed_row, no_local_new_embed_row + 1, false, { "![[Target#Section]]" })
embeds.refresh(no_local_bufnr)
testlib.wait_complete(embeds, no_local_bufnr)

vim.api.nvim_win_set_buf(0, bufnr)
vim.api.nvim_buf_set_lines(bufnr, local_block_definition_row, local_block_definition_row + 1, false, { "Local block changed ^local" })
embeds.refresh(bufnr)
testlib.wait_complete(embeds, bufnr)
assert_contains(
  source_render_text(marks_with_cursor_on_buf(bufnr, local_block_row), local_block_row),
  "Local block changed",
  "editing same-note block content should refresh its embed"
)

-- Scenario: inserting plain text immediately before the next heading refreshes
-- a retained same-note section whose previous inclusive range ended one row earlier.
vim.cmd.edit(root .. "/BoundarySelf.md")
local boundary_self_bufnr = vim.api.nvim_get_current_buf()
vim.b[boundary_self_bufnr].obsidian_buffer = true
embeds.setup()
testlib.wait_complete(embeds, boundary_self_bufnr)
local boundary_next_row, boundary_embed_row
for row, line in ipairs(vim.api.nvim_buf_get_lines(boundary_self_bufnr, 0, -1, false)) do
  if line == "## Boundary Next" then boundary_next_row = row - 1 end
  if line == "![[#Boundary Section]]" then boundary_embed_row = row - 1 end
end
assert_contains(
  source_render_text(marks_with_cursor_on_buf(boundary_self_bufnr, boundary_embed_row), boundary_embed_row),
  "Boundary original line",
  "same-note boundary fixture should render before editing"
)
vim.api.nvim_buf_set_lines(boundary_self_bufnr, boundary_next_row, boundary_next_row, false, { "Boundary inserted line" })
local boundary_refreshed = vim.wait(2000, function()
  local shifted_embed_row = boundary_embed_row + 1
  local text = source_render_text(
    marks_with_cursor_on_buf(boundary_self_bufnr, shifted_embed_row),
    shifted_embed_row
  )
  return text:find("Boundary inserted line", 1, true) ~= nil
end, 20)
assert_true(boundary_refreshed, "inserting at a same-note section boundary should refresh its embed")

-- Scenario: a named reference that resolves back to its origin remains a real
-- dependency and refreshes the origin buffer after its source is written.
vim.cmd.edit(root .. "/NamedSelf.md")
local named_self_bufnr = vim.api.nvim_get_current_buf()
vim.b[named_self_bufnr].obsidian_buffer = true
embeds.setup()
testlib.wait_complete(embeds, named_self_bufnr)
local named_body_row, named_embed_row
for row, line in ipairs(vim.api.nvim_buf_get_lines(named_self_bufnr, 0, -1, false)) do
  if line == "Named original line" then named_body_row = row - 1 end
  if line == "![[NamedSelf#Named Section]]" then named_embed_row = row - 1 end
end
vim.api.nvim_buf_set_lines(named_self_bufnr, named_body_row, named_body_row + 1, false, { "Named changed line" })
vim.cmd.write()
for row, line in ipairs(vim.api.nvim_buf_get_lines(named_self_bufnr, 0, -1, false)) do
  if line == "![[NamedSelf#Named Section]]" then named_embed_row = row - 1; break end
end
local named_self_refreshed = vim.wait(2000, function()
  local text = source_render_text(marks_with_cursor_on_buf(named_self_bufnr, named_embed_row), named_embed_row)
  return text:find("Named changed line", 1, true) ~= nil
end, 20)
assert_true(named_self_refreshed, "writing a named self-reference target should refresh its origin buffer")

-- Scenario: writing a rendered target note refreshes buffers that depend on it.
vim.cmd.edit(root .. "/Target.md")
local target_bufnr = vim.api.nvim_get_current_buf()
local target_lines = vim.api.nvim_buf_get_lines(target_bufnr, 0, -1, false)
for idx, line in ipairs(target_lines) do
  if line == "Section line" then
    vim.api.nvim_buf_set_lines(target_bufnr, idx - 1, idx, false, { "Section line changed by dependency write" })
    break
  end
end
vim.cmd.write()
local dependency_refreshed = vim.wait(1000, function()
  local dep_text = source_render_text(marks_with_cursor_on_buf(no_local_bufnr, no_local_new_embed_row), no_local_new_embed_row)
  return dep_text:find("Section line changed by dependency write", 1, true) ~= nil
end, 20)
assert_true(dependency_refreshed, "writing a target note should refresh buffers that render it")

-- Scenario: render-cache hits still preserve nested dependency tracking.
vim.cmd.edit(root .. "/MainCache.md")
local cache_bufnr = vim.api.nvim_get_current_buf()
vim.b[cache_bufnr].obsidian_buffer = true
vim.api.nvim_win_set_cursor(0, { 1, 0 })
embeds.setup()
testlib.wait_complete(embeds, cache_bufnr)

vim.api.nvim_buf_set_lines(cache_bufnr, 0, 1, false, { "Cache embed removed" })
embeds.refresh(cache_bufnr)
testlib.wait_complete(embeds, cache_bufnr)

vim.cmd.edit(root .. "/CacheInner.md")
local cache_inner_bufnr = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(cache_inner_bufnr, 0, 1, false, { "cache inner changed by dependency write" })
vim.cmd.write()
local cached_nested_dependency_refreshed = vim.wait(1000, function()
  local dep_text = source_render_text(marks_with_cursor_on_buf(cache_bufnr, 1), 1)
  return dep_text:find("cache inner changed by dependency write", 1, true) ~= nil
end, 20)
assert_true(
  cached_nested_dependency_refreshed,
  "cached embeds should preserve nested dependencies after incremental row edits"
)

-- Scenario: a renderer failure in one embed becomes an inline warning and does
-- not stop later embeds in the same buffer.
vim.cmd.edit(root .. "/MainError.md")
local error_bufnr = vim.api.nvim_get_current_buf()
vim.b[error_bufnr].obsidian_buffer = true
vim.api.nvim_win_set_cursor(0, { 1, 0 })
embeds.setup()
testlib.wait_complete(embeds, error_bufnr)
local error_text = source_render_text(marks_with_cursor_on_buf(error_bufnr, 0), 0)
assert_contains(error_text, "Embed not found: Explode", "missing embeds should render inline without stopping the buffer")
local after_error_text = source_render_text(marks_with_cursor_on_buf(error_bufnr, 1), 1)
assert_contains(after_error_text, "after error body", "renderer failure in one embed should not stop later embeds")

-- Scenario: a returned parser failure while analyzing an embedded note is
-- visible, is not cached, and is retried successfully after parser recovery.
local nested_analysis_calls, fail_nested_analysis = 0, true
local original_nested_analyze = analyzer_module.analyze
analyzer_module.analyze = function(lines)
  if lines[1] == "nested parser recovery body" then
    nested_analysis_calls = nested_analysis_calls + 1
    if fail_nested_analysis then return { rows = {}, error = "nested parser unavailable" } end
  end
  return original_nested_analyze(lines)
end
vim.cmd.edit(root .. "/MainNestedAnalysis.md")
local nested_analysis_bufnr = vim.api.nvim_get_current_buf()
vim.b[nested_analysis_bufnr].obsidian_buffer = true
vim.api.nvim_win_set_cursor(0, { 1, 0 })
embeds.setup()
testlib.wait_complete(embeds, nested_analysis_bufnr)
assert_contains(
  source_render_text(marks_with_cursor_on_buf(nested_analysis_bufnr, 0), 0),
  "Embed error: nested parser unavailable",
  "nested parser failures should render as errors rather than literal target text"
)
fail_nested_analysis = false
embeds.refresh(nested_analysis_bufnr)
testlib.wait_complete(embeds, nested_analysis_bufnr)
analyzer_module.analyze = original_nested_analyze
assert_true(nested_analysis_calls == 2, "failed nested analysis should not be cached")
assert_contains(
  source_render_text(marks_with_cursor_on_buf(nested_analysis_bufnr, 0), 0),
  "nested parser recovery body",
  "nested analysis should recover on the next refresh"
)

-- Scenario: unresolved refs are indexed so creating the missing note refreshes
-- existing buffers automatically.
vim.cmd.edit(root .. "/MainManualCreate.md")
local manual_missing_bufnr = vim.api.nvim_get_current_buf()
vim.b[manual_missing_bufnr].obsidian_buffer = true
vim.api.nvim_win_set_cursor(0, { 1, 0 })
embeds.setup()
testlib.wait_complete(embeds, manual_missing_bufnr)
local missing_text = source_render_text(marks_with_cursor_on_buf(manual_missing_bufnr, 0), 0)
assert_contains(missing_text, "Embed not found: CreatedLater", "missing embeds should render a warning")
vim.cmd.edit(root .. "/CreatedLater.md")
vim.api.nvim_buf_set_lines(vim.api.nvim_get_current_buf(), 0, -1, false, { "created later body" })
vim.cmd.write()
local recovered_automatically = vim.wait(1000, function()
  local recovered_text = source_render_text(marks_with_cursor_on_buf(manual_missing_bufnr, 0), 0)
  return recovered_text:find("created later body", 1, true) ~= nil
end, 20)
assert_true(recovered_automatically, "creating a missing target should refresh unresolved embeds")

-- Scenario: manual refresh invalidates cached resolution when observer events
-- miss an out-of-band target creation.
vim.cmd.edit(root .. "/MainExternalCreate.md")
local external_missing_bufnr = vim.api.nvim_get_current_buf()
vim.b[external_missing_bufnr].obsidian_buffer = true
vim.api.nvim_win_set_cursor(0, { 1, 0 })
embeds.setup()
testlib.wait_complete(embeds, external_missing_bufnr)
local external_missing_text = source_render_text(marks_with_cursor_on_buf(external_missing_bufnr, 0), 0)
assert_contains(external_missing_text, "Embed not found: CreatedOutsideObserver", "missing embeds should be cached")
vim.fn.writefile({ "created outside observer body" }, root .. "/CreatedOutsideObserver.md")
embeds.refresh(external_missing_bufnr)
testlib.wait_complete(embeds, external_missing_bufnr)
local external_recovered_text = source_render_text(marks_with_cursor_on_buf(external_missing_bufnr, 0), 0)
assert_contains(
  external_recovered_text,
  "created outside observer body",
  "manual refresh should invalidate cached unresolved embeds"
)

vim.cmd.edit(root .. "/RelativeMissing/Main.md")
local relative_missing_bufnr = vim.api.nvim_get_current_buf()
vim.b[relative_missing_bufnr].obsidian_buffer = true
vim.api.nvim_win_set_cursor(0, { 1, 0 })
embeds.setup()
testlib.wait_complete(embeds, relative_missing_bufnr)
local relative_missing_text = source_render_text(marks_with_cursor_on_buf(relative_missing_bufnr, 0), 0)
assert_contains(relative_missing_text, "Embed not found: ./Later", "missing relative embeds should render a warning")
assert_true(
  not relative_missing_text:find("Embed error", 1, true),
  "missing relative embeds should not raise while resolving"
)
vim.cmd.edit(root .. "/RelativeMissing/Later.md")
vim.api.nvim_buf_set_lines(vim.api.nvim_get_current_buf(), 0, -1, false, { "relative later body" })
vim.cmd.write()
local relative_recovered_automatically = vim.wait(1000, function()
  local recovered_text = source_render_text(marks_with_cursor_on_buf(relative_missing_bufnr, 0), 0)
  return recovered_text:find("relative later body", 1, true) ~= nil
end, 20)
assert_true(relative_recovered_automatically, "creating a missing relative target should refresh unresolved embeds")

-- Scenario: toggling embeds off clears every render/conceal extmark.
vim.api.nvim_win_set_buf(0, bufnr)
assert_true(embeds.toggle(bufnr) == false, "toggle should return disabled state")
local after_toggle = testlib.projected_marks(bufnr)
assert_true(#after_toggle == 0, "toggle should clear embed extmarks")
vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { "![[CreatedLater]]" })
assert_true(embeds.toggle(bufnr) == true, "toggle should return enabled state")
testlib.wait_complete(embeds, bufnr)
assert_contains(
  source_render_text(marks_with_cursor_on_buf(bufnr, 0), 0),
  "created later body",
  "re-enabling should analyze a fresh buffer snapshot"
)

-- Scenario: virtual embed lines follow the active window's wrap option.
vim.cmd.edit(root .. "/MainLong.md")
local long_bufnr = vim.api.nvim_get_current_buf()
vim.b[long_bufnr].obsidian_buffer = true
vim.cmd("setlocal nowrap")
embeds.setup()
testlib.wait_complete(embeds, long_bufnr)

local function rendered_line_count(buffer, winid)
  local count = 0
  for _, mark in ipairs(testlib.projected_marks(buffer, winid)) do
    count = count + #(mark[4].virt_lines or {})
  end
  return count
end

assert_true(rendered_line_count(long_bufnr) == 1, "nowrap should keep a long embed on one virtual line")
vim.cmd("setlocal wrap")
assert_true(rendered_line_count(long_bufnr) > 1, "wrap should reflow a long embed across virtual lines")
local wrapped_parts = {}
for _, line in ipairs(vim.split(testlib.rendered_text(long_bufnr, ns), "\n", { plain = true })) do
  wrapped_parts[#wrapped_parts + 1] = without_outer_rail(line)
end
local wrapped_text = table.concat(wrapped_parts, "")
assert_true(
  wrapped_text == long_embed_line,
  "wrapping should preserve all embedded text\nexpected: " .. vim.inspect(long_embed_line) .. "\nactual: " .. vim.inspect(wrapped_text)
)

-- The same semantic render must reflow independently in differently sized windows.
local wide_win = vim.api.nvim_get_current_win()
vim.cmd("vsplit")
local narrow_win = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_buf(narrow_win, long_bufnr)
vim.api.nvim_set_option_value("wrap", true, { win = wide_win })
vim.api.nvim_set_option_value("wrap", true, { win = narrow_win })
vim.api.nvim_win_set_width(wide_win, 52)
local wide_count = rendered_line_count(long_bufnr, wide_win)
local narrow_count = rendered_line_count(long_bufnr, narrow_win)
assert_true(narrow_count > wide_count, "narrow and wide windows should project different wrap counts")
local function projected_text(winid)
  local parts = {}
  for _, mark in ipairs(testlib.projected_marks(long_bufnr, winid)) do
    for _, virt_line in ipairs(mark[4].virt_lines or {}) do
      local text = ""
      for _, chunk in ipairs(virt_line) do text = text .. chunk[1] end
      parts[#parts + 1] = without_outer_rail(text)
    end
  end
  return table.concat(parts, "")
end
assert_true(projected_text(wide_win) == long_embed_line, "wide-window wrapping should preserve text")
assert_true(projected_text(narrow_win) == long_embed_line, "narrow-window wrapping should preserve text")
vim.api.nvim_win_close(narrow_win, true)
vim.api.nvim_set_current_win(wide_win)

-- A nested provider must receive the text width of each host window after
-- both the outer list and the nested list have reserved their prefixes.
local projected_provider_widths = {}
local unregister_width_provider = embeds.register_provider({
  name = "smoke_nested_width",
  match = function(ref) return ref.target == "Width.provider" end,
  render_async = function(_, _, done)
    done({ project = function(width)
      projected_provider_widths[#projected_provider_widths + 1] = width
      return { { { "nested width " .. width, "Normal" } } }
    end })
  end,
})
vim.cmd.edit(root .. "/MainNestedProvider.md")
local nested_provider_bufnr = vim.api.nvim_get_current_buf()
vim.b[nested_provider_bufnr].obsidian_buffer = true
embeds.setup()
testlib.wait_complete(embeds, nested_provider_bufnr)
vim.cmd("vsplit")
local nested_narrow_win = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_buf(nested_narrow_win, nested_provider_bufnr)
vim.api.nvim_win_set_width(wide_win, 52)
local function nested_provider_width(winid)
  local before = #projected_provider_widths
  local marks = testlib.projected_marks(nested_provider_bufnr, winid)
  assert_true(#projected_provider_widths > before, "nested provider should project for each host window")
  local width = projected_provider_widths[#projected_provider_widths]
  local text = ""
  for _, mark in ipairs(marks) do
    for _, chunk in ipairs(mark[4].virt_text or {}) do text = text .. chunk[1] end
    for _, line in ipairs(mark[4].virt_lines or {}) do
      for _, chunk in ipairs(line) do text = text .. chunk[1] end
    end
  end
  assert_contains(text, "nested width " .. width, "nested provider output should reflect its host width")
  local available = vim.api.nvim_win_get_width(winid)
  if not require("obsidian-embed.config").get().virt_lines_leftcol then
    available = available - (vim.fn.getwininfo(winid)[1].textoff or 0)
  end
  local rail_width = vim.fn.strdisplaywidth(require("obsidian-embed.config").get().presentation.rail)
  assert_true(width == math.max(1, available - 2 * rail_width - 6),
    "nested provider width should reserve both rails and list continuations")
  return width
end
local nested_wide_width = nested_provider_width(wide_win)
local nested_narrow_width = nested_provider_width(nested_narrow_win)
assert_true(nested_wide_width ~= nested_narrow_width, "split windows should project nested providers at different widths")
vim.api.nvim_win_close(nested_narrow_win, true)
vim.api.nvim_set_current_win(wide_win)
vim.api.nvim_win_set_buf(wide_win, long_bufnr)

-- Deferred blocks still count toward the active-render budget before any
-- window projects them. Keep one row in flight to make admission deterministic.
local render_policy = require("obsidian-embed.policy")
local old_line_limit, old_in_flight, old_idle_ms = render_policy.active_line_limit,
  render_policy.max_in_flight, render_policy.idle_ms
render_policy.active_line_limit, render_policy.max_in_flight, render_policy.idle_ms = 1, 1, 1000
local function assert_provider_row_capped(path)
  vim.cmd.edit(root .. "/" .. path)
  local cap_bufnr = vim.api.nvim_get_current_buf()
  vim.b[cap_bufnr].obsidian_buffer = true
  embeds.setup()
  assert_true(vim.wait(3000, function()
    local units = embeds.inspect(cap_bufnr).units
    return units.ready == 1 and units.pending == 1
  end, 10), "deferred provider row should pause later active work: " .. path)
  vim.wait(50)
  local units = embeds.inspect(cap_bufnr).units
  assert_true(units.ready == 1 and units.pending == 1,
    "active line cap should hold until the idle gate: " .. path)
  embeds.toggle(cap_bufnr)
end
assert_provider_row_capped("MainNestedProviderCap.md")
assert_provider_row_capped("MainDirectProviderCap.md")
render_policy.active_line_limit, render_policy.max_in_flight, render_policy.idle_ms =
  old_line_limit, old_in_flight, old_idle_ms
vim.api.nvim_win_set_buf(wide_win, long_bufnr)
unregister_width_provider()

-- Automatic sign columns change textoff without changing the signcolumn
-- option. The presenter must notice the live layout change during redraw.
local presenter = require("obsidian-embed.presenter")
vim.cmd("vsplit")
local layout_win = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_buf(layout_win, long_bufnr)
vim.api.nvim_set_option_value("wrap", true, { win = layout_win })
vim.api.nvim_set_option_value("signcolumn", "auto", { win = layout_win })
vim.api.nvim_set_option_value("number", false, { win = layout_win })
vim.api.nvim_set_option_value("relativenumber", false, { win = layout_win })
vim.api.nvim_set_option_value("foldcolumn", "0", { win = layout_win })
vim.api.nvim_set_option_value("statuscolumn", "", { win = layout_win })
vim.fn.sign_define("ObsidianEmbedsWidth", { text = "!", texthl = "ErrorMsg" })
local sign_group = "obsidian-embeds-width"
local function set_width_sign(placed)
  vim.fn.sign_unplace(sign_group, { buffer = long_bufnr })
  if placed then
    vim.fn.sign_place(1, sign_group, "ObsidianEmbedsWidth", long_bufnr, { lnum = 1, priority = 10 })
  end
  vim.api.nvim__redraw({ flush = true })
end
local width_without_sign, count_without_sign, count_with_sign
for width = 25, 80 do
  vim.api.nvim_win_set_width(layout_win, width)
  set_width_sign(false)
  local without = rendered_line_count(long_bufnr, layout_win)
  set_width_sign(true)
  local with = rendered_line_count(long_bufnr, layout_win)
  if with > without then
    width_without_sign, count_without_sign, count_with_sign = width, without, with
    break
  end
end
assert_true(width_without_sign ~= nil, "sign-column fixture should find a wrapping boundary")
vim.api.nvim_win_set_width(layout_win, width_without_sign)
set_width_sign(false)
presenter.request_redraw(long_bufnr)
local function actual_rendered_line_count()
  local window_namespace = vim.api.nvim_get_namespaces()["obsidian-embed.window." .. layout_win]
  if not window_namespace then return 0 end
  local count = 0
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(long_bufnr, window_namespace, 0, -1, { details = true })) do
    count = count + #(mark[4].virt_lines or {})
  end
  return count
end
assert_true(vim.wait(1000, function()
  return actual_rendered_line_count() == count_without_sign
end, 10), "window presentation should synchronize before the sign-column edit")
local textoff_without_sign = vim.fn.getwininfo(layout_win)[1].textoff
set_width_sign(true)
assert_true(vim.wait(1000, function()
  return vim.fn.getwininfo(layout_win)[1].textoff > textoff_without_sign
    and actual_rendered_line_count() == count_with_sign
end, 10), "automatic sign-column appearance should reproject wrapping")
set_width_sign(false)
assert_true(vim.wait(1000, function()
  return actual_rendered_line_count() == count_without_sign
end, 10), "automatic sign-column removal should restore wrapping")
vim.fn.sign_undefine("ObsidianEmbedsWidth")
vim.api.nvim_win_close(layout_win, true)
vim.api.nvim_set_current_win(wide_win)

local original_breakat = vim.o.breakat
vim.o.breakat = " "
vim.cmd("setlocal linebreak")
local word_wrapped = {}
for _, mark in ipairs(testlib.projected_marks(long_bufnr)) do
  for _, virt_line in ipairs(mark[4].virt_lines or {}) do
    local text = ""
    for _, chunk in ipairs(virt_line) do text = text .. chunk[1] end
    word_wrapped[#word_wrapped + 1] = text
  end
end
for index = 1, #word_wrapped - 1 do
  assert_true(word_wrapped[index]:match("%s$"), "linebreak should wrap at configured word boundaries")
end
vim.o.breakat = original_breakat

-- Scenario: replacing a generation cancels provider work retained by its
-- generation-scoped render owner.
local provider_started, provider_cancelled = 0, 0
local unregister_provider = embeds.register_provider({
  name = "smoke_pending_provider",
  match = function(ref) return ref.target == "Pending.provider" end,
  render_async = function()
    provider_started = provider_started + 1
    return function() provider_cancelled = provider_cancelled + 1 end
  end,
})
write_file(root .. "/ProviderCancel.md", { "![[Pending.provider]]" })
vim.cmd.edit(root .. "/ProviderCancel.md")
local provider_bufnr = vim.api.nvim_get_current_buf()
vim.b[provider_bufnr].obsidian_buffer = true
embeds.setup()
assert_true(vim.wait(1000, function() return provider_started == 1 end, 10), "pending provider should start")
vim.api.nvim_buf_set_lines(provider_bufnr, 0, 1, false, { "provider replaced" })
embeds.refresh(provider_bufnr)
testlib.wait_complete(embeds, provider_bufnr)
assert_true(provider_cancelled == 1, "replacing a generation should cancel its pending provider")
unregister_provider()

print("obsidian embeds smoke test passed")
