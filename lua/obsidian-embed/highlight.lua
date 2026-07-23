local M = {}

local function append_chunks(dst, chunks)
  for _, chunk in ipairs(chunks or {}) do dst[#dst + 1] = vim.deepcopy(chunk) end
end

local function text_chunks(text, group)
  if not text or text == "" then return {} end
  return { { text, group } }
end

local function append_tokens(dst, tokens)
  for _, token in ipairs(tokens or {}) do dst[#dst + 1] = vim.deepcopy(token) end
end

local function host_token(text)
  if not text or text == "" then return {} end
  return { { kind = "host", text = text } }
end

---Add semantic presentation prefixes without choosing their rendered styling.
---@param line ObsidianEmbedsVirtLine
---@param first table[]
---@param continuation table[]
---@return ObsidianEmbedsVirtLine
function M.with_prefix(line, first, continuation)
  local out = {}
  append_chunks(out, line)
  out.presentation_prefix = {}
  append_tokens(out.presentation_prefix, first)
  append_tokens(out.presentation_prefix, line.presentation_prefix)
  out.presentation_continuation = {}
  append_tokens(out.presentation_continuation, continuation)
  append_tokens(out.presentation_continuation, line.presentation_continuation)
  return out
end


function M.with_host(line, first, continuation)
  return M.with_prefix(line, host_token(first), host_token(continuation))
end

---Wrap every line in one resolved embed with the configured editorial rail.
---@param lines ObsidianEmbedsVirtLine[]
---@param opts ObsidianEmbedsConfig
---@return ObsidianEmbedsVirtLine[]
function M.with_rail(lines, opts)
  local out = {}
  for _, line in ipairs(lines or {}) do
    out[#out + 1] = M.with_prefix(line, { { kind = "rail" } }, { { kind = "rail" } })
  end
  return out
end


local function chunks_for_tokens(tokens, opts)
  local out = {}
  for _, token in ipairs(tokens or {}) do
    if token.kind == "rail" then
      append_chunks(out, text_chunks(opts.presentation.rail, opts.presentation.highlights.rail))
    elseif token.kind == "host" then
      append_chunks(out, text_chunks(token.text, opts.presentation.highlights.text))
    end
  end
  return out
end

---Materialize semantic prefixes only at the Neovim presentation boundary.
function M.materialize(line, opts)
  local out = {}
  append_chunks(out, chunks_for_tokens(line.presentation_prefix, opts))
  append_chunks(out, line)
  out.continuation_prefix = chunks_for_tokens(line.presentation_continuation, opts)
  return out
end

---Normalize a Tree-sitter capture name into a usable highlight group.
---@param capture_name string
---@return string?
function M.capture_hl_group(capture_name)
  if capture_name == "spell" or capture_name == "nospell" or capture_name == "conceal" then
    return nil
  elseif vim.startswith(capture_name, "_") then
    return nil
  elseif vim.startswith(capture_name, "@") then
    return capture_name
  end
  return "@" .. capture_name
end

---Assign deterministic precedence when highlight captures overlap.
---@param group string
---@return integer
function M.capture_priority(group)
  if group == "@markup.link.url" then
    return 80
  elseif group == "@markup.link.label" then
    return 75
  elseif group == "@markup.raw" then
    return 70
  elseif group == "@markup.strong" or group == "@markup.italic" then
    return 65
  elseif vim.startswith(group, "@markup.heading") then
    return 60
  elseif group == "@markup.list" or group == "@markup.quote" then
    return 55
  elseif vim.startswith(group, "@punctuation") then
    return 45
  elseif group == "@markup.link" then
    return 40
  end
  return 50
end

---Convert analyzed text chunks into a prefixed Neovim virtual line.
---@param chunks { text: string, group: string }[]
---@param depth integer
---@param opts ObsidianEmbedsConfig
---@return ObsidianEmbedsVirtLine
function M.precomputed_line(chunks, depth, opts)
  local out = {}
  for _, chunk in ipairs(chunks or {}) do
    out[#out + 1] = { chunk.text, chunk.group }
  end
  if #out == 0 then
    out[1] = { "", opts.presentation.highlights.text }
  end
  return out
end

---Build a prefixed warning line using the configured warning highlight.
---@param message string
---@param depth integer
---@param opts ObsidianEmbedsConfig
---@return ObsidianEmbedsVirtLine
function M.warn_line(message, depth, opts)
  return { { message, opts.presentation.highlights.warning } }
end

return M
