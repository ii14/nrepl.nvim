local api, fn = vim.api, vim.fn
local util = require('neorepl.util')

local ns = api.nvim_create_namespace('neorepl')

local COMMAND_PREFIX = '/'
local MSG_INVALID_COMMAND = {'invalid command'}
local BREAK_UNDO = api.nvim_replace_termcodes('<C-G>u', true, false, true)

---@generic T
---@param v T|nil
---@param default T
---@return T
local function get_opt(v, default)
  if v == nil then
    return default
  else
    return v
  end
end

---@class neorepl.Repl
---@field bufnr       number        repl buffer
---@field lua         neorepl.Lua
---@field vim         neorepl.Vim
---@field buffer      number        buffer context
---@field window      number        window context
---@field vim_mode    boolean       vim mode
---@field mark_id     number        current mark id counter
---@field redraw      boolean       redraw after evaluation
---@field inspect     boolean       inspect variables
---@field indent      number        indent level
---@field hist        neorepl.Hist    command history
local Repl = {}
Repl.__index = Repl

---Create a new REPL instance
---@param config? neorepl.Config
---@return neorepl.Repl
function Repl.new(config)
  if config.buffer then
    config.buffer = util.parse_buffer(config.buffer, true)
    if not config.buffer then
      error('invalid buffer')
    end
  end
  if config.window then
    config.window = util.parse_window(config.window, true)
    if not config.window then
      error('invalid window')
    end
  end

  vim.cmd('enew')
  local bufnr = api.nvim_get_current_buf()

  require('neorepl.map').define()

  if config.no_defaults ~= true then
    require('neorepl.map').define_defaults()
    -- vim.opt_local.completeopt = 'menu'
  end

  vim.opt_local.buftype = 'nofile'
  vim.opt_local.swapfile = false
  api.nvim_buf_set_name(bufnr, 'neorepl://neorepl('..bufnr..')')
  -- set filetype after mappings and settings to allow overriding in ftplugin
  api.nvim_buf_set_option(bufnr, 'filetype', 'neorepl')
  vim.cmd([[syn match neoreplLinebreak "^\\"]])

  ---@type neorepl.Repl
  local self = setmetatable({
    bufnr = bufnr,
    buffer = config.buffer or 0,
    window = config.window or 0,
    vim_mode = config.lang == 'vim',
    redraw = get_opt(config.redraw, true),
    inspect = get_opt(config.inspect, true),
    indent = get_opt(config.indent, 0),
    hist = require('neorepl.hist').new(config),
    mark_id = 1,
  }, Repl)

  self.lua = require('neorepl.lua').new(self, config)
  self.vim = require('neorepl.vim').new(self, config)

  return self
end

---Append lines to the buffer
---@param lines string[]  lines
---@param hlgroup string  highlight group
function Repl:put(lines, hlgroup)
  -- indent lines
  if self.indent > 0 then
    local prefix = string.rep(' ', self.indent)
    local t = {}
    for i, line in ipairs(lines) do
      t[i] = prefix..line
    end
    lines = t
  end

  local s = api.nvim_buf_line_count(self.bufnr)
  api.nvim_buf_set_lines(self.bufnr, -1, -1, false, lines)
  local e = api.nvim_buf_line_count(self.bufnr)

  -- highlight
  if s ~= e then
    self.mark_id = self.mark_id + 1
    api.nvim_buf_set_extmark(self.bufnr, ns, s, 0, {
      id = self.mark_id,
      end_line = e,
      hl_group = hlgroup,
      hl_eol = true,
    })
  end
end

function Repl:clear()
  self.mark_id = 1
  api.nvim_buf_clear_namespace(self.bufnr, ns, 0, -1)
  api.nvim_buf_set_lines(self.bufnr, 0, -1, false, {})
end

---Append empty line
function Repl:new_line()
  api.nvim_buf_set_lines(self.bufnr, -1, -1, false, {''})
  vim.cmd('$') -- TODO: don't use things like this, buffer can change during evaluation

  -- break undo sequence
  local mode = api.nvim_get_mode().mode
  if mode == 'i' or mode == 'ic' or mode == 'ix' then
    api.nvim_feedkeys(BREAK_UNDO, 'n', true)
  end
end

