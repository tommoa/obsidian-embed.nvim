local M = {} -- Adapter-only render contexts; never stored in canonical state.

---@alias ObsidianEmbedsPathIndex table<string, table<string, true>>
---@alias ObsidianEmbedsVirtChunk [string, string]
---@alias ObsidianEmbedsVirtLine ObsidianEmbedsVirtChunk[]
---@class ObsidianEmbedsHostLayout
---@field kind "body"|"list"|"task"|"quote"|"table"
---@field prefix string Structural text retained before an exact embed.
---@field continuation string Structural text used before continuation lines.
---@field exact boolean Whether the host content consists solely of one embed.
---@alias ObsidianEmbedsRefRange { start_col: integer, end_col: integer }

---@class ObsidianEmbedsRef
---@field raw string
---@field target string
---@field embed boolean
---@field kind? string
---@field label? string
---@field anchor? string
---@field block? string
---@field range ObsidianEmbedsRefRange

---@class ObsidianEmbedsSectionRange
---@field start_row integer
---@field end_row integer

---@class ObsidianEmbedsSection
---@field range ObsidianEmbedsSectionRange

---@class ObsidianEmbedsBlock
---@field id? string
---@field block? string
---@field line? integer
---@field section? ObsidianEmbedsSection

---@class ObsidianEmbedsNote
---@field id? string
---@field title? string
---@field path? string
---@field bufnr? integer
---@field contents string[]
---@field aliases? string[]
---@field frontmatter_end_line? integer
---@field display_name? fun(self: ObsidianEmbedsNote): string
---@field reference_ids? fun(self: ObsidianEmbedsNote, opts?: table): string[]
---@field get_reference_paths? fun(self: ObsidianEmbedsNote, opts?: table): string[]
---@field resolve_block fun(self: ObsidianEmbedsNote, block: string): ObsidianEmbedsBlock?
---@field resolve_anchor_link fun(self: ObsidianEmbedsNote, anchor: string): { section?: ObsidianEmbedsSection }?

---@class ObsidianEmbedsNoteOpts
---@field collect_sections? boolean
---@field collect_anchor_links? boolean
---@field collect_blocks? boolean
---@field max_lines? integer

---@class ObsidianEmbedsCurrentNoteRequirements
---@field needed boolean
---@field collect_sections boolean
---@field collect_anchor_links boolean
---@field collect_blocks boolean

---@class ObsidianEmbedsDependencySet
---@field paths ObsidianEmbedsPathIndex Workspace root to absolute note paths.
---@field unresolved ObsidianEmbedsPathIndex Workspace root to unresolved reference keys.
---@field queries ObsidianEmbedsPathIndex Workspace root to non-relative lookup keys.

---@class ObsidianEmbedsRowState
---@field row integer
---@field refs ObsidianEmbedsRef[]
---@field exact boolean True when the source line is exactly one embed ref.
---@field host ObsidianEmbedsHostLayout
---@field blocks ObsidianEmbedsRenderBlock[]
---@field dependencies ObsidianEmbedsDependencySet
---@field same_note_ranges ObsidianEmbedsSameNoteRange[]

---@class ObsidianEmbedsRenderBlock
---@field ref ObsidianEmbedsRef
---@field lines? ObsidianEmbedsVirtLine[]
---@field project? fun(width: integer): ObsidianEmbedsVirtLine[]
---@field line_count? integer Pre-projection scheduler count; each provider reserves one line.

---@class ObsidianEmbedsSameNoteRange
---@field start_row integer
---@field end_row integer

---@class ObsidianEmbedsBufferState
---@field bufnr integer
---@field workspace_root string
---@field base_dir? string
---@field host_path? string Absolute path of the note owning this render context.
---@field cursor_row? integer
---@field line_count integer
---@field source_lines string[]
---@field changedtick integer
---@field resolution_requests table<string, table>
---@field owner? table
---@field generation? integer
---@field io_runtime? table
---@field cache_epoch? integer
---@field cache_write? fun(kind: string, key: string, value: table)
---@field cache_read? fun(kind: string, key: string): table?
---@field current_note_opts? ObsidianEmbedsNoteOpts
---@field current_note? ObsidianEmbedsNote
---@field current_note_error? string
---@field has_same_note_refs boolean

