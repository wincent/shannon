local M = {}

M.name = 'tmux'

function M.current_pane()
  return vim.env.TMUX_PANE
end

-- Returns the id of the first pane in the current window, other than the
-- current one, that runs one of `agents`. Agents are tried in order.
function M.find_agent(agents)
  local current_pane = M.current_pane()
  if not current_pane then
    return nil
  end

  local pane_pids = {}
  local pane_output = vim.fn.system("tmux list-panes -F '#{pane_id} #{pane_pid}'")
  for pane_id, pane_pid in pane_output:gmatch('(%%[%d]+)%s+(%d+)') do
    if pane_id ~= current_pane then
      pane_pids[tonumber(pane_pid)] = pane_id
    end
  end

  for _, agent in ipairs(agents) do
    local agent_pids = vim.fn.system({ 'pgrep', '-x', agent })
    for pid_str in agent_pids:gmatch('%d+') do
      local pid = pid_str
      for _ = 1, 10 do
        local ppid = vim.trim(vim.fn.system({ 'ps', '-p', pid, '-o', 'ppid=' }))
        if ppid == '' or ppid == '1' then
          break
        end
        local ppid_num = tonumber(ppid)
        if ppid_num and pane_pids[ppid_num] then
          return pane_pids[ppid_num]
        end
        pid = ppid
      end
    end
  end

  return nil
end

function M.paste(pane, tmpfile)
  -- Use a unique, named buffer so concurrent Shannon invocations can't race
  -- on tmux's anonymous-buffer stack (paste-buffer without -b always targets
  -- the most-recently-created buffer, not the one we just loaded).
  local buffer_name = string.format('shannon-%d-%d', vim.fn.getpid(), vim.uv.hrtime())
  vim.fn.system({ 'tmux', 'load-buffer', '-b', buffer_name, tmpfile })
  -- Use bracketed paste (-p) so agent TUIs (pi, claude) treat embedded
  -- newlines as literal newlines (like Shift+Enter) instead of submitting
  -- on the first LF. -r disables tmux's default LF->CR replacement so real
  -- newlines reach the application. -d deletes our named buffer afterwards
  -- so we don't leak onto the stack and eventually evict the user's own
  -- buffers when buffer-limit (default 50) is hit. The trailing send-keys
  -- Enter is sent outside the bracketed paste and triggers the actual submit.
  vim.fn.system({ 'tmux', 'paste-buffer', '-d', '-p', '-r', '-b', buffer_name, '-t', pane })
  vim.fn.system({ 'tmux', 'send-keys', '-t', pane, 'Enter' })
end

return M
