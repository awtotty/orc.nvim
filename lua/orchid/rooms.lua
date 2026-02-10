local M = {}

---@class OrchidRoom
---@field bufnr number Terminal buffer number
---@field chan number Terminal channel ID
---@field worktree_path string Absolute path to the worktree
---@field branch string Branch name
---@field status string "active"|"ready"|"needs_attention"|"exited"
---@field win number|nil Window ID if currently visible
---@field last_file string|nil

---@type table<string, OrchidRoom>
M.rooms = {}

---@type string|nil
M.active_room = nil

---@type string|nil  -- last_file for @main when it hasn't been spawned yet
M._main_last_file = nil

local function get_config()
  return require("orchid").config
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
---@param base_dir string The .orchid directory
local function ensure_signal_instructions(base_dir)
  vim.fn.mkdir(base_dir, "p")
  local claude_md = base_dir .. "/CLAUDE.md"

  -- Overwrite each time so instruction updates take effect
  local f

  f = io.open(claude_md, "w")
  if f then
    f:write([[# Orchid Signal Protocol

You are running in an Orchid room. The user cannot see your output unless they open your terminal. You MUST signal the editor so the user knows when you need them.

Signal by appending to `$ORCHID_SIGNAL_FILE`:

```
echo "TYPE: message" >> "$ORCHID_SIGNAL_FILE"
```

IMPORTANT: Always signal BEFORE stopping or waiting. The user will not see your question otherwise.

- BEFORE asking the user anything: `echo "QUESTION: <your question>" >> "$ORCHID_SIGNAL_FILE"`
- BEFORE stopping when blocked: `echo "BLOCKED: <reason>" >> "$ORCHID_SIGNAL_FILE"`
- AFTER completing a task: `echo "DONE: <summary>" >> "$ORCHID_SIGNAL_FILE"`
- On errors you cannot recover from: `echo "ERROR: <message>" >> "$ORCHID_SIGNAL_FILE"`
]])
    f:close()
  end
end

