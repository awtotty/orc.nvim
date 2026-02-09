local M = {}

---@class OrcConfig
---@field cli string CLI command to run in each space
---@field worktree_base string Where to put worktrees (relative to repo root)
---@field signal_file string Signal file path within worktree
---@field terminal_direction string "float"|"vertical"|"horizontal"

---@type OrcConfig
M.config = {
  cli = "claude",
  worktree_base = "../orc-spaces",
  signal_file = ".claude/signal",
  terminal_direction = "float",
}

---@param opts? OrcConfig
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
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
  local spaces = require("orc.spaces")
  local entries = spaces.list()

  if vim.tbl_isempty(entries) then
    vim.notify("orc: no spaces", vim.log.levels.INFO)
    return
  end

  local lines = {}
  for name, space in pairs(entries) do
    local marker = (name == spaces.active_space) and "* " or "  "
    table.insert(lines, marker .. name .. " [" .. space.status .. "] " .. space.branch)
  end

  table.sort(lines)
  vim.notify("orc spaces:\n" .. table.concat(lines, "\n"), vim.log.levels.INFO)
end

function M.prompt(name)
  require("orc.prompt").prompt(name)
end

return M
