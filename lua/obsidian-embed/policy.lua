local M = {}

-- These are implementation policy, not user preferences. Keeping them here
-- gives the scheduler one source of truth without turning responsiveness into
-- a collection of knobs that every user has to tune.
M.slice_ns = 8 * 1000 * 1000
M.prefetch_screens = 2
M.max_in_flight = 4
M.resolver_request_limit = 4
M.resolver_note_read_limit = 4
M.active_embed_limit = 250
M.active_line_limit = 5000
M.idle_ms = 250
M.debounce_ms = 16
M.max_depth = 8

return M