--- Spawn a hidden terminal in a worktree and register it as a room.
---@param name string
---@param worktree_path string
---@param branch string
---@return boolean success
local function spawn_room(name, worktree_path, branch)
  local config = get_config()
  local signal_path = worktree_path .. "/" .. config.signal_file

  -- Skip setup for @main (user's own repo)
  if name ~= "@main" then
    local root = repo_root()
    if root then
      ensure_signal_instructions(root .. "/" .. config.worktree_base)

      -- Symlink all .claude files from root so rooms inherit settings, MCPs, etc.
      local claude_dir = worktree_path .. "/.claude"
      vim.fn.mkdir(claude_dir, "p")
      local root_claude_dir = root .. "/.claude"
      local handle = vim.uv.fs_scandir(root_claude_dir)
      if handle then
        while true do
          local entry, typ = vim.uv.fs_scandir_next(handle)
          if not entry then break end
          if typ == "file" and entry ~= "settings.local.json" then
            local dst = claude_dir .. "/" .. entry
            if vim.fn.filereadable(dst) == 0 and not vim.uv.fs_lstat(dst) then
              vim.uv.fs_symlink(root_claude_dir .. "/" .. entry, dst)
            end
          end
        end
      end

      -- Symlink root CLAUDE.md
      local root_claude = root .. "/CLAUDE.md"
      local dst_claude = worktree_path .. "/CLAUDE.md"
      if vim.fn.filereadable(root_claude) == 1 and vim.fn.filereadable(dst_claude) == 0 then
        vim.uv.fs_symlink(root_claude, dst_claude)
      end

      -- Build room settings: merge root permissions + signal permission + hooks
      local hooks_settings = claude_dir .. "/settings.local.json"
      local sig = signal_path:gsub('"', '\\"')

      -- Collect permissions: start with signal echo
      local allow = { string.format('Bash(echo * >> "%s")', sig) }

      -- Copy permissions from root settings.local.json
      local root_settings_path = root_claude_dir .. "/settings.local.json"
      local rf = io.open(root_settings_path, "r")
      if rf then
        local content = rf:read("*a")
        rf:close()
        local parse_ok, root_settings = pcall(vim.json.decode, content)
        if parse_ok and root_settings and root_settings.permissions and root_settings.permissions.allow then
          for _, perm in ipairs(root_settings.permissions.allow) do
            table.insert(allow, perm)
          end
        end
      end

      local settings = {
        permissions = { allow = allow },
        hooks = {
          Notification = {
            {
              matcher = "idle_prompt",
              hooks = {
                {
                  type = "command",
                  command = string.format('echo "QUESTION: Agent is waiting for input" >> "%s"', sig),
                },
              },
            },
            {
              matcher = "permission_prompt",
              hooks = {
                {
                  type = "command",
                  command = string.format('echo "BLOCKED: Agent needs tool permission" >> "%s"', sig),
                },
              },
            },
          },
          UserPromptSubmit = {
            {
              hooks = {
                {
                  type = "command",
                  command = string.format('echo "READY: Agent resumed" >> "%s"', sig),
                },
              },
            },
          },
        },
      }

      local hf = io.open(hooks_settings, "w")
      if hf then
        hf:write(vim.json.encode(settings))
        hf:close()
      end
    end
  end

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("bufhidden", "hide", { buf = bufnr })

  local chan = vim.api.nvim_buf_call(bufnr, function()
    return vim.fn.termopen(config.cli, {
      cwd = worktree_path,
      env = { ORCHID_SIGNAL_FILE = signal_path },
      on_exit = function(_, code)
        vim.schedule(function()
          if M.rooms[name] then
            M.rooms[name].status = "exited"
            vim.notify("Orchid: '" .. name .. "' CLI exited (code " .. code .. ")", vim.log.levels.INFO)
          end
        end)
      end,
    })
  end)

  if chan <= 0 then
    vim.api.nvim_buf_delete(bufnr, { force = true })
    return false
  end

  M.rooms[name] = {
    bufnr = bufnr,
    chan = chan,
    worktree_path = worktree_path,
    branch = branch,
    status = "active",
    win = nil,
    last_file = (name == "@main") and M._main_last_file or nil,
  }

  -- Cycle-room keymaps on the terminal buffer
  vim.api.nvim_buf_set_keymap(bufnr, "n", "<C-k>", "", {
    callback = function() M.cycle(-1) end,
    noremap = true,
    silent = true,
  })
  vim.api.nvim_buf_set_keymap(bufnr, "n", "<C-j>", "", {
    callback = function() M.cycle(1) end,
    noremap = true,
    silent = true,
  })

  if not M.active_room then
    M.active_room = name
  end

  if name ~= "@main" then
    local ok, signal = pcall(require, "orchid.signal")
    if ok then
      signal.watch(name, worktree_path)
    end
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
  local dir = vim.fn.stdpath("data") .. "/orchid"
  vim.fn.mkdir(dir, "p")
  local hash = vim.fn.sha256(root):sub(1, 12)
  return dir .. "/" .. hash .. ".json"
end

--- Save room metadata to disk. Excludes @main (lazily created).
function M.save()
  local path = state_path()
  if not path then
    return
  end

  local data = { _active = M.active_room, _main_last_file = M._main_last_file }
  for name, room in pairs(M.rooms) do
    if name == "@main" then
      if room.last_file then
        data._main_last_file = room.last_file
      end
    else
      data[name] = {
        worktree_path = room.worktree_path,
        branch = room.branch,
        last_file = room.last_file,
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

--- Restore rooms from disk, re-creating terminal buffers.
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

  local saved_active = data._active
  local main_last_file = data._main_last_file
  data._active = nil
  data._main_last_file = nil

  for name, info in pairs(data) do
    if type(info) == "table" and info.worktree_path and not M.rooms[name] and vim.fn.isdirectory(info.worktree_path) == 1 then
      spawn_room(name, info.worktree_path, info.branch)
      if M.rooms[name] and info.last_file then
        M.rooms[name].last_file = info.last_file
      end
    end
  end

  if main_last_file then
    M._main_last_file = main_last_file
    if M.rooms["@main"] then
      M.rooms["@main"].last_file = main_last_file
    end
  end

  if saved_active then
    M.active_room = saved_active
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

--- Create a new room.
--- Supports: new branch, existing branch, or existing worktree.
---@param name string
---@param opts? {base?: string, branch?: string, worktree?: string}
function M.create(name, opts)
  opts = opts or {}

  if M.rooms[name] then
    vim.notify("Orchid: room '" .. name .. "' already exists", vim.log.levels.WARN)
    return
  end

  local root = repo_root()
  if not root then
    vim.notify("Orchid: not inside a git repository", vim.log.levels.ERROR)
    return
  end

  local config = get_config()
  local worktree_path, branch

  if opts.worktree then
    worktree_path = vim.fs.normalize(opts.worktree)
    if vim.fn.isdirectory(worktree_path) ~= 1 then
      vim.notify("Orchid: worktree path does not exist: " .. worktree_path, vim.log.levels.ERROR)
      return
    end
    local wt_map = existing_worktrees()
    branch = wt_map[worktree_path] or name
  elseif opts.branch and branch_exists(opts.branch) then
    branch = opts.branch
    worktree_path = vim.fs.normalize(root .. "/" .. config.worktree_base .. "/" .. name)
    local result = vim.fn.system({ "git", "worktree", "add", "--force", worktree_path, branch })
    if vim.v.shell_error ~= 0 then
      vim.notify("Orchid: failed to create worktree: " .. result, vim.log.levels.ERROR)
      return
    end
  else
    local base = opts.base or "HEAD"
    branch = opts.branch or name
    worktree_path = vim.fs.normalize(root .. "/" .. config.worktree_base .. "/" .. name)
    local result = vim.fn.system({ "git", "worktree", "add", "-b", branch, worktree_path, base })
    if vim.v.shell_error ~= 0 then
      vim.notify("Orchid: failed to create worktree: " .. result, vim.log.levels.ERROR)
      return
    end
  end

  if not spawn_room(name, worktree_path, branch) then
    vim.notify("Orchid: failed to start terminal", vim.log.levels.ERROR)
    return
  end

  vim.notify("Orchid: created room '" .. name .. "'", vim.log.levels.INFO)
  M.switch(name)
end

--- Toggle visibility of a room's terminal.
---@param name? string Defaults to active room. Use "@main" for the main worktree.
function M.toggle(name)
  -- Prevent individual toggles from breaking grid layout
  local ok, grid = pcall(require, "orchid.grid")
  if ok and grid.is_active() then
    vim.notify("Orchid: close grid first (<leader>og) before toggling individual rooms", vim.log.levels.WARN)
    return
  end

  name = name or M.active_room or "@main"

  -- Lazily create a terminal for the main worktree
  if name == "@main" and not M.rooms["@main"] then
    local main = M.main_worktree()
    if not main then
      vim.notify("Orchid: not inside a git repository", vim.log.levels.ERROR)
      return
    end
    if not spawn_room("@main", main.path, main.branch) then
      vim.notify("Orchid: failed to start terminal", vim.log.levels.ERROR)
      return
    end
  end
  if not name then
    vim.notify("Orchid: no active room", vim.log.levels.WARN)
    return
  end

  local room = M.rooms[name]
  if not room then
    vim.notify("Orchid: room '" .. name .. "' not found", vim.log.levels.WARN)
    return
  end

  -- Respawn CLI if it exited
  if room.status == "exited" then
    if vim.api.nvim_buf_is_valid(room.bufnr) then
      vim.api.nvim_buf_delete(room.bufnr, { force = true })
    end
    if not spawn_room(name, room.worktree_path, room.branch) then
      vim.notify("Orchid: failed to restart terminal", vim.log.levels.ERROR)
      return
    end
    room = M.rooms[name]
  end

  -- If visible, close it
  if room.win and vim.api.nvim_win_is_valid(room.win) then
    vim.api.nvim_win_close(room.win, true)
    room.win = nil
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
    win = vim.api.nvim_open_win(room.bufnr, true, {
      relative = "editor",
      width = width,
      height = height,
      row = row,
      col = col,
      style = "minimal",
      border = "rounded",
      title = " Orchid: " .. display .. " ",
      title_pos = "center",
    })
  elseif config.terminal_direction == "vertical" then
    vim.cmd("vsplit")
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, room.bufnr)
  else -- horizontal
    vim.cmd("split")
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, room.bufnr)
  end

  room.win = win
  if room.status == "needs_attention" then
    room.status = "active"
  end
