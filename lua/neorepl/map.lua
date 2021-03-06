local api, fn = vim.api, vim.fn
local buf = require('neorepl.buf')

---Replace keycodes
---@type fun(s: string): string
local T do
  local cache = {}
  function T(s)
    if not cache[s] then
      cache[s] = api.nvim_replace_termcodes(s, true, false, true)
    end
    return cache[s]
  end
end

---@param modes string|string[]
---@param lhss string|string[]
---@param rhs string|function
---@param expr boolean
local function map(modes, lhss, rhs, expr)
  if type(modes) ~= 'table' then
    modes = { modes }
  end
  if type(lhss) ~= 'table' then
    lhss = { lhss }
  end
  local opts = { noremap = true, expr = expr }
  if type(rhs) == 'function' then
    opts.callback = rhs
    rhs = ''
  end
  for _, mode in ipairs(modes) do
    for _, lhs in ipairs(lhss) do
      api.nvim_buf_set_keymap(0, mode, lhs, rhs, opts)
    end
  end
end

---@type fun(): neorepl.Repl
local get = buf.get


local M = {}

---Evaluate current line
function M.eval_line()
  get():eval_line()
end

---Get previous line from the history
function M.hist_prev()
  get():hist_move(true)
end

---Get next line from the history
function M.hist_next()
  get():hist_move(false)
end

---Complete current line
function M.complete()
  get():complete()
end

---Go to the start of the next output
function M.goto_next()
  get():goto_output(false, false, vim.v.count1)
end

---Go to the end of the next output
function M.goto_next_end()
  get():goto_output(false, true, vim.v.count1)
end

---Go to the start of the previous output
function M.goto_prev()
  get():goto_output(true, false, vim.v.count1)
end

---Go to the end of the previous output
function M.goto_prev_end()
  get():goto_output(true, true, vim.v.count1)
end

do
  local backspace

  ---Restore 'backspace'
  function M._restore()
    if backspace then
      api.nvim_set_option('backspace', backspace)
      backspace = nil
    end
  end

  function M.backspace()
    local line = api.nvim_get_current_line()
    local col = fn.col('.')
    local res
    backspace = api.nvim_get_option('backspace')
    if col == 2 and line:sub(1, 1) == '\\' then
      api.nvim_set_option('backspace', 'indent,start,eol')
      res = '<BS><BS>'
    elseif col == 1 and line:sub(1, 1) == '\\' then
      api.nvim_set_option('backspace', 'indent,start,eol')
      res = '<Del><BS>'
    else
      api.nvim_set_option('backspace', 'indent,start')
      res = '<BS>'
    end
    return T(res .. [[<cmd>lua require"neorepl.map"._restore()<CR>]])
  end

  function M.delete_word()
    local line = api.nvim_get_current_line()
    local col = fn.col('.')
    local res
    backspace = api.nvim_get_option('backspace')
    if col == 2 and line:sub(1, 1) == '\\' then
      api.nvim_set_option('backspace', 'indent,start,eol')
      res = '<BS><BS>'
    elseif col == 1 and line:sub(1, 1) == '\\' then
      api.nvim_set_option('backspace', 'indent,start,eol')
      res = '<Del><BS>'
    else
      api.nvim_set_option('backspace', 'indent,start')
      res = '<C-W>'
    end
    return T(res .. [[<cmd>lua require'neorepl.map'._restore()<CR>]])
  end

  -- TODO: delete_line
end


---Define mappings for the current buffer
function M.define()
  map({'','i'}, '<Plug>(neorepl-eval-line)', M.eval_line)
  map('i', '<Plug>(neorepl-break-line)', [[<CR><C-U>\]])
  map('i', '<Plug>(neorepl-backspace)', M.backspace, true)
  map('i', '<Plug>(neorepl-delete-word)', M.delete_word, true)
  -- TODO: neorepl-delete-line
  map({'','i'}, '<Plug>(neorepl-hist-prev)', M.hist_prev)
  map({'','i'}, '<Plug>(neorepl-hist-next)', M.hist_next)
  map('i', '<Plug>(neorepl-complete)', M.complete)
  map({'','i'}, '<Plug>(neorepl-[[)', M.goto_prev)
  map({'','i'}, '<Plug>(neorepl-[])', M.goto_prev_end)
  map({'','i'}, '<Plug>(neorepl-]])', M.goto_next)
  map({'','i'}, '<Plug>(neorepl-][)', M.goto_next_end)
end

---Define defaults mappings for the current buffer
function M.define_defaults()
  map('i', {'<CR>','<C-M>'}, '<Plug>(neorepl-eval-line)')
  map('i', {'<NL>','<C-J>'}, '<Plug>(neorepl-break-line)')
  map('i', {'<BS>','<C-H>'}, '<Plug>(neorepl-backspace)')
  map('i', '<C-W>', '<Plug>(neorepl-delete-word)')
  map('i', '<Tab>', [[pumvisible() ? '<C-N>' : '<Plug>(neorepl-complete)']], true)
  map('i', '<C-P>', [[pumvisible() ? '<C-P>' : '<Plug>(neorepl-hist-prev)']], true)
  map('i', '<C-N>', [[pumvisible() ? '<C-N>' : '<Plug>(neorepl-hist-next)']], true)
  map('i', '<C-E>', [[pumvisible() ? '<C-E>' : '<End>']], true)
  map('i', '<C-Y>', '<C-Y>')
  map('i', '<C-A>', '<Home>')
  map('', '[[', '<Plug>(neorepl-[[)')
  map('', '[]', '<Plug>(neorepl-[])')
  map('', ']]', '<Plug>(neorepl-]])')
  map('', '][', '<Plug>(neorepl-][)')
end

return M
