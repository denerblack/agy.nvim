-- agy.nvim — Neovim introspection for the MCP bridge.
--
-- These functions are invoked from the companion MCP server (mcp/nvim-mcp-server.mjs)
-- via `nvim --server $NVIM --remote-expr "luaeval('require([[agy.mcp]]).<fn>()')"`.
-- Each returns a JSON string so the Node side can JSON.parse it directly.
--
-- "Active file" / "selection" are tracked by the plugin (see require('agy').setup)
-- into vim.g.agy_active_file / vim.g.agy_selection, because when agy is focused in
-- its terminal split the live "current window" is the terminal, not your code.

local M = {}

local MAX_CONTENT_BYTES = 200 * 1024 -- cap file content shipped to the agent

local function relpath(abs)
  if not abs or abs == "" then
    return abs
  end
  return vim.fn.fnamemodify(abs, ":.")
end

-- Find a loaded, listed buffer for the given absolute path.
local function bufnr_for(abs)
  if not abs or abs == "" then
    return -1
  end
  local b = vim.fn.bufnr(abs)
  if b ~= -1 and vim.api.nvim_buf_is_loaded(b) then
    return b
  end
  return -1
end

-- Read a file's current text, preferring the live buffer (unsaved edits) and
-- falling back to disk. Returns content, line_count, truncated.
local function read_content(abs)
  local lines
  local b = bufnr_for(abs)
  if b ~= -1 then
    lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  elseif vim.fn.filereadable(abs) == 1 then
    lines = vim.fn.readfile(abs)
  else
    return nil, 0, false
  end
  local count = #lines
  local text = table.concat(lines, "\n")
  local truncated = false
  if #text > MAX_CONTENT_BYTES then
    text = text:sub(1, MAX_CONTENT_BYTES)
    truncated = true
  end
  return text, count, truncated
end

-- The file the user is editing (tracked), with its current content.
function M.active_file()
  local abs = vim.g.agy_active_file
  if (not abs or abs == "") then
    -- fall back to the current buffer if it is a normal named file
    local cur = vim.api.nvim_get_current_buf()
    if vim.bo[cur].buftype == "" then
      local name = vim.api.nvim_buf_get_name(cur)
      if name ~= "" then
        abs = name
      end
    end
  end
  if not abs or abs == "" then
    return vim.json.encode({ ok = false, reason = "no active file" })
  end
  local content, count, truncated = read_content(abs)
  return vim.json.encode({
    ok = content ~= nil,
    path = relpath(abs),
    abspath = abs,
    line_count = count,
    truncated = truncated,
    content = content,
  })
end

-- The most recent visual selection (tracked on leaving visual mode).
function M.selection()
  local s = vim.g.agy_selection
  if type(s) ~= "table" or not s.abspath then
    return vim.json.encode({ ok = false, reason = "no selection" })
  end
  -- refresh the text from the live buffer in case it changed
  local b = bufnr_for(s.abspath)
  local text = s.text
  if b ~= -1 and s.start_line and s.end_line then
    local lines = vim.api.nvim_buf_get_lines(b, s.start_line - 1, s.end_line, false)
    text = table.concat(lines, "\n")
  end
  return vim.json.encode({
    ok = true,
    path = relpath(s.abspath),
    abspath = s.abspath,
    start_line = s.start_line,
    end_line = s.end_line,
    text = text,
  })
end

-- All open, named, normal-file buffers.
function M.open_files()
  local files = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].buftype == "" then
      local name = vim.api.nvim_buf_get_name(b)
      if name ~= "" then
        files[#files + 1] = {
          path = relpath(name),
          abspath = name,
          modified = vim.bo[b].modified,
        }
      end
    end
  end
  return vim.json.encode({ ok = true, cwd = vim.fn.getcwd(), files = files })
end

-- LSP diagnostics for a buffer, normalized to 1-based positions.
local SEVERITY = { "ERROR", "WARN", "INFO", "HINT" }
local function diag_list(bufnr)
  local out = {}
  for _, d in ipairs(vim.diagnostic.get(bufnr)) do
    out[#out + 1] = {
      severity = SEVERITY[d.severity] or tostring(d.severity),
      line = d.lnum + 1,
      end_line = (d.end_lnum or d.lnum) + 1,
      col = d.col + 1,
      message = d.message,
      source = d.source,
      code = d.code and tostring(d.code) or nil,
    }
  end
  return out
end

-- Diagnostics (errors / warnings / info / hints) for the file the user is editing.
function M.diagnostics()
  local abs = vim.g.agy_active_file
  local b = abs and bufnr_for(abs) or -1
  if b == -1 then
    local cur = vim.api.nvim_get_current_buf()
    if vim.bo[cur].buftype == "" and vim.api.nvim_buf_get_name(cur) ~= "" then
      b, abs = cur, vim.api.nvim_buf_get_name(cur)
    end
  end
  if b == -1 then
    return vim.json.encode({ ok = false, reason = "no active file buffer" })
  end
  local diags = diag_list(b)
  local counts = { ERROR = 0, WARN = 0, INFO = 0, HINT = 0 }
  for _, d in ipairs(diags) do
    counts[d.severity] = (counts[d.severity] or 0) + 1
  end
  return vim.json.encode({
    ok = true,
    path = relpath(abs),
    abspath = abs,
    count = #diags,
    counts = counts,
    diagnostics = diags,
  })
end

-- Replace a 1-based inclusive line range in a live buffer with new text.
-- Arguments arrive base64-encoded JSON (avoids remote-expr quoting issues):
--   { path?, start_line, end_line, text }
-- end_line == start_line - 1 inserts before start_line without replacing.
-- The edit lands in the buffer (undoable with `u`); it is not saved to disk.
function M.apply_edit(arg_b64)
  local ok, args = pcall(function()
    return vim.json.decode(vim.base64.decode(arg_b64))
  end)
  if not ok or type(args) ~= "table" then
    return vim.json.encode({ ok = false, reason = "could not decode arguments" })
  end

  local abs = args.path
  if abs and abs ~= "" then
    abs = vim.fn.fnamemodify(abs, ":p")
  else
    abs = vim.g.agy_active_file
  end
  if not abs or abs == "" then
    return vim.json.encode({ ok = false, reason = "no target file (pass 'path' or open a file)" })
  end

  local b = bufnr_for(abs)
  if b == -1 then
    return vim.json.encode({ ok = false, reason = "file is not open in a loaded buffer: " .. abs })
  end
  if not vim.bo[b].modifiable then
    return vim.json.encode({ ok = false, reason = "buffer is not modifiable" })
  end

  local s = tonumber(args.start_line)
  local e = tonumber(args.end_line)
  if not s or not e then
    return vim.json.encode({ ok = false, reason = "start_line and end_line are required" })
  end
  local total = vim.api.nvim_buf_line_count(b)
  s = math.max(1, math.min(s, total + 1))
  if e > total then
    e = total
  end
  -- 0-based, end-exclusive range for nvim_buf_set_lines
  local start0 = s - 1
  local end0 = (e >= s) and e or start0 -- e < s => insertion (empty range)

  local repl = vim.split(args.text or "", "\n", { plain = true })
  local applied, err = pcall(vim.api.nvim_buf_set_lines, b, start0, end0, false, repl)
  if not applied then
    return vim.json.encode({ ok = false, reason = tostring(err) })
  end
  return vim.json.encode({
    ok = true,
    path = relpath(abs),
    abspath = abs,
    replaced_lines = end0 - start0,
    inserted_lines = #repl,
    new_line_count = vim.api.nvim_buf_line_count(b),
  })
end

return M
