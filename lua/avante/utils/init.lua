local api = vim.api
local fn = vim.fn
local lsp = vim.lsp

local LRUCache = require("avante.utils.lru_cache")

---@class avante.utils: LazyUtilCore
---@field tokens avante.utils.tokens
---@field root avante.utils.root
---@field file avante.utils.file
---@field path avante.utils.path
---@field environment avante.utils.environment
---@field lsp avante.utils.lsp
---@field logger avante.utils.promptLogger
local M = {}

setmetatable(M, {
  __index = function(t, k)
    local ok, lazyutil = pcall(require, "lazy.core.util")
    if ok and lazyutil[k] then return lazyutil[k] end

    ---@diagnostic disable-next-line: no-unknown
    t[k] = require("avante.utils." .. k)
    return t[k]
  end,
})

---Check if a plugin is installed
---@param plugin string
---@return boolean
function M.has(plugin)
  local ok, LazyConfig = pcall(require, "lazy.core.config")
  if ok then return LazyConfig.plugins[plugin] ~= nil end

  local res, _ = pcall(require, plugin)
  return res
end

function M.is_win() return M.path.is_win() end

M.path_sep = M.path.SEP

---@return "linux" | "darwin" | "windows"
function M.get_os_name()
  local os_name = vim.uv.os_uname().sysname
  if os_name == "Linux" then
    return "linux"
  elseif os_name == "Darwin" then
    return "darwin"
  elseif os_name == "Windows_NT" then
    return "windows"
  else
    error("Unsupported operating system: " .. os_name)
  end
end

function M.get_system_info()
  local os_name = vim.loop.os_uname().sysname
  local os_version = vim.loop.os_uname().release
  local os_machine = vim.loop.os_uname().machine
  local lang = os.getenv("LANG")
  local shell = os.getenv("SHELL")

  local res = string.format(
    "- Platform: %s-%s-%s\n- Shell: %s\n- Language: %s\n- Current date: %s",
    os_name,
    os_version,
    os_machine,
    shell,
    lang,
    os.date("%Y-%m-%d")
  )

  local project_root = M.root.get()
  if project_root then res = res .. string.format("\n- Project root: %s", project_root) end

  local is_git_repo = vim.fn.isdirectory(".git") == 1
  if is_git_repo then res = res .. "\n- The user is operating inside a git repository" end

  return res
end

---@param input_cmd string
---@param shell_cmd string?
local function get_cmd_for_shell(input_cmd, shell_cmd)
  local shell = vim.o.shell:lower()
  local cmd ---@type string

  -- powershell then we can just run the cmd
  if shell:match("powershell") or shell:match("pwsh") then
    cmd = input_cmd
  elseif fn.has("win32") > 0 then
    cmd = 'powershell.exe -NoProfile -Command "' .. input_cmd:gsub('"', "'") .. '"'
  else
    -- linux and macos we will just do sh -c
    shell_cmd = shell_cmd or "sh -c"
    cmd = shell_cmd .. " " .. fn.shellescape(input_cmd)
  end

  return cmd
end

--- This function will run given shell command synchronously.
---@param input_cmd string
---@param shell_cmd string?
---@return vim.SystemCompleted
function M.shell_run(input_cmd, shell_cmd)
  local cmd = get_cmd_for_shell(input_cmd, shell_cmd)

  local output = fn.system(cmd)
  local code = vim.v.shell_error

  return { stdout = output, code = code }
end

---@param input_cmd string
---@param shell_cmd string?
---@param on_complete fun(output: string, code: integer)
---@param cwd? string
---@param timeout? integer Timeout in milliseconds
function M.shell_run_async(input_cmd, shell_cmd, on_complete, cwd, timeout)
  local cmd = get_cmd_for_shell(input_cmd, shell_cmd)
  ---@type string[]
  local output = {}
  local timer = nil
  local completed = false

  -- Create a wrapper for on_complete to ensure it's only called once
  local function complete_once(out, code)
    if completed then return end
    completed = true

    -- Clean up timer if it exists
    if timer then
      timer:stop()
      timer:close()
      timer = nil
    end

    on_complete(out, code)
  end

  -- Start the job
  local job_id = fn.jobstart(cmd, {
    on_stdout = function(_, data)
      if not data then return end
      vim.list_extend(output, data)
    end,
    on_stderr = function(_, data)
      if not data then return end
      vim.list_extend(output, data)
    end,
    on_exit = function(_, exit_code) complete_once(table.concat(output, "\n"), exit_code) end,
    cwd = cwd,
  })

  -- Set up timeout if specified
  if timeout and timeout > 0 then
    timer = vim.loop.new_timer()
    if timer then
      timer:start(timeout, 0, function()
        vim.schedule(function()
          if not completed and job_id then
            -- Kill the job
            fn.jobstop(job_id)
            -- Complete with timeout error
            complete_once("Command timed out after " .. timeout .. "ms", 124)
          end
        end)
      end)
    end
  end
end

---@see https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/util/toggle.lua
---
---@alias _ToggleSet fun(state: boolean): nil
---@alias _ToggleGet fun(): boolean
---
---@class ToggleBind
---@field name string
---@field set _ToggleSet
---@field get _ToggleGet
---
---@class ToggleBind.wrap: ToggleBind
---@operator call:boolean

---@param toggle ToggleBind
function M.toggle_wrap(toggle)
  return setmetatable(toggle, {
    __call = function()
      toggle.set(not toggle.get())
      local state = toggle.get()
      if state then
        M.info("enabled: " .. toggle.name)
      else
        M.warn("disabled: " .. toggle.name)
      end
      return state
    end,
  }) --[[@as ToggleBind.wrap]]
end

