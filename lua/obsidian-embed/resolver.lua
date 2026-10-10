local config = require("obsidian-embed.config")
local parser = require("obsidian-embed.parser")
local dependencies = require("obsidian-embed.dependencies")
local obsidian_port = require("obsidian-embed.obsidian_port")
local policy = require("obsidian-embed.policy")
local util = require("obsidian-embed.util")

local M = {}

local function live_waiters(request)
  return #request.waiters > 0 and not request.cancelled
end

local function pump_admission(runtime)
  while runtime.active < policy.resolver_request_limit and #runtime.queue > 0 do
    local queued = table.remove(runtime.queue, 1)
    if not queued.request.cancelled then
      runtime.active = runtime.active + 1
      queued.request.admitted = true
      queued.start()
    end
  end
end

---Admit note reads through one workspace-wide queue.
local function pump_note_reads(runtime)
  runtime.read_active = runtime.read_active or 0
  runtime.read_queue = runtime.read_queue or {}
  while runtime.read_active < policy.resolver_note_read_limit and #runtime.read_queue > 0 do
    local queued = table.remove(runtime.read_queue, 1)
    if live_waiters(queued.request) then
      runtime.read_active = runtime.read_active + 1
      local released = false
      queued.start(function()
        if released then return end
        released = true
        runtime.read_active = math.max(runtime.read_active - 1, 0)
        pump_note_reads(runtime)
      end)
    else
      queued.cancel()
    end
  end
end

local function admit_note_read(runtime, request, start, cancel)
  runtime.read_queue = runtime.read_queue or {}
  runtime.read_queue[#runtime.read_queue + 1] = {
    request = request, start = start, cancel = cancel,
  }
  pump_note_reads(runtime)
end

