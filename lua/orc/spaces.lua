local M = {}

---@class OrcSpace
---@field bufnr number Terminal buffer number
---@field chan number Terminal channel ID
---@field worktree_path string Absolute path to the worktree
---@field branch string Branch name
---@field status string "ready"|"needs_attention"|"exited"
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

--- Ensure the shared CLAUDE.md exists in the worktree base directory.
--- Claude Code walks parent directories, so all worktrees inherit it.
---@param base_dir string The .orc-spaces directory
local function ensure_signal_instructions(base_dir)
  vim.fn.mkdir(base_dir, "p")
  local claude_md = base_dir .. "/CLAUDE.md"

  -- Overwrite each time so instruction updates take effect
  local f

  f = io.open(claude_md, "w")
  if f then
    f:write([[# Orc Signal Protocol

You are running in an orc space. The user cannot see your output unless they open your terminal. You MUST signal the editor so the user knows when you need them.

Signal by appending to `$ORC_SIGNAL_FILE`:

```
echo "TYPE: message" >> "$ORC_SIGNAL_FILE"
```

IMPORTANT: Always signal BEFORE stopping or waiting. The user will not see your question otherwise.

- BEFORE asking the user anything: `echo "QUESTION: <your question>" >> "$ORC_SIGNAL_FILE"`
- BEFORE stopping when blocked: `echo "BLOCKED: <reason>" >> "$ORC_SIGNAL_FILE"`
- AFTER completing a task: `echo "DONE: <summary>" >> "$ORC_SIGNAL_FILE"`
- On errors you cannot recover from: `echo "ERROR: <message>" >> "$ORC_SIGNAL_FILE"`
]])
    f:close()
  end
end

