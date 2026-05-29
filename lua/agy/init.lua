-- agy.nvim — embedded Antigravity CLI (agy) inside Neovim
-- Floating terminal that runs the `agy` agent, with session persistence,
-- file/selection context sending, and auto-reload of files agy edits.
--
-- Inspired by the Claude Code editor integration, tailored to the `agy` CLI.

local M = {}

---@class AgyConfig
local defaults = {
  command = "agy", -- the CLI binary
  -- extra args appended on every launch, e.g. { "--add-dir", vim.fn.getcwd() }
  args = {},
  -- floating window geometry (fractions of the editor size)
  float = {
    width = 0.85,
    height = 0.85,
    border = "rounded",
    title = " agy ",
    title_pos = "center",
  },
  -- start agy with --continue (resume most recent conversation) the first time
  continue = false,
  -- pass --dangerously-skip-permissions so agy never blocks on tool prompts
  skip_permissions = false,
  -- reload buffers when agy modifies files on disk
  auto_reload = true,
  -- mention syntax used to reference a file in the prompt (Claude-style "@path")
  file_mention = "@%s ",
}

---@type AgyConfig
M.config = vim.deepcopy(defaults)

-- terminal state: persists across toggles so the session is not killed
local state = {
  buf = nil, ---@type integer?
  win = nil, ---@type integer?
  job = nil, ---@type integer?
  started = false,
}

local function is_valid(handle, validator)
  return handle ~= nil and validator(handle)
end

local function win_open()
  return is_valid(state.win, vim.api.nvim_win_is_valid)
end

local function buf_alive()
  return is_valid(state.buf, vim.api.nvim_buf_is_valid)
end

-- Build the float window config from M.config.float
local function float_opts()
  local f = M.config.float
  local cols = vim.o.columns
  local lines = vim.o.lines
  local width = math.floor(cols * f.width)
  local height = math.floor(lines * f.height)
  return {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((lines - height) / 2),
    col = math.floor((cols - width) / 2),
    style = "minimal",
    border = f.border,
    title = f.title,
    title_pos = f.title_pos,
  }
end

-- Build the shell command list to launch agy
local function build_cmd()
  local cmd = { M.config.command }
  if M.config.continue then
    table.insert(cmd, "--continue")
  end
  if M.config.skip_permissions then
    table.insert(cmd, "--dangerously-skip-permissions")
  end
  for _, a in ipairs(M.config.args) do
    table.insert(cmd, a)
  end
  return cmd
end

-- Reload any buffers whose underlying file changed on disk (agy edited them)
local function reload_changed_files()
  if not M.config.auto_reload then
    return
  end
  vim.schedule(function()
    -- checktime triggers autoread for all buffers; guard for cmdwin
    if vim.fn.getcmdwintype() == "" then
      vim.cmd("silent! checktime")
    end
  end)
end

-- Open (or focus) the floating window. Creates the terminal on first use.
function M.open()
  if not buf_alive() then
    state.buf = vim.api.nvim_create_buf(false, true)
    state.started = false
  end

  if not win_open() then
    state.win = vim.api.nvim_open_win(state.buf, true, float_opts())
    vim.wo[state.win].winhl = "Normal:Normal,FloatBorder:FloatBorder"
    vim.wo[state.win].winblend = 0
  else
    vim.api.nvim_set_current_win(state.win)
  end

  -- Launch agy inside the terminal the first time the buffer is shown
  if not state.started then
    vim.api.nvim_buf_call(state.buf, function()
      state.job = vim.fn.jobstart(build_cmd(), {
        term = true,
        on_exit = function()
          state.started = false
          state.job = nil
          if win_open() then
            vim.api.nvim_win_close(state.win, true)
          end
          if buf_alive() then
            vim.api.nvim_buf_delete(state.buf, { force = true })
          end
          state.buf = nil
          reload_changed_files()
        end,
      })
    end)
    state.started = true

    -- buffer-local UX: q / <Esc><Esc> hide the window
    vim.bo[state.buf].buflisted = false
    vim.keymap.set("t", "<C-h>", [[<C-\><C-n><C-w>h]], { buffer = state.buf, desc = "Window left" })
    vim.keymap.set("n", "q", M.hide, { buffer = state.buf, desc = "Hide agy" })
  end

  vim.cmd("startinsert")
end

-- Hide the window but keep the terminal/session running.
function M.hide()
  if win_open() then
    vim.api.nvim_win_close(state.win, true)
    state.win = nil
  end
  reload_changed_files()
end

-- Toggle visibility of the agy terminal.
function M.toggle()
  if win_open() then
    M.hide()
  else
    M.open()
  end
end

-- Send raw text to the agy prompt (types into the TUI).
---@param text string
function M.send(text)
  if not state.job then
    M.open()
  end
  vim.fn.chansend(state.job, text)
end

-- Submit text to agy as a prompt (text + carriage return).
---@param text string
function M.submit(text)
  M.send(text .. "\r")
end

-- Reference the current file in the agy prompt as an @mention.
function M.send_file()
  local path = vim.fn.expand("%:p")
  if path == "" then
    vim.notify("agy: no file in current buffer", vim.log.levels.WARN)
    return
  end
  local rel = vim.fn.fnamemodify(path, ":.")
  M.open()
  vim.defer_fn(function()
    M.send(string.format(M.config.file_mention, rel))
  end, 100)
end

-- Send the current visual selection to agy as context.
function M.send_selection()
  local mode = vim.fn.mode()
  -- grab the last visual selection
  local srow = vim.fn.line("'<")
  local erow = vim.fn.line("'>")
  if mode:match("[vV]") then
    srow, erow = vim.fn.line("v"), vim.fn.line(".")
  end
  if srow > erow then
    srow, erow = erow, srow
  end
  local lines = vim.api.nvim_buf_get_lines(0, srow - 1, erow, false)
  local rel = vim.fn.fnamemodify(vim.fn.expand("%:p"), ":.")
  local block = string.format("From %s:%d-%d:\n%s\n", rel, srow, erow, table.concat(lines, "\n"))
  M.open()
  vim.defer_fn(function()
    M.send(block)
  end, 100)
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})

  -- Make autoread effective so reload_changed_files actually swaps content
  vim.o.autoread = true

  vim.api.nvim_create_user_command("Agy", function()
    M.toggle()
  end, { desc = "Toggle the embedded agy terminal" })

  vim.api.nvim_create_user_command("AgyContinue", function()
    -- relaunch with --continue: kill current session, reset, reopen
    if state.job then
      vim.fn.jobstop(state.job)
    end
    local prev = M.config.continue
    M.config.continue = true
    M.open()
    M.config.continue = prev
  end, { desc = "Open agy resuming the most recent conversation" })

  vim.api.nvim_create_user_command("AgySendFile", function()
    M.send_file()
  end, { desc = "Send the current file as an @mention to agy" })

  vim.api.nvim_create_user_command("AgySendSelection", function()
    M.send_selection()
  end, { range = true, desc = "Send the visual selection to agy" })

  -- Reload edited files when we return to a normal buffer
  vim.api.nvim_create_autocmd({ "FocusGained", "BufEnter" }, {
    group = vim.api.nvim_create_augroup("agy_autoreload", { clear = true }),
    callback = reload_changed_files,
  })
end

return M
