local config = require("obsidian-embed.config")
local highlight = require("obsidian-embed.highlight")
local parser = require("obsidian-embed.parser")

local M = {}

local excluded_node_types = {
  code_span = true,
  fenced_code_block = true,
  indented_code_block = true,
  html_block = true,
  html_comment = true,
  minus_metadata = true,
  pipe_table_delimiter_row = false,
}

local query_cache = {}

local function semantic_signature(refs, exact, host)
  local parts = {
    exact and "1" or "0", host and host.kind or "body",
    host and host.prefix or "", host and host.continuation or "",
  }
  for _, ref in ipairs(refs) do
    parts[#parts + 1] = table.concat({
      ref.target or "", ref.alias or "", ref.selector and ref.selector.kind or "",
      ref.selector and ref.selector.value or "", tostring(ref.start_col), tostring(ref.end_col),
    }, "\0")
  end
  return table.concat(parts, "\1")
end

local function collect_structure(root, structure)
  local function visit(node)
    local node_type = node:type()
    local start_row, start_col, end_row, end_col = node:range()
    if node_type == "pipe_table" then
      local last_row = end_col > 0 and end_row or end_row - 1
      for row = start_row, last_row do structure.table_rows[row] = true end
    elseif node_type == "block_quote_marker"
      or (node_type == "block_continuation" and end_col > start_col)
      or vim.startswith(node_type, "list_marker_")
      or vim.startswith(node_type, "task_list_marker_")
    then
      structure.spans[start_row] = structure.spans[start_row] or {}
      structure.spans[start_row][#structure.spans[start_row] + 1] = {
        start_col = start_col,
        end_col = end_col,
        kind = node_type,
      }
    end
    for child in node:iter_children() do visit(child) end
  end
  visit(root)
end

---Convert an obsidian.nvim ref into the renderer's compact analyzed form.
---@param ref table
---@return table
local function normalize_ref(ref)
  local selector
  if ref.block then
    selector = { kind = "block", value = ref.block }
  elseif ref.anchor then
    selector = { kind = "heading", value = ref.anchor }
  end
  return {
    target = ref.target or "",
    alias = ref.label ~= "" and ref.label or nil,
    selector = selector,
    start_col = ref.range.start_col,
    end_col = ref.range.end_col,
  }
end

M.normalize_ref = normalize_ref

---Convert an analyzed ref back into the shape expected by resolver APIs.
---@param ref table
---@return table
function M.to_upstream_ref(ref)
  return {
    raw = nil,
    target = ref.target,
    label = ref.alias,
    anchor = ref.selector and ref.selector.kind == "heading" and ref.selector.value or nil,
    block = ref.selector and ref.selector.kind == "block" and ref.selector.value or nil,
    embed = true,
    range = { start_col = ref.start_col, end_col = ref.end_col },
  }
end

---Record syntax ranges where embed-like text must remain literal.
---@param root TSNode
---@param excluded table<integer, table[]>
local function collect_exclusions(root, excluded)
  ---Walk syntax nodes recursively, stopping when an excluded region is found.
  local function visit(node)
    if excluded_node_types[node:type()] then
      local start_row, start_col, end_row, end_col = node:range()
      for row = start_row, end_row do
        if row < end_row or end_col > 0 then
          excluded[row] = excluded[row] or {}
          excluded[row][#excluded[row] + 1] = {
            start_col = row == start_row and start_col or 0,
            end_col = row == end_row and end_col or math.huge,
          }
        end
      end
      return
    end
    for child in node:iter_children() do
      visit(child)
    end
  end
  visit(root)
end

---Report whether a candidate embed intersects any excluded syntax range.
---@param span table
---@param ranges table[]?
---@return boolean
local function overlaps(span, ranges)
  for _, range in ipairs(ranges or {}) do
    if span.start_col < range.end_col and range.start_col < span.end_col then
      return true
    end
  end
  return false