--- Spawn a hidden terminal in a worktree and register it as a space.
---@param name string
---@param worktree_path string
---@param branch string
---@return boolean success
local function spawn_space(name, worktree_path, branch)
  local config = get_config()
  local signal_path = worktree_path .. "/" .. config.signal_file

  -- Write shared instructions in the worktree base (gitignored, skip for @main)
  if name ~= "@main" then
    local root = repo_root()
    if root then
      ensure_signal_instructions(root .. "/" .. config.worktree_base)
    end
  end

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("bufhidden", "hide", { buf = bufnr })

  local chan = vim.api.nvim_buf_call(bufnr, function()
    return vim.fn.termopen(config.cli, {
      cwd = worktree_path,
      env = { ORC_SIGNAL_FILE = signal_path },
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
    vim.api.nvim_buf_delete(bufnr, { force = true })
    return false
  end

  M.spaces[name] = {
    bufnr = bufnr,
    chan = chan,
    worktree_path = worktree_path,
    branch = branch,
    status = "ready",
    win = nil,
  }

  if not M.active_space then
    M.active_space = name
  end

  local ok, signal = pcall(require, "orc.signal")
  if ok then
    signal.watch(name, worktree_path)
  end

  return true
end

--- Check if a local branch exists.
---@param branch string
---@return boolean
local function branch_exists(branch)
  vim.fn.system({ "git", "rev-parse", "--verify", branch })
  return vim.v.shell_error == 0
end

--- List existing git worktrees as {path, branch} pairs.
---@return table<string, string> map of worktree_path → branch
local function existing_worktrees()
  local out = vim.fn.systemlist({ "git", "worktree", "list", "--porcelain" })
  local result = {}
  local current_path = nil
  for _, line in ipairs(out) do
    local path = line:match("^worktree (.+)$")
    if path then
      current_path = path
    end
    local branch_ref = line:match("^branch (.+)$")
    if branch_ref and current_path then
      result[current_path] = branch_ref:gsub("^refs/heads/", "")
    end
  end
  return result
end

--- State file path for the current repo.
---@return string|nil
local function state_path()
  local root = repo_root()
  if not root then
    return nil
  end
  local dir = vim.fn.stdpath("data") .. "/orc"
  vim.fn.mkdir(dir, "p")
  local hash = vim.fn.sha256(root):sub(1, 12)
  return dir .. "/" .. hash .. ".json"
end

--- Save space metadata to disk. Excludes @main (lazily created).
function M.save()
  local path = state_path()
  if not path then
    return
  end

  local data = {}
  for name, space in pairs(M.spaces) do
    if name ~= "@main" then
      data[name] = {
        worktree_path = space.worktree_path,
        branch = space.branch,
      }
    end
  end

  local json = vim.json.encode(data)
  local f = io.open(path, "w")
  if f then
    f:write(json)
    f:close()
  end
end

--- Restore spaces from disk, re-creating terminal buffers.
function M.restore()
  local path = state_path()
  if not path then
    return
  end

  local f = io.open(path, "r")
  if not f then
    return
  end

  local content = f:read("*a")
  f:close()

  if content == "" then
    return
  end

  local ok, data = pcall(vim.json.decode, content)
  if not ok or type(data) ~= "table" then
    return
  end

  for name, info in pairs(data) do
    if not M.spaces[name] and vim.fn.isdirectory(info.worktree_path) == 1 then
      spawn_space(name, info.worktree_path, info.branch)
    end
  end
end

--- Get info about the main worktree.
---@return {path: string, branch: string}|nil
function M.main_worktree()
  local root = repo_root()
  if not root then
    return nil
  end
  local branch = vim.fn.systemlist("git -C " .. vim.fn.shellescape(root) .. " rev-parse --abbrev-ref HEAD")
  return {
    path = root,
    branch = (vim.v.shell_error == 0 and branch[1]) or "HEAD",
  }
end

--- Create a new space.
--- Supports: new branch, existing branch, or existing worktree.
---@param name string
---@param opts? {base?: string, branch?: string, worktree?: string}
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
  local worktree_path, branch

  if opts.worktree then
    worktree_path = vim.fs.normalize(opts.worktree)
    if vim.fn.isdirectory(worktree_path) ~= 1 then
      vim.notify("orc: worktree path does not exist: " .. worktree_path, vim.log.levels.ERROR)
      return
    end
    local wt_map = existing_worktrees()
    branch = wt_map[worktree_path] or name

  elseif opts.branch and branch_exists(opts.branch) then
    branch = opts.branch
    worktree_path = vim.fs.normalize(root .. "/" .. config.worktree_base .. "/" .. name)
    local result = vim.fn.system({ "git", "worktree", "add", worktree_path, branch })
    if vim.v.shell_error ~= 0 then
      vim.notify("orc: failed to create worktree: " .. result, vim.log.levels.ERROR)
      return
    end

  else
    local base = opts.base or "HEAD"
    branch = opts.branch or ("orc/" .. name)
    worktree_path = vim.fs.normalize(root .. "/" .. config.worktree_base .. "/" .. name)
    local result = vim.fn.system({ "git", "worktree", "add", "-b", branch, worktree_path, base })
    if vim.v.shell_error ~= 0 then
      vim.notify("orc: failed to create worktree: " .. result, vim.log.levels.ERROR)
      return
    end
  end

  if not spawn_space(name, worktree_path, branch) then
    vim.notify("orc: failed to start terminal", vim.log.levels.ERROR)
    return
  end

  M.save()
  vim.notify("orc: created space '" .. name .. "'", vim.log.levels.INFO)
end

--- Toggle visibility of a space's terminal.
---@param name? string Defaults to active space. Use "@main" for the main worktree.
function M.toggle(name)
  name = name or M.active_space

  -- Lazily create a terminal for the main worktree
  if name == "@main" and not M.spaces["@main"] then
    local main = M.main_worktree()
    if not main then
      vim.notify("orc: not inside a git repository", vim.log.levels.ERROR)
      return
    end
    if not spawn_space("@main", main.path, main.branch) then
      vim.notify("orc: failed to start terminal", vim.log.levels.ERROR)
      return
    end
  end
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
    local display = (name == "@main") and "main" or name
    win = vim.api.nvim_open_win(space.bufnr, true, {
      relative = "editor",
      width = width,
      height = height,
      row = row,
      col = col,
      style = "minimal",
      border = "rounded",
      title = " orc: " .. display .. " ",
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
  vim.cmd("startinsert")
end

--- Delete a space: kill terminal, remove worktree, clean up state.
--- The branch is kept so it can be reviewed from the main worktree.
---@param name string
function M.delete(name)
  if name == "@main" then
    vim.notify("orc: cannot delete the main worktree", vim.log.levels.WARN)
    return
  end

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

  -- Remove worktree (branch is preserved for review)
  local result = vim.fn.system({ "git", "worktree", "remove", "--force", space.worktree_path })
  if vim.v.shell_error ~= 0 then
    vim.notify("orc: worktree removal warning: " .. result, vim.log.levels.WARN)
  end

  M.spaces[name] = nil

  if M.active_space == name then
    M.active_space = next(M.spaces)
  end

  M.save()
  vim.notify("orc: deleted space '" .. name .. "' (branch " .. space.branch .. " kept)", vim.log.levels.INFO)
end

--- List all spaces (excludes @main).
---@return table<string, OrcSpace>
function M.list()
  local result = {}
  for name, space in pairs(M.spaces) do
    if name ~= "@main" then
      result[name] = space
    end
  end
  return result
end

--- Get the active space name.
---@return string|nil
function M.get_active()
  return M.active_space
end

--- Switch the active space and open the current file in that worktree.
---@param name string
function M.switch(name)
  if name ~= "@main" and not M.spaces[name] then
    vim.notify("orc: space '" .. name .. "' not found", vim.log.levels.WARN)
    return
  end

  -- Resolve target worktree path
  local target_root
  if name == "@main" then
    local main = M.main_worktree()
    target_root = main and main.path
  else
    target_root = M.spaces[name].worktree_path
  end

  -- Try to open the current file in the target worktree
  local current = vim.api.nvim_buf_get_name(0)
  if target_root and current ~= "" then
    local root = repo_root()
    if root then
      -- Find relative path: check space worktrees first (more specific),
      -- then fall back to main root
      local rel = nil
      for _, space in pairs(M.spaces) do
        local wp = space.worktree_path
        if current:sub(1, #wp + 1) == wp .. "/" then
          rel = current:sub(#wp + 2)
          break
        end
      end
      if not rel and current:sub(1, #root + 1) == root .. "/" then
        rel = current:sub(#root + 2)
      end

      if rel then
        local target_file = target_root .. "/" .. rel
        if vim.fn.filereadable(target_file) == 1 then
          vim.cmd("edit " .. vim.fn.fnameescape(target_file))
        else
          vim.cmd("enew")
        end
      else
        vim.cmd("enew")
      end
    end
  end

  M.active_space = name
  local display = (name == "@main") and "main" or name
  vim.notify("orc: active space -> '" .. display .. "'", vim.log.levels.INFO)
end

--- Update a space's status.
---@param name string
---@param status string
function M.set_status(name, status)
  if M.spaces[name] then
    M.spaces[name].status = status
  end
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

--- Get space names for completion.
---@return string[]
function M.names()
  return vim.tbl_keys(M.spaces)
end

return M
