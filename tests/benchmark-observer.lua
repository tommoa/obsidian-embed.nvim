-- Observe installed marks without copying embedded-note virtual-line payloads.
local M = {}

function M.new(bufnr, namespace, rows, needs_continuations, token)
  local observer = { marker_seen = false, coverage_seen = false }
  local expected = {}
  for _, row in ipairs(rows) do expected[row] = true end

  function observer.observe(check_coverage)
    if not observer.marker_seen then
      -- Fixtures use exact embeds away from the cursor, so the first output
      -- line is a virt_text mark. Filtering avoids copying thousands of virtual
      -- continuation lines merely to find this marker; cache it once observed.
      local marks = vim.api.nvim_buf_get_extmarks(bufnr, namespace,
        { rows[1], 0 }, { rows[1], -1 }, { type = "virt_text", details = true, limit = 1 })
      local parts = {}
      for _, chunk in ipairs(marks[1] and marks[1][4].virt_text or {}) do parts[#parts + 1] = chunk[1] end
      observer.marker_seen = table.concat(parts):find(token, 1, true) ~= nil
    end
    if check_coverage and not observer.coverage_seen then
      -- The caller waits for a post-settlement pass before requesting coverage.
      -- Verify output row/type presence using positions only. Semantic input
      -- rows cannot prove that the presenter installed their output.
      for _, kind in ipairs(needs_continuations and { "virt_text", "virt_lines" } or { "virt_text" }) do
        local actual = {}
        for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, namespace, 0, -1,
          { type = kind, details = false })) do
          actual[mark[2]] = true
        end
        for _, row in ipairs(rows) do
          assert(actual[row], string.format("missing installed %s at source row %d", kind, row + 1))
        end
        for row in pairs(actual) do
          assert(expected[row], string.format("unexpected installed %s at source row %d", kind, row + 1))
        end
      end
      observer.coverage_seen = true
    end
    return observer.marker_seen, observer.coverage_seen
  end

  return observer
end

return M
