---Return the buffer targeted by an interactive Obsidian embed command.
local function current_buf()
  return vim.api.nvim_get_current_buf()
end

---@param data { fargs: string[] }
return function(data)
  local embeds = require("obsidian-embed")
  local subcommand = data.fargs[1] or "toggle"
  if #data.fargs > 1 then
    vim.notify("Usage: Obsidian embed [toggle|refresh|inspect]", vim.log.levels.ERROR)
  elseif subcommand == "toggle" then
    embeds.toggle(current_buf())
  elseif subcommand == "refresh" then
    embeds.refresh(current_buf())
  elseif subcommand == "inspect" then
    vim.print(embeds.inspect(current_buf()))
  else
    vim.notify("Usage: Obsidian embed [toggle|refresh|inspect]", vim.log.levels.ERROR)
  end
end
