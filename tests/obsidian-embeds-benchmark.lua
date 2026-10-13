-- Reporting harness, deliberately separate from smoke-test timing thresholds.
-- Headless: nvim --headless -u NONE -i NONE -l tests/obsidian-embeds-benchmark.lua
-- Painted frames: nvim -u NONE -i NONE -n -c "lua dofile('tests/obsidian-embeds-benchmark.lua')"
-- OBSIDIAN_EMBEDS_BENCH_RUNS (default 3), OBSIDIAN_EMBEDS_BENCH_CASE (optional),
-- OBSIDIAN_EMBEDS_BENCH_OUTPUT (optional JSON path); dependencies use testlib's RTP.
local directory = vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))
local test = dofile(directory .. "/testlib.lua")
local fixtures = dofile(directory .. "/benchmark-fixtures.lua")
local observers = dofile(directory .. "/benchmark-observer.lua")
test.setup_runtime()

local runs = tonumber(vim.env.OBSIDIAN_EMBEDS_BENCH_RUNS or "3")
assert(runs and runs >= 1 and runs % 1 == 0, "benchmark runs must be a positive integer")
local selected = vim.env.OBSIDIAN_EMBEDS_BENCH_CASE
local root = vim.fn.tempname()
vim.fn.mkdir(root .. "/.obsidian", "p")
require("obsidian").setup {
  legacy_commands = false,
  workspaces = { { name = "benchmark", path = root } },
  ui = { enable = false },
}
-- Load parsers and queries before timing so attachment and edit measurements
-- exclude dependency initialization.
for _, lang in ipairs({ "markdown", "markdown_inline" }) do
  vim.treesitter.get_string_parser("**sample**", lang):parse()
  assert(vim.treesitter.query.get(lang, "highlights"), "missing highlight query: " .. lang)
end
local embeds = require("obsidian-embed")
local runtime = require("obsidian-embed.runtime")
local analyzer = require("obsidian-embed.analyzer")
local machine = require("obsidian-embed.machine")
local presenter = require("obsidian-embed.presenter")
embeds.setup()
vim.o.columns, vim.o.lines = 100, 32
vim.o.laststatus, vim.o.showtabline = 0, 0
vim.o.showmode, vim.o.ruler = false, false
vim.o.cmdheight = 1
vim.o.wrap = false
local painted = #vim.api.nvim_list_uis() > 0
assert(not painted or vim.env.OBSIDIAN_EMBEDS_BENCH_OUTPUT, "terminal runs require a JSON output path")
local active
local originals = {}
local function now() return vim.uv.hrtime() / 1e6 end