-- Wrapper around vim.keymap.set that will
-- not create a keymap if a lazy key handler exists.
-- It will also set `silent` to true by default.
--
---@param mode string|string[] Mode short-name, see |nvim_set_keymap()|.
---                            Can also be list of modes to create mapping on multiple modes.
---@param lhs string           Left-hand side |{lhs}| of the mapping.
---@param rhs string|function  Right-hand side |{rhs}| of the mapping, can be a Lua function.
---
---@param opts? vim.keymap.set.Opts
function M.safe_keymap_set(mode, lhs, rhs, opts)
  ---@type boolean
  local ok
  ---@module "lazy.core.handler"
  local H

  ok, H = pcall(require, "lazy.core.handler")
  if not ok then
    M.debug("lazy.nvim is not available. Avante will use vim.keymap.set")
    vim.keymap.set(mode, lhs, rhs, opts)
    return
  end

  local Keys = H.handlers.keys
  ---@cast Keys LazyKeysHandler
  local modes = type(mode) == "string" and { mode } or mode
  ---@cast modes -string

  ---@param m string
  ---@diagnostic disable-next-line: undefined-field
  modes = vim.tbl_filter(function(m) return not (Keys and Keys.have and Keys:have(lhs, m)) end, modes)

  -- don't create keymap if a lazy keys handler exists
  if #modes > 0 then
    opts = opts or {}
    opts.silent = opts.silent ~= false
    if opts.remap and not vim.g.vscode then
      ---@diagnostic disable-next-line: no-unknown
      opts.remap = nil
    end
    vim.keymap.set(mode, lhs, rhs, opts)
  end
end

