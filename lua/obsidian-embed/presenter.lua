local config = require("obsidian-embed.config")
local highlight = require("obsidian-embed.highlight")

local M = {}
local installed = false
local state_for_buffer
local layout_ns = vim.api.nvim_create_namespace("obsidian-embed.layout")
local provider_status = {
  calls = 0,
  state_hits = 0,
  emitted = 0,
  last_error = nil,
  last_bufnr = nil,
  last_winid = nil,
}
local window_presentations = {}
local redraw_timers = {}
local layout_redraw_pending = {}

local function opts()
  return config.get()
end

local function append_lines(dst, lines)
  for _, line in ipairs(lines or {}) do dst[#dst + 1] = line end
end

local function text_width(winid)
  local width = vim.api.nvim_win_get_width(winid)
  if not opts().virt_lines_leftcol then
    local info = (vim.fn.getwininfo(winid) or {})[1]
    width = width - (info and info.textoff or 0)
  end
  return math.max(width, 1)
end

---Identify every live window input that can change manual wrapping.
local function projection_signature(winid)
  local wrap = vim.api.nvim_get_option_value("wrap", { win = winid })
  if not wrap then return "nowrap" end
  local linebreak = vim.api.nvim_get_option_value("linebreak", { win = winid })
  return table.concat({
    "wrap", tostring(text_width(winid)), linebreak and "linebreak" or "break-anywhere",
    linebreak and vim.o.breakat or "",
  }, "\0")
end

local function display_width(text, start_col)
  if not text:find("[\128-\255\t]") then return #text end
  return vim.fn.strdisplaywidth(text, start_col)
end

local function append_chunk(line, chunk, text)
  local previous = line[#line]
  if previous and previous[2] == chunk[2] then
    previous[1] = previous[1] .. text
  else
    local copied = vim.deepcopy(chunk)
    copied[1] = text
    line[#line + 1] = copied
  end
end

local function glyphs_to_line(glyphs)
  local line = {}
  for _, glyph in ipairs(glyphs) do append_chunk(line, glyph.chunk, glyph.char) end
  return line
end

local function glyph_width(glyphs)
  local used = 0
  for _, glyph in ipairs(glyphs) do
    glyph.width = display_width(glyph.char, used)
    used = used + glyph.width
  end
  return used
end

local function glyphs_for_chunks(chunks)
  local glyphs = {}
  for _, chunk in ipairs(chunks or {}) do
    for _, char in ipairs(vim.fn.split(chunk[1], "\\zs")) do
      glyphs[#glyphs + 1] = { char = char, chunk = chunk }
    end
  end
  glyph_width(glyphs)
  return glyphs
end

local function copied_glyphs(glyphs)
  local out = vim.deepcopy(glyphs or {})
  glyph_width(out)
  return out
end

local function soft_wrap(lines, width, linebreak)
  local wrapped = {}
  local breakat = linebreak and vim.o.breakat or ""
  for _, line in ipairs(lines) do
    local total = 0
    for _, chunk in ipairs(line) do total = total + display_width(chunk[1], total) end
    if total <= width then
      wrapped[#wrapped + 1] = line
    else
      local continuation = glyphs_for_chunks(line.continuation_prefix)
      local current, used = {}, 0
      local protected = 0
      for _, chunk in ipairs(line) do
        for _, char in ipairs(vim.fn.split(chunk[1], "\\zs")) do
          local char_width = display_width(char, used)
          if used > 0 and used + char_width > width then
            local break_index
            if linebreak then
              for index = #current, 1, -1 do
                if index > protected and breakat:find(current[index].char, 1, true) then
                  break_index = index
                  break
                end
              end
            end
            if break_index then
              local before, after = {}, {}
              for index, glyph in ipairs(current) do
                if index <= break_index then before[#before + 1] = glyph else after[#after + 1] = glyph end
              end
              wrapped[#wrapped + 1] = glyphs_to_line(before)
              current = copied_glyphs(continuation)
              protected = #current
              for _, glyph in ipairs(after) do current[#current + 1] = glyph end
              used = glyph_width(current)
            else
              wrapped[#wrapped + 1] = glyphs_to_line(current)
              current = copied_glyphs(continuation)
              protected, used = #current, glyph_width(current)
            end
            char_width = display_width(char, 0)
          end
          current[#current + 1] = { char = char, chunk = chunk, width = char_width }
          used = used + char_width
        end
      end
      wrapped[#wrapped + 1] = glyphs_to_line(current)
    end
  end
  return wrapped
end

local function plain_lines(lines)
  local out = {}
  for _, line in ipairs(lines or {}) do
    local chunks = {}
    for _, chunk in ipairs(line) do chunks[#chunks + 1] = chunk end
    out[#out + 1] = chunks
  end
  return out
end

local function host_lines(lines, prefix)
  local out = {}
  for _, line in ipairs(lines or {}) do
    out[#out + 1] = highlight.materialize(highlight.with_host(line, prefix, prefix), opts())
  end
  return out
end

local display_lines

local function strip_text_prefix(line, prefix)
  local out = vim.deepcopy(line or {})
  local remaining = prefix or ""
  while remaining ~= "" and out[1] do
    local text = out[1][1]
    if vim.startswith(text, remaining) then
      out[1][1] = text:sub(#remaining + 1)
      remaining = ""
      if out[1][1] == "" then table.remove(out, 1) end
    else
      remaining = remaining:sub(#text + 1)
      table.remove(out, 1)
    end
  end
  return out
end

local function replacement_lines(winid, line, host)
  local decorated = highlight.materialize(
    highlight.with_host(line, host.prefix or "", host.continuation or ""),
    opts()
  )
  local wrapped = display_lines(winid, { decorated })
  local first = strip_text_prefix(wrapped[1], host.prefix)
  local continuation = {}
  for index = 2, #wrapped do continuation[#continuation + 1] = wrapped[index] end
  return first, continuation
end

display_lines = function(winid, lines)
  if not vim.api.nvim_get_option_value("wrap", { win = winid }) then return lines end
  return soft_wrap(
    lines,
    text_width(winid),
    vim.api.nvim_get_option_value("linebreak", { win = winid })
  )
end

local function cursor_row(winid)
  if opts().presentation.source ~= "reveal_cursor" then return nil end
  return vim.api.nvim_win_get_cursor(winid)[1] - 1
end

local function hidden(row, local_cursor)
  local source = opts().presentation.source
  return source ~= "show" and (source == "conceal" or local_cursor == nil or row ~= local_cursor)
end

local function block_has_output(block)
  return block and (block.project ~= nil or (block.lines and block.lines[1] ~= nil))
end

local function can_replace_source(row_state)
  return row_state
    and row_state.exact
    and #row_state.blocks == 1
    and block_has_output(row_state.blocks[1])
end

local function rendered_lines(row_state, winid)
  local lines = {}
  local host = row_state.host or { continuation = "" }
  local available = math.max(1, text_width(winid) - vim.fn.strdisplaywidth(opts().presentation.rail)
    - vim.fn.strdisplaywidth(host.continuation or ""))
  for _, block in ipairs(row_state.blocks or {}) do
    if block.project then
      local ok, projected = pcall(block.project, available)
      if ok and type(projected) == "table" then
        append_lines(lines, projected)
      else
        lines[#lines + 1] = { { "Embed provider error: " .. tostring(projected), opts().presentation.highlights.warning } }
      end
    else
      append_lines(lines, block.lines)
    end
  end
  return lines
end

local function mark(row, col, details)
  details.priority = opts().priority
  details.strict = false
  return { 0, row, col, details }
end

---Purely project semantic buffer state for one window.
---@return table[] marks Extmark-shaped tuples used by the provider and tests.
function M.project(state, winid)
  if not state or not vim.api.nvim_win_is_valid(winid) then return {} end
  local marks, local_cursor = {}, cursor_row(winid)
  if state.diagnostic then
    marks[#marks + 1] = mark(state.diagnostic.row or 0, 0, {
      virt_lines = { { { "Obsidian embeds: " .. state.diagnostic.message, opts().presentation.highlights.warning } } },
      virt_lines_above = true,
      virt_lines_overflow = opts().presentation.nowrap_overflow,
      virt_lines_leftcol = opts().virt_lines_leftcol,
    })
  end
  local rows = vim.tbl_keys(state.rows)
  table.sort(rows)
  for _, row in ipairs(rows) do
    local row_state = state.rows[row]
    local source_hidden = hidden(row, local_cursor)
    local replaced = source_hidden and can_replace_source(row_state)
    if source_hidden then
      for _, block in ipairs(row_state.blocks or {}) do
        if block_has_output(block) then
          local ref = block.ref
          marks[#marks + 1] = mark(row, ref.range.start_col, {
            end_row = row, end_col = ref.range.end_col, conceal = "",
          })
        end
      end
    end

    local lines = rendered_lines(row_state, winid)
    if #lines > 0 then
      local host = row_state.host or { prefix = "", continuation = "" }
      local continuation = host.continuation or ""
      local first
      local projected_lines = {}
      if replaced then
        first, projected_lines = replacement_lines(winid, lines[1], host)
      end
      local first_index = replaced and 2 or 1
      if first then
        marks[#marks + 1] = mark(row, row_state.refs[1].range.start_col, {
          virt_text = plain_lines({ first })[1],
          -- The presenter has already wrapped this replacement and projects
          -- continuations as virtual lines. Inline virtual text participates
          -- in Neovim's wrapping a second time, leaving a blank screen row
          -- when the concealed source is hosted by a list item.
          virt_text_pos = "overlay",
        })
      end
      local remaining = {}
      for index = first_index, #lines do
        remaining[#remaining + 1] = lines[index]
      end
      if #remaining > 0 then
        local displayed = display_lines(winid, host_lines(remaining, continuation))
        append_lines(projected_lines, displayed)
      end
      if #projected_lines > 0 then
        marks[#marks + 1] = mark(row, 0, {
          virt_lines = plain_lines(projected_lines),
          virt_lines_overflow = opts().presentation.nowrap_overflow,
          virt_lines_leftcol = opts().virt_lines_leftcol,
        })
      end
    end
  end
  return marks
end

function M.project_buffer(bufnr, winid)
  return M.project(state_for_buffer and state_for_buffer(bufnr) or nil, winid or vim.api.nvim_get_current_win())
end

local function clear_window(winid)
  local presentation = window_presentations[winid]
  if not presentation then return end
  if presentation.bufnr and vim.api.nvim_buf_is_valid(presentation.bufnr) then
    pcall(vim.api.nvim_buf_clear_namespace, presentation.bufnr, presentation.ns_id, 0, -1)
  end
  pcall(vim.api.nvim__ns_set, presentation.ns_id, { wins = {} })
  window_presentations[winid] = nil
  layout_redraw_pending[winid] = nil
end

local function sync_window(winid, bufnr)
  if not vim.api.nvim_win_is_valid(winid) or vim.api.nvim_win_get_buf(winid) ~= bufnr then
    clear_window(winid)
    return
  end
  local state = state_for_buffer and state_for_buffer(bufnr) or nil
  if not state then clear_window(winid); return end
  local presentation = window_presentations[winid]
  if not presentation then
    presentation = {
      ns_id = vim.api.nvim_create_namespace("obsidian-embed.window." .. winid),
    }
    window_presentations[winid] = presentation
  elseif presentation.bufnr and presentation.bufnr ~= bufnr
      and vim.api.nvim_buf_is_valid(presentation.bufnr) then
    pcall(vim.api.nvim_buf_clear_namespace, presentation.bufnr, presentation.ns_id, 0, -1)
  end
  presentation.bufnr = bufnr
  presentation.projection_signature = projection_signature(winid)
  vim.api.nvim__ns_set(presentation.ns_id, { wins = { winid } })
  vim.api.nvim_buf_clear_namespace(bufnr, presentation.ns_id, 0, -1)
  provider_status.calls = provider_status.calls + 1
  provider_status.state_hits = provider_status.state_hits + 1
  provider_status.last_bufnr = bufnr
  provider_status.last_winid = winid
  for _, projected in ipairs(M.project(state, winid)) do
    local ok, err = pcall(
      vim.api.nvim_buf_set_extmark,
      bufnr, presentation.ns_id, projected[2], projected[3], vim.deepcopy(projected[4])
    )
    if ok then
      provider_status.emitted = provider_status.emitted + 1
    else
      provider_status.last_error = tostring(err)
    end
  end
end

local function sync_buffer(bufnr)
  local live = {}
  for _, winid in ipairs(vim.fn.win_findbuf(bufnr)) do
    live[winid] = true
    sync_window(winid, bufnr)
  end
  for winid, presentation in pairs(window_presentations) do
    if presentation.bufnr == bufnr and not live[winid] then clear_window(winid) end
  end
end

---Install process-wide window cleanup for adapter-owned presentation state.
function M.setup(get_state)
  state_for_buffer = get_state
  if installed then return end
  installed = true
  vim.api.nvim_create_autocmd("WinClosed", {
    callback = function(ev) clear_window(tonumber(ev.match)) end,
  })
  vim.api.nvim_set_decoration_provider(layout_ns, {
    on_win = function(_, winid, bufnr)
      local presentation = window_presentations[winid]
      if presentation and presentation.bufnr == bufnr
          and presentation.projection_signature ~= projection_signature(winid)
          and not layout_redraw_pending[winid]
      then
        layout_redraw_pending[winid] = true
        vim.schedule(function()
          layout_redraw_pending[winid] = nil
          local current = window_presentations[winid]
          if current and current.bufnr == bufnr and vim.api.nvim_win_is_valid(winid) then
            M.request_redraw(bufnr)
          end
        end)
      end
      return false
    end,
  })
end

function M.inspect_provider()
  return vim.deepcopy(provider_status)
end

function M.request_redraw(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) or redraw_timers[bufnr] then return end
  local timer = assert(vim.uv.new_timer())
  redraw_timers[bufnr] = timer
  timer:start(16, 0, vim.schedule_wrap(function()
    if not timer:is_closing() then timer:close() end
    redraw_timers[bufnr] = nil
    if vim.api.nvim_buf_is_valid(bufnr) then
      sync_buffer(bufnr)
      vim.api.nvim__redraw({ buf = bufnr, valid = false, flush = false })
    end
  end))
end

function M.clear_buffer(bufnr)
  local timer = redraw_timers[bufnr]
  if timer then
    if not timer:is_closing() then timer:stop(); timer:close() end
    redraw_timers[bufnr] = nil
  end
  for winid, presentation in pairs(window_presentations) do
    if presentation.bufnr == bufnr then clear_window(winid) end
  end
end

return M
