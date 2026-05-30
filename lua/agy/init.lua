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
  context = {
    -- Typing "@path" opens agy's workspace file picker; this key confirms the
    -- highlighted match so the mention is finalized (Tab = Complete, safe —
    -- it never submits the prompt; "\r" would Select instead).
    finalize_key = "\t",
    -- annotation appended after a finalized mention when lines are selected
    line_range = " (lines %d-%d) ",
    -- delays (ms) so the picker has time to populate / settle between steps
    picker_delay = 350,
    suffix_delay = 120,
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

-- Inject the context into the agy prompt in stages, because typing "@path"
-- opens agy's workspace file picker that must be confirmed before more text
-- is typed:
--   1. type "@<relative path>"  -> opens the picker, filtered to the file
--   2. send finalize_key (Tab)  -> confirms the mention, closes the picker
--   3. append a trailing space (and line range for a selection) as plain text
-- The prompt is left ready for the user to type their question; nothing is
-- submitted.
local function inject_context(ctx)
  if not ctx or not ctx.file or not state.job then
    return
  end
  local c = M.config.context
  vim.fn.chansend(state.job, "@" .. ctx.file)
  vim.defer_fn(function()
    if not state.job then
      return
    end
    vim.fn.chansend(state.job, c.finalize_key)
    vim.defer_fn(function()
      if not state.job then
        return
      end
      local suffix = " "
      if ctx.srow then
        suffix = string.format(c.line_range, ctx.srow, ctx.erow)
      end
      vim.fn.chansend(state.job, suffix)
    end, c.suffix_delay)
  end, c.picker_delay)
end

-- agy's TUI can take several seconds to boot. We poll the terminal buffer
-- until its input box has rendered before typing context into it; sending
-- too early silently drops the keystrokes.
local READY_POLL_MS = 100
local READY_MAX_TRIES = 150 -- ~15s ceiling before sending anyway
local READY_CUSHION_MS = 400 -- settle time after the box appears

-- True once agy has drawn its input box (a horizontal rule of box chars),
-- which means it is accepting typed input.
local function tui_ready()
  if not buf_alive() then
    return false
  end
  for _, l in ipairs(vim.api.nvim_buf_get_lines(state.buf, 0, -1, false)) do
    -- the prompt box is delimited by long runs of U+2500 ("─")
    if l:find("────") then
      return true
    end
  end
  return false
end

-- Inject context once the TUI is ready (or immediately if already running).
local function inject_when_ready(ctx, fresh)
  if not ctx then
    return
  end
  if not fresh then
    inject_context(ctx) -- session already running: picker responds at once
    return
  end
  local function attempt(tries)
    if not state.job or not buf_alive() then
      return
    end
    if tui_ready() or tries >= READY_MAX_TRIES then
      vim.defer_fn(function()
        inject_context(ctx)
      end, READY_CUSHION_MS)
    else
      vim.defer_fn(function()
        attempt(tries + 1)
      end, READY_POLL_MS)
    end
  end
  attempt(0)
end

-- Open agy and prefill the prompt with the given context (file / selection).
local function open_with_context(ctx)
  local fresh = not state.started
  M.open()
  if not M.config.auto_context then
    return
  end
  inject_when_ready(ctx, fresh)
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
