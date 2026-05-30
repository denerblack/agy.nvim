-- agy.nvim — embedded Antigravity CLI (agy) inside Neovim
-- Runs the `agy` agent in a full-height editor split (right by default, like
-- Claude Code), with session persistence, file/selection context sending, and
-- auto-reload of files agy edits.
--
-- Inspired by the Claude Code editor integration, tailored to the `agy` CLI.

local M = {}

---@class AgyConfig
local defaults = {
  command = "agy", -- the CLI binary
  -- extra args appended on every launch, e.g. { "--add-dir", vim.fn.getcwd() }
  args = {},
  -- editor split layout (Claude-style): a full-height vertical split.
  split = {
    side = "right", -- "right" | "left"
    width = 0.40, -- fraction of total columns
  },
  -- start agy with --continue (resume most recent conversation) the first time
  continue = false,
  -- pass --dangerously-skip-permissions so agy never blocks on tool prompts
  skip_permissions = false,
  -- reload buffers when agy modifies files on disk
  auto_reload = true,
  -- automatically attach the active file (and visual selection) to the prompt
  -- whenever agy is opened, the way Copilot Chat pulls in the current context.
  auto_context = true,
  -- how that context is written into the prompt (Claude-style "@path" mentions)
  context = {
    file = "@%s ", -- %s = relative path
    selection = "@%s (lines %d-%d) ", -- relative path, start line, end line
  },
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

-- Open a full-height vertical split for the agy buffer and return its window id.
-- "botright"/"topleft" make the split span the entire editor height on the
-- far right/left edge, matching the Claude Code layout.
local function open_split()
  local s = M.config.split
  local placement = s.side == "left" and "topleft" or "botright"
  vim.cmd(placement .. " vsplit")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, state.buf)
  local width = math.floor(vim.o.columns * s.width)
  vim.api.nvim_win_set_width(win, width)
  -- keep the split fixed-width so other windows don't squeeze it on resize
  vim.wo[win].winfixwidth = true
  return win
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

-- Open (or focus) the agy split. Creates the terminal on first use.
function M.open()
  if not buf_alive() then
    state.buf = vim.api.nvim_create_buf(false, true)
    state.started = false
  end

  if not win_open() then
    state.win = open_split()
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

-- Send raw text to the agy prompt (types into the TUI, no submit).
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

-- Capture context from the CURRENT window — must run before agy is focused,
-- otherwise the "current file" becomes the agy terminal itself.
-- Returns { file = relpath, srow?, erow? } or nil when there's no real file.
---@param want_selection boolean
local function capture_context(want_selection)
  local buf = vim.api.nvim_get_current_buf()
  if buf == state.buf then
    return nil -- already inside agy; nothing to attach
  end
  local path = vim.api.nvim_buf_get_name(buf)
  if path == "" or vim.bo[buf].buftype ~= "" then
    return nil -- scratch/terminal/no-name buffer
  end
  local ctx = { file = vim.fn.fnamemodify(path, ":.") }
  if want_selection then
    local srow, erow
    if vim.fn.mode():match("[vV\22]") then
      srow, erow = vim.fn.line("v"), vim.fn.line(".") -- live visual selection
    else
      srow, erow = vim.fn.line("'<"), vim.fn.line("'>") -- last visual marks
    end
    if srow and erow and srow > 0 and erow > 0 then
      if srow > erow then
        srow, erow = erow, srow
      end
      ctx.srow, ctx.erow = srow, erow
    end
  end
  return ctx
end

-- Render a context table into the prompt mention string.
local function context_string(ctx)
  if not ctx or not ctx.file then
    return nil
  end
  if ctx.srow then
    return string.format(M.config.context.selection, ctx.file, ctx.srow, ctx.erow)
  end
  return string.format(M.config.context.file, ctx.file)
end

-- Open agy and prefill the prompt with the given context (file / selection).
local function open_with_context(ctx)
  local fresh = not state.started
  M.open()
  if not M.config.auto_context then
    return
  end
  local str = context_string(ctx)
  if not str then
    return
  end
  -- a freshly launched TUI needs a moment before it accepts input
  vim.defer_fn(function()
    if state.job then
      vim.fn.chansend(state.job, str)
    end
  end, fresh and 200 or 40)
end

-- Toggle the agy terminal. When opening from a code buffer, the active file
-- (and visual selection, if any) is attached to the prompt automatically.
---@param opts? { selection?: boolean }
function M.toggle(opts)
  if win_open() then
    M.hide()
  else
    open_with_context(capture_context(opts and opts.selection))
  end
end

-- Reference the current file in the agy prompt as an @mention.
function M.send_file()
  local ctx = capture_context(false)
  if not ctx then
    vim.notify("agy: no file in current buffer", vim.log.levels.WARN)
    return
  end
  open_with_context(ctx)
end

-- Attach the current visual selection (file + line range) to the prompt.
function M.send_selection()
  local ctx = capture_context(true)
  if not ctx then
    vim.notify("agy: no file in current buffer", vim.log.levels.WARN)
    return
  end
  open_with_context(ctx)
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
