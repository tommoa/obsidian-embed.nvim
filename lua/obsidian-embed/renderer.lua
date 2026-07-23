local config = require("obsidian-embed.config")
local analyzer = require("obsidian-embed.analyzer")
local highlight = require("obsidian-embed.highlight")
local policy = require("obsidian-embed.policy")
local resolver = require("obsidian-embed.resolver")
local state = require("obsidian-embed.render_context")
local dependencies = require("obsidian-embed.dependencies")
local providers = require("obsidian-embed.providers")

local M = {}

local function queue_continuation(_, _, callback)
  -- Yield recursive work back to Neovim. The row's generation is validated
  -- once when the complete candidate returns to the state machine.
  vim.schedule(callback)
end

---Return rendering and presentation options.
---@return ObsidianEmbedsConfig
local function opts()
  return config.get()
end

---Append optional rendered lines to an accumulated result.
---@param dst ObsidianEmbedsVirtLine[]
---@param lines? ObsidianEmbedsVirtLine[]
local function append_lines(dst, lines)
  if not lines then
    return
  end
  for _, line in ipairs(lines) do
    dst[#dst + 1] = line
  end
end

---Create a warning virtual line at the current nesting depth.
---@param message string
---@param depth integer
---@return ObsidianEmbedsVirtLine
local function warn_line(message, depth)
  return highlight.warn_line(message, depth, opts())
end

local function warn_block(message, depth)
  return highlight.with_rail({ warn_line(message, depth) }, opts())
end

---Build the deliberately small public context exposed to an embed provider.
local function provider_context(ctx, ref)
  return {
    bufnr = ctx.owner and ctx.owner.bufnr,
    workspace_root = ctx.workspace_root,
    host_path = ctx.host_path,
    base_dir = ctx.base_dir,
    ref = vim.deepcopy(ref),
    generation = ctx.owner and ctx.owner.generation,
  }
end

---Run a matching provider and retain its declared file dependencies.
local function provider_render_async(ref, ctx, done)
  local public = provider_context(ctx, ref)
  local provider, match_error = providers.match(ref, public)
  if not provider then return false end
  if match_error then done(nil, "embed provider " .. provider.name .. " match failed: " .. match_error); return true end
  providers.render_async(provider, ref, public, function(result, err)
    if err then done(nil, "embed provider " .. provider.name .. ": " .. tostring(err)); return end
    for _, path in ipairs(result.dependencies or {}) do dependencies.track_path(ctx, path) end
    done(result)
  end, ctx.owner)
  return true
end

local function project_provider(result, width, depth)
  local ok, lines = pcall(result.project, width)
  if not ok then return warn_block("Embed provider error: " .. tostring(lines), depth) end
  if type(lines) ~= "table" then return warn_block("Embed provider returned invalid projection", depth) end
  return lines
end

local function prefix_lines(lines, first_prefix, continuation_prefix)
  local out = {}
  for index, line in ipairs(lines or {}) do
    out[#out + 1] = highlight.with_host(
      line,
      index == 1 and first_prefix or continuation_prefix,
      continuation_prefix
    )
  end
  return out
end

---Analyze and recursively render a selected note slice without blocking.
---@param api table
---@param lines string[]
---@param ctx ObsidianEmbedsRenderContext
---@param done fun(lines: ObsidianEmbedsVirtLine[]?, err?: string)
local function render_lines_async(api, lines, ctx, done)
  local analysis_key = table.concat(lines, "\n")
  local analysis = ctx.cache_read and ctx.cache_read("analysis", analysis_key) or nil
  local cached = analysis ~= nil
  if not analysis then
    local ok, value = pcall(analyzer.analyze, lines)
    if not ok then
      done(nil, tostring(value))
      return
    end
    analysis = value
  end
  if analysis.error then
    done(nil, analysis.error)
    return
  end
  if not cached and ctx.cache_write then
    ctx.cache_write("analysis", analysis_key, analysis)
  end
  local out = {}
  local line_index = 1

  ---Render the next analyzed line, continuing until the slice is exhausted.
  local function render_next_line()
    local line = lines[line_index]
    local analyzed_row = analysis.rows[line_index]
    if not line or not analyzed_row then
      done(out)
      return
    end
    line_index = line_index + 1

    local refs = {}
    for _, ref in ipairs(analyzed_row.refs) do
      refs[#refs + 1] = analyzer.to_upstream_ref(ref)
    end

    if analyzed_row.exact_embed and refs[1] then
      local child_ctx = state.derive(ctx, { depth = ctx.depth + 1 })
      -- Continue the line loop after an exact nested embed finishes rendering.
      api.safe_render_ref_async(refs[1], child_ctx, function(rendered)
        append_lines(out, prefix_lines(
          rendered,
          analyzed_row.host.prefix,
          analyzed_row.host.continuation
        ))
        queue_continuation(ctx, "nested_line_ready", render_next_line)
      end)
      return
    end

    out[#out + 1] = highlight.precomputed_line(analyzed_row.chunks, ctx.depth, opts())
    local ref_index = 1
    ---Render inline embeds on the current line in source order.
    local function render_next_ref()
      local ref = refs[ref_index]
      if not ref then
        render_next_line()
        return
      end
      ref_index = ref_index + 1
      local child_ctx = state.derive(ctx, { depth = ctx.depth + 1 })
      -- Continue the ref loop after one inline embed finishes rendering.
      api.safe_render_ref_async(ref, child_ctx, function(rendered)
        append_lines(out, prefix_lines(
          rendered,
          analyzed_row.host.continuation,
          analyzed_row.host.continuation
        ))
        queue_continuation(ctx, "nested_ref_ready", render_next_ref)
      end)
    end
    render_next_ref()
  end

  render_next_line()
end

---Resolve, slice, and recursively render one embed reference.
---@param api table
---@param ref ObsidianEmbedsRef
---@param ctx ObsidianEmbedsRenderContext
---@param done fun(lines: ObsidianEmbedsVirtLine[]?, err?: string)
function M.render_ref_async(api, ref, ctx, done)
  ctx = state.new_render_context(ctx)
  if resolver.should_ignore_ref(ref) then
    done(nil)
    return
  elseif ctx.depth > policy.max_depth then
    done(warn_block("Embed skipped: recursion limit reached", ctx.depth))
    return
  end

  -- Providers take precedence over the default note resolver. Recursive note
  -- rendering has no final window width yet, so it projects with the current
  -- screen width; top-level rows retain the projector until presentation.
  -- TODO(phase6): carry provider projectors through recursive render products
  -- so nested embeds use the final window width instead of this fallback.
  if provider_render_async(ref, ctx, function(result, provider_err)
    if provider_err then done(nil, provider_err); return end
    done(highlight.with_rail(project_provider(result, vim.o.columns, ctx.depth), opts()))
  end) then return end

  -- Select and render the resolved note candidates when lookup completes.
  resolver.resolve_notes_async(ref, ctx, function(notes, resolve_err)
    if resolve_err then
      done(warn_block("Embed error: " .. resolve_err, ctx.depth))
      return
    elseif #notes == 0 then
      done(warn_block("Embed not found: " .. ref.target, ctx.depth))
      return
    end

    local note = notes[1]
    dependencies.track_note(ctx, note)
    local key = resolver.note_key(note, ref)
    if ctx.stack[key] then
      done(warn_block("Embed skipped: recursion limit reached", ctx.depth))
      return
    end

    local lines, line_err = resolver.lines_for_ref(note, ref)
    if not lines then
      done(warn_block(line_err or ("Embed not found: " .. ref.target), ctx.depth))
      return
    end

    local prefix = {}
    if #notes > 1 then
      prefix[1] = warn_line("Multiple matches for: " .. ref.target, ctx.depth)
    end
    ctx.stack[key] = true
    -- Complete this ref after its selected note slice has recursively rendered.
    render_lines_async(api, lines, state.for_note_context(ctx, note), function(rendered, render_err)
      ctx.stack[key] = nil
      if render_err then
        done(nil, render_err)
        return
      end
      append_lines(prefix, rendered)
      done(highlight.with_rail(prefix, opts()))
    end)
  end)
end

---Render a ref with a once-only callback and convert thrown errors to warnings.
---@param api table
---@param ref ObsidianEmbedsRef
---@param ctx ObsidianEmbedsRenderContext
---@param done fun(lines: ObsidianEmbedsVirtLine[]?)
function M.safe_render_ref_async(api, ref, ctx, done)
  local completed = false
  ---Complete a safe render exactly once and normalize failures for display.
  local function finish(lines, err)
    if completed then
      return
    end
    completed = true
    if err then
      done(warn_block("Embed error: " .. tostring(err), ctx and ctx.depth or 1))
    else
      done(lines)
    end
  end
  local ok, err = pcall(M.render_ref_async, api, ref, ctx, finish)
  if not ok then
    finish(nil, err)
  end
end

---Render every analyzed embed on one source row into a row-state result.
---@param api table
---@param buffer_state ObsidianEmbedsBufferState
---@param row integer
---@param analyzed_row table
---@param done fun(row_state: ObsidianEmbedsRowState?, err?: string)
function M.render_analyzed_row_state_async(api, buffer_state, row, analyzed_row, done)
  local blocks = {}
  local rendered_refs = {}
  local dependency_set = dependencies.new()
  local ctx = state.new_row_context(buffer_state, dependency_set)
  local index = 1

  ---Render row refs sequentially so dependency and output order stays stable.
  local function render_next()
    local normalized_ref = analyzed_row.refs[index]
    if not normalized_ref then
      if #blocks == 0 and #rendered_refs == 0 then
        done(nil)
      else
        done({
          refs = rendered_refs,
          exact = analyzed_row.exact_embed,
          host = analyzed_row.host,
          blocks = blocks,
          dependencies = dependency_set,
          same_note_ranges = resolver.same_note_ranges_for_refs(buffer_state.current_note, rendered_refs),
        })
      end
      return
    end
    index = index + 1
    local ref = analyzer.to_upstream_ref(normalized_ref)
    -- Accumulate one ref result before advancing to the next source ref.
    local handled = provider_render_async(ref, ctx, function(result, provider_err)
      if provider_err then done(nil, provider_err); return end
      rendered_refs[#rendered_refs + 1] = ref
      blocks[#blocks + 1] = {
        ref = ref,
        project = function(width)
          return highlight.with_rail(project_provider(result, width, ctx.depth), opts())
        end,
      }
      queue_continuation(ctx, "row_provider_ready", render_next)
    end)
    if handled then return end
    api.safe_render_ref_async(ref, ctx, function(rendered)
      rendered_refs[#rendered_refs + 1] = ref
      blocks[#blocks + 1] = { ref = ref, lines = rendered or {} }
      queue_continuation(ctx, "row_ref_ready", render_next)
    end)
  end

  render_next()
end

return M
