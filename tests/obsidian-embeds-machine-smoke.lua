local test = dofile(vim.fs.joinpath(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h"), "testlib.lua"))
test.setup_runtime()

local machine = require("obsidian-embed.machine")
local policy = require("obsidian-embed.policy")

local snapshot = {
  bufnr = 7,
  workspace_key = "/vault",
  base_dir = "/vault",
  lines = { "![[Background]]", "plain", "![[Visible]]" },
  row_ids = { 1, 2, 3 },
  viewports = { { first_row = 2, last_row = 2 } },
  cursor_row = 2,
  force_render = true,
}

-- Refresh is the single entry into a new generation.
local session = machine.new(7)
test.assert_true(not pcall(machine.transition, session, { type = "misspelled" }), "unknown events should fail loudly")
local result = machine.transition(session, { type = "refresh", snapshot = snapshot })
test.assert_true(session.phase == "analyzing" and session.generation == 1, "refresh should start analysis")
test.assert_true(result.analyze, "refresh should request analysis")

local analysis = { rows = {
  { refs = { { target = "Background" } }, semantic_signature = "background" },
  { refs = {}, semantic_signature = "plain" },
  { refs = { { target = "Visible" } }, semantic_signature = "visible" },
} }
result = machine.transition(session, { type = "analysis_completed", generation = 1, analysis = analysis })
test.assert_true(session.phase == "rendering" and result.wake == "tick", "analysis should schedule rows")

-- The machine admits visible work before rows outside the viewport.
result = machine.transition(session, { type = "tick", generation = 1 })
test.assert_true(result.render_row == 2 and session.units[2].stage == "running", "visible row should run first")
local result = {
  refs = {}, exact = true, blocks = { { ref = {}, lines = { { { "ready", "Normal" } } } } }, same_note_ranges = {},
  dependencies = { paths = { ["/vault"] = { ["/vault/Visible.md"] = true } }, queries = {}, unresolved = {} },
}
result = machine.transition(session, {
  type = "row_completed", generation = 1, row = 2, result = result, embed_count = 1, line_count = 1,
})
test.assert_true(session.units[2].stage == "ready", "row completion should become ready")
test.assert_true(#result.dependency_deltas == 1 and result.redraw, "completed rows should publish atomically")
result = machine.transition(session, { type = "tick", generation = 1 })
test.assert_true(result.render_row == 0, "prefetch rows should be admitted after visible rows without waiting for idle")

-- Priority is computed from the latest viewport rather than retained in lane queues.
local reprioritized = machine.new(9)
local reprioritized_snapshot = {
  bufnr = 9, workspace_key = "/vault", base_dir = "/vault",
  lines = { "![[First]]", "plain", "plain", "plain", "plain", "![[Second]]" },
  row_ids = { 1, 2, 3, 4, 5, 6 }, viewports = { { first_row = 0, last_row = 0 } }, force_render = true,
}
machine.transition(reprioritized, { type = "refresh", snapshot = reprioritized_snapshot })
machine.transition(reprioritized, { type = "analysis_completed", generation = 1, analysis = { rows = {
  { refs = { { target = "First" } }, semantic_signature = "first" },
  { refs = {}, semantic_signature = "plain-2" }, { refs = {}, semantic_signature = "plain-3" },
  { refs = {}, semantic_signature = "plain-4" }, { refs = {}, semantic_signature = "plain-5" },
  { refs = { { target = "Second" } }, semantic_signature = "second" },
} } })
machine.transition(reprioritized, {
  type = "view_changed", generation = 1,
  viewports = { { first_row = 5, last_row = 5 } }, cursor_row = 5,
})
result = machine.transition(reprioritized, { type = "tick", generation = 1 })
test.assert_true(result.render_row == 5, "latest viewport should reprioritize pending rows without rebuilding queues")

-- Generation identity is the only stale-completion token.
local old_generation = session.generation
local replacement = vim.deepcopy(snapshot)
replacement.force_render = false
machine.transition(session, { type = "refresh", snapshot = replacement })
machine.transition(session, { type = "row_completed", generation = old_generation, row = 2, result = result })
test.assert_true(session.generation == old_generation + 1 and session.phase == "analyzing", "stale completion should be inert")

-- Semantically unchanged rows can settle without scheduling render work.
local retained_analysis = { rows = {
  { refs = {}, semantic_signature = "plain-now" },
  { refs = {}, semantic_signature = "plain" },
  { refs = { { target = "Visible" } }, semantic_signature = "visible" },
} }
result = machine.transition(session, {
  type = "analysis_completed", generation = session.generation, analysis = retained_analysis,
})
test.assert_true(session.phase == "settled" and result.wake == nil, "retained rows should settle immediately")

-- Resolution-context changes discard committed renders and remove dependencies
-- using the workspace that originally owned them.
local moved = machine.new(10)
local old_context = {
  bufnr = 10, workspace_key = "/vault-a", base_dir = "/vault-a/notes",
  lines = { "![[./Target]]" }, row_ids = { 1 }, viewports = { { first_row = 0, last_row = 0 } }, force_render = true,
}
machine.transition(moved, { type = "refresh", snapshot = old_context })
machine.transition(moved, { type = "analysis_completed", generation = 1, analysis = { rows = {
  { refs = { { target = "./Target" } }, semantic_signature = "relative" },
} } })
machine.transition(moved, { type = "tick", generation = 1 })
local old_result = {
  refs = {}, exact = true, blocks = { { ref = {}, lines = { { { "old", "Normal" } } } } }, same_note_ranges = {},
  dependencies = { paths = { ["/vault-a"] = { ["/vault-a/notes/Target.md"] = true } }, queries = {}, unresolved = {} },
}
machine.transition(moved, {
  type = "row_completed", generation = 1, row = 0, result = old_result, embed_count = 1, line_count = 1,
})
local new_context = vim.deepcopy(old_context)
new_context.workspace_key, new_context.base_dir = "/vault-b", "/vault-b/notes"
result = machine.transition(moved, { type = "refresh", snapshot = new_context })
local cleanup = result.dependency_deltas[1]
test.assert_true(
  cleanup and cleanup.workspace_key == "/vault-a" and cleanup.previous == old_result.dependencies,
  "moving resolution context should remove dependencies from the previous workspace"
)
test.assert_true(next(moved.committed_rows) == nil, "moving resolution context should discard committed renders")

-- Parser failures retain last-good presentation and expose one diagnostic.
local failing = vim.deepcopy(snapshot)
failing.force_render = true
machine.transition(session, { type = "refresh", snapshot = failing })
result = machine.transition(session, {
  type = "analysis_completed", generation = session.generation, analysis = { rows = {}, error = "parser unavailable" },
})
test.assert_true(session.phase == "degraded" and session.last_diagnostic.message == "parser unavailable", "parser failure should degrade safely")
test.assert_true(result.redraw, "parser diagnostics should be presented")

-- Row failures retain last-good output and redraw the new diagnostic.
local row_failure = machine.new(11)
local row_failure_snapshot = {
  bufnr = 11, workspace_key = "/vault", base_dir = "/vault",
  lines = { "![[Failure]]" }, row_ids = { 1 }, viewports = { { first_row = 0, last_row = 0 } }, force_render = true,
}
machine.transition(row_failure, { type = "refresh", snapshot = row_failure_snapshot })
machine.transition(row_failure, { type = "analysis_completed", generation = 1, analysis = { rows = {
  { refs = { { target = "Failure" } }, semantic_signature = "failure" },
} } })
machine.transition(row_failure, { type = "tick", generation = 1 })
local last_good = { refs = {}, exact = true, blocks = {}, same_note_ranges = {}, dependencies = { paths = {}, queries = {}, unresolved = {} } }
row_failure.committed_rows[0] = last_good
result = machine.transition(row_failure, {
  type = "row_completed", generation = 1, row = 0, error = "provider failed",
})
test.assert_true(result.redraw, "row render diagnostics should request presentation")
test.assert_true(row_failure.phase == "degraded" and row_failure.last_diagnostic.message == "provider failed",
  "row render failures should degrade with their diagnostic")
test.assert_true(row_failure.committed_rows[0] == last_good, "row render failures should retain last-good output")

-- Background work waits for the idle gate, and the fixed in-flight limit is enforced.
local background = machine.new(8)
local background_snapshot = {
  bufnr = 8, workspace_key = "/vault", base_dir = "/vault",
  lines = { "![[One]]", "![[Two]]", "![[Three]]", "![[Four]]", "![[Five]]" },
  row_ids = { 1, 2, 3, 4, 5 }, viewports = { { first_row = 100, last_row = 110 } }, force_render = true,
}
machine.transition(background, { type = "refresh", snapshot = background_snapshot })
local rows = {}
for index = 1, 5 do rows[index] = { refs = { { target = tostring(index) } }, semantic_signature = tostring(index) } end
machine.transition(background, { type = "analysis_completed", generation = 1, analysis = { rows = rows } })
result = machine.transition(background, { type = "tick", generation = 1 })
test.assert_true(result.wake == "idle", "background-only work should wait for idle")
machine.transition(background, { type = "idle_elapsed", generation = 1 })
for _ = 1, policy.max_in_flight + 1 do machine.transition(background, { type = "tick", generation = 1 }) end
local running = 0
for _, unit in pairs(background.units) do if unit.stage == "running" then running = running + 1 end end
test.assert_true(running == policy.max_in_flight, "machine should enforce the in-flight limit")

-- Enable and detach transitions own cleanup explicitly.
result = machine.transition(session, { type = "enabled_set", enabled = false })
test.assert_true(session.phase == "disabled" and not result.analyze, "disable should enter inactive state")
result = machine.transition(session, { type = "enabled_set", enabled = true, snapshot = snapshot })
test.assert_true(session.phase == "analyzing" and result.analyze, "enable should start a fresh generation")
result = machine.transition(session, { type = "detach" })
test.assert_true(session.phase == "detached", "detach should enter detached state for runtime reconciliation")

print("obsidian embeds machine smoke test passed")
