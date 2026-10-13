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

## Performance benchmark

The manual **Embed benchmark** workflow runs fixed dependency versions on Ubuntu
and publishes raw JSON, generated Markdown, dependency versions, and logs as a
30-day artifact. Its summary also appears on the workflow run page. Headless and
terminal measurements run sequentially on one runner. Choose the sample count
and workload when dispatching it. Correctness and workload errors fail the job;
machine-dependent timings have no pass/fail thresholds. For close comparisons,
use matching dependencies and run baseline and proposed changes on the same
machine; hosted-runner timings vary between jobs.

Run locally with the same dependencies as the smoke tests:

```sh
OBSIDIAN_EMBEDS_BENCH_OUTPUT=/tmp/embed-headless.json \
  nvim --headless -u NONE -i NONE -l tests/obsidian-embeds-benchmark.lua

OBSIDIAN_EMBEDS_BENCH_OUTPUT=/tmp/embed-terminal.json \
  nvim -u NONE -i NONE -n \
  -c "lua dofile('tests/obsidian-embeds-benchmark.lua')"

python3 scripts/report-benchmark.py /tmp/embed-headless.json /tmp/embed-terminal.json
```

The default is three samples of `repeated`, `distinct`, `deep`, `large-note`, and
`rich-host`. `OBSIDIAN_EMBEDS_BENCH_RUNS` sets the count;
`OBSIDIAN_EMBEDS_BENCH_CASE` selects one workload. Each 10,000-line host measures
initial attachment, a visible embed edit, and an unrelated edit. Fixtures use
sample-specific note content while preserving caching within a sample; workload
checks reject unintended cache reuse. The benchmark captures host/note analysis,
first installed output, composed terminal frames, full settlement, presentation
and heartbeat gaps. Setup/file creation are excluded; automatic edit debounce is
included. Five-millisecond sampling and instrumentation affect timings. Installed
coverage checks mark presence, not every glyph or virtual-line payload length.
Wrapping, multiple windows, providers, dependency-file edits, and memory usage
remain outside these measurements. Keep generated results outside the checkout.
