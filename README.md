# obsidian-embed.nvim

Render Obsidian note embeds inline in Neovim.

## Requirements

- Neovim 0.10 or newer
- [obsidian.nvim](https://github.com/obsidian-nvim/obsidian.nvim)
- Markdown and Markdown Inline Tree-sitter parsers

## Installation

The checkout is configured locally in this repository's accompanying Neovim
configuration:

```lua
{
  dir = vim.fs.joinpath(vim.uv.os_homedir(), "docs", "obsidian-embed.nvim"),
  name = "obsidian-embed.nvim",
  ft = { "markdown", "obsidian_base" },
  dependencies = { "obsidian-nvim/obsidian.nvim" },
  opts = {},
  config = function(_, opts)
    require("obsidian-embed").setup(opts)
  end,
}
```

`obsidian.nvim` must be configured before this plugin. The dependency ensures
that order when using lazy.nvim.

## Usage

The plugin attaches to buffers marked by `obsidian.nvim` and exposes:

- `:Obsidian embed toggle`
- `:Obsidian embed refresh`
- `:Obsidian embed inspect`

Lua users can call `require("obsidian-embed").toggle()`, `refresh()`,
`inspect()`, and `register_provider()` directly.

## Configuration

```lua
require("obsidian-embed").setup({
  presentation = {
    source = "reveal_cursor",
    frontmatter = false,
    rail = "│ ",
    highlights = {
      text = "ObsidianEmbedText",
      rail = "ObsidianEmbedRail",
      warning = "ObsidianEmbedWarning",
    },
    nowrap_overflow = "trunc",
  },
})
```

`source` accepts `"reveal_cursor"`, `"conceal"`, or `"show"`.

## Development

Run the Nix smoke checks with `nix flake check`. The tests are standalone and
do not read the user's Neovim configuration.
