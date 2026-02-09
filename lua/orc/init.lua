local M = {}

---@class OrcConfig
---@field cli string CLI command to run in each space
---@field worktree_base string Where to put worktrees (relative to repo root)
---@field signal_file string Signal file path within worktree
---@field terminal_direction string "float"|"vertical"|"horizontal"

---@type OrcConfig
M.config = {
  cli = "claude",
  worktree_base = ".orc-spaces",
  signal_file = ".claude/signal",
  terminal_direction = "float",
}

---@param opts? OrcConfig
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  require("orc.spaces").restore()
end

-- Public API — delegate to submodules

function M.create(name, opts)
  require("orc.spaces").create(name, opts)
end

function M.toggle(name)
  require("orc.spaces").toggle(name)
end

function M.delete(name)
  require("orc.spaces").delete(name)
end

function M.switch(name)
  require("orc.spaces").switch(name)
end

function M.list()
  require("orc.ui").list()
end

function M.prompt(name)
  require("orc.prompt").prompt(name)
end

--- Get the active space name.
---@return string|nil
function M.get_active()
  return require("orc.spaces").get_active()
end

--- Get info about the main worktree.
---@return {path: string, branch: string}|nil
function M.main_worktree()
  return require("orc.spaces").main_worktree()
end

--- Get all spaces (excludes @main).
---@return table<string, OrcSpace>
function M.spaces()
  return require("orc.spaces").list()
end

--- Get a space by name, or the active space.
---@param name? string
---@return OrcSpace|nil, string|nil
function M.get(name)
  return require("orc.spaces").get(name)
end

--- Update a space's status.
---@param name string
---@param status string
function M.set_status(name, status)
  require("orc.spaces").set_status(name, status)
end

--- Get space names for command completion.
---@return string[]
function M.names()
  return require("orc.spaces").names()
end

return M