end

--- Check if a worktree has uncommitted changes.
---@param worktree_path string
---@return boolean
function M.has_uncommitted_changes(worktree_path)
  local out = vim.fn.systemlist({ "git", "-C", worktree_path, "status", "--porcelain" })
  return vim.v.shell_error == 0 and #out > 0
end

--- Delete a room: kill terminal, remove worktree, clean up state.
--- The branch is kept so it can be reviewed from the main worktree.
---@param name string
---@param opts? {force?: boolean}
function M.delete(name, opts)
  opts = opts or {}
  if name == "@main" then
    vim.notify("Orchid: cannot delete the main worktree", vim.log.levels.WARN)
    return
  end

  local room = M.rooms[name]
  if not room then
    vim.notify("Orchid: room '" .. name .. "' not found", vim.log.levels.WARN)
    return
  end

  if not opts.force and M.has_uncommitted_changes(room.worktree_path) then
    local ui = require("orchid.ui")
    ui.float_select("'" .. name .. "' has uncommitted changes. delete?", { "no", "yes" }, function(choice)
      if choice == "yes" then
        M.delete(name, { force = true })
      end
    end)
    return
  end

  -- Stop signal watcher
  local ok, signal = pcall(require, "orchid.signal")
  if ok then
    signal.unwatch(name)
  end

  -- Close window if open
  if room.win and vim.api.nvim_win_is_valid(room.win) then
    vim.api.nvim_win_close(room.win, true)
  end

  -- Kill terminal
  if vim.api.nvim_buf_is_valid(room.bufnr) then
    vim.fn.jobstop(room.chan)
    vim.api.nvim_buf_delete(room.bufnr, { force = true })
  end

  -- Remove worktree (branch is preserved for review)
  local result = vim.fn.system({ "git", "worktree", "remove", "--force", room.worktree_path })
  if vim.v.shell_error ~= 0 then
    vim.notify("Orchid: worktree removal warning: " .. result, vim.log.levels.WARN)
  end

  M.rooms[name] = nil

  if M.active_room == name then
    M.switch("@main")
  end

  M.save()
  vim.notify("Orchid: deleted room '" .. name .. "' (branch " .. room.branch .. " kept)", vim.log.levels.INFO)
