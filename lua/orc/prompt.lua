local M = {}

--- Get the visual selection lines from the current buffer.
---@return string[]|nil lines, string|nil filename, number|nil start_line, number|nil end_line
local function get_visual_selection()
  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")
  local start_line = start_pos[2]
  local end_line = end_pos[2]

  if start_line == 0 or end_line == 0 or start_line > end_line then
    return nil, nil, nil, nil
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)
  local filename = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":~:.")

  return lines, filename, start_line, end_line
end

--- Detect the filetype for fenced code block language.
---@return string
local function get_lang()
  local ft = vim.bo.filetype
  if ft == "" then
    return ""
  end
  return ft
end

--- Format the context block.
---@param lines string[]
---@param filename string
---@param start_line number
---@param end_line number
---@return string
local function format_context(lines, filename, start_line, end_line)
  local lang = get_lang()
  local header = string.format("In `%s:%d-%d`:", filename, start_line, end_line)
  local fence_open = "```" .. lang
  local fence_close = "```"
  local code = table.concat(lines, "\n")

  return header .. "\n" .. fence_open .. "\n" .. code .. "\n" .. fence_close
end

--- Send text to a space's terminal.
---@param space_name? string
---@param text string
local function send_to_space(space_name, text)
  local orc = require("orc")
  local space, name = orc.get(space_name)

  if not space then
    vim.notify("orc: no space to send to", vim.log.levels.WARN)
    return
  end

  if not vim.api.nvim_buf_is_valid(space.bufnr) then
    vim.notify("orc: space '" .. name .. "' terminal is invalid", vim.log.levels.ERROR)
    return
  end

  -- Send the text followed by Enter
  vim.fn.chansend(space.chan, text .. "\n")
  vim.notify("orc: prompt sent to '" .. name .. "'", vim.log.levels.INFO)
end

--- Open a prompt input and send to a space, optionally with visual selection context.
---@param space_name? string
function M.prompt(space_name)
  local context = nil

  -- Try to capture visual selection
  local lines, filename, start_line, end_line = get_visual_selection()
  if lines and #lines > 0 then
    context = format_context(lines, filename, start_line, end_line)
  end

  vim.ui.input({ prompt = "orc prompt: " }, function(input)
    if not input or input == "" then
      return
    end

    local message
    if context then
      message = context .. "\n\n" .. input
    else
      message = input
    end

    send_to_space(space_name, message)
  end)
end

return M