---Get lines under cursor
---Returns nil on illegal line break
---@return string[]|nil
function Repl:get_line()
  local line = api.nvim_get_current_line()
  local lnum = api.nvim_win_get_cursor(0)[1]
  local s, e = lnum, lnum
  local lines = {line}

  if line:sub(1,1) == '\\' then
    for i = lnum - 1, 1, -1 do
      line = api.nvim_buf_get_lines(self.bufnr, i - 1, i, true)[1]
      table.insert(lines, 1, line)
      if line:sub(1,1) ~= '\\' then
        s = i
        break
      end
    end
    if lines[1]:sub(1,1) == '\\' then
      return nil -- illegal line break
    end
  end

  local max = api.nvim_buf_line_count(self.bufnr)
  while e < max do
    e = e + 1
    line = api.nvim_buf_get_lines(self.bufnr, e - 1, e, true)[1]
    if line:sub(1,1) == '\\' then
      table.insert(lines, line)
    else
      break
    end
  end

  return lines, s, e
end

---Evaluate current line
function Repl:eval_line()
  -- reset history position
  self.hist:reset_pos()

  local lines = self:get_line()
  if lines == nil then
    self:put({'illegal line break'}, 'neoreplError')
    return self:new_line()
  end

  -- ignore if it's only whitespace
  if util.lines_empty(lines) then
    return self:new_line()
  end

  -- save lines to history
  self.hist:append(lines)

  -- repl command
  local line = lines[1]
  if line:sub(1,1) == COMMAND_PREFIX then
    line = line:sub(2)
    local cmd, rest = line:match('^(%a*)%s*(.*)$')
    if not cmd then
      self:put(MSG_INVALID_COMMAND, 'neoreplError')
      return self:new_line()
    end

    -- copy lines, trim command and line breaks
    local args = {rest}
    for i = 2, #lines do
      args[i] = lines[i]:sub(2)
    end

    if util.lines_empty(args) then
      args = nil
    elseif #args == 1 then
      -- trim trailing whitespace
      args[1] = args[1]:match('^(.-)%s*$')
    end

    for _, c in ipairs(require('neorepl.cmd')) do
      if c.pattern == nil then
        local name = c.command
        c.pattern = '\\v\\C^'..name:sub(1,1)..'%['..name:sub(2)..']$'
      end

      if fn.match(cmd, c.pattern) >= 0 then
        -- don't append new line when command returns false
        if c.run(args, self) ~= false then
          self:new_line()
        end
        return
      end
    end

    self:put(MSG_INVALID_COMMAND, 'neoreplError')
    return self:new_line()
  end

  -- strip leading backslashes
  local prg = {}
  prg[1] = lines[1]
  for i = 2, #lines do
    prg[i] = lines[i]:sub(2)
  end

  if self.vim_mode then
    if self.vim:eval(prg) ~= false then
      return self:new_line()
    end
  else
    if self.lua:eval(prg) ~= false then
      return self:new_line()
    end
  end
end

---Execute function in current buffer/window context
function Repl:exec_context(f)
  local buf = self.buffer
  local win = self.window

  -- validate buffer and window
  local buf_valid = buf == 0 or api.nvim_buf_is_valid(buf)
  local win_valid = win == 0 or api.nvim_win_is_valid(win)
  if not buf_valid or not win_valid then
    local lines = {}
    if not buf_valid then
      self.buffer = 0
      table.insert(lines, 'buffer no longer valid, setting it back to 0')
    end
    if not win_valid then
      self.window = 0
      table.insert(lines, 'window no longer valid, setting it back to 0')
    end
    table.insert(lines, 'operation cancelled')
    self:put(lines, 'neoreplError')
    return false
  end

  if win > 0 then
    if buf > 0 then
      -- can buffer change here? maybe it's going to be easier to pcall all of this
      api.nvim_win_call(win, function()
        api.nvim_buf_call(buf, f)
      end)
    else
      api.nvim_win_call(win, f)
    end
  elseif buf > 0 then
    api.nvim_buf_call(buf, f)
  else
    f()
  end
  return true
end

