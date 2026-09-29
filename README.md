# obsidian-embed.nvim

Render Obsidian note embeds inline in Neovim.

## Requirements

- Neovim 0.11 or newer
- [obsidian.nvim](https://github.com/obsidian-nvim/obsidian.nvim)
- Markdown and Markdown Inline Tree-sitter parsers

## Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "tommoa/obsidian-embed.nvim",
  ft = { "markdown", "obsidian_base" },
  dependencies = { "obsidian-nvim/obsidian.nvim" },
  opts = {},
  config = function(_, opts)
    require("obsidian-embed").setup(opts)
  end,
}
```

Configure `obsidian.nvim` separately with a workspace. The dependency loads
its configured lazy.nvim spec before this plugin calls `setup()`.

## Usage

The plugin attaches to buffers marked by `obsidian.nvim` and exposes:

- `:Obsidian embed toggle`
- `:Obsidian embed refresh`
- `:Obsidian embed inspect`

Lua users can call `require("obsidian-embed").toggle()`, `refresh()`,
`inspect()`, and `register_provider()` directly.

### Custom embed providers

Providers are tried in registration order before the built-in Markdown note
renderer. URI and attachment embeds are skipped before provider matching.
This example renders the first line of `![[status.txt]]` from the active
workspace:

```lua
local unregister = require("obsidian-embed").register_provider({
  name = "status-file",
  match = function(ref) return ref.target == "status.txt" end,
  render_async = function(ref, ctx, done)
    local path = vim.fs.joinpath(ctx.workspace_root, ref.target)
    local cancelled = false
    vim.schedule(function()
      if cancelled then return end
      local lines = vim.fn.getbufline(path, 1)
      if #lines == 0 then
        local ok, disk_lines = pcall(vim.fn.readfile, path)
        if not ok then done(nil, tostring(disk_lines)); return end
        lines = disk_lines
      end
      local first_line = lines[1] or ""
      done({
        dependencies = { path },
        project = function(_width)
          return { { { first_line, "Normal" } } }
        end,
      })
    end)
    return function() cancelled = true end
  end,
})

-- Call unregister() when removing or reloading this provider.
```

`match(ref, ctx)` runs in registration order; the first matching provider owns
the embed. `ref.target` is the target from the embed syntax. The context has
`bufnr`, `workspace_root`, `host_path`, `base_dir`, `ref`, and `generation`.
`host_path` and `base_dir` can be absent when not applicable.
`render_async(ref, ctx, done)` must call `done(result)` or `done(nil, error)`.
A successful result needs `project(width)`, which returns virtual lines: each
line is a list of chunks shaped like `{ "text", "highlight_group" }`.
`width` is the projection width in display cells; providers can use it when
needed. Top-level results can be projected again after a window resize.
Optional `dependencies` are filesystem
paths whose loaded-buffer edits, writes, and `FileChangedShellPost` events trigger
refreshes; there is no continuous filesystem watcher. Return a cancellation
function for pending work; callbacks from a cancelled render are ignored. The
returned `unregister()` function removes the provider and can be called more
than once. Unregistering does not cancel renders already in flight. The
scheduled file read above is suited to small files; use nonblocking I/O for
larger work. See `:help obsidian-embed-providers` for the full contract.

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
