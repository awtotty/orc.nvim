if vim.g.loaded_orc then
  return
end
vim.g.loaded_orc = true

vim.api.nvim_create_user_command("OrcCreate", function(cmd)
  local name = cmd.fargs[1]
  if not name or name == "" then
    vim.ui.input({ prompt = "Space name: " }, function(input)
      if input and input ~= "" then
        require("orc").create(input)
      end
    end)
    return
  end
  require("orc").create(name)
end, {
  nargs = "?",
  desc = "Create a new orc space (worktree + agent)",
})

vim.api.nvim_create_user_command("OrcToggle", function(cmd)
  require("orc").toggle(cmd.fargs[1])
end, {
  nargs = "?",
  complete = function()
    return vim.tbl_keys(require("orc.spaces").spaces)
  end,
  desc = "Toggle an orc space terminal",
})

vim.api.nvim_create_user_command("OrcDelete", function(cmd)
  local name = cmd.fargs[1]
  if not name or name == "" then
    vim.notify("orc: usage: :OrcDelete <name>", vim.log.levels.WARN)
    return
  end
  require("orc").delete(name)
end, {
  nargs = 1,
  complete = function()
    return vim.tbl_keys(require("orc.spaces").spaces)
  end,
  desc = "Delete an orc space",
})

vim.api.nvim_create_user_command("OrcList", function()
  require("orc").list()
end, {
  desc = "List all orc spaces",
})

vim.api.nvim_create_user_command("OrcPrompt", function(cmd)
  require("orc").prompt(cmd.fargs[1])
end, {
  nargs = "?",
  range = true,
  complete = function()
    return vim.tbl_keys(require("orc.spaces").spaces)
  end,
  desc = "Send a prompt to an orc space",
})

vim.api.nvim_create_user_command("OrcSwitch", function(cmd)
  local name = cmd.fargs[1]
  if not name or name == "" then
    vim.notify("orc: usage: :OrcSwitch <name>", vim.log.levels.WARN)
    return
  end
  require("orc").switch(name)
end, {
  nargs = 1,
  complete = function()
    return vim.tbl_keys(require("orc.spaces").spaces)
  end,
  desc = "Switch the active orc space",
})
