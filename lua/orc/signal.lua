local M = {}

---@type table<string, uv_fs_event_t>
local watchers = {}

local function get_config()
  return require("orc").config
end

--- Parse a signal line into type and message.
---@param line string
---@return string|nil type, string|nil message
local function parse_signal(line)
  local type, message = line:match("^(%u+):%s*(.+)$")
  return type, message
end

--- Map signal type to vim.log.levels.
---@param signal_type string
---@return number
local function signal_level(signal_type)
  if signal_type == "BLOCKED" or signal_type == "ERROR" then
    return vim.log.levels.ERROR
  elseif signal_type == "QUESTION" then
    return vim.log.levels.WARN
  else
    return vim.log.levels.INFO
  end
end

--- Read and process the signal file.
---@param name string Space name
---@param path string Signal file path
local function process_signal(name, path)
  local f = io.open(path, "r")
  if not f then
    return
  end

  local content = f:read("*a")
  f:close()

  if content == "" then
    return
  end

  -- Process each line
  for line in content:gmatch("[^\r\n]+") do
    local signal_type, message = parse_signal(line)
    if signal_type and message then
      local level = signal_level(signal_type)
      vim.schedule(function()
        vim.notify(
          string.format("orc [%s] %s: %s", name, signal_type, message),
          level
        )
        -- Update space status
        local spaces = require("orc.spaces")
        if spaces.spaces[name] then
          if signal_type == "DONE" then
            spaces.spaces[name].status = "idle"
          elseif signal_type == "QUESTION" or signal_type == "BLOCKED" then
            spaces.spaces[name].status = "needs_attention"
          end
        end
      end)
    end
  end

  -- Clear the signal file after reading
  f = io.open(path, "w")
  if f then
    f:close()
  end
end

--- Start watching a space's signal file.
---@param name string Space name
---@param worktree_path string
function M.watch(name, worktree_path)
  if watchers[name] then
    return
  end

  local config = get_config()
  local signal_path = worktree_path .. "/" .. config.signal_file
  local signal_dir = vim.fn.fnamemodify(signal_path, ":h")

  -- Ensure the signal directory exists
  vim.fn.mkdir(signal_dir, "p")

  -- Create the signal file if it doesn't exist
  local f = io.open(signal_path, "a")
  if f then
    f:close()
  end

  local handle = vim.uv.new_fs_event()
  if not handle then
    return
  end

  handle:start(signal_path, {}, function(err)
    if err then
      return
    end
    process_signal(name, signal_path)
  end)

  watchers[name] = handle
end

--- Stop watching a space's signal file.
---@param name string
function M.unwatch(name)
  local handle = watchers[name]
  if handle then
    handle:stop()
    handle:close()
    watchers[name] = nil
  end
end

--- Stop all watchers.
function M.unwatch_all()
  for name in pairs(watchers) do
    M.unwatch(name)
  end
end

return M