---@class ObsidianEmbedsRenderContext
---@field depth integer
---@field stack table<string, true>
---@field workspace_root string
---@field base_dir? string Directory relative links resolve from for the note currently being rendered.
---@field host_path? string Absolute path of the note owning this render branch.
---@field current_note? ObsidianEmbedsNote
---@field current_note_error? string
---@field dependencies ObsidianEmbedsDependencySet
---@field resolution_requests table<string, table>
---@field io_runtime? table
---@field cache_epoch? integer
---@field owner? table

---Require a constructor field while preserving its inferred value.
local function assert_present(value, name)
  assert(value ~= nil, "obsidian-embed.nvim state requires " .. name)
  return value
end

---Create mutable rendering state from an immutable source snapshot.
---@param args { bufnr: integer, workspace_root: string, base_dir?: string, cursor_row?: integer, lines: string[], requirements: ObsidianEmbedsCurrentNoteRequirements, current_note_opts?: ObsidianEmbedsNoteOpts, current_note?: ObsidianEmbedsNote, current_note_error?: string }
---@return ObsidianEmbedsBufferState
function M.new_buffer_state(args)
  args = args or {}
  local lines = assert_present(args.lines, "lines")
  local requirements = assert_present(args.requirements, "requirements")
  local bufnr = assert_present(args.bufnr, "bufnr")

  return {
    bufnr = bufnr,
    workspace_root = assert_present(args.workspace_root, "workspace_root"),
    base_dir = args.base_dir,
    host_path = args.host_path,
    cursor_row = args.cursor_row,
    line_count = #lines,
    source_lines = lines,
    changedtick = vim.b[bufnr].changedtick or 0,
    resolution_requests = {},
    current_note_opts = args.current_note_opts,
    current_note = args.current_note,
    current_note_error = args.current_note_error,
    io_runtime = args.io_runtime,
    cache_epoch = args.cache_epoch,
    cache_write = args.cache_write,
    cache_read = args.cache_read,
    has_same_note_refs = requirements.needed == true,
  }
end

---Validate and create the context shared through one asynchronous render branch.
---@param args ObsidianEmbedsRenderContext
---@return ObsidianEmbedsRenderContext
function M.new_render_context(args)
  args = args or {}
  assert_present(args.depth, "depth")
  assert_present(args.stack, "stack")
  assert_present(args.workspace_root, "workspace_root")
  assert_present(args.resolution_requests, "resolution_requests")
  assert_present(args.dependencies, "dependencies")
  return vim.tbl_extend("force", {}, args)
end

---Create a root render context for one analyzed source row.
---@param buffer_state ObsidianEmbedsBufferState
---@param dependencies ObsidianEmbedsDependencySet
---@return ObsidianEmbedsRenderContext
function M.new_row_context(buffer_state, dependencies)
  return M.new_render_context({
    depth = 1,
    stack = {},
    workspace_root = buffer_state.workspace_root,
    base_dir = buffer_state.base_dir,
    host_path = buffer_state.host_path,
    current_note = buffer_state.current_note,
    current_note_error = buffer_state.current_note_error,
    resolution_requests = buffer_state.resolution_requests,
    io_runtime = buffer_state.io_runtime,
    cache_epoch = buffer_state.cache_epoch,
    cache_write = buffer_state.cache_write,
    cache_read = buffer_state.cache_read,
    owner = buffer_state.owner,
    dependencies = dependencies,
  })
end

---Derive a render context while sharing caches and overriding selected fields.
---@param ctx ObsidianEmbedsRenderContext
---@param overrides? table
---@return ObsidianEmbedsRenderContext
function M.derive(ctx, overrides)
  return M.new_render_context(vim.tbl_extend("force", {}, ctx, overrides or {}))
end

---Derive the context used to resolve relative embeds inside a target note.
---@param ctx ObsidianEmbedsRenderContext
---@param note ObsidianEmbedsNote
---@return ObsidianEmbedsRenderContext
function M.for_note_context(ctx, note)
  return M.derive(ctx, {
    current_note = note,
    current_note_error = ctx.current_note_error,
    base_dir = note and note.path and vim.fs.dirname(tostring(note.path)) or ctx.base_dir,
    host_path = note and note.path and tostring(note.path) or ctx.host_path,
  })
end

return M
