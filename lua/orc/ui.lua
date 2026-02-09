local M = {}

--- Open the spaces list in a floating buffer.
function M.list()
  local orc = require("orc")
  local entries = orc.spaces()
  local active = orc.get_active()

  local lines = {}
  local line_to_name = {}

  -- Main worktree always listed first
  local main = orc.main_worktree()
  if main then
    local marker = (active == "@main" or active == nil) and " ● " or "   "
    table.insert(lines, marker .. "main  " .. main.branch .. "  " .. main.path)
    line_to_name[#lines] = "@main"
  end

  local sorted = {}
  for name in pairs(entries) do
    table.insert(sorted, name)
  end
  table.sort(sorted)

  for _, name in ipairs(sorted) do
    local space = entries[name]
    local marker = (name == active) and " ● " or "   "
    table.insert(lines, marker .. name .. "  [" .. space.status .. "]  " .. space.branch)
    line_to_name[#lines] = name
  end

  -- Action lines
  local actions = {}
  table.insert(lines, "   + new space")
  actions[#lines] = "new"
  table.insert(lines, "   + from branch")
  actions[#lines] = "branch"
  table.insert(lines, "   + from worktree")
  actions[#lines] = "worktree"

  -- Create buffer
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })

  local width = 0
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  width = math.max(width + 4, 30)
  local height = #lines

  -- Open float
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " orc spaces ",
    title_pos = "center",
  })

  vim.api.nvim_set_option_value("cursorline", true, { win = win })

  -- Place cursor on the first space line (find minimum key)
  local first_line = nil
  for k in pairs(line_to_name) do
    if not first_line or k < first_line then
      first_line = k
    end
  end
  if first_line then
    vim.api.nvim_win_set_cursor(win, { first_line, 0 })
  end

  local close = function()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  -- <CR>: switch to space or run create action
  vim.keymap.set("n", "<CR>", function()
    local row = vim.api.nvim_win_get_cursor(win)[1]
    local action = actions[row]
    close()

    if action == "new" then
      vim.ui.input({ prompt = "Space name: " }, function(name)
        if name and name ~= "" then
          orc.create(name)
        end
      end)

    elseif action == "branch" then
      vim.ui.input({ prompt = "Branch: " }, function(branch_name)
        if not branch_name or branch_name == "" then return end
        vim.ui.input({ prompt = "Space name (default: " .. branch_name:gsub("/", "-") .. "): " }, function(name)
          name = (name and name ~= "") and name or branch_name:gsub("/", "-")
          orc.create(name, { branch = branch_name })
        end)
      end)

    elseif action == "worktree" then
      vim.ui.input({ prompt = "Worktree path: " }, function(path)
        if not path or path == "" then return end
        vim.ui.input({ prompt = "Space name: " }, function(name)
          if name and name ~= "" then
            orc.create(name, { worktree = path })
          end
        end)
      end)

    elseif line_to_name[row] then
      orc.switch(line_to_name[row])
    end
  end, { buffer = buf, nowait = true })

  -- d: delete space with confirmation (not on main)
  vim.keymap.set("n", "d", function()
    local row = vim.api.nvim_win_get_cursor(win)[1]
    local name = line_to_name[row]
    if not name or name == "@main" then
      return
    end
    close()
    vim.ui.input({ prompt = "Delete space '" .. name .. "'? (y/N): " }, function(input)
      if input and input:lower() == "y" then
        orc.delete(name)
      end
    end)
  end, { buffer = buf, nowait = true })

  vim.keymap.set("n", "q", close, { buffer = buf, nowait = true })
  vim.keymap.set("n", "<Esc>", close, { buffer = buf, nowait = true })
  vim.api.nvim_create_autocmd("BufLeave", { buffer = buf, once = true, callback = close })
end

return M
