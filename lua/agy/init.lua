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
    -- the picker fetches matches asynchronously; poll until our file is listed
    picker_poll_ms = 80, -- interval between checks for the picker match
    picker_max_tries = 60, -- ~4.8s ceiling before confirming anyway
    suffix_delay = 150, -- settle time after confirming, before the line range
    clear_settle_ms = 300, -- wait after Ctrl-U (clear) before re-typing
  },
  -- keep agy pointed at the file you are editing: when you switch back to the
  -- agy window after changing files, the mention is refreshed to the new file
  -- (only when the prompt holds nothing but an auto-mention, never a question).
  follow_active_file = true,
}

---@type AgyConfig
M.config = vim.deepcopy(defaults)

-- terminal state: persists across toggles so the session is not killed
local state = {
  buf = nil, ---@type integer?
  win = nil, ---@type integer?
  job = nil, ---@type integer?
  started = false,
  source_file = nil, ---@type string? last real file the user was editing
  refreshing = false, ---@type boolean guards against overlapping refreshes
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

-- True once agy's file picker has fetched and listed our file as a match.
-- The picker loads matches asynchronously ("Fetching matches for ..."), so a
-- fixed delay before confirming is unreliable; we poll the rendered buffer.
local function picker_match_ready(file)
  if not buf_alive() then
    return false
  end
  local base = file:match("[^/]+$") or file
  local saw_match = false
  for _, l in ipairs(vim.api.nvim_buf_get_lines(state.buf, 0, -1, false)) do
    if l:find("Fetching matches", 1, true) then
      return false -- still loading
    end
    -- a result row shows the basename next to a "File" label or the full path
    if l:find(base, 1, true) and (l:find("File", 1, true) or l:find("/" .. base, 1, true)) then
      saw_match = true
    end
  end
  return saw_match
end

-- Inject the context into the agy prompt in stages, because typing "@path"
-- opens agy's workspace file picker that must be confirmed before more text
-- is typed:
--   1. type "@<relative path>"          -> opens the picker, filters to the file
--   2. poll until the match is listed    -> the picker fetches asynchronously
--   3. send finalize_key (Tab)           -> confirms the mention, closes picker
--   4. append a trailing space (and line range for a selection) as plain text
-- The prompt is left ready for the user to type their question; nothing is
-- submitted.
local function inject_context(ctx)
  if not ctx or not ctx.file or not state.job then
    return
  end
  local c = M.config.context
  vim.fn.chansend(state.job, "@" .. ctx.file)

  local function finalize()
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
  end

  local function wait_match(tries)
    if not state.job or not buf_alive() then
      return
    end
    if picker_match_ready(ctx.file) or tries >= c.picker_max_tries then
      finalize()
    else
      vim.defer_fn(function()
        wait_match(tries + 1)
      end, c.picker_poll_ms)
    end
  end
  vim.defer_fn(function()
    wait_match(0)
  end, c.picker_poll_ms)
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

-- Remember the file the user is editing, so we can keep agy pointed at it and
-- expose it to the MCP bridge (vim.g.agy_active_file holds the absolute path).
local function record_source()
  local buf = vim.api.nvim_get_current_buf()
  if buf == state.buf or vim.bo[buf].buftype ~= "" then
    return
  end
  local name = vim.api.nvim_buf_get_name(buf)
  if name ~= "" then
    state.source_file = vim.fn.fnamemodify(name, ":.")
    vim.g.agy_active_file = name -- absolute path, for the MCP server
  end
end

-- Record the visual selection (file + range + text) when leaving visual mode,
-- so the MCP bridge can report it via vim.g.agy_selection.
local function record_selection()
  local buf = vim.api.nvim_get_current_buf()
  if buf == state.buf or vim.bo[buf].buftype ~= "" then
    return
  end
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" then
    return
  end
  local srow, erow = vim.fn.line("'<"), vim.fn.line("'>")
  if srow <= 0 or erow <= 0 then
    return
  end
  if srow > erow then
    srow, erow = erow, srow
  end
  local lines = vim.api.nvim_buf_get_lines(buf, srow - 1, erow, false)
  vim.g.agy_selection = {
    abspath = name,
    start_line = srow,
    end_line = erow,
    text = table.concat(lines, "\n"),
  }
end

-- Read the current text in agy's prompt input line ("> ..."), or nil if it
-- can't be determined (e.g. the TUI hasn't drawn the box yet).
local function prompt_input()
  if not buf_alive() then
    return nil
  end
  local lines = vim.api.nvim_buf_get_lines(state.buf, 0, -1, false)
  for i = #lines, 1, -1 do
    local content = lines[i]:match("^>%s*(.-)%s*$")
    if content ~= nil then
      return content
    end
  end
  return nil
end

-- True when the prompt holds only an auto-injected mention (or is empty), so
-- it is safe to replace without destroying a question the user is typing.
local function is_replaceable(text)
  if text == nil then
    return false
  end
  if text == "" then
    return true
  end
  if text:match("^@%S+%s*$") then
    return true
  end
  if text:match("^@%S+%s*%(lines%s+%d+%-%d+%)%s*$") then
    return true
  end
  return false
