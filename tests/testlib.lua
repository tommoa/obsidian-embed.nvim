local M = {}

---@param message string
function M.fail(message)
  error(message, 0)
end

---@param value any
---@param message string
function M.assert_true(value, message)
  if not value then
    M.fail(message)
  end
end

---@param haystack string
---@param needle string
---@param message string
function M.assert_contains(haystack, needle, message)
  if not haystack:find(needle, 1, true) then
    M.fail(message .. "\nexpected to find: " .. needle .. "\nin: " .. haystack)
  end
end

---@param path string
---@param lines string[]
function M.write_file(path, lines)
  local file = assert(io.open(path, "w"))
  file:write(table.concat(lines, "\n"))
  file:write("\n")
  file:close()
end

---@return nil
function M.setup_runtime()
  local source = debug.getinfo(1, "S").source:sub(2)
  local plugin_root = vim.fs.dirname(vim.fs.dirname(source))
  vim.opt.runtimepath:prepend(plugin_root)

  local explicit = vim.env.OBSIDIAN_EMBEDS_RTP
  if explicit and explicit ~= "" then
    for _, path in ipairs(vim.split(explicit, ":", { plain = true, trimempty = true })) do
      vim.opt.runtimepath:prepend(path)
    end
    return
  end

  local lazy_dir = vim.fn.stdpath("data") .. "/lazy"
  vim.opt.runtimepath:prepend(lazy_dir .. "/obsidian.nvim")
  vim.opt.runtimepath:prepend(lazy_dir .. "/plenary.nvim")
end

---@param bufnr integer
---@param namespace integer
---@return string
function M.rendered_text(bufnr, namespace)
  local lines = {}
  local marks = require("obsidian-embed.runtime").project_marks(bufnr)
  for _, mark in ipairs(marks) do
    local details = mark[4]
    if details.virt_text then
      local parts = {}
      for _, chunk in ipairs(details.virt_text) do parts[#parts + 1] = chunk[1] end
      lines[#lines + 1] = table.concat(parts, "")
    end
    for _, virt_line in ipairs(details.virt_lines or {}) do
      local parts = {}
      for _, chunk in ipairs(virt_line) do
        parts[#parts + 1] = chunk[1]
      end
      lines[#lines + 1] = table.concat(parts, "")
    end
  end
  return table.concat(lines, "\n")
end

function M.projected_marks(bufnr, winid)
  return require("obsidian-embed.runtime").project_marks(bufnr, winid)
end

---@param embeds table
---@param bufnr integer
---@param timeout? integer
function M.wait_complete(embeds, bufnr, timeout)
  local complete = vim.wait(timeout or 3000, function()
    local snapshot = embeds.inspect(bufnr)
    return snapshot.phase == "settled" or snapshot.phase == "degraded" or snapshot.phase == "disabled"
  end, 10)
  M.assert_true(complete, "embed rendering did not complete: " .. vim.inspect(embeds.inspect(bufnr)))
end

---Wait for an automatic refresh to advance and settle one attached buffer.
---@param embeds table
---@param bufnr integer
---@param previous_generation integer
---@return table snapshot
function M.wait_refresh(embeds, bufnr, previous_generation)
  local snapshot
  local complete = vim.wait(15000, function()
    local current = embeds.inspect(bufnr)
    if current.generation <= previous_generation then return false end
    if current.phase == "settled" or current.phase == "degraded" or current.phase == "disabled" then
      snapshot = current
      return true
    end
    return false
  end, 10)
  M.assert_true(complete, "embed refresh did not complete: " .. vim.inspect(embeds.inspect(bufnr)))
  M.assert_true(snapshot.phase == "settled", "embed refresh did not settle: " .. vim.inspect(snapshot))
  return snapshot
end

return M
