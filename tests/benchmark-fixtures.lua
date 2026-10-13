-- Generated, deterministic fixtures: no checked-in megabyte notes or downloads.
local M = {}

M.cases = {
  { name = "repeated", host_lines = 10000, embeds = 500, targets = 1, note_lines = 1, depth = 1 },
  { name = "distinct", host_lines = 10000, embeds = 500, targets = 500, note_lines = 1, depth = 1 },
  { name = "deep", host_lines = 10000, embeds = 32, targets = 8, note_lines = 1, depth = 8 },
  { name = "large-note", host_lines = 10000, embeds = 4, targets = 1, note_lines = 5000, depth = 1 },
  { name = "rich-host", host_lines = 10000, embeds = 500, targets = 1, note_lines = 1, depth = 1, rich = true },
}

function M.write(test, root, case, sample)
  vim.fn.mkdir(root, "p")
  local base, edited = "BENCH_BASE_" .. sample, "BENCH_EDIT_" .. sample
  -- Analysis caches use note content, so every nested reference must vary by
  -- sample as well as the leaf marker. Names stay shared within one sample.
  local function note_name(prefix, index)
    return prefix .. "_" .. sample .. "_" .. index
  end
  local function note(name, marker, count)
    local lines = { marker .. " **bold** [link](Target.md) `code` " .. name }
    for index = 2, count do
      lines[index] = "row " .. index .. " **bold** [link](Target.md) `code`"
    end
    test.write_file(root .. "/" .. name .. ".md", lines)
  end
  if case.depth > 1 then
    for _, prefix in ipairs({ "Target", "Edited" }) do
      for index = 1, case.depth - 1 do
        test.write_file(root .. "/" .. note_name(prefix, index) .. ".md",
          { "![[" .. note_name(prefix, index + 1) .. "]]" })
      end
      note(note_name(prefix, case.depth), prefix == "Target" and base or edited, 1)
    end
  else
    for index = 1, case.targets do note(note_name("Target", index), base, case.note_lines) end
    note(note_name("Edited", 1), edited, case.note_lines)
  end
  local lines, rows = {}, {}
  for index = 1, case.host_lines do
    lines[index] = case.rich
      and ("plain row " .. index .. " **bold** [link](Target.md) `code`")
      or ("plain row " .. index)
  end
  -- The first embed is visible, with the cursor on an ordinary source row.
  for index = 1, case.embeds do
    local row = 1 + math.floor((index - 1) * (case.host_lines - 2) / case.embeds)
    rows[index] = row
    local target = case.depth > 1 and 1 or ((index - 1) % case.targets + 1)
    lines[row + 1] = "![[" .. note_name("Target", target) .. "]]"
  end
  test.write_file(root .. "/Main.md", lines)
  return {
    base = base, edited = edited, rows = rows, main = root .. "/Main.md",
    edited_ref = "![[" .. note_name("Edited", 1) .. "]]",
    needs_continuations = case.note_lines > 1,
  }
end

return M
