-- Usage: rex do paste.lua block_id=BLOCK path=FILE
--
-- Pastes the contents of FILE into the terminal BLOCK and presses Enter, like
-- `tmux paste-buffer -p` followed by `tmux send-keys Enter`.

local terminal = 'com.superlogical.terminal'
local block_id = rex.args.block_id

local file = assert(io.open(rex.args.path, 'rb'))
local text = file:read('*a')
file:close()

-- A paste event, unlike writing the bytes, lets the terminal add the
-- bracketed-paste markers when the program has turned on bracketed paste, and
-- strip any markers inside the text.
local function paste(chunk)
  assert(rex.call('block.event', {
    session_id = rex.session_id,
    block_id = block_id,
    event = { type = 'paste', payload = { text = chunk } },
  }))
end

-- Rex refuses requests over 64 KiB once encoded as JSON, where one byte can
-- take six (`\u001b`), so paste in chunks. Cut only between UTF-8 characters,
-- because each chunk must be a valid JSON string.
local chunk_size = 8192
local first = 1
while first <= #text do
  local last = math.min(first + chunk_size - 1, #text)
  while last < #text and text:byte(last + 1) >= 0x80 and text:byte(last + 1) < 0xc0 do
    last = last - 1
  end
  paste(text:sub(first, last))
  first = last + 1
end

assert(rex.block.call(terminal, 'write', { block_id = block_id, data = '\r' }))