---Move between entries in history
---@param prev boolean previous entry if true, next entry if false
function Repl:hist_move(prev)
  if self.hist:len() == 0 then return end
  local lines, s, e = self:get_line()
  if lines == nil then return end
  local nlines = self.hist:move(prev, lines)
  api.nvim_buf_set_lines(self.bufnr, s - 1, e, true, nlines)
  api.nvim_win_set_cursor(0, { s + #nlines - 1, #nlines[#nlines] })
end

function Repl:get_completion()
  assert(api.nvim_get_current_buf() == self.bufnr, 'Not in neorepl buffer')
  assert(api.nvim_win_get_buf(0) == self.bufnr, 'Not in neorepl window')

  local line = api.nvim_get_current_line()
  local pos = api.nvim_win_get_cursor(0)[2]
  line = line:sub(1, pos)
  local results, start

  if line:sub(1,1) == COMMAND_PREFIX then
    line = line:sub(2)
    -- TODO: complete command arguments too
    if line:match('^%S*$') then
      results = {}
      local size = #line
      for _, c in ipairs(require('neorepl.cmd')) do
        if line == c.command:sub(1, size) then
          table.insert(results, c.command)
        end
      end
      if #results > 0 then
        return 2, results
      end
      return
    end

    -- TODO: complete multiple lines
    local begin = fn.match(line, [[\v\C^v%[im]\s+\zs]])
    if begin >= 0 then
      results, start = self.vim:complete(line:sub(begin + 1))
    else
      begin = fn.match(line, [[\v\C^l%[ua]\s+\zs]])
      if begin < 0 then return end
      results, start = self.lua:complete(line:sub(begin + 1))
    end
    if start then
      start = start + begin + 1
    end

    if results and #results > 0 then
      return start or pos + 1, results
    end
    return
  end

  if self.vim_mode then
    start, results = self.vim:complete(line)
  else
    -- TODO: complete multiple lines
    start, results = self.lua:complete(line)
  end

  if results and #results > 0 then
    return start or pos + 1, results
  end
end

---Complete word under cursor
function Repl:complete()
  local offset, candidates = self:get_completion()
  if offset and #candidates > 0 then
    fn.complete(offset, candidates)
  end
end

---Go to previous/next output implementation
---@param backward boolean
---@param to_end? boolean
function Repl:goto_output(backward, to_end, count)
  count = count or 1
  local ranges = {}
  do
    local lnum = 1
    -- TODO: do I have to sort them?
    for _, m in ipairs(api.nvim_buf_get_extmarks(self.bufnr, ns, 0, -1, { details = true })) do
      local s = m[2] + 1
      local e = m[4].end_row
      if e >= s then
        -- insert ranges between extmarks
        if s > lnum then
          table.insert(ranges, { lnum, s - 1 })
        end
        table.insert(ranges, { s, e })
        lnum = e + 1
      end
    end
    -- insert last range
    local last = api.nvim_buf_line_count(self.bufnr)
    if last >= lnum then
      table.insert(ranges, { lnum, last })
    end
  end

  local lnum = api.nvim_win_get_cursor(0)[1]
  for i, range in ipairs(ranges) do
    if lnum >= range[1] and lnum <= range[2] then
      if backward and not to_end and lnum > range[1] then
        if count == 1 then
          api.nvim_win_set_cursor(0, { range[1], 0 })
          return
        else
          count = count - 1
        end
      elseif not backward and to_end and lnum < range[2] then
        if count == 1 then
          api.nvim_win_set_cursor(0, { range[2], 0 })
          return
        else
          count = count - 1
        end
      end

      if backward then
        count = -count
      end

      local idx = i + count
      if idx > #ranges then
        idx = #ranges
      elseif idx < 1 then
        idx = 1
      end
      range = ranges[idx]
      if range then
        api.nvim_win_set_cursor(0, { (to_end and range[2] or range[1]), 0 })
      end
      return
    end
  end
end

api.nvim_set_hl(0, 'neoreplError',     { default = true, link = 'ErrorMsg' })
api.nvim_set_hl(0, 'neoreplOutput',    { default = true, link = 'String' })
api.nvim_set_hl(0, 'neoreplValue',     { default = true, link = 'Number' })
api.nvim_set_hl(0, 'neoreplInfo',      { default = true, link = 'Function' })
api.nvim_set_hl(0, 'neoreplLinebreak', { default = true, link = 'Function' })

return Repl