end

---Split a multiline Tree-sitter capture into line-local highlight spans.
---@param spans table[]
---@param lines string[]
---@param start_row integer
---@param start_col integer
---@param end_row integer
---@param end_col integer
---@param group string
local function append_multiline_span(spans, lines, start_row, start_col, end_row, end_col, group, lang)
  for row = start_row, end_row do
    local line = lines[row + 1]
    if line and (row < end_row or end_col > 0) then
      local row_start = row == start_row and start_col or 0
      local row_end = row == end_row and end_col or #line
      if row_start < row_end then
        spans[#spans + 1] = {
          row = row,
          start_col = row_start,
          end_col = math.min(row_end, #line),
          group = group,
          priority = highlight.capture_priority(group),
          lang = lang,
        }
      end
    end
  end
end

---Convert overlapping highlight spans into ordered virtual-text chunks.
---@param line string
---@param spans table[]
---@return table[]
local function chunks_for_line(line, spans, hidden)
  local default_group = config.get().presentation.highlights.text
  if line == "" then
    return { { text = "", group = default_group } }
  end

  local breakpoints = { [0] = true, [#line] = true }
  for _, span in ipairs(spans) do
    breakpoints[span.start_col] = true
    breakpoints[span.end_col] = true
  end
  for _, range in ipairs(hidden or {}) do
    breakpoints[range.start_col] = true
    breakpoints[range.end_col] = true
  end
  local points = vim.tbl_keys(breakpoints)
  table.sort(points)

  local chunks = {}
  for index = 1, #points - 1 do
    local start_col = points[index]
    local end_col = points[index + 1]
    if not overlaps({ start_col = start_col, end_col = end_col }, hidden) then
      local group = default_group
      local priority = 0
      for _, span in ipairs(spans) do
        if span.start_col <= start_col and end_col <= span.end_col and span.priority > priority then
          group = span.group
          priority = span.priority
        end
      end
      local text = line:sub(start_col + 1, end_col)
      local previous = chunks[#chunks]
      if previous and previous.group == group then
        previous.text = previous.text .. text
      else
        chunks[#chunks + 1] = { text = text, group = group }
      end
    end
  end
  if #chunks == 0 then chunks[1] = { text = "", group = default_group } end
  return chunks
end

---Collect exclusions and highlight captures from one parser frontend.
local function collect_parser(language_parser, source, lines, spans, excluded, structure)
  language_parser:parse()
  language_parser:for_each_tree(function(tree, language_tree)
    local lang = language_tree:lang()
    collect_exclusions(tree:root(), excluded)
    collect_structure(tree:root(), structure)
    local query = query_cache[lang]
    if query == nil then
      query = vim.treesitter.query.get(lang, "highlights") or false
      query_cache[lang] = query
    end
    if query then
      for id, node in query:iter_captures(tree:root(), source, 0, -1) do
        local group = highlight.capture_hl_group(query.captures[id])
        if group then
          local start_row, start_col, capture_end_row, end_col = node:range()
          append_multiline_span(spans, lines, start_row, start_col, capture_end_row, end_col, group, lang)
        end
      end
    end
  end)
end

local function covered(col, spans)
  for _, span in ipairs(spans or {}) do
    if span.start_col <= col and col < span.end_col then return span end
  end
end

local function host_layout(line, refs, row, structure)
  -- Table cells keep their source width; the presenter overlays a bounded preview.
  if structure.table_rows[row] then
    return { kind = "table", prefix = "", continuation = "", exact = false }
  end

  local spans = structure.spans[row] or {}
  local prefix_end = 0
  while prefix_end < #line do
    local char = line:sub(prefix_end + 1, prefix_end + 1)
    if char:match("%s") or covered(prefix_end, spans) then
      prefix_end = prefix_end + 1
    else
      break
    end
  end

  local kind = "body"
  for _, span in ipairs(spans) do
    if vim.startswith(span.kind, "task_list_marker_") then
      kind = "task"
      break
    elseif vim.startswith(span.kind, "list_marker_") then
      kind = "list"
    elseif (span.kind == "block_quote_marker"
        or (span.kind == "block_continuation"
          and line:sub(span.start_col + 1, span.end_col):find(">", 1, true)))
      and kind == "body"
    then
      kind = "quote"
    end
  end

  local exact = false
  if #refs == 1 and refs[1].start_col == prefix_end then
    exact = vim.trim(line:sub(refs[1].end_col + 1)) == ""
  end
  local prefix = line:sub(1, prefix_end)
  local continuation = {}
  for index = 1, #prefix do continuation[index] = prefix:sub(index, index) end
  for _, span in ipairs(spans) do
    if span.kind ~= "block_quote_marker" and span.kind ~= "block_continuation" then
      for col = span.start_col, math.min(span.end_col, #prefix) - 1 do
        continuation[col + 1] = " "
      end
    end
  end
  return {
    kind = kind,
    prefix = prefix,
    continuation = table.concat(continuation),
    exact = exact,
  }
end

---Project parser captures into the shared row representation.
local function project_rows(lines, spans, excluded, structure, parse_refs)
  local spans_by_row = {}
  for _, span in ipairs(spans) do
    spans_by_row[span.row] = spans_by_row[span.row] or {}
    spans_by_row[span.row][#spans_by_row[span.row] + 1] = span
  end

  local rows = {}
  for row = 0, #lines - 1 do
    local line, refs = lines[row + 1] or "", {}
    for _, upstream_ref in ipairs(parse_refs and parser.embed_refs(line) or {}) do
      local ref = normalize_ref(upstream_ref)
      if not overlaps(ref, excluded[row]) then
        spans_by_row[row] = spans_by_row[row] or {}
        spans_by_row[row][#spans_by_row[row] + 1] = {
          row = row, start_col = ref.start_col, end_col = ref.end_col,
          group = "@markup.link", priority = highlight.capture_priority("@markup.link"),
        }
        if parser.is_note_embed(upstream_ref) then refs[#refs + 1] = ref end
      end
    end
    local host = host_layout(line, refs, row, structure)
    local exact = host.exact
    rows[#rows + 1] = {
      chunks = chunks_for_line(line, spans_by_row[row] or {}, refs), refs = refs,
      host = host,
      exact_embed = exact,
      semantic_signature = parse_refs and semantic_signature(refs, exact, host) or "parser-error",
    }
  end
  return rows
end

---Analyze source lines once into refs, exact-embed flags, and highlight chunks.
---@param lines string[]
---@return table analysis
function M.analyze(lines)
  local source, spans, excluded = table.concat(lines, "\n"), {}, {}
  local structure = { spans = {}, table_rows = {} }
  local ok, err = pcall(function()
    for _, root_lang in ipairs({ "markdown", "markdown_inline" }) do
      collect_parser(
        vim.treesitter.get_string_parser(source, root_lang), source, lines,
        spans, excluded, structure
      )
    end
  end)
  return {
    rows = project_rows(lines, spans, excluded, structure, ok),
    error = not ok and tostring(err) or nil,
  }
end

---Analyze a live buffer using its incremental parser.
---@param bufnr integer
---@param lines string[]
---@return table analysis
function M.analyze_buffer(bufnr, lines)
  local spans, excluded = {}, {}
  local structure = { spans = {}, table_rows = {} }
  local ok, err = pcall(function()
    for _, root_lang in ipairs({ "markdown", "markdown_inline" }) do
      collect_parser(
        vim.treesitter.get_parser(bufnr, root_lang), bufnr, lines,
        spans, excluded, structure
      )
    end
  end)
  return {
    rows = project_rows(lines, spans, excluded, structure, ok),
    error = not ok and tostring(err) or nil,
  }
end

return M