-- Time the analyzer and presenter calls made by the plugin. Extra calls from
-- the sampling loop would add work and change the durations being measured.
local function instrument(module, key, metric, line_argument)
  local original = module[key]
  originals[#originals + 1] = function() module[key] = original end
  module[key] = function(...)
    local measurement, started = active, now()
    local result = original(...)
    if measurement then
      local duration = now() - started
      local stats = measurement[metric]
      stats.calls, stats.total_ms = stats.calls + 1, stats.total_ms + duration
      stats.max_ms = math.max(stats.max_ms, duration)
      if line_argument then stats.lines = stats.lines + #select(line_argument, ...) end
      if metric == "host_analysis" then
        -- Record the presentation count when host analysis finishes. A later
        -- presentation pass is required to observe output for this generation.
        measurement.calls_after_analysis = presenter.inspect_provider().calls
      end
    end
    return result
  end
end
instrument(analyzer, "analyze_buffer", "host_analysis", 2)
instrument(analyzer, "analyze", "note_analysis", 1)
instrument(presenter, "project", "projection")
local transition = machine.transition
originals[#originals + 1] = function() machine.transition = transition end
-- Record commit and settlement timestamps when the state machine changes phase.
-- Polling would add up to one sampling interval to these timestamps. Rendering
-- can settle before the presenter installs the corresponding extmarks.
machine.transition = function(session, event)
  local result = transition(session, event)
  if active and session.bufnr == active.bufnr and session.generation > active.previous_generation then
    if event.type == "row_completed" and event.row == active.first_row and not event.error then
      active.first_ready_ms = active.first_ready_ms or (now() - active.started)
    end
    if session.phase == "settled" and not active.settled_ms then
      active.settled_ms = now() - active.started
      active.calls_at_settlement = presenter.inspect_provider().calls
    end
  end
  return result
end

local function stats() return { calls = 0, total_ms = 0, max_ms = 0, lines = 0 } end
local function screen_contains(token)
  -- A terminal UI is required: screenstring observes Neovim's composed frame.
  for row = 1, vim.o.lines - vim.o.cmdheight do
    local chars = {}
    for col = 1, vim.o.columns do chars[#chars + 1] = vim.fn.screenstring(row, col) end
    if table.concat(chars):find(token, 1, true) then return true end
  end
  return false
end

local function measure(bufnr, token, fixture, action)
  -- Keep a previous sample's outstanding garbage collection outside the next
  -- timing window. Allocations and collection caused by this action still count.
  collectgarbage("collect")
  local previous = embeds.inspect(bufnr).generation or 0
  local measurement = {
    bufnr = bufnr, previous_generation = previous,
    first_row = fixture.rows[1],
    host_analysis = stats(), note_analysis = stats(), projection = stats(),
    heartbeat_period_ms = 5, worst_heartbeat_gap_ms = 0, heartbeat_samples = 0,
  }
  local heartbeat = assert(vim.uv.new_timer())
  local last
  -- Start the heartbeat before the action: synchronous host analysis blocks
  -- the event loop before rendering starts and must contribute to the worst gap.
  heartbeat:start(0, measurement.heartbeat_period_ms, vim.schedule_wrap(function()
    local sampled = now()
    if active == measurement and last then
      measurement.worst_heartbeat_gap_ms = math.max(measurement.worst_heartbeat_gap_ms, sampled - last)
      measurement.heartbeat_samples = measurement.heartbeat_samples + 1
    end
    last = sampled
  end))
  assert(vim.wait(1000, function() return last ~= nil end, 1), "heartbeat failed to start")
  local winid = vim.api.nvim_get_current_win()
  local observer, observed_calls
  measurement.started = now()
  last, active = measurement.started, measurement
  action()
  measurement.action_ms = now() - measurement.started
  local complete = vim.wait(60000, function()
    local status = embeds.inspect(bufnr)
    assert(status.phase ~= "degraded", "benchmark degraded: " .. vim.inspect(status))
    local provider = presenter.inspect_provider()
    assert(not provider.last_error, "presentation extmark failed")
    local fresh = status.generation > previous
    local updated = measurement.calls_after_analysis and provider.calls > measurement.calls_after_analysis
      and provider.last_bufnr == bufnr and provider.last_winid == winid
    -- Read installed marks once per fresh presentation pass, not every poll.
    -- Coverage is checked only after a pass following semantic settlement.
    if fresh and updated and provider.calls ~= observed_calls then
      observed_calls = provider.calls
      if not observer then
        local ns = assert(vim.api.nvim_get_namespaces()["obsidian-embed.window." .. winid])
        observer = observers.new(bufnr, ns, fixture.rows, fixture.needs_continuations, token)
      end
      local final_pass = measurement.calls_at_settlement and provider.calls > measurement.calls_at_settlement
      local marker = observer.observe(final_pass)
      if marker then measurement.first_installed_ms = measurement.first_installed_ms or (now() - measurement.started) end
    end
    if painted and measurement.first_installed_ms and not measurement.first_display_ms then
      -- Explicit redraw makes this a composed-frame latency, including draw cost.
      vim.cmd.redraw()
      if screen_contains(token) then measurement.first_display_ms = now() - measurement.started end
    end
    -- Verify installed output in a presentation pass following semantic settlement.
    if fresh and status.phase == "settled" and measurement.first_installed_ms
        and (not painted or measurement.first_display_ms)
        and observer and observer.coverage_seen
    then return true end
    return false
  end, 5)
  measurement.presentation_settled_ms = now() - measurement.started
  -- Let a heartbeat observe the final synchronous draw/projection before stopping.
  vim.wait(15, function() return false end, 5)
  active = nil
  heartbeat:stop()
  heartbeat:close()
  assert(complete, "benchmark timed out: " .. vim.inspect(embeds.inspect(bufnr)))
  local status = embeds.inspect(bufnr)
  assert(status.generation == previous + 1, "unexpected additional generation")
  assert(measurement.host_analysis.calls == 1, "expected exactly one host analysis")
  assert(status.units.failed == 0 and measurement.heartbeat_samples > 0, "incomplete measurement")
  measurement.ready_rows = status.units.ready
  -- These fields coordinate observation within a sample; published samples
  -- contain durations and workload counters, without buffer IDs or clock origins.
  measurement.bufnr, measurement.previous_generation, measurement.started, measurement.first_row = nil, nil, nil, nil
  measurement.calls_after_analysis, measurement.calls_at_settlement = nil, nil
  return measurement
end

local function git_revision(directory)
  local result = vim.system({ "git", "-C", directory, "rev-parse", "HEAD" }, { text = true }):wait()
  return result.code == 0 and vim.trim(result.stdout) or "unavailable"
end
local report = {
  schema_version = 1,
  environment = {
    neovim = vim.version(), luajit = jit.version, os = vim.uv.os_uname(),
    cpus = vim.uv.cpu_info(), memory_bytes = vim.uv.get_total_memory(),
    plugin_revision = git_revision(vim.fs.dirname(directory)),
    obsidian_revision = git_revision(vim.fs.dirname(debug.getinfo(require("obsidian").setup, "S").source:sub(2))),
    plenary_revision = git_revision(vim.fs.dirname(vim.api.nvim_get_runtime_file("lua/plenary/path.lua", false)[1])),
    parsers = {},
    runtimepath = vim.opt.runtimepath:get(), ui_attached = painted,
    columns = vim.o.columns, lines = vim.o.lines,
    policy = vim.deepcopy(require("obsidian-embed.policy")),
  },
  runs = {},
}
-- cpu_info includes accumulated OS counters; retain only useful environment data.
for _, cpu in ipairs(report.environment.cpus or {}) do cpu.times = nil end
for _, lang in ipairs({ "markdown", "markdown_inline" }) do
  report.environment.parsers[lang] = {
    files = vim.api.nvim_get_runtime_file("parser/" .. lang .. ".*", true),
    abi = vim.treesitter.language.inspect(lang).abi_version,
    queries = vim.api.nvim_get_runtime_file("queries/" .. lang .. "/highlights.scm", true),
  }
end
local ok, err = xpcall(function()
  for sample = 1, runs do
    for _, case in ipairs(fixtures.cases) do
      if not selected or selected == case.name then
        local fixture = fixtures.write(test, root .. "/" .. case.name .. sample, case, sample .. "_" .. case.name)
        vim.cmd("noautocmd edit " .. vim.fn.fnameescape(fixture.main))
        local bufnr = vim.api.nvim_get_current_buf()
        vim.bo[bufnr].filetype = "markdown"
        vim.api.nvim_win_set_cursor(0, { 1, 0 })
        -- Drain setup hooks before making the buffer eligible for attachment.
        vim.wait(20, function() return false end, 5)
        local initial = measure(bufnr, fixture.base, fixture, function()
          vim.b[bufnr].obsidian_buffer = true
          runtime.attach(bufnr)
        end)
        assert(initial.ready_rows == case.embeds, "fixture did not render every embed")
        -- Fresh content must incur one analysis per distinct target, while
        -- repeated references share it. These are workload checks, not timings.
        assert(initial.note_analysis.calls == case.targets,
          string.format("%s initial: expected %d fresh note analyses, got %d",
            case.name, case.targets, initial.note_analysis.calls))
        assert(initial.note_analysis.lines == case.targets * case.note_lines, "unexpected initial analysis workload")
        local edit = measure(bufnr, fixture.edited, fixture, function()
          vim.api.nvim_buf_set_lines(bufnr, fixture.rows[1], fixture.rows[1] + 1, false, { fixture.edited_ref })
        end)
        assert(edit.note_analysis.calls == case.depth,
          string.format("%s edit: expected %d fresh note analyses, got %d",
            case.name, case.depth, edit.note_analysis.calls))
        assert(edit.note_analysis.lines == case.depth * case.note_lines, "unexpected edited analysis workload")
        local unrelated = measure(bufnr, fixture.edited, fixture, function()
          vim.api.nvim_buf_set_lines(bufnr, case.host_lines - 1, case.host_lines, false, { "unrelated edit" })
        end)
        assert(edit.ready_rows == case.embeds and unrelated.ready_rows == case.embeds, "edit lost embed rows")
        assert(unrelated.note_analysis.calls == 0, "unrelated edit should retain rendered notes")
        report.runs[#report.runs + 1] = { case = case, sample = sample, initial = initial, edit = edit, unrelated = unrelated }
        runtime.detach(bufnr)
        vim.cmd("noautocmd bwipeout! " .. bufnr)
        if not painted then
          io.stderr:write(string.format("benchmark %s sample %d/%d complete\n", case.name, sample, runs))
        end
      end
    end
  end
  assert(#report.runs > 0, "unknown benchmark case: " .. tostring(selected))
end, debug.traceback)
active = nil
-- Restore instrumentation and delete fixtures on both success and failure.
-- Interactive runs use cquit so CI receives a nonzero status instead of a prompt.
for _, restore in ipairs(originals) do restore() end
vim.fn.delete(root, "rf")
if not ok then
  if painted then
    vim.api.nvim_err_writeln(err)
    vim.cmd("cquit")
  end
  error(err, 0)
end
local function summarize(values)
  table.sort(values)
  local middle = math.floor(#values / 2) + 1
  local median = #values % 2 == 1 and values[middle] or (values[middle - 1] + values[middle]) / 2
  return { min = values[1], median = median, max = values[#values] }
end
-- Aggregate durations by workload and edit phase. Keep raw counters in runs:
-- averaging them would obscure the exact workload checks performed above.
-- Optional frame/commit timestamps are omitted when that phase did not emit one.
report.summary = {}
for _, case in ipairs(fixtures.cases) do
  if not selected or selected == case.name then
    local summary = { case = case.name }
    for _, stage in ipairs({ "initial", "edit", "unrelated" }) do
      summary[stage] = {}
      for _, metric in ipairs({
        "action_ms", "first_ready_ms", "first_installed_ms", "first_display_ms", "settled_ms",
        "presentation_settled_ms", "worst_heartbeat_gap_ms",
      }) do
        local values = {}
        for _, run in ipairs(report.runs) do
          if run.case.name == case.name and run[stage][metric] then values[#values + 1] = run[stage][metric] end
        end
        if #values > 0 then summary[stage][metric] = summarize(values) end
      end
      for _, phase in ipairs({ "host_analysis", "note_analysis", "projection" }) do
        summary[stage][phase] = {}
        for _, metric in ipairs({ "total_ms", "max_ms" }) do
          local values = {}
          for _, run in ipairs(report.runs) do
            if run.case.name == case.name then values[#values + 1] = run[stage][phase][metric] end
          end
          summary[stage][phase][metric] = summarize(values)
        end
      end
    end
    report.summary[#report.summary + 1] = summary
  end
end
local encoded = vim.json.encode(report)
if vim.env.OBSIDIAN_EMBEDS_BENCH_OUTPUT then
  local output = assert(io.open(vim.env.OBSIDIAN_EMBEDS_BENCH_OUTPUT, "w"))
  output:write(encoded, "\n")
  output:close()
end
if painted then
  -- Exit the interactive process; JSON lives in the requested output file.
  vim.cmd("qa!")
elseif vim.env.OBSIDIAN_EMBEDS_BENCH_OUTPUT then
  print("case         analysis   installed   settled   max-gap   edit-installed (ms, medians)")
  for _, summary in ipairs(report.summary) do
    print(string.format("%-12s %8.1f %10.1f %9.1f %9.1f %12.1f", summary.case,
      summary.initial.host_analysis.total_ms.median, summary.initial.first_installed_ms.median,
      summary.initial.settled_ms.median, summary.initial.worst_heartbeat_gap_ms.median,
      summary.edit.first_installed_ms.median))
  end
  print("JSON report: " .. vim.env.OBSIDIAN_EMBEDS_BENCH_OUTPUT)
else
  print(encoded)
end
