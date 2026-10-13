local source = debug.getinfo(1, "S").source:sub(2)
local root = vim.fs.dirname(vim.fs.dirname(source))
dofile(root .. "/tests/testlib.lua").setup_runtime()
assert(vim.fn.has("nvim-0.11") == 1, "tests require Neovim 0.11+")
assert(vim.fn.executable("rg") == 1, "tests require ripgrep on PATH")
require("plenary.job")
require("obsidian")
for _, language in ipairs({ "markdown", "markdown_inline" }) do
  vim.treesitter.get_string_parser("# sample **text**", language):parse()
  assert(vim.treesitter.query.get(language, "highlights"), "missing " .. language .. " highlight query")
  print(language .. " parser: " .. vim.inspect(vim.api.nvim_get_runtime_file("parser/" .. language .. ".so", true)))
end
print("Neovim: " .. tostring(vim.version()))
print("Dependency runtime: " .. vim.env.OBSIDIAN_EMBEDS_RTP)
