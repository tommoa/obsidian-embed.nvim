local analyzer = require("obsidian-embed.analyzer")
local config = require("obsidian-embed.config")
local dependency_observer = require("obsidian-embed.dependency_observer")
local dependencies = require("obsidian-embed.dependencies")
local machine = require("obsidian-embed.machine")
local obsidian_port = require("obsidian-embed.obsidian_port")
local policy = require("obsidian-embed.policy")
local presenter = require("obsidian-embed.presenter")
local renderer = require("obsidian-embed.renderer")
local resolver = require("obsidian-embed.resolver")
local state_mod = require("obsidian-embed.render_context")
local util = require("obsidian-embed.util")

local M = {}

---@class ObsidianEmbedsCache
---@field entries table<string, table>
---@field order string[]

---@class ObsidianEmbedsWorkspace
---@field io table Resolver admission queue and active-operation count.
---@field analysis_cache ObsidianEmbedsCache
---@field resolution_cache ObsidianEmbedsCache
---@field cache_epoch integer Invalidation identity rejecting writes from obsolete requests.

---@class ObsidianEmbedsResources
---@field group? integer
---@field debounce_timer? uv.uv_timer_t
---@field tick_timer? uv.uv_timer_t
---@field idle_timer? uv.uv_timer_t
---@field source_lines string[]
---@field row_ids integer[]
---@field next_row_id integer
---@field force_render? boolean
---@field diagnostic_row? integer

---@type table<integer, ObsidianEmbedsSession>
local sessions, resources, render_contexts, workspaces = {}, {}, {}, {}
local dependency_index = dependencies.new_index()
---@cast resources table<integer, ObsidianEmbedsResources>
---@cast render_contexts table<integer, ObsidianEmbedsBufferState>
---@cast workspaces table<string, ObsidianEmbedsWorkspace>
local initialized, runtime_installed = false, false
---@type fun(bufnr: integer, event: ObsidianEmbedsMachineEvent)
local dispatch
---@type fun(bufnr: integer, force_render?: boolean)
local schedule_refresh
local event_queue, reducing = {}, false
local pumping, pump_requested = {}, {}

---Run ready work for one event-loop slice, yielding before Neovim becomes
---unresponsive. Async waits are not work units and therefore end the slice.
---@param step fun(): boolean
local function run_slice(step)
  local started = vim.uv.hrtime()
  while vim.uv.hrtime() - started < policy.slice_ns do
    if not step() then return end
  end
end

---@param bufnr? integer
---@return integer
local function normalize_bufnr(bufnr)
  if bufnr == nil or bufnr == 0 then return vim.api.nvim_get_current_buf() end
  return bufnr
end

---@param timer? uv.uv_timer_t
local function close_timer(timer)
  if timer and not timer:is_closing() then timer:stop(); timer:close() end
end

---Return the single mutable owner for workspace caches and resolver requests.
---@param key string
---@return ObsidianEmbedsWorkspace
local function ensure_workspace(key)
  local workspace = workspaces[key]
  if workspace then return workspace end
  workspace = {
    io = {
      active = 0, queue = {}, requests = {},
      read_active = 0, read_queue = {},
    },
    analysis_cache = { entries = {}, order = {} },
    resolution_cache = { entries = {}, order = {} },
    cache_epoch = 0,
  }
  workspaces[key] = workspace
  return workspace
end

---Drop cached note resolution state and reject writes from obsolete requests.
---@param workspace ObsidianEmbedsWorkspace
local function invalidate_resolution_cache(workspace)
  workspace.cache_epoch = workspace.cache_epoch + 1
  workspace.resolution_cache = { entries = {}, order = {} }
end