end

--- List all rooms (excludes @main).
---@return table<string, OrchidRoom>
function M.list()
  local result = {}
  for name, room in pairs(M.rooms) do
    if name ~= "@main" then
      result[name] = room
    end
  end
  return result
end

--- Get the active room name.
---@return string|nil
function M.get_active()
  return M.active_room
end

--- Switch the active room and open the current file in that worktree.
---@param name string
function M.switch(name)
  if name ~= "@main" and not M.rooms[name] then
    vim.notify("Orchid: room '" .. name .. "' not found", vim.log.levels.WARN)
    return
  end

  -- Save current file as last_file for the room we're leaving
  local current = vim.api.nvim_buf_get_name(0)
  if M.active_room and current ~= "" then
    local root = repo_root()
    if root then
      local old_room = M.rooms[M.active_room]
      local old_root = old_room and old_room.worktree_path or root
      if current:sub(1, #old_root + 1) == old_root .. "/" then
        local rel = current:sub(#old_root + 2)
        if old_room then
          old_room.last_file = rel
        end
        if M.active_room == "@main" then
          M._main_last_file = rel
        end
      end
    end
  end

  -- Resolve target worktree path
  local target_root
  if name == "@main" then
    local main = M.main_worktree()
    target_root = main and main.path
  else
    target_root = M.rooms[name].worktree_path
  end

  -- Open file in target worktree: prefer target's last_file, fall back to current file's relative path
  if target_root then
    local target_room = M.rooms[name]
    local rel = target_room and target_room.last_file
    if not rel and name == "@main" then
      rel = M._main_last_file
    end

    -- Fall back to current file's relative path in target worktree
    if not rel and current ~= "" then
      local root = repo_root()
      if root then
        for _, room in pairs(M.rooms) do
          local wp = room.worktree_path
          if current:sub(1, #wp + 1) == wp .. "/" then
            rel = current:sub(#wp + 2)
            break
          end
        end
        if not rel and current:sub(1, #root + 1) == root .. "/" then
          rel = current:sub(#root + 2)
        end
      end
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

  -- Handle window visibility across the switch
  local ok, grid = pcall(require, "orchid.grid")
  if ok and grid.is_active() then
    -- In grid mode: swap the focused pane to the new room
    M.active_room = name
    M.save()
    grid.swap(name)
    vim.cmd("stopinsert")
    local display = (name == "@main") and "main" or name
    vim.notify("Orchid: active room -> '" .. display .. "'", vim.log.levels.INFO)
    return
  end

  -- Check if the old active room had a visible window
  local old_win_visible = false
  if M.active_room then
    local old_room = M.rooms[M.active_room]
    if old_room and old_room.win and vim.api.nvim_win_is_valid(old_room.win) then
      old_win_visible = true
      vim.api.nvim_win_close(old_room.win, true)
      old_room.win = nil
    end
  end

  M.active_room = name
  M.save()
  vim.cmd("stopinsert")
  local display = (name == "@main") and "main" or name
  vim.notify("Orchid: active room -> '" .. display .. "'", vim.log.levels.INFO)

  -- If the old room's window was visible, open the new room's window
  if old_win_visible then
    M.toggle(name)
  end
end

--- Update a room's status.
---@param name string
---@param status string
function M.set_status(name, status)
  if M.rooms[name] then
    M.rooms[name].status = status
  end
end

--- Get a room by name, or the active room.
---@param name? string
---@return OrchidRoom|nil, string|nil
function M.get(name)
  name = name or M.active_room
  if not name then
    return nil, nil
  end
  return M.rooms[name], name
end

--- Get a sorted list of all room names.
---@return string[]
local function sorted_room_names()
  local names = vim.tbl_keys(M.rooms)
  table.sort(names, function(a, b)
    if a == "@main" then return true end
    if b == "@main" then return false end
    return a < b
  end)
  return names
end

--- Cycle to the next or previous room, opening its float if one was visible.
---@param direction number 1 for forward, -1 for backward
function M.cycle(direction)
  local names = sorted_room_names()
  if #names <= 1 then return end

  local current = M.active_room or "@main"
  local idx = 1
  for i, name in ipairs(names) do
    if name == current then
      idx = i
      break
    end
  end

  idx = ((idx - 1 + direction) % #names) + 1
  M.switch(names[idx])
end

--- Get room names for completion.
---@return string[]
function M.names()
  return vim.tbl_keys(M.rooms)
end

return M
