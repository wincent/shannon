-- Usage: rex do agent.lua apps=APP[,APP...] exclude=BLOCK
--
-- Prints "<block id> <state> [<kind>]" for the first terminal in the window
-- of the calling block (`REX_BLOCK`) where a program reports itself as APP
-- through the Program Status Protocol (OSC 7501). Apps are tried in order.
-- The terminal EXCLUDE is skipped. `kind` is only printed for a blocked
-- program, such as one showing a permission prompt. Prints nothing when no
-- terminal matches.

local terminal = 'com.superlogical.terminal'

-- A record outlives a program that is killed, so trust only records whose
-- owner still runs in the terminal: in the foreground, or as a parent of the
-- foreground process.
local function running_pids(block_id)
  local pids = {}
  local process = rex.block.call(terminal, 'process', { block_id = block_id })
  if process and process.foreground then
    pids[process.foreground.pid] = true
    for _, ancestor in ipairs(process.ancestors or {}) do
      pids[ancestor.pid] = true
    end
  end
  return pids
end

local window_id = assert(rex.session.describe_block({ block_id = rex.block_id })).block.window_id

-- For each candidate terminal, the status records of programs still running
-- in it.
local candidates = {}
for _, block in ipairs(assert(rex.session.list_blocks({})).blocks) do
  if
    block.window_id == window_id
    and block.creator_name == terminal
    and block.block_id ~= rex.args.exclude
  then
    local status = rex.block.call(terminal, 'program_status', { block_id = block.block_id })
    if status and next(status.records) then
      local pids = running_pids(block.block_id)
      local records = {}
      for _, record in ipairs(status.records) do
        if record.owner and pids[record.owner.pid] then
          table.insert(records, record)
        end
      end
      table.insert(candidates, { block_id = block.block_id, records = records })
    end
  end
end

for app in rex.args.apps:gmatch('[^,]+') do
  for _, candidate in ipairs(candidates) do
    local match
    for _, record in ipairs(candidate.records) do
      if (record.effective_app or record.app) == app then
        -- Any blocked record means a prompt on screen that Enter would answer.
        if record.state == 'blocked' then
          print(candidate.block_id .. ' blocked ' .. (record.kind or ''))
          return
        end
        match = match or record
      end
    end
    if match then
      print(candidate.block_id .. ' ' .. match.state)
      return
    end
  end
end