---Write a bounded LRU entry without exposing cache policy to the state machine.
---@param cache ObsidianEmbedsCache
---@param key string
---@param value table
local function cache_write(cache, key, value)
  cache.entries[key] = vim.deepcopy(value)
  for index = #cache.order, 1, -1 do
    if cache.order[index] == key then table.remove(cache.order, index) end
  end
  cache.order[#cache.order + 1] = key
  while #cache.order > 256 do cache.entries[table.remove(cache.order, 1)] = nil end
end

---Apply one committed row's dependency delta to buffer-granular reverse indexes.
---@param delta table
local function update_dependencies(delta)
  dependency_index:apply(delta.bufnr, delta.workspace_key, delta.previous, delta.replacement)
end

---@param bufnr integer
---@return table?
local function presentation(bufnr)
  return machine.presentation(sessions[bufnr])
end

local function ensure_initialized()
  local opts = config.get()
  vim.api.nvim_set_hl(0, opts.presentation.highlights.text, { default = true, link = "Normal" })
  vim.api.nvim_set_hl(0, opts.presentation.highlights.rail, { default = true, link = "NonText" })
  vim.api.nvim_set_hl(0, opts.presentation.highlights.warning, { default = true, link = "WarningMsg" })
  if initialized then return end
  initialized = true
  presenter.setup(presentation)
end

---@param bufnr integer
---@return table[]
local function viewports(bufnr)
  local result = {}
  for _, winid in ipairs(vim.fn.win_findbuf(bufnr)) do
    if vim.api.nvim_win_is_valid(winid) then
      local ok, range = pcall(vim.api.nvim_win_call, winid, function()
        return { first_row = vim.fn.line("w0") - 1, last_row = vim.fn.line("w$") - 1 }
      end)
      if ok then result[#result + 1] = range end
    end
  end
  table.sort(result, function(a, b) return a.first_row < b.first_row end)
  return result
end

---@param bufnr integer
---@return integer?
local function cursor_row(bufnr)
  return vim.api.nvim_get_current_buf() == bufnr and vim.api.nvim_win_get_cursor(0)[1] - 1 or nil
end

---Capture source values at a generation boundary; async work never reads a
---partially edited buffer through this table.
---@param bufnr integer
---@return ObsidianEmbedsSnapshot?
local function snapshot(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then return nil end
  local root = util.workspace_root_for_buffer(bufnr, false)
  if not root then return nil end
  local resource = resources[bufnr]
  local lines = resource and vim.deepcopy(resource.source_lines) or vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local row_ids = resource and vim.deepcopy(resource.row_ids) or {}
  if #row_ids == 0 then for index = 1, #lines do row_ids[index] = index end end
  return {
    bufnr = bufnr,
    changedtick = vim.b[bufnr].changedtick or 0,
    workspace_key = root,
    base_dir = vim.fs.dirname(vim.api.nvim_buf_get_name(bufnr)),
    lines = lines,
    row_ids = row_ids,
    diagnostic_row = resource and resource.diagnostic_row or 0,
    viewports = viewports(bufnr),
    cursor_row = cursor_row(bufnr),
  }
end

local function current_note_requirements(analysis)
  local requirements = resolver.empty_requirements()
  for _, row in ipairs(analysis.rows) do
    for _, ref in ipairs(row.refs) do
      resolver.add_current_note_requirements(requirements, analyzer.to_upstream_ref(ref))
    end
  end
  return requirements
end

---Analyze the complete Markdown context for one source generation.
---@param source ObsidianEmbedsSnapshot
---@return table
local function analyze(source)
  return analyzer.analyze_buffer(source.bufnr, source.lines)
end

---Build generation-scoped renderer context while sharing workspace services.
---@param source ObsidianEmbedsSnapshot
---@param analysis table
---@param generation integer
local function prepare_context(source, analysis, generation)
  local requirements = current_note_requirements(analysis)
  local note_opts = resolver.current_note_opts(requirements)
  local current_note, current_note_error
  if note_opts then
    local ok, value = pcall(obsidian_port.note_from_buffer, source.workspace_key, source.bufnr, note_opts)
    if ok then
      current_note = resolver.normalize_note(value, "buf:" .. source.bufnr .. ":" .. tostring(vim.b[source.bufnr].changedtick or 0))
    else
      current_note_error = tostring(value)
    end
  end
  local workspace = ensure_workspace(source.workspace_key)
  local cache_epoch = workspace.cache_epoch
  local state = state_mod.new_buffer_state({
    bufnr = source.bufnr,
    workspace_root = source.workspace_key,
    base_dir = source.base_dir,
    host_path = vim.api.nvim_buf_get_name(source.bufnr),
    lines = source.lines,
    cursor_row = source.cursor_row,
    requirements = requirements,
    current_note_opts = note_opts,
    current_note = current_note,
    current_note_error = current_note_error,
  })
  state.resolution_requests = workspace.io.requests
  state.io_runtime = workspace.io
  state.cache_epoch = cache_epoch
  state.cache_read = function(kind, key)
    local cache = kind == "analysis" and workspace.analysis_cache or workspace.resolution_cache
    return cache.entries[key]
  end
  state.cache_write = function(kind, key, value)
    if workspace.cache_epoch ~= cache_epoch then return end
    local cache = kind == "analysis" and workspace.analysis_cache or workspace.resolution_cache
    cache_write(cache, key, value)
    if kind == "resolution" then
      for _, note in ipairs(value.candidates or {}) do
        if note.path then
          local keys = {}
          for _, item in ipairs(note.reference_ids or {}) do keys[item] = true end
          for _, item in ipairs(note.reference_paths or {}) do keys[item] = true end
          dependency_index:remember_note(source.workspace_key, note.path, keys)
        end
      end
    end
  end
  state.generation = generation
  state.owner = { bufnr = source.bufnr, generation = generation }
  render_contexts[source.bufnr] = state
end

local render_api = {}
function render_api.render_ref_async(ref, ctx, done) renderer.render_ref_async(render_api, ref, ctx, done) end
function render_api.safe_render_ref_async(ref, ctx, done) renderer.safe_render_ref_async(render_api, ref, ctx, done) end

---Cancel timers and resolver waiters belonging to the preceding generation.
---@param bufnr integer
---@param workspace_key? string
---@param cancel_generation? integer
local function cancel_work(bufnr, workspace_key, cancel_generation)
  local resource, session = resources[bufnr], sessions[bufnr]
  if resource then
    close_timer(resource.tick_timer)
    close_timer(resource.idle_timer)
    resource.tick_timer, resource.idle_timer = nil, nil
  end
  workspace_key = workspace_key or session and session.snapshot and session.snapshot.workspace_key
  cancel_generation = cancel_generation or session and session.generation
  if workspace_key and cancel_generation then
    local workspace = workspaces[workspace_key]
    if workspace then resolver.cancel_waiters(workspace.io, bufnr, cancel_generation) end
  end
  local context = render_contexts[bufnr]
  if context and context.owner then require("obsidian-embed.providers").cancel_owner(context.owner) end
end

---@param bufnr integer
local function clear_presentation(bufnr)
  presenter.clear_buffer(bufnr)
  if vim.api.nvim_buf_is_valid(bufnr) then vim.api.nvim_buf_clear_namespace(bufnr, config.ns_id, 0, -1) end
  render_contexts[bufnr] = nil
end

---Release every Neovim resource after the machine has removed dependencies.
---@param bufnr integer
local function release(bufnr)
  cancel_work(bufnr)
  local resource = resources[bufnr]
  if resource then
    close_timer(resource.debounce_timer)
    if resource.group then pcall(vim.api.nvim_del_augroup_by_id, resource.group) end
  end
  resources[bufnr], render_contexts[bufnr], sessions[bufnr] = nil, nil, nil
end

---Schedule one time-bounded admission slice, coalescing duplicate requests.
---@param bufnr integer
---@param generation integer
local function schedule_tick(bufnr, generation)
  local resource = resources[bufnr]
  if not resource then return end
  if pumping[bufnr] then pump_requested[bufnr] = true; return end
  if resource.tick_timer and not resource.tick_timer:is_closing() then return end
  local timer = assert(vim.uv.new_timer())
  resource.tick_timer = timer
  timer:start(0, 0, vim.schedule_wrap(function()
    close_timer(timer)
    if resources[bufnr] then resources[bufnr].tick_timer = nil end
    pumping[bufnr], pump_requested[bufnr] = true, false
    run_slice(function()
      local session = sessions[bufnr]
      if not session or session.generation ~= generation then return false end
      local before = 0
      for _, unit in pairs(session.units) do if unit.stage == "running" then before = before + 1 end end
      dispatch(bufnr, { type = "tick", generation = generation })
      local after = 0
      for _, unit in pairs(session.units) do if unit.stage == "running" then after = after + 1 end end
      return after > before
    end)
    pumping[bufnr] = nil
    local session = sessions[bufnr]
    if session and session.generation == generation and pump_requested[bufnr] then
      pump_requested[bufnr] = nil
      schedule_tick(bufnr, generation)
    end
  end))
end

local function start_analysis(bufnr, session)
  local generation, source = session.generation, session.snapshot
  local analysis = analyze(source)
  if sessions[bufnr] and sessions[bufnr].generation == generation then
    prepare_context(source, analysis, generation)
  end
  dispatch(bufnr, { type = "analysis_completed", generation = generation, analysis = analysis })
end

local function start_render(bufnr, session, row)
  local generation, context = session.generation, render_contexts[bufnr]
  if not context then return end
  local analyzed_row = session.analysis.rows[row + 1]
  local completed = false
  local function done(result, err)
    if completed then return end
    completed = true
    local workspace = workspaces[context.workspace_root]
    if not workspace or workspace.cache_epoch ~= context.cache_epoch then
      -- An observer event may arrive before this row publishes its dependency
      -- set. Its source is then absent from the reverse index, so make this
      -- obsolete completion itself request the replacement generation.
      schedule_refresh(bufnr, true)
      return
    end
    dispatch(bufnr, {
      type = "row_completed", generation = generation, row = row,
      result = result, error = err, embed_count = #analyzed_row.refs,
      line_count = result and vim.iter(result.blocks or {}):fold(0, function(count, block)
        return count + #(block.lines or {})
      end) or 0,
    })
  end
  local ok, err = pcall(renderer.render_analyzed_row_state_async, render_api, context, row,
    analyzed_row, done)
  if not ok then done(nil, tostring(err)) end
end

local function schedule_idle(bufnr, generation)
  local resource = resources[bufnr]
  if not resource then return end
  close_timer(resource.idle_timer)
  local timer = assert(vim.uv.new_timer())
  resource.idle_timer = timer
  timer:start(policy.idle_ms, 0, vim.schedule_wrap(function()
    close_timer(timer)
    if resources[bufnr] then resources[bufnr].idle_timer = nil end
    dispatch(bufnr, { type = "idle_elapsed", generation = generation })
  end))
end

local function apply_transition(bufnr, before, result)
  local session = sessions[bufnr]
  if not session then return end
  if session.generation ~= before.generation then
    cancel_work(bufnr, before.workspace_key, before.generation)
  end
  if result.invalidate_resolution_workspace then
    local workspace = workspaces[result.invalidate_resolution_workspace]
    if workspace then invalidate_resolution_cache(workspace) end
  end
  for _, delta in ipairs(result.dependency_deltas) do
    delta.bufnr = bufnr
    update_dependencies(delta)
    dependency_observer.attach_dependencies(delta.replacement)
  end
  local entering_inactive = session.phase ~= before.phase
    and (session.phase == "disabled" or session.phase == "detached")
  if entering_inactive then clear_presentation(bufnr) end
  if result.analyze then start_analysis(bufnr, session) end
  if result.render_row ~= nil then start_render(bufnr, session, result.render_row) end
  if result.wake == "tick" then schedule_tick(bufnr, session.generation)
  elseif result.wake == "idle" then schedule_idle(bufnr, session.generation) end
  if result.redraw then presenter.request_redraw(bufnr) end
  if result.notification then vim.notify(result.notification, vim.log.levels.ERROR) end
  if session.phase == "detached" and before.phase ~= "detached" then release(bufnr) end
end

---Serialize transition execution so synchronous callbacks cannot re-enter the
---single writer. Effects may enqueue completion events for the next loop turn.
---@param bufnr integer
---@param event ObsidianEmbedsMachineEvent
function dispatch(bufnr, event)
  event_queue[#event_queue + 1] = { bufnr = bufnr, event = event }
  if reducing then return end
  reducing = true
  while #event_queue > 0 do
    local item = table.remove(event_queue, 1)
    local session = sessions[item.bufnr]
    if session then
      local before = {
        generation = session.generation,
        phase = session.phase,
        workspace_key = session.snapshot and session.snapshot.workspace_key,
      }
      local ok, result = xpcall(function() return machine.transition(session, item.event) end, debug.traceback)
      if not ok then
        result = machine.transition(session, {
          type = "failed", generation = session.generation, operation = item.event.type, message = tostring(result),
        })
      end
      local apply_ok, err = xpcall(function() apply_transition(item.bufnr, before, result) end, debug.traceback)
      if not apply_ok and sessions[item.bufnr] then
        event_queue[#event_queue + 1] = { bufnr = item.bufnr, event = {
          type = "failed", generation = sessions[item.bufnr].generation,
          operation = item.event.type, message = tostring(err), row = item.event.row,
        } }
      end
    end
  end
  reducing = false
end

---@param bufnr integer
local function dispatch_view(bufnr)
  local session = sessions[bufnr]
  if session then dispatch(bufnr, {
    type = "view_changed", generation = session.generation,
    viewports = viewports(bufnr), cursor_row = cursor_row(bufnr),
  }) end
end

---Coalesce source/dependency edits into one fresh generation.
---@param bufnr integer
---@param force_render? boolean
function schedule_refresh(bufnr, force_render)
  local resource = resources[bufnr]
  if not resource then return end
  resource.force_render = resource.force_render or force_render == true
  close_timer(resource.debounce_timer)
  local timer = assert(vim.uv.new_timer())
  resource.debounce_timer = timer
  timer:start(policy.debounce_ms, 0, vim.schedule_wrap(function()
    close_timer(timer)
    if resources[bufnr] then
      resources[bufnr].debounce_timer = nil
      local force = resources[bufnr].force_render == true
      resources[bufnr].force_render = false
      M.refresh(bufnr, force)
    end
  end))
end

local function splice(values, first, last, replacement)
  local out = {}
  for index = 1, first do out[#out + 1] = values[index] end
  for _, value in ipairs(replacement) do out[#out + 1] = value end
  for index = last + 1, #values do out[#out + 1] = values[index] end
  return out
end

---Return whether an edit can change or displace a retained same-note range.
---Neovim edit endpoints are exclusive, while stored range endpoints are
---inclusive. The row immediately after a range can also define its boundary.
---@param range ObsidianEmbedsSameNoteRange
---@param first_line integer
---@param last_line integer
---@param new_last_line integer
---@return boolean
local function edit_invalidates_same_note_range(range, first_line, last_line, new_last_line)
  return first_line <= range.end_row + 1
    and (last_line ~= new_last_line or range.start_row < math.max(last_line, new_last_line))
end

---Attach source observers and start the first render generation.
---@param bufnr? integer
function M.attach(bufnr)
  ensure_initialized()
  obsidian_port.assert_available()
  bufnr = normalize_bufnr(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then error("Obsidian embeds requires a valid buffer", 2) end
  if resources[bufnr] then return end
  local source = snapshot(bufnr)
  if not source then error("Obsidian embeds requires a loaded buffer in an Obsidian workspace", 2) end

  local resource = {
    source_lines = vim.deepcopy(source.lines), row_ids = vim.deepcopy(source.row_ids),
    next_row_id = #source.row_ids + 1,
  }
  resources[bufnr], sessions[bufnr] = resource, machine.new(bufnr)
  local group = vim.api.nvim_create_augroup(config.namespace .. "-" .. bufnr, { clear = true })
  resource.group = group

  vim.api.nvim_buf_attach(bufnr, false, {
    on_lines = function(_, _, changedtick, first_line, last_line, new_last_line)
      if resources[bufnr] ~= resource then return true end
      local changed = vim.api.nvim_buf_get_lines(bufnr, first_line, new_last_line, false)
      -- Parsing belongs to the debounced analysis command. Re-parsing the full
      -- Tree-sitter tree in every on_lines callback would make edit bursts
      -- synchronous and defeats the purpose of coalescing refreshes.
      local replacement_ids = {}
      for index = 1, #changed do
        replacement_ids[index] = resource.next_row_id
        resource.next_row_id = resource.next_row_id + 1
      end
      resource.source_lines = splice(resource.source_lines, first_line, last_line, changed)
      resource.row_ids = splice(resource.row_ids, first_line, last_line, replacement_ids)
      resource.changedtick, resource.diagnostic_row = changedtick, first_line
      local session = sessions[bufnr]
      local force_render = false
      for _, committed in pairs(session and session.committed_rows or {}) do
        for _, range in ipairs(committed.same_note_ranges or {}) do
          if edit_invalidates_same_note_range(range, first_line, last_line, new_last_line) then
            force_render = true
          end
        end
      end
      schedule_refresh(bufnr, force_render)
    end,
    on_reload = function(_, buffer)
      if resources[bufnr] ~= resource then return true end
      resource.source_lines, resource.row_ids = vim.api.nvim_buf_get_lines(buffer, 0, -1, false), {}
      for index = 1, #resource.source_lines do
        resource.row_ids[index] = resource.next_row_id
        resource.next_row_id = resource.next_row_id + 1
      end
      schedule_refresh(bufnr, true)
    end,
    on_detach = function() if resources[bufnr] == resource then M.detach(bufnr) end end,
  })
  vim.api.nvim_create_autocmd({ "BufEnter", "CursorMoved", "CursorMovedI", "WinScrolled" }, {
    group = group, callback = function(ev)
      if resources[bufnr] and (ev.buf == nil or ev.buf == bufnr or vim.api.nvim_get_current_buf() == bufnr) then dispatch_view(bufnr) end
    end,
  })
  vim.api.nvim_create_autocmd("BufFilePost", {
    group = group, buffer = bufnr,
    callback = function() if resources[bufnr] then schedule_refresh(bufnr, true) end end,
  })
  vim.api.nvim_create_autocmd({ "BufWinEnter", "WinEnter", "WinResized", "VimResized" }, {
    group = group, callback = function()
      if resources[bufnr] and #vim.fn.win_findbuf(bufnr) > 0 then presenter.request_redraw(bufnr) end
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group, buffer = bufnr, callback = function() if resources[bufnr] then M.detach(bufnr) end end,
  })
  dependency_observer.setup({
    index = dependency_index,
    on_change = function(event)
      local buffers = dependency_index:affected(event)
      local invalidated_workspaces = {}
      for buffer in pairs(buffers) do
        local session = sessions[buffer]
        local workspace_key = session and session.snapshot and session.snapshot.workspace_key
        local workspace = workspace_key and workspaces[workspace_key]
        if workspace and not invalidated_workspaces[workspace_key] then
          invalidated_workspaces[workspace_key] = true
          invalidate_resolution_cache(workspace)
        end
        schedule_refresh(buffer, true)
      end
    end,
  })
  source.force_render = true
  dispatch(bufnr, { type = "refresh", snapshot = source })
end

---Install automatic attachment and parser-recovery hooks once.
function M.setup()
  ensure_initialized()
  obsidian_port.assert_available()
  if not runtime_installed then
    runtime_installed = true
    local group = vim.api.nvim_create_augroup(config.namespace .. "-runtime", { clear = true })
    vim.api.nvim_create_autocmd({ "BufEnter", "BufReadPost", "FileType" }, { group = group, callback = function(ev)
      vim.schedule(function()
        if runtime_installed and vim.api.nvim_buf_is_valid(ev.buf) and vim.api.nvim_buf_is_loaded(ev.buf)
          and vim.b[ev.buf].obsidian_buffer == true and not resources[ev.buf] then pcall(M.attach, ev.buf)
        elseif sessions[ev.buf] and sessions[ev.buf].phase == "degraded" then schedule_refresh(ev.buf, true) end
      end)
    end })
    vim.api.nvim_create_autocmd("User", { group = group, pattern = { "LazyDone", "TSUpdate" }, callback = function()
      for bufnr, session in pairs(sessions) do if session.phase == "degraded" then schedule_refresh(bufnr, true) end end
    end })
  end
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and vim.b[bufnr].obsidian_buffer == true and not resources[bufnr] then M.attach(bufnr) end
  end
end

---@param bufnr? integer
function M.detach(bufnr)
  bufnr = normalize_bufnr(bufnr)
  if sessions[bufnr] then dispatch(bufnr, { type = "detach" }) end
end

---@param enabled boolean
---@param bufnr? integer
function M.set_enabled(enabled, bufnr)
  if type(enabled) ~= "boolean" then error("enabled must be a boolean", 2) end
  bufnr = normalize_bufnr(bufnr)
  if not sessions[bufnr] then error("Obsidian embeds is not attached to buffer " .. bufnr, 2) end
  local source = enabled and snapshot(bufnr) or nil
  if enabled and not source then error("Obsidian embeds requires a loaded buffer in an Obsidian workspace", 2) end
  if source then source.force_render = true end
  dispatch(bufnr, { type = "enabled_set", enabled = enabled, snapshot = source })
end

---@param bufnr? integer
---@return boolean
function M.toggle(bufnr)
  bufnr = normalize_bufnr(bufnr)
  if not sessions[bufnr] then M.attach(bufnr) end
  local enabled = not sessions[bufnr].enabled
  M.set_enabled(enabled, bufnr)
  return enabled
end

---@param bufnr? integer
---@param force_render? boolean
function M.refresh(bufnr, force_render)
  bufnr = normalize_bufnr(bufnr)
  local session, source = sessions[bufnr], snapshot(bufnr)
  if not session then return end
  if not source then
    M.detach(bufnr)
    return
  end
  local invalidate_resolution = force_render == nil
  local resource = resources[bufnr]
  if force_render ~= false and resource then
    close_timer(resource.debounce_timer)
    resource.debounce_timer, resource.force_render = nil, false
  end
  source.force_render = force_render ~= false
  dispatch(bufnr, { type = "refresh", snapshot = source, invalidate_resolution = invalidate_resolution })
end

function M.inspect(bufnr) return machine.inspect(sessions[normalize_bufnr(bufnr)]) end
function M.project_marks(bufnr, winid) return presenter.project_buffer(normalize_bufnr(bufnr), winid) end

return M
