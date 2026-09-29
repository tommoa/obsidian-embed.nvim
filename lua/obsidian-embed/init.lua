local manager = require("obsidian-embed.runtime")
local providers = require("obsidian-embed.providers")

local M = {}

local function register_command()
  require("obsidian").register_command("embed", {
    nargs = "*",
    note_action = true,
    complete = function(arg_lead)
      return vim.tbl_filter(function(item)
        return vim.startswith(item, arg_lead)
      end, { "toggle", "refresh", "inspect" })
    end,
  })
end

---Install the runtime and automatically attach eligible Obsidian buffers.
---@param opts? table
function M.setup(opts)
  -- The presenter uses nvim__ns_set to keep buffer extmarks window-local.
  if vim.fn.has("nvim-0.11") == 0 then
    error("obsidian-embed.nvim requires Neovim 0.11 or newer", 2)
  end
  require("obsidian-embed.config").setup(opts)
  register_command()
  manager.setup()
end

---Start a new render generation from the buffer's current contents.
---@param bufnr? integer
function M.refresh(bufnr)
  manager.refresh(bufnr)
end

---Toggle rendering and return the new enabled state.
---@param bufnr? integer
---@return boolean
function M.toggle(bufnr)
  return manager.toggle(bufnr)
end

---Return a copied diagnostic snapshot for a buffer.
---@param bufnr? integer
---@return table
function M.inspect(bufnr)
  return manager.inspect(bufnr)
end

---Register a renderer for references the default Markdown-note renderer does
---not own. Registration is safe before `setup`; the returned function removes
---that provider when called.
---@param provider ObsidianEmbedsProvider
---@return fun()
function M.register_provider(provider)
  return providers.register(provider)
end

return M
