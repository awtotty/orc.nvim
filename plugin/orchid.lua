if vim.g.loaded_orchid then
  return
end
vim.g.loaded_orchid = true

vim.api.nvim_create_user_command("OrchidCreate", function(cmd)
  local name = cmd.fargs[1]
  if not name or name == "" then
    vim.ui.input({ prompt = "Room name: " }, function(input)
      if input and input ~= "" then
        require("orchid").create(input)
      end
    end)
    return
  end
  -- Parse optional flags: --branch=<branch> --worktree=<path>
  local opts = {}
  for i = 2, #cmd.fargs do
    local branch = cmd.fargs[i]:match("^%-%-branch=(.+)$")
    if branch then opts.branch = branch end
    local wt = cmd.fargs[i]:match("^%-%-worktree=(.+)$")
    if wt then opts.worktree = wt end
  end
  require("orchid").create(name, opts)
end, {
  nargs = "*",
  desc = "Create a new Orchid room (worktree + agent). Options: --branch=<name> --worktree=<path>",
})

vim.api.nvim_create_user_command("OrchidToggle", function(cmd)
  require("orchid").toggle(cmd.fargs[1])
end, {
  nargs = "?",
  complete = function()
    return require("orchid").names()
  end,
  desc = "Toggle an Orchid room terminal",
})

vim.api.nvim_create_user_command("OrchidDelete", function(cmd)
  local name = cmd.fargs[1]
  if not name or name == "" then
    vim.notify("Orchid: usage: :OrchidDelete <name>", vim.log.levels.WARN)
    return
  end
  require("orchid").delete(name)
end, {
  nargs = 1,
  complete = function()
    return require("orchid").names()
  end,
  desc = "Delete an Orchid room",
})

vim.api.nvim_create_user_command("OrchidList", function()
  require("orchid").list()
end, {
  desc = "List all Orchid rooms",
})

vim.api.nvim_create_user_command("OrchidPrompt", function(cmd)
  require("orchid").prompt(cmd.fargs[1])
end, {
  nargs = "?",
  range = true,
  complete = function()
    return require("orchid").names()
  end,
  desc = "Send a prompt to an Orchid room",
})

vim.api.nvim_create_user_command("OrchidGrid", function()
  require("orchid").grid()
end, {
  desc = "Toggle Orchid grid view (show multiple rooms)",
})

vim.api.nvim_create_user_command("OrchidSwitch", function(cmd)
  local name = cmd.fargs[1]
  if not name or name == "" then
    vim.notify("Orchid: usage: :OrchidSwitch <name>", vim.log.levels.WARN)
    return
  end
  require("orchid").switch(name)
end, {
  nargs = 1,
  complete = function()
    return require("orchid").names()
  end,
  desc = "Switch the active Orchid room",
})
