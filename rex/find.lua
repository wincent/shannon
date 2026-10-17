-- Usage: rex do find.lua names=NAME[,NAME...] [exclude=BLOCK]
--
-- Prints "<block id> <pid>" for the first terminal in the window of the
-- calling block (`REX_BLOCK`) where a process called NAME runs in the
-- foreground, or is a parent of the foreground process. Names are tried in
-- order. The terminal EXCLUDE is skipped. Prints nothing when no terminal
-- matches.

local terminal = 'com.superlogical.terminal'

-- `name` is the executable's file name. The base name of `argv0` covers
-- programs started through a wrapper that runs another executable under the
-- name the user typed.
local function is_named(process, name)
  return process.name == name or (process.argv0 or ''):match('[^/]*$') == name
end

local window_id = assert(rex.session.describe_block({ block_id = rex.block_id })).block.window_id

-- For each candidate terminal, its foreground process followed by that
-- process's parents, up to the terminal's own child process.
local candidates = {}
for _, block in ipairs(assert(rex.session.list_blocks({})).blocks) do
  if
    block.window_id == window_id
    and block.creator_name == terminal
    and block.block_id ~= rex.args.exclude
  then
    local process = rex.block.call(terminal, 'process', { block_id = block.block_id })
    if process and process.foreground then
      local processes = { process.foreground }
      for _, ancestor in ipairs(process.ancestors or {}) do
        table.insert(processes, ancestor)
      end
      table.insert(candidates, { block_id = block.block_id, processes = processes })
    end
  end
end

for name in rex.args.names:gmatch('[^,]+') do
  for _, candidate in ipairs(candidates) do
    for _, process in ipairs(candidate.processes) do
      if is_named(process, name) then
        print(candidate.block_id .. ' ' .. process.pid)
        return
      end
    end
  end
end
