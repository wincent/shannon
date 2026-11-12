local M = {}

M.name = 'Rex'

-- The scripts live in `rex/` at the root of the plugin, beside `bin/`, so that
-- `bin/find-nvim-socket` can use them too.
local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h:h:h:h:h')

local function script(name)
  return root .. '/rex/' .. name
end

function M.current_pane()
  return vim.env.REX_BLOCK
end

-- Rex finds agents by the name each one reports through the Program Status
-- Protocol (OSC 7501). `agents` holds process names, so map the ones that
-- report a different name.
local apps = { claude = 'claude-code' }

-- Returns the id of the first terminal in the current window, other than the
-- current one, that runs one of `agents`. Agents are tried in order. Returns
-- nil and a reason when that agent is blocked, because the Enter that submits
-- the prompt would answer whatever it is asking instead.
function M.find_agent(agents)
  local names = {}
  for i, agent in ipairs(agents) do
    names[i] = apps[agent] or agent
  end
  local output = vim.fn.system({
    'rex',
    'do',
    script('agent.lua'),
    'apps=' .. table.concat(names, ','),
    'exclude=' .. M.current_pane(),
  })
  if vim.v.shell_error ~= 0 then
    return nil
  end
  local block_id, state, kind = output:match('^(%S+) (%S+) ?(%S*)')
  if state == 'blocked' then
    return nil, 'the agent in Rex is waiting for an answer (' .. (kind ~= '' and kind or 'blocked') .. ')'
  end
  return block_id
end

function M.paste(pane, tmpfile)
  vim.fn.system({ 'rex', 'do', script('paste.lua'), 'block_id=' .. pane, 'path=' .. tmpfile })
end

return M