local function admit(runtime, request, start)
  runtime = runtime or { active = 0, queue = {} }
  runtime.queue[#runtime.queue + 1] = { request = request, start = start }
  pump_admission(runtime)
end

local function release(runtime, request)
  if request.admitted then
    request.admitted = false
    runtime.active = math.max(runtime.active - 1, 0)
  end
  pump_admission(runtime)
end

---Detach obsolete waiters and stop external searches when nobody remains.
function M.cancel_waiters(runtime, bufnr, generation)
  if not runtime then return 0 end
  local cancelled = 0
  local stores = runtime.requests or {}
  for key, request in pairs(stores) do
    local retained = {}
    for _, waiter in ipairs(request.waiters or {}) do
      local owner = waiter.ctx.owner
      if not owner or owner.bufnr ~= bufnr or owner.generation ~= generation then
        retained[#retained + 1] = waiter
      else
        cancelled = cancelled + 1
      end
    end
    request.waiters = retained
    if #retained == 0 and request.stage ~= "ready" then
      request.cancelled = true
      stores[key] = nil
      for _, cancel in ipairs(request.cancellations or {}) do
        pcall(cancel)
      end
      if request.admitted then release(runtime, request) end
    end
  end
  return cancelled
end

---Return resolver-affecting presentation options.
---@return ObsidianEmbedsConfig
local function opts()
  return config.get()
end

---Derive the minimum note parsing options required by a ref selector.
---@param ref ObsidianEmbedsRef
---@return ObsidianEmbedsNoteOpts
local function ref_note_opts(ref)
  return {
    collect_sections = ref.anchor ~= nil,
    collect_anchor_links = ref.anchor ~= nil,
    collect_blocks = ref.block ~= nil,
    max_lines = math.huge,
  }
end

---Encode note parsing options as part of a resolution request identity.
---@param note_opts ObsidianEmbedsNoteOpts
---@return string
local function note_opts_key(note_opts)
  return table.concat({
    note_opts.collect_sections and "S" or "-",
    note_opts.collect_anchor_links and "A" or "-",
    note_opts.collect_blocks and "B" or "-",
    tostring(note_opts.max_lines or ""),
  }, "")
end

local function copy_range(range)
  return range and { start_row = range.start_row, end_row = range.end_row } or nil
end

---Discard the transient upstream Note object after extracting plain selector data.
local function normalize_note(note, signature)
  local anchors, blocks = {}, {}
  for key, anchor in pairs(note.anchor_links or {}) do
    anchors[key] = { range = anchor.section and copy_range(anchor.section.range) or nil }
  end
  for key, block in pairs(note.blocks or {}) do
    blocks[key] = {
      id = block.id, block = block.block, line = block.line,
      range = block.section and copy_range(block.section.range) or nil,
    }
  end
  local path = note.path and tostring(note.path) or nil
  local reference_paths = {}
  if path then
    local name = vim.fs.basename(path)
    reference_paths = { name, name:gsub("%.[^.]+$", ""), vim.uri_encode(name) }
  end
  return {
    path = path,
    bufnr = note.bufnr,
    id = note.id,
    title = note.title,
    aliases = vim.deepcopy(note.aliases or {}),
    contents = vim.deepcopy(note.contents or {}),
    frontmatter_end_line = note.frontmatter_end_line,
    reference_ids = note:reference_ids({ lowercase = true }),
    reference_paths = reference_paths,
    anchors = anchors,
    blocks = blocks,
    signature = signature,
  }
end

M.normalize_note = normalize_note

---Build a request key from every input that can change note resolution.
---@param target string
---@param note_opts ObsidianEmbedsNoteOpts
---@param ctx ObsidianEmbedsRenderContext
---@return string
local function resolution_key(target, note_opts, ctx)
  return table.concat({ util.path_key(ctx.base_dir) or "", target, note_opts_key(note_opts) }, "\0")
end

---Report refs handled by URI or attachment rendering rather than note embeds.
---@param ref ObsidianEmbedsRef
---@return boolean
local function should_ignore_ref(ref)
  return not parser.is_note_embed(ref)
end

---Normalize current unsaved lines for a loaded dependency.
local function loaded_note(path, note_opts, workspace_root)
  local loaded_buf = util.loaded_buf_for_path(path)
  if loaded_buf then
    local lines = vim.api.nvim_buf_get_lines(loaded_buf, 0, -1, false)
    local note = obsidian_port.note_from_lines(workspace_root, lines, path, note_opts)
    note.bufnr = loaded_buf
    return normalize_note(note, "buf:" .. loaded_buf .. ":" .. tostring(vim.b[loaded_buf].changedtick or 0))
  end
end

---Read an unloaded file without blocking Neovim, then normalize on its main loop.
local function note_from_path_async(path, note_opts, done, should_continue, workspace_root)
  local loaded = loaded_note(path, note_opts, workspace_root)
  if loaded then
    done(loaded)
    return
  end
  vim.uv.fs_open(path, "r", 438, function(open_err, fd)
    if open_err or not fd then
      vim.schedule(function()
        done(nil, tostring(open_err or "open failed"))
      end)
      return
    end
    vim.uv.fs_fstat(fd, function(stat_err, stat)
      if stat_err or not stat then
        vim.uv.fs_close(fd, function()
          vim.schedule(function()
            done(nil, tostring(stat_err or "stat failed"))
          end)
        end)
        return
      end
      vim.uv.fs_read(fd, stat.size, 0, function(read_err, data)
        vim.uv.fs_close(fd, function(close_err)
          vim.schedule(function()
            if read_err or close_err then
              done(nil, tostring(read_err or close_err))
              return
            end
            local lines = vim.split(data or "", "\n", { plain = true })
            if lines[#lines] == "" then
              table.remove(lines)
            end
            if should_continue and not should_continue() then
              done(nil, "cancelled")
              return
            end
            local ok, note = pcall(obsidian_port.note_from_lines, workspace_root, lines, path, note_opts)
            if ok then
              done(normalize_note(note, table.concat({ "content", path, tostring(#data), data or "" }, "\0")))
            else
              done(nil, tostring(note))
            end
          end)
        end)
      end)
    end)
  end)
end

local function with_markdown_extension(target)
  if vim.endswith(target, ".md") or vim.endswith(target, ".qmd") or vim.endswith(target, ".base") then
    return target
  end
  return target .. ".md"
end

---Load note paths through workspace-wide admission while retaining input order.
local function load_notes(runtime, request, paths, note_opts, done, should_continue, workspace_root)
  if #paths == 0 then
    done({})
    return
  end
  local pending, values, errors, completed = #paths, {}, {}, false
  local function cancel()
    if completed then return end
    completed = true
    done({}, "cancelled")
  end
  for index, path in ipairs(paths) do
    admit_note_read(runtime, request, function(release_read)
      note_from_path_async(path, note_opts, function(note, err)
        release_read()
        if completed then return end
        if should_continue and not should_continue() then cancel(); return end
        values[index], errors[index] = note, err
        pending = pending - 1
        if pending == 0 then
          completed = true
          local notes, first_error = {}, nil
          for i = 1, #paths do
            if values[i] then
              notes[#notes + 1] = values[i]
            elseif errors[i] and errors[i] ~= "cancelled" and not first_error then
              first_error = errors[i]
            end
          end
          done(notes, first_error)
        end
      end, should_continue, workspace_root)
    end, cancel)
  end
end

---Resolve explicit relative refs from the note currently being rendered, not
---from the outer buffer. This matters for nested embeds that contain ./ links.
---@param target string
---@param ctx? ObsidianEmbedsRenderContext
---@return string?
local function relative_target_path(target, ctx)
  if not (ctx and ctx.base_dir) then
    return nil
  end

  if not (vim.startswith(target, "./") or vim.startswith(target, "../")) then
    return nil
  end

  local path = vim.fs.normalize(vim.fs.joinpath(ctx.base_dir, target))
  if not (vim.endswith(path, ".md") or vim.endswith(path, ".qmd") or vim.endswith(path, ".base")) then
    path = path .. ".md"
  end
  return path
end

---Record successful note paths or an unresolved target in dependency data.
---@param ctx? ObsidianEmbedsRenderContext
---@param target string
---@param notes ObsidianEmbedsNote[]
local function track_resolved_notes(ctx, target, notes, relative)
  if not (ctx and ctx.dependencies) then
    return
  end

  if not relative then dependencies.track_query(ctx, target) end
  if #notes == 0 then
    dependencies.track_unresolved(ctx, target)
    return
  end

  for _, note in ipairs(notes) do
    dependencies.track_note(ctx, note)
  end
end

---Expose the resolver's URI and attachment exclusion predicate.
---@param ref ObsidianEmbedsRef
---@return boolean
function M.should_ignore_ref(ref)
  return should_ignore_ref(ref)
end

---Build the recursion identity for a selected note slice.
---@param note ObsidianEmbedsNote
---@param ref ObsidianEmbedsRef
---@return string
function M.note_key(note, ref)
  local path = note.path and tostring(note.path) or ref.target
  return table.concat({ path, ref.anchor or "", ref.block or "" }, "#")
end

---Resolve a reference without blocking Neovim on obsidian.nvim's synchronous
---compatibility wrapper. Duplicate requests within one render generation share
---one upstream operation and store waiter callbacks as data on the context.
---@param ref ObsidianEmbedsRef
---@param ctx ObsidianEmbedsRenderContext
---@param done fun(notes: ObsidianEmbedsNote[], err?: string)
function M.resolve_notes_async(ref, ctx, done)
  local runtime = ctx.io_runtime
  local target = util.decode_target(ref.target)
  if target == "" then
    if ctx.current_note then
      dependencies.track_note(ctx, ctx.current_note)
      done({ ctx.current_note })
    else
      done({}, ctx.current_note_error)
    end
    return
  end

  local note_opts = ref_note_opts(ref)
  local relative_path = relative_target_path(target, ctx)
  local resolve_target = relative_path or target
  local cache_key = resolution_key(resolve_target, note_opts, ctx)
  -- Cache invalidation starts a new sharing scope without abandoning waiters
  -- that still depend on work from the preceding scope.
  local request_key = table.concat({ tostring(ctx.cache_epoch or 0), cache_key }, "\0")
  local function deliver(waiter_ctx, waiter_done, notes, err)
    track_resolved_notes(waiter_ctx, relative_path or target, notes, relative_path ~= nil)
    waiter_done(notes, err)
  end
  local cached = ctx.cache_read and ctx.cache_read("resolution", cache_key) or nil
  if cached then
    local candidates = {}
    for index, note in ipairs(cached.candidates or {}) do
      candidates[index] = note.path and loaded_note(note.path, note_opts, ctx.workspace_root) or note
    end
    deliver(ctx, done, candidates, nil)
    return
  end
  local requests = runtime and runtime.requests or ctx.resolution_requests
  local request = requests[request_key]
  if request then
    request.last_used_ns = vim.uv.hrtime()
    if request.stage == "ready" then
      local notes = {}
      for index, note in ipairs(request.notes) do
        local path = util.note_path_key(note)
        notes[index] = path and loaded_note(path, note_opts, ctx.workspace_root) or note
      end
      request.notes = notes
      deliver(ctx, done, notes, request.err)
    else
      request.waiters[#request.waiters + 1] = { ctx = ctx, done = done }
    end
    return
  end

  request = {
    stage = "running", waiters = { { ctx = ctx, done = done } }, cancellations = {},
    last_used_ns = vim.uv.hrtime(),
  }
  requests[request_key] = request
  runtime = runtime or {
    active = 0, queue = {}, requests = requests,
    read_active = 0, read_queue = {},
  }

  ---Publish one upstream result to all waiters and bound the request store.
  local function finish(notes, err)
    if request.finished then return end
    request.finished = true
    notes = notes or {}
    request.stage = "ready"
    request.notes = notes
    request.err = err
    request.last_used_ns = vim.uv.hrtime()
    -- Resolution owns this cache entry. Keeping the write here means later
    -- rows can reuse completed work without routing data through the lifecycle
    -- state machine or a continuation protocol.
    if not err and ctx.cache_write then
      ctx.cache_write("resolution", cache_key, {
        candidates = notes,
        candidate_count = #notes,
        query_key = relative_path and nil or target:lower(),
        relative = relative_path ~= nil,
      })
    end
    release(runtime, request)
    local waiters = request.waiters
    request.waiters = {}
    for _, waiter in ipairs(waiters) do
      deliver(waiter.ctx, waiter.done, notes, err)
    end
    if requests[request_key] == request then
      requests[request_key] = nil
    end
  end

  local function start_request()
  if relative_path then
    vim.uv.fs_stat(relative_path, function(err, stat)
      vim.schedule(function()
        if err or not stat then
          finish({})
          return
        end
        note_from_path_async(relative_path, note_opts, function(note, load_err)
          finish(note and { note } or {}, load_err)
        end, function() return live_waiters(request) end, ctx.workspace_root)
      end)
    end)
    return
  end

  local root = ctx.workspace_root
  local filename = with_markdown_extension(target)
  local candidates, seen = {}, {}
  local function add_candidate(path)
    path = util.path_key(path)
    if path and not seen[path] then
      seen[path] = true
      candidates[#candidates + 1] = path
    end
  end
  local absolute = filename:sub(1, 1) == "/" or filename:match("^%a:[/\\]") ~= nil
  add_candidate(absolute and filename or vim.fs.joinpath(ctx.base_dir, filename))
  add_candidate(vim.fs.joinpath(root, filename))
  local workspace_opts = obsidian_port.options(root)
  if workspace_opts.notes_subdir then
    add_candidate(vim.fs.joinpath(root, workspace_opts.notes_subdir, filename))
  end
  if workspace_opts.daily_notes.folder then
    add_candidate(vim.fs.joinpath(root, workspace_opts.daily_notes.folder, filename))
  end

  local pending_stats, direct = #candidates, {}
  local function resolve_workspace_target()
    local paths, path_seen, pending_searches = {}, {}, 2
    local function found(path)
      path = util.path_key(path)
      if path and not path_seen[path] then
        path_seen[path] = true
        paths[#paths + 1] = path
      end
    end
    local function exited()
      pending_searches = pending_searches - 1
      if pending_searches ~= 0 then
        return
      end
      -- Search process exits are fast-event callbacks; candidate acquisition
      -- may inspect loaded Neovim buffers and must begin on the main loop.
      vim.schedule(function()
        if not live_waiters(request) then finish({}, "cancelled"); return end
        load_notes(runtime, request, paths, note_opts, function(notes, load_err)
          local query = target:lower()
          local exact, fuzzy = {}, {}
          for _, note in ipairs(notes) do
            if vim.endswith(query, ".base") or not vim.endswith(tostring(note.path):lower(), ".base") then
              local keys = note.reference_ids
              if vim.list_contains(keys, query) then
                exact[#exact + 1] = note
              else
                for _, key in ipairs(keys) do
                  if key:find(query, 1, true) then
                    fuzzy[#fuzzy + 1] = note
                    break
                  end
                end
              end
            end
          end
          finish(#exact > 0 and exact or fuzzy, load_err)
        end, function() return live_waiters(request) end, ctx.workspace_root)
      end)
    end
    local ok, err = pcall(function()
      request.cancellations[#request.cancellations + 1] = obsidian_port.search_async(root, target, { fixed_strings = true, ignore_case = true, max_count_per_file = 1 }, function(match)
        found(match.path.text)
      end, exited)
      request.cancellations[#request.cancellations + 1] = obsidian_port.find_async(root, target, { ignore_case = true }, found, exited)
    end)
    if not ok then
      finish({}, tostring(err))
    end
  end
  if pending_stats == 0 then
    resolve_workspace_target()
    return
  end
  for index, path in ipairs(candidates) do
    if util.loaded_buf_for_path(path) then
      direct[#direct + 1] = { index = index, path = path }
      pending_stats = pending_stats - 1
      if pending_stats == 0 then
        table.sort(direct, function(a, b) return a.index < b.index end)
        local paths = vim.tbl_map(function(item) return item.path end, direct)
        load_notes(runtime, request, paths, note_opts, function(notes, err)
          finish(notes, err)
        end, function() return live_waiters(request) end, ctx.workspace_root)
      end
      goto continue_candidate
    end
    vim.uv.fs_stat(path, function(_, stat)
      vim.schedule(function()
        if stat and stat.type == "file" then
          direct[#direct + 1] = { index = index, path = path }
        end
        pending_stats = pending_stats - 1
        if pending_stats == 0 then
          table.sort(direct, function(a, b) return a.index < b.index end)
          if #direct > 0 then
            local paths = vim.tbl_map(function(item) return item.path end, direct)
            load_notes(runtime, request, paths, note_opts, function(notes, err)
              finish(notes, err)
            end, function() return live_waiters(request) end, ctx.workspace_root)
          else
            resolve_workspace_target()
          end
        end
      end)
    end)
    ::continue_candidate::
  end
  end
  admit(runtime, request, start_request)
end

---Copy a zero-based half-open line range from note contents.
---@param lines string[]
---@param start_row integer Zero-based, inclusive.
---@param end_row integer Zero-based, exclusive.
---@return string[]
local function slice_lines(lines, start_row, end_row)
  local out = {}
  local start_idx = math.max(start_row + 1, 1)
  local end_idx = math.min(end_row, #lines)
  for idx = start_idx, end_idx do
    out[#out + 1] = lines[idx]
  end
  return out
end

---Return whole-note contents with frontmatter included only when configured.
---@param note ObsidianEmbedsNote
---@return string[]
local function without_frontmatter(note)
  if opts().presentation.frontmatter then
    return slice_lines(note.contents, 0, #note.contents)
  end
  local start_row = note.frontmatter_end_line or 0
  return slice_lines(note.contents, start_row, #note.contents)
end

---Remove a trailing block identifier from a rendered block line.
---@param line string
---@param block_id? string
---@return string
local function strip_block_id(line, block_id)
  if not block_id then
    return line
  end
  return line:gsub("%s+" .. vim.pesc(block_id) .. "%s*$", "")
end

---Return the exact note lines an embed should display: block, heading section,
---or whole note. Heading aliases are applied after slicing.
---@param note ObsidianEmbedsNote
---@param ref ObsidianEmbedsRef
---@return string[]? lines
---@return string? err
function M.lines_for_ref(note, ref)
  if ref.block then
    local block = note.blocks[obsidian_port.standardize_block(ref.block)]
    if not block then
      return nil, "Block not found: " .. ref.block
    end

    local lines
    if block.range then
      local range = block.range
      lines = slice_lines(note.contents, range.start_row, range.end_row)
    elseif block.line then
      lines = { note.contents[block.line] or "" }
    else
      lines = { block.block or "" }
    end

    for idx, line in ipairs(lines) do
      lines[idx] = strip_block_id(line, block.id)
    end
    return parser.finalize_lines(lines, opts())
  end

  if ref.anchor then
    local anchor_link = ref.anchor
    if not vim.startswith(anchor_link, "#") then
      anchor_link = "#" .. anchor_link
    end

    local anchor = note.anchors[obsidian_port.standardize_anchor(anchor_link)]
    if anchor and anchor.range then
      local range = anchor.range
      local lines = slice_lines(note.contents, range.start_row, range.end_row)
      return parser.finalize_heading_lines(lines, ref, opts())
    end

    return nil, "Heading not found: " .. ref.anchor
  end

  return parser.finalize_heading_lines(without_frontmatter(note), ref, opts())
end

---Accumulate parsing requirements for an embed of the current source note.
---@param requirements ObsidianEmbedsCurrentNoteRequirements
---@param ref ObsidianEmbedsRef
function M.add_current_note_requirements(requirements, ref)
  if util.decode_target(ref.target) ~= "" or should_ignore_ref(ref) then
    return
  end

  requirements.needed = true
  requirements.collect_anchor_links = requirements.collect_anchor_links or ref.anchor ~= nil
  requirements.collect_sections = requirements.collect_sections or ref.anchor ~= nil
  requirements.collect_blocks = requirements.collect_blocks or ref.block ~= nil
end

---Create an empty current-note parsing requirement set.
---@return ObsidianEmbedsCurrentNoteRequirements
function M.empty_requirements()
  return {
    needed = false,
    collect_sections = false,
    collect_anchor_links = false,
    collect_blocks = false,
  }
end

---Convert accumulated current-note requirements into note parser options.
---@param requirements ObsidianEmbedsCurrentNoteRequirements
---@return ObsidianEmbedsNoteOpts?
function M.current_note_opts(requirements)
  if not requirements.needed then
    return nil
  end

  return {
    collect_sections = requirements.collect_sections,
    collect_anchor_links = requirements.collect_anchor_links,
    collect_blocks = requirements.collect_blocks,
    max_lines = math.huge,
  }
end

---Resolve the source range observed by one same-note embed.
---@param note? ObsidianEmbedsNote
---@param ref ObsidianEmbedsRef
---@return ObsidianEmbedsSameNoteRange?
local function same_note_range_for_ref(note, ref)
  if not note or util.decode_target(ref.target) ~= "" then
    return nil
  end

  if ref.block then
    local block = note.blocks[obsidian_port.standardize_block(ref.block)]
    if not block then
      return nil
    elseif block.range then
      return {
        start_row = block.range.start_row,
        end_row = block.range.end_row - 1,
      }
    elseif block.line then
      return {
        start_row = block.line - 1,
        end_row = block.line - 1,
      }
    end
  elseif ref.anchor then
    local anchor_link = ref.anchor
    if not vim.startswith(anchor_link, "#") then
      anchor_link = "#" .. anchor_link
    end

    local anchor = note.anchors[obsidian_port.standardize_anchor(anchor_link)]
    if anchor and anchor.range then
      return {
        start_row = anchor.range.start_row,
        end_row = anchor.range.end_row - 1,
      }
    end
  else
    return {
      start_row = 0,
      end_row = math.max(#note.contents - 1, 0),
    }
  end

  return nil
end

function M.same_note_ranges_for_refs(note, refs)
  local ranges = {}
  for _, ref in ipairs(refs or {}) do
    local range = same_note_range_for_ref(note, ref)
    if range then ranges[#ranges + 1] = range end
  end
  return ranges
end

return M