end

-- Refresh agy's mention to the file the user is now editing. Runs when the
-- agy window is re-entered; no-ops if the prompt holds a real question or
-- already references the current file.
local function refresh_context()
  if state.refreshing then
    return -- a refresh is already mid-flight; the terminal updates async
  end
  if not (M.config.auto_context and M.config.follow_active_file) then
    return
  end
  if not (state.started and buf_alive() and state.job and state.source_file) then
    return
  end
  local cur = prompt_input()
  if not is_replaceable(cur) then
    return -- the user has typed something; leave it alone
  end
  if cur ~= "" and cur:match("^@(%S+)") == state.source_file then
    return -- already pointed at this file
  end
  state.refreshing = true
  local c = M.config.context
  vim.fn.chansend(state.job, "\21") -- Ctrl-U: clear the input line
  -- let the clear fully process before re-typing, else the new "@path" is
  -- appended to the old mention and the picker searches a garbled string
  vim.defer_fn(function()
    inject_context({ file = state.source_file })
  end, c.clear_settle_ms)
  -- release the guard after the worst-case inject duration plus a margin
  local budget = c.clear_settle_ms + c.picker_poll_ms * (c.picker_max_tries + 2) + c.suffix_delay + 600
  vim.defer_fn(function()
    state.refreshing = false
  end, budget)
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

-- Locate the bundled MCP server script on the runtimepath.
local function mcp_server_path()
  local found = vim.api.nvim_get_runtime_file("mcp/nvim-mcp-server.mjs", false)
  return found and found[1] or nil
end

-- Register the MCP bridge in agy's mcp_config.json so agy can query the active
-- file / selection / open files via the neovim_* tools. Merges into any existing
-- config. Returns true on success.
---@param config_path? string defaults to ~/.gemini/config/mcp_config.json
function M.mcp_install(config_path)
  local server = mcp_server_path()
  if not server then
    vim.notify("agy: could not locate mcp/nvim-mcp-server.mjs on runtimepath", vim.log.levels.ERROR)
    return false
  end
  if vim.fn.executable("node") == 0 then
    vim.notify("agy: 'node' not found on PATH (required by the MCP server)", vim.log.levels.ERROR)
    return false
  end
  config_path = config_path or vim.fn.expand("~/.gemini/config/mcp_config.json")

  local cfg = {}
  if vim.fn.filereadable(config_path) == 1 then
    local raw = table.concat(vim.fn.readfile(config_path), "\n")
    if raw:match("%S") then
      local ok, decoded = pcall(vim.json.decode, raw)
      if ok and type(decoded) == "table" then
        cfg = decoded
      else
        vim.notify("agy: existing mcp_config.json is invalid JSON; aborting", vim.log.levels.ERROR)
        return false
      end
    end
  end

  cfg.mcpServers = cfg.mcpServers or {}
  cfg.mcpServers.neovim = { command = "node", args = { server } }

  vim.fn.mkdir(vim.fn.fnamemodify(config_path, ":h"), "p")
  local json = vim.json.encode(cfg)
  if vim.fn.writefile({ json }, config_path) ~= 0 then
    vim.notify("agy: failed to write " .. config_path, vim.log.levels.ERROR)
    return false
  end
  vim.notify("agy: MCP bridge registered (" .. server .. "). Restart agy to load it.", vim.log.levels.INFO)
  return true
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

  vim.api.nvim_create_user_command("AgyMcpInstall", function()
    M.mcp_install()
  end, { desc = "Register the agy.nvim MCP bridge in agy's mcp_config.json" })

  -- ensure this Neovim is reachable over RPC; agy (in the embedded terminal)
  -- inherits $NVIM pointing here, and the MCP server connects back to it.
  if vim.v.servername == nil or vim.v.servername == "" then
    pcall(vim.fn.serverstart)
  end

  local group = vim.api.nvim_create_augroup("agy", { clear = true })

  -- Reload edited files when we return to a normal buffer
  vim.api.nvim_create_autocmd({ "FocusGained", "BufEnter" }, {
    group = group,
    callback = reload_changed_files,
  })

  -- Remember the file the user is editing (ignores the agy terminal itself).
  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    callback = record_source,
  })

  -- Track the visual selection (for the MCP bridge) when leaving visual mode.
  vim.api.nvim_create_autocmd("ModeChanged", {
    group = group,
    pattern = "[vV\x16]*:*", -- leaving visual / visual-block
    callback = record_selection,
  })

  -- Keep agy pointed at the active file: entering the agy window refreshes the
  -- mention to whatever file you were last editing. WinEnter (not BufEnter)
  -- fires exactly once per focus change, avoiding overlapping refreshes.
  vim.api.nvim_create_autocmd("WinEnter", {
    group = group,
    callback = function()
      if vim.api.nvim_get_current_buf() == state.buf then
        refresh_context()
      end
    end,
  })
end

return M
