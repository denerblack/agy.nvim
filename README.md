# agy.nvim

Embedded [Antigravity CLI](https://antigravity.google) (`agy`) inside Neovim — an
editor-split integration in the spirit of the Claude Code editor plugin.

Run the `agy` agent in a full-height editor split (right by default, like
Claude Code), keep the session alive across toggles, send the current file or
visual selection as context, and have buffers auto-reload when `agy` edits
files on disk.

## Features

- **Editor split** running `agy` on the right (or left), toggleable from anywhere;
  reused (never duplicated) if a session is already on screen.
- **Persistent session** — hiding the window does not kill the conversation.
- **Automatic context** — opening agy attaches the active file (as an `@mention`,
  confirmed through agy's file picker), and the selected line range when you open
  it from visual mode, the way Copilot Chat pulls in the current context. It waits
  for the TUI to finish booting before typing, then leaves the prompt ready for
  your question without submitting.
- **Follows the active file** — switch files and return to the agy split, and the
  mention updates to the file you are now editing (only while the prompt holds
  nothing but an auto-mention — a question you are typing is never clobbered).
- **Auto-reload** — open buffers refresh when `agy` modifies files on disk.
- **Resume** — open continuing the most recent conversation (`agy --continue`).
- **MCP bridge (optional)** — lets agy *query* your editor on demand (active file
  with unsaved edits, visual selection, open files, LSP diagnostics) and apply edits
  to open buffers over MCP, the robust equivalent of an IDE integration. See
  [MCP bridge](#mcp-bridge).

## Requirements

- Neovim >= 0.11 (uses `jobstart({ term = true })`)
- The [`agy`](https://antigravity.google) CLI available on your `PATH`
- `node` on your `PATH` — only for the optional [MCP bridge](#mcp-bridge)

## Installation

### lazy.nvim

```lua
{
  "denerblack/agy.nvim",
  lazy = false,
  config = function()
    require("agy").setup({
      -- continue = true,            -- always resume the last conversation
      -- skip_permissions = true,    -- pass --dangerously-skip-permissions
      -- args = { "--add-dir", vim.fn.getcwd() },
    })
  end,
  keys = {
    { "<C-,>", function() require("agy").toggle() end, mode = { "n", "t" }, desc = "Toggle agy" },
    { "<leader>aa", function() require("agy").toggle() end, desc = "Toggle agy" },
    { "<leader>ac", "<cmd>AgyContinue<cr>", desc = "agy: continue last conversation" },
    { "<leader>af", "<cmd>AgySendFile<cr>", desc = "agy: send current file" },
    -- visual: use the range-aware command (range-safe; avoids E481 "No range allowed")
    { "<leader>as", "<cmd>AgySendSelection<cr>", mode = "v", desc = "agy: send selection" },
  },
}
```

### packer.nvim

```lua
use({ "denerblack/agy.nvim", config = function() require("agy").setup() end })
```

## Usage

| Command             | Action                                            |
| ------------------- | ------------------------------------------------- |
| `:Agy`              | Toggle agy (or send the selection when given a range) |
| `:AgyContinue`      | Open `agy` resuming the most recent conversation  |
| `:AgySendFile`      | Send the current file as an `@mention`            |
| `:AgySendSelection` | Send the visual selection as context (`:'<,'>`)   |
| `:AgyMcpInstall`    | Register the MCP bridge in agy's `mcp_config.json`|

All commands accept a range, so calling them from visual mode (where `:` inserts
`'<,'>`) never errors. `:'<,'>Agy` sends the selection; a bare `:Agy` toggles.

Inside the terminal, `q` (normal mode) hides the window while keeping the
session running.

## Configuration

Defaults shown:

```lua
require("agy").setup({
  command = "agy",            -- the CLI binary
  args = {},                  -- extra args appended on every launch
  split = {
    side = "right",          -- "right" | "left" — full-height editor split
    width = 0.40,            -- fraction of total columns
  },
  continue = false,           -- start with --continue
  skip_permissions = false,   -- pass --dangerously-skip-permissions
  auto_reload = true,         -- reload buffers agy edits on disk
  auto_context = true,        -- attach active file/selection when opening agy
  follow_active_file = true,  -- refresh the mention when you switch files
  context = {
    finalize_key = "\t",            -- confirms agy's @file picker (Tab)
    line_range = " (lines %d-%d) ", -- appended for a visual selection
    picker_poll_ms = 80,            -- poll interval while the picker fetches
    picker_max_tries = 60,          -- ceiling before confirming anyway (~4.8s)
    suffix_delay = 150,             -- ms before appending the line range
    clear_settle_ms = 300,          -- ms after clearing before re-typing
  },
})
```

## MCP bridge

The terminal `@mention` injection above *pushes* context into the prompt. The MCP
bridge is the complementary half: it lets agy **pull** your live editor state on
demand — and apply edits back to open buffers — the robust equivalent of the
Claude Code editor integration, over the channel agy actually supports (MCP).

It exposes these tools to agy:

| Tool                  | Returns                                                        |
| --------------------- | -------------------------------------------------------------- |
| `neovim_active_file`  | The file you are editing, with live content (unsaved edits)    |
| `neovim_selection`    | Your most recent visual selection (file, line range, text)     |
| `neovim_open_files`   | The list of files open in Neovim                               |
| `neovim_diagnostics`  | LSP diagnostics for the active file (errors/warnings/hints)    |
| `neovim_apply_edit`   | Replace a 1-based line range in an open buffer (undoable, unsaved) |

### How it works

agy runs inside Neovim's `:terminal`, so it inherits `$NVIM` — the RPC socket of
the very Neovim instance hosting it. A tiny zero-dependency Node MCP server
(`mcp/nvim-mcp-server.mjs`) connects back to that socket (via
`nvim --server $NVIM --remote-expr`) and answers the tool calls. No `nvr`, no
extra daemon.

```
agy ──(MCP/stdio)──► nvim-mcp-server.mjs ──($NVIM socket)──► Neovim
     calls neovim_active_file              reads the active file/selection
```

### Setup

Requires `node` on your `PATH`. Then register the server in agy's config:

```vim
:AgyMcpInstall
```

This merges an entry into `~/.gemini/config/mcp_config.json`:

```json
{
  "mcpServers": {
    "neovim": { "command": "node", "args": ["/abs/path/to/agy.nvim/mcp/nvim-mcp-server.mjs"] }
  }
}
```

Restart `agy` (toggle it closed/open) so it loads the new MCP server. agy will
call the `neovim_*` tools when you ask about "this file" / "the selection".

> The bridge is optional — without it, the terminal `@mention` auto-context still
> works. With it, agy also sees unsaved edits and can fetch context itself.

## Changelog

See [CHANGELOG.md](CHANGELOG.md).

## License

MIT
