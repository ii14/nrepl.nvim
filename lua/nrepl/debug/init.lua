local debugger = nil
local prev_print = _G.print

local function nested(i)
  i = (i or 0) + 1
  print('nested: '..i)
  return i
end

local function example()
  print('example A')

  for i = 1, 3 do
    print('loop: '..i)
  end

  print('example B')

  local x = nested()
  x = nested(x)

  print('example C')
  print('example D')
  print('example E')
  print('example F')

  return x
end

---@class nreplDebug
---@field repl nreplRepl    parent
---@field func function     debugged function
---@field thread thread     debugged thread
---@field lastcmd string    last command
---@field print fun(...)    print function
local Debug = {}
Debug.__index = Debug

--- Create a new debugger
---@param repl nreplRepl
---@param _ nreplConfig
---@return nreplDebug
function Debug.new(repl, _)
  local this = setmetatable({
    repl = repl,
    lastcmd = '',
  }, Debug)

  -- print override
  this.print = function(...)
    local args = {...}
    for i, v in ipairs(args) do
      args[i] = tostring(v)
    end
    local lines = vim.split(table.concat(args, '\t'), '\n', { plain = true })
    repl:put(lines, 'nreplOutput')
  end

  debugger = require('nrepl.debug.debugger')
  this.func = example
  this.thread = coroutine.create(example)

  return this
end

function Debug:eval(prg)
  assert(type(prg) == 'string')
  local res, err

  if prg == nil or prg == '' then
    prg = self.lastcmd
  else
    self.lastcmd = prg
  end

  _G.print = self.print
  if prg == 'n' then -- next
    res, err = debugger.next(self.thread)
  elseif prg == 's' then -- step
    res, err = debugger.step(self.thread)
  elseif prg == 'f' then -- finish
    res, err = debugger.finish(self.thread)
  elseif prg == 'c' then -- continue
    res, err = coroutine.resume(self.thread)
  elseif prg == 'b' then -- backtrace
    local out = {}
    do local level = 0; while true do
      local i = debug.getinfo(self.thread, level)
      if not i then break end
      table.insert(out, string.format('#%d %s:%d', level, i.short_src, i.currentline))
      level = level + 1
    end end

    if #out > 0 then
      self.repl:put(out, 'nreplInfo')
    else
      self.repl:put({'empty'}, 'nreplInfo')
    end
  elseif prg == 'l' then -- locals
    local out = {}
    do local i = 0; while true do
      i = i + 1
      -- TODO: invalid level throws exception
      local key, value = debug.getlocal(self.thread, 0, i)
      if not key then break end
      value = tostring(value):gsub('\n', '\\n')
      table.insert(out, string.format('#%d %s = %s', i, key, value))
    end end

    if #out > 0 then
      self.repl:put(out, 'nreplInfo')
    else
      self.repl:put({'empty'}, 'nreplInfo')
    end
  elseif prg == 'u' then -- upvalues
    local out = {}
    do local i = 0; while true do
      i = i + 1
      local key, value = debug.getupvalue(self.func, i)
      if not key then break end
      value = tostring(value):gsub('\n', '\\n')
      table.insert(out, string.format('#%d %s = %s', i, key, value))
    end end

    if #out > 0 then
      self.repl:put(out, 'nreplInfo')
    else
      self.repl:put({'empty'}, 'nreplInfo')
    end
  else
    self.repl:put({'invalid debugger command'}, 'nreplError')
  end
  _G.print = prev_print

  if res == true then
    self.repl:put({'Thread returned successfully'}, 'nreplInfo')
  elseif res == false then
    self.repl:put({'Exception: '..err}, 'nreplError')
  elseif res then
    self.repl:put({'Line '..res}, 'nreplInfo')
  end
end

return Debug
