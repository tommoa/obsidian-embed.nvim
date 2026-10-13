# Rendered screen tests

Run the standalone entry point from the repository root:

```sh
nvim --headless -u NONE -i NONE -n -l tests/obsidian-embeds-screen-smoke.lua
```

It needs Neovim 0.11 or newer, `ripgrep`, obsidian.nvim, plenary.nvim, and the
Markdown and Markdown Inline Tree-sitter parsers, just like the existing smoke
tests. `testlib.lua` uses the dependencies in Neovim's data directory under
`lazy/` by default. To supply other installations, include their runtime roots
and a runtime root containing `parser/markdown` and `parser/markdown_inline`:

```sh
OBSIDIAN_EMBEDS_RTP=/path/to/obsidian.nvim:/path/to/plenary.nvim:/path/to/parsers \
  nvim --headless -u NONE -i NONE -n -l tests/obsidian-embeds-screen-smoke.lua
```

`-u NONE` skips user configuration, `-i NONE` skips ShaDa, and `-n` disables swap
files. Notes are created in a temporary vault and deleted on success.

`screenlib.lua` reads Neovim's actual rendered grid with `screenstring()` after
redraws. Headless Neovim maintains this grid without an attached terminal UI;
no external UI client, screenshot library, or additional package is needed.
The harness sets a fixed screen size and window options, crops assertions to
each window's content, and ignores highlight colors. It waits for expected
screen rows with a bounded timeout instead of sleeping for presumed rendering
durations. Failures include expected and actual rows. Wide character trailing
cells and combining character cells are also checked directly.

Coverage includes all three source presentation modes, cursor reveal, toggle,
source editing and undo, differently sized splits with independent cursor
positions, resize, wrap/nowrap, word-boundary wrapping, list continuation,
Unicode display width, and table separator alignment through edit/undo.
Cursor changes made through the API explicitly emit `CursorMoved`, exercising
the same runtime callback used during interactive editing.

For CI integration, run the entry point above alongside the existing
`obsidian-embeds-*-smoke.lua` checks. It accepts the same
`OBSIDIAN_EMBEDS_RTP` environment variable and exits nonzero on failure. This
change does not modify the runner or Nix check definition.
