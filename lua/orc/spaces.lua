local M = {}

---@class OrcSpace
---@field bufnr number Terminal buffer number
---@field chan number Terminal channel ID
---@field worktree_path string Absolute path to the worktree
---@field branch string Branch name
---@field status string "active"|"needs_attention"|"idle"
---@field win number|nil Window ID if currently visible

---@type table<string, OrcSpace>
M.spaces = {}

---@type string|nil
M.active_space = nil

local function get_config()
  return require("orc").config
end

local function repo_root()
  local out = vim.fn.systemlist("git rev-parse --show-toplevel")
  if vim.v.shell_error ~= 0 then
    return nil
  end
  return out[1]
end

--- Create a new space: worktree + branch + hidden terminal running the CLI.
---@param name string
---@param opts? {base?: string}
function M.create(name, opts)
  opts = opts or {}

  if M.spaces[name] then
    vim.notify("orc: space '" .. name .. "' already exists", vim.log.levels.WARN)
    return
  end

  local root = repo_root()
  if not root then
    vim.notify("orc: not inside a git repository", vim.log.levels.ERROR)
    return
  end

  local config = get_config()
  local base = opts.base or "HEAD"
  local branch = "orc/" .. name
  local worktree_path = vim.fs.normalize(root .. "/" .. config.worktree_base .. "/" .. name)

  -- Create the worktree
  local cmd = { "git", "worktree", "add", "-b", branch, worktree_path, base }
  local result = vim.fn.system(cmd)
  if vim.v.shell_error ~= 0 then
    vim.notify("orc: failed to create worktree: " .. result, vim.log.levels.ERROR)
    return
  end

  -- Create a hidden terminal buffer
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("bufhidden", "hide", { buf = bufnr })

  local chan = vim.api.nvim_buf_call(bufnr, function()
    return vim.fn.termopen(config.cli, {
      cwd = worktree_path,
      on_exit = function(_, code)
        vim.schedule(function()
          if M.spaces[name] then
            M.spaces[name].status = "exited"
            vim.notify("orc: '" .. name .. "' CLI exited (code " .. code .. ")", vim.log.levels.INFO)
          end
        end)
      end,
    })
  end)

  if chan <= 0 then
    vim.notify("orc: failed to start terminal", vim.log.levels.ERROR)
    vim.api.nvim_buf_delete(bufnr, { force = true })
    return
  end

  M.spaces[name] = {
    bufnr = bufnr,
    chan = chan,
    worktree_path = worktree_path,
    branch = branch,
    status = "active",
    win = nil,
  }

  if not M.active_space then
    M.active_space = name
  end

  -- Start signal file watcher if available
  local ok, signal = pcall(require, "orc.signal")
  if ok then
    signal.watch(name, worktree_path)
  end

  vim.notify("orc: created space '" .. name .. "'", vim.log.levels.INFO)
end

--- Toggle visibility of a space's terminal.
---@param name? string Defaults to active space.
function M.toggle(name)
  name = name or M.active_space
  if not name then
    vim.notify("orc: no active space", vim.log.levels.WARN)
    return
  end

  local space = M.spaces[name]
  if not space then
    vim.notify("orc: space '" .. name .. "' not found", vim.log.levels.WARN)
    return
  end

  -- If visible, close it
  if space.win and vim.api.nvim_win_is_valid(space.win) then
    vim.api.nvim_win_close(space.win, true)
    space.win = nil
    return
  end

  -- Otherwise, open it
  local config = get_config()
  local win

  if config.terminal_direction == "float" then
    local width = math.floor(vim.o.columns * 0.8)
    local height = math.floor(vim.o.lines * 0.8)
    local row = math.floor((vim.o.lines - height) / 2)
    local col = math.floor((vim.o.columns - width) / 2)
    win = vim.api.nvim_open_win(space.bufnr, true, {
      relative = "editor",
      width = width,
      height = height,
      row = row,
      col = col,
      style = "minimal",
      border = "rounded",
      title = " orc: " .. name .. " ",
      title_pos = "center",
    })
  elseif config.terminal_direction == "vertical" then
    vim.cmd("vsplit")
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, space.bufnr)
  else -- horizontal
    vim.cmd("split")
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, space.bufnr)
  end

  space.win = win
  M.active_space = name

  -- Enter terminal mode
  vim.cmd("startinsert")
end

--- Delete a space: kill terminal, remove worktree, clean up state.
---@param name string
function M.delete(name)
  local space = M.spaces[name]
  if not space then
    vim.notify("orc: space '" .. name .. "' not found", vim.log.levels.WARN)
    return
  end

  -- Stop signal watcher
  local ok, signal = pcall(require, "orc.signal")
  if ok then
    signal.unwatch(name)
  end

  -- Close window if open
  if space.win and vim.api.nvim_win_is_valid(space.win) then
    vim.api.nvim_win_close(space.win, true)
  end

  -- Kill terminal
  if vim.api.nvim_buf_is_valid(space.bufnr) then
    vim.fn.jobstop(space.chan)
    vim.api.nvim_buf_delete(space.bufnr, { force = true })
  end

  -- Remove worktree
  local result = vim.fn.system({ "git", "worktree", "remove", "--force", space.worktree_path })
  if vim.v.shell_error ~= 0 then
    vim.notify("orc: worktree removal warning: " .. result, vim.log.levels.WARN)
  end

  -- Delete the branch
  vim.fn.system({ "git", "branch", "-D", space.branch })

  M.spaces[name] = nil

  if M.active_space == name then
    M.active_space = next(M.spaces)
  end

  vim.notify("orc: deleted space '" .. name .. "'", vim.log.levels.INFO)
end

--- List all spaces.
---@return table<string, OrcSpace>
function M.list()
  return M.spaces
end

--- Switch the active space.
---@param name string
function M.switch(name)
  if not M.spaces[name] then
    vim.notify("orc: space '" .. name .. "' not found", vim.log.levels.WARN)
    return
  end
  M.active_space = name
  vim.notify("orc: active space → '" .. name .. "'", vim.log.levels.INFO)
end

--- Get a space by name, or the active space.
---@param name? string
---@return OrcSpace|nil, string|nil
function M.get(name)
  name = name or M.active_space
  if not name then
    return nil, nil
  end
  return M.spaces[name], name
end

return M
