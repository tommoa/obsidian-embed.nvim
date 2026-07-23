local policy = require("obsidian-embed.policy")

local M = {}

local lane_rank = { visible = 1, prefetch = 2, background = 3 }
local valid_events = {
  refresh = true, analysis_completed = true, view_changed = true, tick = true,
  row_completed = true, idle_elapsed = true, enabled_set = true, failed = true, detach = true,
}

---@alias ObsidianEmbedsPhase "disabled"|"analyzing"|"rendering"|"settled"|"degraded"|"detached"
---@alias ObsidianEmbedsLane "visible"|"prefetch"|"background"
---@alias ObsidianEmbedsUnitStage "pending"|"running"|"ready"|"failed"

---@class ObsidianEmbedsSnapshot
---@field bufnr integer
---@field workspace_key string
---@field base_dir? string
---@field lines string[]
---@field row_ids integer[] Stable identities used to retain unchanged rendered rows.
---@field viewports table[]
---@field cursor_row? integer
---@field diagnostic_row? integer
---@field force_render? boolean

---@class ObsidianEmbedsUnit
---@field stage ObsidianEmbedsUnitStage
---@field error? string

---@class ObsidianEmbedsSession
---@field bufnr integer
---@field attached boolean
---@field enabled boolean
---@field phase ObsidianEmbedsPhase
---@field generation integer The sole identity used to reject stale async completions.
---@field snapshot? ObsidianEmbedsSnapshot
---@field analysis? table
---@field previous_by_id? table<integer, table>
---@field units table<integer, ObsidianEmbedsUnit>
---@field committed_rows table<integer, ObsidianEmbedsRowState>
---@field idle_unlocked boolean
---@field idle_scheduled boolean
---@field active_embed_count integer
---@field generated_line_count integer
---@field last_diagnostic? table

---@class ObsidianEmbedsMachineEvent
---@field type string
---@field generation? integer
---@field cancel_generation? integer
---@field snapshot? ObsidianEmbedsSnapshot
---@field analysis? table
---@field row? integer
---@field result? ObsidianEmbedsRowState
---@field error? string
---@field enabled? boolean
---@field invalidate_resolution? boolean

---@class ObsidianEmbedsTransitionResult
---@field analyze boolean
---@field render_row? integer
---@field wake? "tick"|"idle"
---@field dependency_deltas table[]
---@field redraw boolean
---@field notification? string
---@field invalidate_resolution_workspace? string

local function transition_result()
  return { analyze = false, dependency_deltas = {}, redraw = false }
end

