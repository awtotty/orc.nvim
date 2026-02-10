local M = {}

---@class OrchidConfig
---@field cli string CLI command to run in each room
---@field worktree_base string Where to put worktrees (relative to repo root)
---@field signal_file string Signal file path within worktree
---@field terminal_direction string "float"|"vertical"|"horizontal"

---@type OrchidConfig
M.config = {
  cli = "claude",
  worktree_base = ".orchid",
  signal_file = ".claude/signal",
  terminal_direction = "float",
  keys = {
    { "<leader>ow", "<cmd>OrchidList<cr>", mode = "n", desc = "Orchid: list rooms" },
    { "<leader>ot", "<cmd>OrchidToggle<cr>", mode = { "n", "v" }, desc = "Orchid: toggle terminal" },
    { "<leader>oe", "<cmd>OrchidPrompt<cr>", mode = { "n", "v" }, desc = "Orchid: prompt" },
    { "<leader>og", "<cmd>OrchidGrid<cr>", mode = "n", desc = "Orchid: toggle grid" },
  },
}

---@param opts? OrchidConfig
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  for _, key in ipairs(M.config.keys) do
    vim.keymap.set(key.mode, key[1], key[2], { desc = key.desc })
  end
  require("orchid.rooms").restore()
end

-- Public API — delegate to submodules

function M.create(name, opts)
  require("orchid.rooms").create(name, opts)
end

function M.toggle(name)
  require("orchid.rooms").toggle(name)
end

function M.delete(name, opts)
  require("orchid.rooms").delete(name, opts)
end

function M.switch(name)
  require("orchid.rooms").switch(name)
end

function M.list()
  require("orchid.ui").list()
end

function M.prompt(name)
  require("orchid.prompt").prompt(name)
end

function M.grid()
  require("orchid.grid").toggle()
end

--- Get the active room name.
---@return string|nil
function M.get_active()
  return require("orchid.rooms").get_active()
end

--- Get info about the main worktree.
---@return {path: string, branch: string}|nil
function M.main_worktree()
  return require("orchid.rooms").main_worktree()
end

--- Get all rooms (excludes @main).
---@return table<string, OrchidRoom>
function M.rooms()
  return require("orchid.rooms").list()
end

--- Get a room by name, or the active room.
---@param name? string
---@return OrchidRoom|nil, string|nil
function M.get(name)
  return require("orchid.rooms").get(name)
end

--- Update a room's status.
---@param name string
---@param status string
function M.set_status(name, status)
  require("orchid.rooms").set_status(name, status)
end

--- Get room names for command completion.
---@return string[]
function M.names()
  return require("orchid.rooms").names()
end

return M