---@param str string
---@param opts? {suffix?: string, prefix?: string}
function M.trim(str, opts)
  local res = str
  if not opts then return res end
  if opts.suffix then
    res = res:sub(#res - #opts.suffix + 1) == opts.suffix and res:sub(1, #res - #opts.suffix) or res
  end
  if opts.prefix then res = res:sub(1, #opts.prefix) == opts.prefix and res:sub(#opts.prefix + 1) or res end
  return res
end

function M.in_visual_mode()
  local current_mode = fn.mode()
  return current_mode == "v" or current_mode == "V" or current_mode == ""
end

---Get the selected content and range in Visual mode
---@return avante.SelectionResult | nil Selected content and range
function M.get_visual_selection_and_range()
  if not M.in_visual_mode() then return nil end

  local Range = require("avante.range")
  local SelectionResult = require("avante.selection_result")

  -- Get the start and end positions of Visual mode
  local start_pos = fn.getpos("v")
  local end_pos = fn.getpos(".")

  -- Get the start and end line and column numbers
  local start_line = start_pos[2]
  local start_col = start_pos[3]
  local end_line = end_pos[2]
  local end_col = end_pos[3]
  -- If the start point is after the end point, swap them
  if start_line > end_line or (start_line == end_line and start_col > end_col) then
    start_line, end_line = end_line, start_line
    start_col, end_col = end_col, start_col
  end
  local content = "" -- luacheck: ignore
  local range = Range:new({ lnum = start_line, col = start_col }, { lnum = end_line, col = end_col })
  -- Check if it's a single-line selection
  if start_line == end_line then
    -- Get partial content of a single line
    local line = fn.getline(start_line)
    -- content = string.sub(line, start_col, end_col)
    content = line
  else
    -- Multi-line selection: Get all lines in the selection
    local lines = fn.getline(start_line, end_line)
    -- Extract partial content of the first line
    -- lines[1] = string.sub(lines[1], start_col)
    -- Extract partial content of the last line
    -- lines[#lines] = string.sub(lines[#lines], 1, end_col)
    -- Concatenate all lines in the selection into a string
    if type(lines) == "table" then
      content = table.concat(lines, "\n")
    else
      content = lines
    end
  end
  if not content then return nil end
  local filepath = fn.expand("%:p")
  local filetype = M.get_filetype(filepath)
  -- Return the selected content and range
  return SelectionResult:new(filepath, filetype, content, range)
end

---Wrapper around `api.nvim_buf_get_lines` which defaults to the current buffer
---@param start integer
---@param end_ integer
---@param buf integer?
---@return string[]
function M.get_buf_lines(start, end_, buf) return api.nvim_buf_get_lines(buf or 0, start, end_, false) end

---Get cursor row and column as (1, 0) based
---@param win_id integer?
---@return integer, integer
---@diagnostic disable-next-line: redundant-return-value
function M.get_cursor_pos(win_id) return unpack(api.nvim_win_get_cursor(win_id or 0)) end

---Check if the buffer is likely to have actionable conflict markers
---@param bufnr integer?
---@return boolean
function M.is_valid_buf(bufnr)
  bufnr = bufnr or 0
  return #vim.bo[bufnr].buftype == 0 and vim.bo[bufnr].modifiable
end

--- Check if a NUI container is valid:
--- 1. Container must exist
--- 2. Container must have a valid buffer number
--- 3. Container must have a valid window ID (optional, based on check_winid parameter)
--- Always returns a boolean value
---@param container NuiSplit | nil
---@param check_winid boolean? Whether to check window validity, defaults to false
---@return boolean
function M.is_valid_container(container, check_winid)
  -- Default check_winid to false if not specified
  if check_winid == nil then check_winid = false end

  -- First check if container exists
  if container == nil then return false end

  -- Check buffer validity
  if container.bufnr == nil or not api.nvim_buf_is_valid(container.bufnr) then return false end

  -- Check window validity if requested
  if check_winid then
    if container.winid == nil or not api.nvim_win_is_valid(container.winid) then return false end
  end

  return true
end

---@param name string?
---@return table
function M.get_hl(name)
  if not name then return {} end
  return api.nvim_get_hl(0, { name = name, link = false })
end

--- vendor from lazy.nvim for early access and override

---@param path string
---@return string
function M.norm(path) return M.path.normalize(path) end

---@param msg string|string[]
---@param opts? LazyNotifyOpts
function M.notify(msg, opts)
  if vim.in_fast_event() then
    return vim.schedule(function() M.notify(msg, opts) end)
  end

  opts = opts or {}
  if type(msg) == "table" then
    ---@diagnostic disable-next-line: no-unknown
    msg = table.concat(vim.tbl_filter(function(line) return line or false end, msg), "\n")
  end
  ---@diagnostic disable-next-line: undefined-field
  if opts.stacktrace then
    ---@diagnostic disable-next-line: undefined-field
    msg = msg .. M.pretty_trace({ level = opts.stacklevel or 2 })
  end
  local lang = opts.lang or "markdown"
  ---@diagnostic disable-next-line: undefined-field
  local n = opts.once and vim.notify_once or vim.notify
  n(msg, opts.level or vim.log.levels.INFO, {
    on_open = function(win)
      local ok = pcall(function() vim.treesitter.language.add("markdown") end)
      vim.wo[win].conceallevel = 3
      vim.wo[win].concealcursor = ""
      vim.wo[win].spell = false
      local buf = api.nvim_win_get_buf(win)
      if not pcall(vim.treesitter.start, buf, lang) then
        vim.bo[buf].filetype = lang
        vim.bo[buf].syntax = lang
      end
    end,
    title = opts.title or "Avante",
  })
end

---@param msg string|string[]
---@param opts? LazyNotifyOpts
function M.error(msg, opts)
  opts = opts or {}
  opts.level = vim.log.levels.ERROR
  M.notify(msg, opts)
end

---@param msg string|string[]
---@param opts? LazyNotifyOpts
function M.info(msg, opts)
  opts = opts or {}
  opts.level = vim.log.levels.INFO
  M.notify(msg, opts)
end

---@param msg string|string[]
---@param opts? LazyNotifyOpts
function M.warn(msg, opts)
  opts = opts or {}
  opts.level = vim.log.levels.WARN
  M.notify(msg, opts)
end

function M.debug(...)
  if not require("avante.config").debug then return end

  local args = { ... }
  if #args == 0 then return end

  -- Get caller information
  local info = debug.getinfo(2, "Sl")
  local caller_source = info.source:match("@(.+)$") or "unknown"
  local caller_module = caller_source:gsub("^.*/lua/", ""):gsub("%.lua$", ""):gsub("/", ".")

  local timestamp = M.get_timestamp()
  local formated_args = {
    "[" .. timestamp .. "] [AVANTE] [DEBUG] [" .. caller_module .. ":" .. info.currentline .. "]",
  }

  for _, arg in ipairs(args) do
    if type(arg) == "string" then
      table.insert(formated_args, arg)
    else
      table.insert(formated_args, vim.inspect(arg))
    end
  end
  print(unpack(formated_args))
end

function M.tbl_indexof(tbl, value)
  for i, v in ipairs(tbl) do
    if v == value then return i end
  end
  return nil
end

function M.update_win_options(winid, opt_name, key, value)
  local cur_opt_value = api.nvim_get_option_value(opt_name, { win = winid })

  if cur_opt_value:find(key .. ":") then
    cur_opt_value = cur_opt_value:gsub(key .. ":[^,]*", key .. ":" .. value)
  else
    if #cur_opt_value > 0 then cur_opt_value = cur_opt_value .. "," end
    cur_opt_value = cur_opt_value .. key .. ":" .. value
  end

  api.nvim_set_option_value(opt_name, cur_opt_value, { win = winid })
end

function M.get_win_options(winid, opt_name, key)
  local cur_opt_value = api.nvim_get_option_value(opt_name, { win = winid })
  if not cur_opt_value then return end
  local pieces = vim.split(cur_opt_value, ",")
  for _, piece in ipairs(pieces) do
    local kv_pair = vim.split(piece, ":")
    if kv_pair[1] == key then return kv_pair[2] end
  end
end

function M.get_winid(bufnr)
  for _, winid in ipairs(api.nvim_list_wins()) do
    if api.nvim_win_get_buf(winid) == bufnr then return winid end
  end
end

function M.unlock_buf(bufnr)
  vim.bo[bufnr].readonly = false
  vim.bo[bufnr].modified = false
  vim.bo[bufnr].modifiable = true
end

function M.lock_buf(bufnr)
  if bufnr == api.nvim_get_current_buf() then vim.cmd("noautocmd stopinsert") end
  vim.bo[bufnr].readonly = true
  vim.bo[bufnr].modified = false
  vim.bo[bufnr].modifiable = false
end

---@param winnr? number
---@return nil
function M.scroll_to_end(winnr)
  winnr = winnr or 0
  local bufnr = api.nvim_win_get_buf(winnr)
  local lnum = api.nvim_buf_line_count(bufnr)
  local last_line = api.nvim_buf_get_lines(bufnr, -2, -1, true)[1]
  api.nvim_win_set_cursor(winnr, { lnum, api.nvim_strwidth(last_line) })
end

---@param bufnr nil|integer
---@return nil
function M.buf_scroll_to_end(bufnr)
  for _, winnr in ipairs(M.buf_list_wins(bufnr or 0)) do
    M.scroll_to_end(winnr)
  end
end

---@param bufnr nil|integer
---@return integer[]
function M.buf_list_wins(bufnr)
  local wins = {}

  if not bufnr or bufnr == 0 then bufnr = api.nvim_get_current_buf() end

  for _, winnr in ipairs(api.nvim_list_wins()) do
    if api.nvim_win_is_valid(winnr) and api.nvim_win_get_buf(winnr) == bufnr then table.insert(wins, winnr) end
  end

  return wins
end

local sidebar_buffer_var_name = "is_avante_sidebar_buffer"

function M.mark_as_sidebar_buffer(bufnr) api.nvim_buf_set_var(bufnr, sidebar_buffer_var_name, true) end

function M.is_sidebar_buffer(bufnr)
  local ok, v = pcall(api.nvim_buf_get_var, bufnr, sidebar_buffer_var_name)
  if not ok then return false end
  return v == true
end

function M.trim_spaces(s) return s:match("^%s*(.-)%s*$") end

function M.fallback(v, default_value) return type(v) == "nil" and default_value or v end

---Join URL parts together, handling slashes correctly
---@param ... string URL parts to join
---@return string Joined URL
function M.url_join(...)
  local parts = { ... }
  local result = parts[1] or ""

  for i = 2, #parts do
    local part = parts[i]
    if not part or part == "" then goto continue end

    -- Remove trailing slash from result if present
    if result:sub(-1) == "/" then result = result:sub(1, -2) end

    -- Remove leading slash from part if present
    if part:sub(1, 1) == "/" then part = part:sub(2) end

    -- Join with slash
    result = result .. "/" .. part

    ::continue::
  end

  if result:sub(-1) == "/" then result = result:sub(1, -2) end

  return result
end

-- luacheck: push no max comment line length
---@param type_name "'nil'" | "'number'" | "'string'" | "'boolean'" | "'table'" | "'function'" | "'thread'" | "'userdata'" | "'list'" | '"map"'
---@return boolean
function M.is_type(type_name, v)
  ---@diagnostic disable-next-line: deprecated
  local islist = vim.islist or vim.tbl_islist
  if type_name == "list" then return islist(v) end

  if type_name == "map" then return type(v) == "table" and not islist(v) end

  return type(v) == type_name
end
-- luacheck: pop

---@param text string
---@return string
function M.get_indentation(text)
  if not text then return "" end
  return text:match("^%s*") or ""
end

function M.trim_space(text)
  if not text then return text end
  return text:gsub("%s*", "")
end

function M.trim_escapes(text)
  if not text then return text end
  local res = text
    :gsub("//n", "/n")
    :gsub("//r", "/r")
    :gsub("//t", "/t")
    :gsub('/"', '"')
    :gsub('\\"', '"')
    :gsub("\\n", "\n")
    :gsub("\\r", "\r")
    :gsub("\\t", "\t")
  return res
end

---@param original_lines string[]
---@param target_lines string[]
---@param compare_fn fun(line_a: string, line_b: string): boolean
---@return integer | nil start_line
---@return integer | nil end_line
function M.try_find_match(original_lines, target_lines, compare_fn)
  local start_line, end_line
  for i = 1, #original_lines - #target_lines + 1 do
    local match = true
    for j = 1, #target_lines do
      if not compare_fn(original_lines[i + j - 1], target_lines[j]) then
        match = false
        break
      end
    end
    if match then
      start_line = i
      end_line = i + #target_lines - 1
      break
    end
  end
  return start_line, end_line
end

---@param original_lines string[]
---@param target_lines string[]
---@return integer | nil start_line
---@return integer | nil end_line
function M.fuzzy_match(original_lines, target_lines)
  local start_line, end_line
  ---exact match
  start_line, end_line = M.try_find_match(
    original_lines,
    target_lines,
    function(line_a, line_b) return line_a == line_b end
  )
  if start_line ~= nil and end_line ~= nil then return start_line, end_line end
  ---fuzzy match
  start_line, end_line = M.try_find_match(
    original_lines,
    target_lines,
    function(line_a, line_b) return M.trim(line_a, { suffix = " \t" }) == M.trim(line_b, { suffix = " \t" }) end
  )
  if start_line ~= nil and end_line ~= nil then return start_line, end_line end
  ---trim_space match
  start_line, end_line = M.try_find_match(
    original_lines,
    target_lines,
    function(line_a, line_b) return M.trim_space(line_a) == M.trim_space(line_b) end
  )
  if start_line ~= nil and end_line ~= nil then return start_line, end_line end
  ---trim slashes match
  start_line, end_line = M.try_find_match(
    original_lines,
    target_lines,
    function(line_a, line_b) return line_a == M.trim_escapes(line_b) end
  )
  if start_line ~= nil and end_line ~= nil then return start_line, end_line end
  ---trim slashes and trim_space match
  start_line, end_line = M.try_find_match(
    original_lines,
    target_lines,
    function(line_a, line_b) return M.trim_space(line_a) == M.trim_space(M.trim_escapes(line_b)) end
  )
  return start_line, end_line
end

function M.relative_path(absolute)
  local project_root = M.get_project_root()
  return M.make_relative_path(absolute, project_root)
end

function M.get_doc()
  local absolute = api.nvim_buf_get_name(0)
  local params = lsp.util.make_position_params(0, "utf-8")

  local position = {
    row = params.position.line + 1,
    col = params.position.character,
  }

  local doc = {
    uri = params.textDocument.uri,
    version = api.nvim_buf_get_var(0, "changedtick"),
    relativePath = M.relative_path(absolute),
    insertSpaces = vim.o.expandtab,
    tabSize = fn.shiftwidth(),
    indentSize = fn.shiftwidth(),
    position = position,
  }

  return doc
end

function M.prepend_line_number(content, start_line)
  start_line = start_line or 1
  local lines = vim.split(content, "\n")
  local result = {}
  for i, line in ipairs(lines) do
    i = i + start_line - 1
    table.insert(result, "L" .. i .. ": " .. line)
  end
  return table.concat(result, "\n")
end

---Iterates through a list of strings and removes prefixes in form of "L<number>: " from them
---@param content string[]
---@return string[]
function M.trim_line_numbers(content)
  return vim.iter(content):map(function(line) return line:gsub("^L%d+: ", "") end):totable()
end

function M.debounce(func, delay)
  local timer = nil

  return function(...)
    local args = { ... }

    if timer then
      timer:stop()
      timer:close()
    end

    timer = vim.loop.new_timer()
    if not timer then return end

    timer:start(delay, 0, function()
      vim.schedule(function() func(unpack(args)) end)
      timer:close()
      timer = nil
    end)

    return timer
  end
end

function M.throttle(func, delay)
  local timer = nil
  local args

  return function(...)
    args = { ... }

    if timer then return end

    timer = vim.loop.new_timer()
    if not timer then return end
    timer:start(delay, 0, function()
      vim.schedule(function() func(unpack(args)) end)
      timer:close()
      timer = nil
    end)
  end
end

function M.winline(winid)
  -- If the winid is not provided, then line number should be 1, so that it can land on the first line
  if not vim.api.nvim_win_is_valid(winid) then return 1 end

  local line = 1
  vim.api.nvim_win_call(winid, function() line = fn.winline() end)

  return line
end

function M.get_project_root() return M.root.get() end

function M.is_same_file_ext(target_ext, filepath)
  local ext = fn.fnamemodify(filepath, ":e")
  if (target_ext == "tsx" and ext == "ts") or (target_ext == "ts" and ext == "tsx") then return true end
  if (target_ext == "jsx" and ext == "js") or (target_ext == "js" and ext == "jsx") then return true end
  return ext == target_ext
end

-- Get recent filepaths in the same project and same file ext
---@param limit? integer
---@param filenames? string[]
---@param same_file_ext? boolean
---@return string[]
function M.get_recent_filepaths(limit, filenames, same_file_ext)
  local project_root = M.get_project_root()
  local current_ext = fn.expand("%:e")
  local oldfiles = vim.v.oldfiles
  local recent_files = {}

  for _, file in ipairs(oldfiles) do
    if vim.startswith(file, project_root) then
      local has_ext = file:match("%.%w+$")
      if not has_ext then goto continue end
      if same_file_ext then
        if not M.is_same_file_ext(current_ext, file) then goto continue end
      end
      if filenames and #filenames > 0 then
        for _, filename in ipairs(filenames) do
          if file:find(filename) then table.insert(recent_files, file) end
        end
      else
        table.insert(recent_files, file)
      end
      if #recent_files >= (limit or 10) then break end
    end
    ::continue::
  end

  return recent_files
end

local function pattern_to_lua(pattern)
  local lua_pattern = pattern:gsub("[%(%)%.%%%+%-%*%?%[%]%^%$]", "%%%1")
  lua_pattern = lua_pattern:gsub("%*%*/", ".-/")
  lua_pattern = lua_pattern:gsub("%*", "[^/]*")
  lua_pattern = lua_pattern:gsub("%?", ".")
  if lua_pattern:sub(-1) == "/" then lua_pattern = lua_pattern .. ".*" end
  return lua_pattern
end

function M.parse_gitignore(gitignore_path)
  local ignore_patterns = {}
  local negate_patterns = {}
  local file = io.open(gitignore_path, "r")
  if not file then return ignore_patterns, negate_patterns end

  for line in file:lines() do
    if line:match("%S") and not line:match("^#") then
      local trimmed_line = line:match("^%s*(.-)%s*$")
      if trimmed_line:sub(1, 1) == "!" then
        table.insert(negate_patterns, pattern_to_lua(trimmed_line:sub(2)))
      else
        table.insert(ignore_patterns, pattern_to_lua(trimmed_line))
      end
    end
  end

  file:close()
  ignore_patterns = vim.list_extend(ignore_patterns, { "%.git", "%.worktree", "__pycache__", "node_modules" })
  return ignore_patterns, negate_patterns
end

-- @param file string
-- @param ignore_patterns string[]
-- @param negate_patterns string[]
-- @return boolean
function M.is_ignored(file, ignore_patterns, negate_patterns)
  for _, pattern in ipairs(negate_patterns) do
    if file:match(pattern) then return false end
  end
  for _, pattern in ipairs(ignore_patterns) do
    if file:match(pattern .. "/") or file:match(pattern .. "$") then return true end
  end
  return false
end

---@param options { directory: string, add_dirs?: boolean, max_depth?: integer }
---@return string[]
function M.scan_directory(options)
  local cmd_supports_max_depth = true
  local cmd = (function()
    if vim.fn.executable("rg") == 1 then
      local cmd = { "rg", "--files", "--color", "never", "--no-require-git", "--no-ignore-parent" }
      if options.max_depth ~= nil then vim.list_extend(cmd, { "--max-depth", options.max_depth }) end
      table.insert(cmd, options.directory)
      return cmd
    end
    if vim.fn.executable("fd") == 1 then
      local cmd = { "fd", "--type", "f", "--color", "never", "--no-require-git" }
      if options.max_depth ~= nil then vim.list_extend(cmd, { "--max-depth", options.max_depth }) end
      vim.list_extend(cmd, { "--base-directory", options.directory })
      return cmd
    end
    if vim.fn.executable("fdfind") == 1 then
      local cmd = { "fdfind", "--type", "f", "--color", "never", "--no-require-git" }
      if options.max_depth ~= nil then vim.list_extend(cmd, { "--max-depth", options.max_depth }) end
      vim.list_extend(cmd, { "--base-directory", options.directory })
      return cmd
    end
  end)()

  if not cmd then
    if M.path_exists(M.join_paths(options.directory, ".git")) and vim.fn.executable("git") == 1 then
      if vim.fn.has("win32") == 1 then
        cmd = {
          "powershell",
          "-NoProfile",
          "-NonInteractive",
          "-Command",
          string.format(
            "Push-Location '%s'; (git ls-files --exclude-standard), (git ls-files --exclude-standard --others)",
            options.directory:gsub("/", "\\")
          ),
        }
      else
        cmd = {
          "bash",
          "-c",
          string.format("cd %s && git ls-files -co --exclude-standard", options.directory),
        }
      end
      cmd_supports_max_depth = false
    else
      M.error("No search command found, please install fd or fdfind or rg")
      return {}
    end
  end

  local files = vim.fn.systemlist(cmd)

  files = vim
    .iter(files)
    :map(function(file)
      if not M.is_absolute_path(file) then return M.join_paths(options.directory, file) end
      return file
    end)
    :totable()

  if options.max_depth ~= nil and not cmd_supports_max_depth then
    files = vim
      .iter(files)
      :filter(function(file)
        local base_dir = options.directory
        if base_dir:sub(-2) == "/." then base_dir = base_dir:sub(1, -3) end
        local rel_path = M.make_relative_path(file, base_dir)
        local pieces = vim.split(rel_path, "/")
        return #pieces <= options.max_depth
      end)
      :totable()
  end

  if options.add_dirs then
    local dirs = {}
    local dirs_seen = {}
    for _, file in ipairs(files) do
      local dir = M.get_parent_path(file)
      if not dirs_seen[dir] then
        table.insert(dirs, dir)
        dirs_seen[dir] = true
      end
    end
    files = vim.list_extend(dirs, files)
  end

  return files
end

function M.get_parent_path(filepath)
  if filepath == nil then error("filepath cannot be nil") end
  if filepath == "" then return "" end
  local is_abs = M.is_absolute_path(filepath)
  if filepath:sub(-1) == M.path_sep then filepath = filepath:sub(1, -2) end
  if filepath == "" then return "" end
  local parts = vim.split(filepath, M.path_sep)
  local parent_parts = vim.list_slice(parts, 1, #parts - 1)
  local res = table.concat(parent_parts, M.path_sep)
  if res == "" then
    if is_abs then return M.path_sep end
    return "."
  end
  return res
end

function M.make_relative_path(filepath, base_dir) return M.path.relative(base_dir, filepath, false) end

function M.is_absolute_path(path) return M.path.is_absolute(path) end

function M.to_absolute_path(path)
  if not path or path == "" then return path end
  if path:sub(1, 1) == "/" or path:sub(1, 7) == "term://" then return path end
  return M.join_paths(M.get_project_root(), path)
end

function M.join_paths(...)
  local paths = { ... }
  local result = paths[1] or ""
  for i = 2, #paths do
    local path = paths[i]
    if path == nil or path == "" then goto continue end

    if M.is_absolute_path(path) then
      result = path
      goto continue
    end

    result = result == "" and path or M.path.join(result, path)
    ::continue::
  end
  return M.norm(result)
end

function M.path_exists(path) return M.path.is_exist(path) end

function M.is_first_letter_uppercase(str) return string.match(str, "^[A-Z]") ~= nil end

---@param content string
---@return { new_content: string, enable_project_context: boolean, enable_diagnostics: boolean }
function M.extract_mentions(content)
  -- if content contains @codebase, enable project context and remove @codebase
  local new_content = content
  local enable_project_context = false
  local enable_diagnostics = false
  if content:match("@codebase") then
    enable_project_context = true
    new_content = content:gsub("@codebase", "")
  end
  if content:match("@diagnostics") then enable_diagnostics = true end
  return {
    new_content = new_content,
    enable_project_context = enable_project_context,
    enable_diagnostics = enable_diagnostics,
  }
end

---@return AvanteMention[]
function M.get_mentions()
  return {
    {
      description = "codebase",
      command = "codebase",
      details = "repo map",
    },
    {
      description = "diagnostics",
      command = "diagnostics",
      details = "diagnostics",
    },
  }
end

---@return AvanteMention[]
function M.get_chat_mentions()
  local mentions = M.get_mentions()

  table.insert(mentions, {
    description = "file",
    command = "file",
    details = "add files...",
    callback = function(sidebar) sidebar.file_selector:open() end,
  })

  table.insert(mentions, {
    description = "quickfix",
    command = "quickfix",
    details = "add files in quickfix list to chat context",
    callback = function(sidebar) sidebar.file_selector:add_quickfix_files() end,
  })

  table.insert(mentions, {
    description = "buffers",
    command = "buffers",
    details = "add open buffers to the chat context",
    callback = function(sidebar) sidebar.file_selector:add_buffer_files() end,
  })

  return mentions
end

---@param path string
---@param set_current_buf? boolean
---@return integer bufnr
function M.open_buffer(path, set_current_buf)
  if set_current_buf == nil then set_current_buf = true end

  local abs_path = M.join_paths(M.get_project_root(), path)

  local bufnr ---@type integer
  if set_current_buf then
    bufnr = vim.fn.bufnr(abs_path)
    if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].modified then
      vim.api.nvim_buf_call(bufnr, function() vim.cmd("noautocmd write") end)
    end
    vim.cmd("noautocmd edit " .. abs_path)
    bufnr = vim.api.nvim_get_current_buf()
  else
    bufnr = vim.fn.bufnr(abs_path, true)
    pcall(vim.fn.bufload, bufnr)
  end

  vim.cmd("filetype detect")

  return bufnr
end

---@param old_lines avante.ui.Line[]
---@param new_lines avante.ui.Line[]
---@return { start_line: integer, end_line: integer, content: avante.ui.Line[] }[]
local function get_lines_diff(old_lines, new_lines)
  local remaining_lines = 100
  local start_line = 0
  if #new_lines >= #old_lines then
    start_line = math.max(#old_lines - remaining_lines, 0)
    old_lines = vim.list_slice(old_lines, start_line + 1)
    new_lines = vim.list_slice(new_lines, start_line + 1)
  end
  local diffs = {}
  local prev_diff_idx = nil
  for i, line in ipairs(new_lines) do
    if line ~= old_lines[i] then
      if prev_diff_idx == nil then prev_diff_idx = i end
    else
      if prev_diff_idx ~= nil then
        local content = vim.list_slice(new_lines, prev_diff_idx, i - 1)
        table.insert(diffs, { start_line = start_line + prev_diff_idx, end_line = start_line + i, content = content })
        prev_diff_idx = nil
      end
    end
  end
  if prev_diff_idx ~= nil then
    table.insert(diffs, {
      start_line = start_line + prev_diff_idx,
      end_line = start_line + #new_lines + 1,
      content = vim.list_slice(new_lines, prev_diff_idx),
    })
  end
  if #new_lines < #old_lines then
    table.insert(
      diffs,
      { start_line = start_line + #new_lines + 1, end_line = start_line + #old_lines + 1, content = {} }
    )
  end
  table.sort(diffs, function(a, b) return a.start_line > b.start_line end)
  return diffs
end

---@param bufnr integer
---@param new_lines string[]
---@return { start_line: integer, end_line: integer, content: string[] }[]
local function get_buffer_content_diffs(bufnr, new_lines)
  local old_lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local diffs = {}
  local prev_diff_idx = nil
  for i, line in ipairs(new_lines) do
    if line ~= old_lines[i] then
      if prev_diff_idx == nil then prev_diff_idx = i end
    else
      if prev_diff_idx ~= nil then
        local content = vim.list_slice(new_lines, prev_diff_idx, i - 1)
        table.insert(diffs, { start_line = prev_diff_idx, end_line = i, content = content })
        prev_diff_idx = nil
      end
    end
  end
  if prev_diff_idx ~= nil then
    table.insert(
      diffs,
      { start_line = prev_diff_idx, end_line = #new_lines + 1, content = vim.list_slice(new_lines, prev_diff_idx) }
    )
  end
  if #new_lines < #old_lines then
    table.insert(diffs, { start_line = #new_lines + 1, end_line = #old_lines + 1, content = {} })
  end
  table.sort(diffs, function(a, b) return a.start_line > b.start_line end)
  return diffs
end

--- Update the buffer content more efficiently by only updating the changed lines
---@param bufnr integer
---@param new_lines string[]
function M.update_buffer_content(bufnr, new_lines)
  local diffs = get_buffer_content_diffs(bufnr, new_lines)
  if #diffs == 0 then return end
  for _, diff in ipairs(diffs) do
    api.nvim_buf_set_lines(bufnr, diff.start_line - 1, diff.end_line - 1, false, diff.content)
  end
end

---@param ns_id number
---@param bufnr integer
---@param old_lines avante.ui.Line[]
---@param new_lines avante.ui.Line[]
function M.update_buffer_lines(ns_id, bufnr, old_lines, new_lines)
  local diffs = get_lines_diff(old_lines, new_lines)
  if #diffs == 0 then return end
  for _, diff in ipairs(diffs) do
    local lines = diff.content
    local text_lines = vim.tbl_map(function(line) return tostring(line) end, lines)
    vim.api.nvim_buf_set_lines(bufnr, diff.start_line - 1, diff.end_line - 1, false, text_lines)
    for i, line in ipairs(lines) do
      line:set_highlights(ns_id, bufnr, diff.start_line + i - 2)
    end
    vim.cmd("redraw")
  end
end

function M.uniform_path(path)
  if type(path) ~= "string" then path = tostring(path) end
  if not M.file.is_in_project(path) then return path end
  local project_root = M.get_project_root()
  local abs_path = M.is_absolute_path(path) and path or M.join_paths(project_root, path)
  local relative_path = M.make_relative_path(abs_path, project_root)
  return relative_path
end

function M.is_same_file(filepath_a, filepath_b) return M.uniform_path(filepath_a) == M.uniform_path(filepath_b) end

---Removes <think> tags, returning only text between them
---@param content string
---@return string
function M.trim_think_content(content) return (content:gsub("^<think>.-</think>", "", 1)) end

local _filetype_lru_cache = LRUCache:new(60)

function M.get_filetype(filepath)
  local cached_filetype = _filetype_lru_cache:get(filepath)
  if cached_filetype then return cached_filetype end
  -- Some files are sometimes not detected correctly when buffer is not included
  -- https://github.com/neovim/neovim/issues/27265

  local buf = vim.api.nvim_create_buf(false, true)
  local filetype = vim.filetype.match({ filename = filepath, buf = buf }) or ""
  vim.api.nvim_buf_delete(buf, { force = true })
  -- Parse the first filetype from a multifiltype file
  filetype = filetype:gsub("%..*$", "")
  _filetype_lru_cache:set(filepath, filetype)
  return filetype
end

---@param filepath string
---@return string[]|nil lines
---@return string|nil error
function M.read_file_from_buf_or_disk(filepath)
  local abs_path = filepath:sub(1, 7) == "term://" and filepath or M.join_paths(M.get_project_root(), filepath)
  --- Lookup if the file is loaded in a buffer
  local ok, bufnr = pcall(vim.fn.bufnr, abs_path)
  if ok then
    if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
      -- If buffer exists and is loaded, get buffer content
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      return lines, nil
    end
  end

  local stat = vim.uv.fs_stat(abs_path)
  if stat and stat.type == "directory" then return {}, "Cannot read a directory as file" .. filepath end

  -- Fallback: read file from disk
  local file, open_err = io.open(abs_path, "r")
  if file then
    local content = file:read("*all")
    file:close()
    content = content:gsub("\r\n", "\n")
    return vim.split(content, "\n"), nil
  else
    return {}, open_err
  end
end

---Check if an icon plugin is installed
---@return boolean
function M.icons_enabled() return M.has("nvim-web-devicons") or M.has("mini.icons") or M.has("mini.nvim") end

---Display an string with icon, if an icon plugin is available.
---Dev icons are an optional install for avante, this function prevents ugly chars
---being displayed by displaying fallback options or nothing at all.
---@param string_with_icon string
---@param utf8_fallback string|nil
---@return string
function M.icon(string_with_icon, utf8_fallback)
  if M.icons_enabled() then
    return string_with_icon
  else
    return utf8_fallback or ""
  end
end

function M.deep_extend_with_metatable(behavior, ...)
  local tables = { ... }
  local base = tables[1]
  if behavior == "keep" then base = tables[#tables] end
  local mt = getmetatable(base)

  local result = vim.tbl_deep_extend(behavior, ...)

  if mt then setmetatable(result, mt) end

  return result
end

function M.utc_now()
  local utc_date = os.date("!*t")
  ---@diagnostic disable-next-line: param-type-mismatch
  local utc_time = os.time(utc_date)
  return os.date("%Y-%m-%d %H:%M:%S", utc_time)
end

---@param dt1 string
---@param dt2 string
---@return integer delta_seconds
function M.datetime_diff(dt1, dt2)
  local pattern = "(%d+)-(%d+)-(%d+) (%d+):(%d+):(%d+)"
  local y1, m1, d1, h1, min1, s1 = dt1:match(pattern)
  local y2, m2, d2, h2, min2, s2 = dt2:match(pattern)

  local time1 = os.time({ year = y1, month = m1, day = d1, hour = h1, min = min1, sec = s1 })
  local time2 = os.time({ year = y2, month = m2, day = d2, hour = h2, min = min2, sec = s2 })

  local delta_seconds = os.difftime(time2, time1)
  return delta_seconds
end

---@param iso_str string
---@return string|nil
---@return string|nil error
function M.parse_iso8601_date(iso_str)
  local year, month, day, hour, min, sec = iso_str:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)Z")
  if not year then return nil, "Invalid ISO 8601 format" end

  local time_table = {
    year = tonumber(year),
    month = tonumber(month),
    day = tonumber(day),
    hour = tonumber(hour),
    min = tonumber(min),
    sec = tonumber(sec),
    isdst = false,
  }

  local timestamp = os.time(time_table)

  return tostring(os.date("%Y-%m-%d %H:%M:%S", timestamp)), nil
end

function M.random_string(length)
  local charset = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
  local result = {}
  for _ = 1, length do
    local rand = math.random(1, #charset)
    table.insert(result, charset:sub(rand, rand))
  end
  return table.concat(result)
end

function M.is_left_adjacent(win_a, win_b)
  if not vim.api.nvim_win_is_valid(win_a) or not vim.api.nvim_win_is_valid(win_b) then return false end

  local _, col_a = unpack(vim.fn.win_screenpos(win_a))
  local _, col_b = unpack(vim.fn.win_screenpos(win_b))
  local width_a = vim.api.nvim_win_get_width(win_a)

  local right_edge_a = col_a + width_a

  return right_edge_a + 1 == col_b
end

function M.is_top_adjacent(win_a, win_b)
  local row_a, _ = unpack(vim.fn.win_screenpos(win_a))
  local row_b, _ = unpack(vim.fn.win_screenpos(win_b))
  local height_a = vim.api.nvim_win_get_height(win_a)
  return row_a + height_a + 1 == row_b
end

function M.should_hidden_border(win_a, win_b)
  return M.is_left_adjacent(win_a, win_b) or M.is_top_adjacent(win_a, win_b)
end

---@param fields AvanteLLMToolParamField[]
---@return table[] properties
---@return string[] required
function M.llm_tool_param_fields_to_json_schema(fields)
  local properties = {}
  local required = {}
  for _, field in ipairs(fields) do
    if field.type == "object" and field.fields then
      local properties_, required_ = M.llm_tool_param_fields_to_json_schema(field.fields)
      properties[field.name] = {
        type = field.type,
        description = field.get_description and field.get_description() or field.description,
        properties = properties_,
        required = required_,
      }
    elseif field.type == "array" and field.items then
      local properties_ = M.llm_tool_param_fields_to_json_schema({ field.items })
      local _, obj = next(properties_)
      properties[field.name] = {
        type = field.type,
        description = field.get_description and field.get_description() or field.description,
        items = obj,
      }
    else
      properties[field.name] = {
        type = field.type,
        description = field.get_description and field.get_description() or field.description,
      }
      if field.choices then properties[field.name].enum = field.choices end
    end
    if not field.optional then table.insert(required, field.name) end
  end
  return properties, required
end

---@return AvanteSlashCommand[]
function M.get_commands()
  local Config = require("avante.config")

  ---@param items_ {name: string, description: string, shorthelp?: string}[]
  ---@return string
  local function get_help_text(items_)
    local help_text = ""
    for _, item in ipairs(items_) do
      help_text = help_text .. "- " .. item.name .. ": " .. (item.shorthelp or item.description) .. "\n"
    end
    return help_text
  end

  local builtin_items = {
    { description = "Show help message", name = "help" },
    { description = "Init AGENTS.md based on the current project", name = "init" },
    { description = "Clear chat history", name = "clear" },
    { description = "New chat", name = "new" },
    { description = "Compact history messages to save tokens", name = "compact" },
    {
      shorthelp = "Ask a question about specific lines",
      description = "/lines <start>-<end> <question>",
      name = "lines",
    },
    { description = "Commit the changes", name = "commit" },
  }

  ---@type {[AvanteSlashCommandBuiltInName]: AvanteSlashCommandCallback}
  local builtin_cbs = {
    help = function(sidebar, args, cb)
      local help_text = get_help_text(builtin_items)
      sidebar:update_content(help_text, { focus = false, scroll = false })
      if cb then cb(args) end
    end,
    clear = function(sidebar, args, cb) sidebar:clear_history(args, cb) end,
    new = function(sidebar, args, cb) sidebar:new_chat(args, cb) end,
    compact = function(sidebar, args, cb) sidebar:compact_history_messages(args, cb) end,
    init = function(sidebar, args, cb) sidebar:init_current_project(args, cb) end,
    lines = function(_, args, cb)
      if cb then cb(args) end
    end,
    commit = function(_, _, cb)
      local question = "Please commit the changes"
      if cb then cb(question) end
    end,
  }

  local builtin_commands = vim
    .iter(builtin_items)
    :map(
      ---@param item AvanteSlashCommand
      function(item)
        return {
          name = item.name,
          description = item.description,
          callback = builtin_cbs[item.name],
          details = item.shorthelp and table.concat({ item.shorthelp, item.description }, "\n") or item.description,
        }
      end
    )
    :totable()

  return vim.list_extend(builtin_commands, Config.slash_commands)
end

function M.get_timestamp() return tostring(os.date("%Y-%m-%d %H:%M:%S")) end

function M.uuid()
  local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
  return string.gsub(template, "[xy]", function(c)
    local v = (c == "x") and math.random(0, 0xf) or math.random(8, 0xb)
    return string.format("%x", v)
  end)
end

---@param tool_use AvanteLLMToolUse
function M.tool_use_to_xml(tool_use)
  local xml = string.format("<tool_use>\n<%s>\n", tool_use.name)
  for k, v in pairs(tool_use.input or {}) do
    xml = xml .. string.format("<%s>%s</%s>\n", k, tostring(v), k)
  end
  xml = xml .. "</" .. tool_use.name .. ">\n</tool_use>"
  return xml
end

---@param tool_use AvanteLLMToolUse
function M.is_edit_func_call_tool_use(tool_use)
  local is_replace_func_call = false
  local is_str_replace_editor_func_call = false
  local is_str_replace_based_edit_tool_func_call = false
  local path = nil
  if tool_use.name == "replace_in_file" then
    is_replace_func_call = true
    path = tool_use.input.path
  end
  if tool_use.name == "str_replace_editor" then
    if tool_use.input.command == "str_replace" then
      is_replace_func_call = true
      is_str_replace_editor_func_call = true
      path = tool_use.input.path
    end
  end
  if tool_use.name == "str_replace_based_edit_tool" then
    if tool_use.input.command == "str_replace" then
      is_replace_func_call = true
      is_str_replace_based_edit_tool_func_call = true
      path = tool_use.input.path
    end
  end
  return is_replace_func_call, is_str_replace_editor_func_call, is_str_replace_based_edit_tool_func_call, path
end

---Counts number of strings in text, accounting for possibility of a trailing newline
---@param str string | nil
---@return integer
function M.count_lines(str)
  if not str or str == "" then return 0 end

  local _, count = str:gsub("\n", "\n")
  -- Number of lines is one more than number of newlines unless we have a trailing newline
  return str:sub(-1) ~= "\n" and count + 1 or count
end

function M.tbl_override(value, override)
  override = override or {}
  if type(override) == "function" then return override(value) or value end
  return vim.tbl_extend("force", value, override)
end

function M.call_once(func)
  local called = false
  return function(...)
    if called then return end
    called = true
    return func(...)
  end
end

return M