local function dependency_delta(out, fields)
  out.dependency_deltas[#out.dependency_deltas + 1] = fields
end

---@param row integer
---@param viewports table[]
---@return ObsidianEmbedsLane
local function lane_for(row, viewports)
  for _, viewport in ipairs(viewports or {}) do
    if viewport.first_row <= row and row <= viewport.last_row then return "visible" end
  end
  for _, viewport in ipairs(viewports or {}) do
    local height = math.max(viewport.last_row - viewport.first_row + 1, 1)
    local margin = height * policy.prefetch_screens
    if viewport.first_row - margin <= row and row <= viewport.last_row + margin then return "prefetch" end
  end
  return "background"
end

---@param session ObsidianEmbedsSession
---@return integer?
local function next_row(session)
  local selected_row, selected_rank
  for row, unit in pairs(session.units) do
    if unit.stage == "pending" then
      local lane = lane_for(row, session.snapshot.viewports)
      local rank = lane_rank[lane]
      if (lane ~= "background" or session.idle_unlocked)
        and (not selected_rank or rank < selected_rank or (rank == selected_rank and row < selected_row))
      then
        selected_row, selected_rank = row, rank
      end
    end
  end
  return selected_row
end

local function has_pending(session)
  for _, unit in pairs(session.units) do
    if unit.stage == "pending" then return true end
  end
  return false
end

local function running_count(session)
  local count = 0
  for _, unit in pairs(session.units) do
    if unit.stage == "running" then count = count + 1 end
  end
  return count
end

local function all_terminal(session)
  for _, unit in pairs(session.units) do
    if unit.stage == "pending" or unit.stage == "running" then return false end
  end
  return true
end

---Create the lifecycle data for one attached buffer. Neovim resources remain
---runtime-owned and are deliberately absent from this table.
---@param bufnr integer
---@return ObsidianEmbedsSession
function M.new(bufnr)
  return {
    bufnr = bufnr,
    attached = true,
    enabled = true,
    phase = "settled",
    generation = 0,
    snapshot = nil,
    analysis = nil,
    units = {},
    committed_rows = {},
    idle_unlocked = false,
    idle_scheduled = false,
    active_embed_count = 0,
    generated_line_count = 0,
    last_diagnostic = nil,
  }
end

---Start a generation while retaining committed rows whose stable IDs survive.
---@param session ObsidianEmbedsSession
---@param event ObsidianEmbedsMachineEvent
---@param out ObsidianEmbedsTransitionResult
local function refresh(session, event, out)
  local previous_snapshot, previous_analysis = session.snapshot, session.analysis
  local context_changed = previous_snapshot ~= nil
    and (previous_snapshot.workspace_key ~= event.snapshot.workspace_key
      or previous_snapshot.base_dir ~= event.snapshot.base_dir)
  local retained_ids = {}
  for _, row_id in ipairs(event.snapshot.row_ids or {}) do retained_ids[row_id] = true end
  for _, row in pairs(session.committed_rows) do
    if context_changed or not retained_ids[row.row_id] then
      dependency_delta(out, {
        workspace_key = previous_snapshot and previous_snapshot.workspace_key,
        previous = row.dependencies,
      })
    end
  end

  local previous_by_id = {}
  for row, row_id in ipairs(previous_snapshot and previous_snapshot.row_ids or {}) do
    previous_by_id[row_id] = { row = row - 1, analysis = previous_analysis and previous_analysis.rows[row] }
  end
  local committed_by_id = {}
  if not context_changed then
    for _, row in pairs(session.committed_rows) do committed_by_id[row.row_id] = row end
  end
  local retained = {}
  for row, row_id in ipairs(event.snapshot.row_ids or {}) do
    local value = committed_by_id[row_id]
    if value then
      value.row = row - 1
      retained[row - 1] = value
    end
  end

  session.generation = session.generation + 1
  session.phase = session.enabled and "analyzing" or "disabled"
  session.snapshot = event.snapshot
  session.previous_by_id = previous_by_id
  session.analysis = nil
  session.units = {}
  session.committed_rows = retained
  session.idle_unlocked = false
  session.idle_scheduled = false
  session.active_embed_count = 0
  session.generated_line_count = 0
  session.last_diagnostic = nil
  if event.invalidate_resolution == true then
    out.invalidate_resolution_workspace = event.snapshot.workspace_key
  end
  if session.enabled then
    out.analyze = true
  end
end

---Apply one lifecycle event. This is the only writer of semantic session state;
---the runtime merely applies the returned work description and dispatches completions.
---@param session ObsidianEmbedsSession
---@param event ObsidianEmbedsMachineEvent
---@return ObsidianEmbedsTransitionResult
function M.transition(session, event)
  local out = transition_result()
  if not session or not event then return out end
  assert(valid_events[event.type], "unknown Obsidian embed event: " .. tostring(event.type))

  if event.type == "refresh" then
    -- Both initial attachment and later source changes use the same path.
    refresh(session, event, out)

  elseif event.type == "analysis_completed" then
    -- Analysis creates row-sized work units; unchanged units can be retained.
    if event.generation ~= session.generation or not session.enabled then return out end
    if event.analysis.error then
      session.phase = "degraded"
      session.last_diagnostic = {
        kind = "parser",
        message = event.analysis.error,
        row = session.snapshot.diagnostic_row or 0,
      }
      out.redraw = true
      return out
    end

    session.analysis = event.analysis
    session.last_diagnostic = nil
    for row, committed in pairs(session.committed_rows) do
      local analyzed_row = event.analysis.rows[row + 1]
      if not analyzed_row or #analyzed_row.refs == 0 then
        session.committed_rows[row] = nil
        dependency_delta(out, {
          workspace_key = session.snapshot.workspace_key,
          previous = committed.dependencies,
        })
      end
    end
    for index, analyzed_row in ipairs(event.analysis.rows) do
      if #analyzed_row.refs > 0 then
        local row, row_id = index - 1, session.snapshot.row_ids[index]
        local previous = session.previous_by_id and session.previous_by_id[row_id]
        local retained = not session.snapshot.force_render
          and previous and previous.analysis
          and previous.analysis.semantic_signature == analyzed_row.semantic_signature
          and session.committed_rows[row] ~= nil
        session.units[row] = { stage = retained and "ready" or "pending" }
      end
    end
    session.previous_by_id = nil
    -- A generation containing only retained rows is already complete; the
    -- presence of units alone does not imply that render work remains.
    session.phase = has_pending(session) and "rendering" or "settled"
    out.redraw = true
    if session.phase == "rendering" and has_pending(session) then
      out.wake = "tick"
    end

  elseif event.type == "view_changed" then
    -- View changes affect priority and presentation, never source generation.
    if event.generation ~= session.generation then return out end
    session.snapshot.viewports = event.viewports
    session.snapshot.cursor_row = event.cursor_row
    out.redraw = true
    if session.phase == "rendering" and running_count(session) < policy.max_in_flight then
      out.wake = "tick"
    end

  elseif event.type == "tick" then
    -- Admit at most one row per tick so the runtime can enforce a time budget.
    if event.generation ~= session.generation or not session.enabled then return out end
    local capped = not session.idle_unlocked
      and (session.active_embed_count >= policy.active_embed_limit
        or session.generated_line_count >= policy.active_line_limit)
    if capped then
      if not session.idle_scheduled then
        session.idle_scheduled = true
        out.wake = "idle"
      end
    elseif running_count(session) < policy.max_in_flight then
      local row = next_row(session)
      if row then
        session.units[row].stage = "running"
        out.render_row = row
      elseif has_pending(session) and not session.idle_unlocked and not session.idle_scheduled then
        session.idle_scheduled = true
        out.wake = "idle"
      elseif all_terminal(session) then
        session.phase = session.last_diagnostic and "degraded" or "settled"
      end
    end

  elseif event.type == "row_completed" then
    -- A complete row candidate replaces its last-good value atomically.
    if event.generation ~= session.generation then return out end
    local unit = session.units[event.row]
    if not unit or unit.stage ~= "running" then return out end
    unit.stage = event.error and "failed" or "ready"
    unit.error = event.error
    if event.error then
      session.last_diagnostic = { kind = "render", message = event.error, row = event.row }
      out.redraw = true
    elseif event.result then
      local row_id = session.snapshot.row_ids[event.row + 1]
      local previous = session.committed_rows[event.row]
      event.result.row = event.row
      event.result.row_id = row_id
      session.committed_rows[event.row] = event.result
      dependency_delta(out, {
        workspace_key = session.snapshot.workspace_key,
        previous = previous and previous.dependencies,
        replacement = event.result.dependencies,
      })
      out.redraw = true
    end
    session.active_embed_count = session.active_embed_count + (event.embed_count or 0)
    session.generated_line_count = session.generated_line_count + (event.line_count or 0)
    if all_terminal(session) then
      session.phase = session.last_diagnostic and "degraded" or "settled"
    else
      out.wake = "tick"
    end

  elseif event.type == "idle_elapsed" then
    if event.generation ~= session.generation or not session.enabled then return out end
    session.idle_scheduled = false
    session.idle_unlocked = true
    out.wake = "tick"

  elseif event.type == "enabled_set" then
    -- Disabling invalidates callbacks but retains semantic results for re-enable.
    if event.enabled == session.enabled then return out end
    session.enabled = event.enabled
    if event.enabled then
      refresh(session, { snapshot = assert(event.snapshot) }, out)
    else
      session.generation = session.generation + 1
      session.phase = "disabled"
    end

  elseif event.type == "failed" then
    -- Runtime failures become one visible diagnostic without corrupting rows.
    if event.generation and event.generation ~= session.generation then return out end
    session.phase = "degraded"
    session.last_diagnostic = { kind = event.operation or "runtime", message = event.message, row = event.row or 0 }
    out.redraw = true
    out.notification = "Obsidian embeds: " .. event.message

  elseif event.type == "detach" then
    -- Dependency removals precede resource release in runtime reconciliation.
    for _, row in pairs(session.committed_rows) do
      dependency_delta(out, {
        workspace_key = session.snapshot and session.snapshot.workspace_key,
        previous = row.dependencies,
      })
    end
    session.generation = session.generation + 1
    session.attached = false
    session.phase = "detached"
  end

  return out
end

---@param session? ObsidianEmbedsSession
---@return table?
function M.presentation(session)
  if not session or not session.enabled then return nil end
  return {
    line_count = session.snapshot and #session.snapshot.lines or 0,
    rows = session.committed_rows,
    diagnostic = session.last_diagnostic,
  }
end

---@param session? ObsidianEmbedsSession
---@return table
function M.inspect(session)
  local units = { pending = 0, running = 0, ready = 0, failed = 0 }
  if session then
    for _, unit in pairs(session.units) do units[unit.stage] = units[unit.stage] + 1 end
  end
  return {
    attached = session ~= nil and session.attached or false,
    enabled = session ~= nil and session.enabled or false,
    phase = session and session.phase or "detached",
    generation = session and session.generation or 0,
    units = units,
    last_diagnostic = session and vim.deepcopy(session.last_diagnostic) or nil,
  }
end

return M
