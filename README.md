# agy.nvim

Embedded [Antigravity CLI](https://antigravity.google) (`agy`) inside Neovim — a
floating-terminal integration in the spirit of the Claude Code editor plugin.

Run the `agy` agent in a full-height editor split (right by default, like
Claude Code), keep the session alive across toggles, send the current file or
visual selection as context, and have buffers auto-reload when `agy` edits
files on disk.

## Features

- **Editor split** running `agy` on the right (or left), toggleable from anywhere.
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

## Requirements

- Neovim >= 0.11 (uses `jobstart({ term = true })`)
- The [`agy`](https://antigravity.google) CLI available on your `PATH`

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
    { "<leader>af", function() require("agy").send_file() end, desc = "agy: send current file" },
    { "<leader>as", function() require("agy").send_selection() end, mode = "v", desc = "agy: send selection" },
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
| `:Agy`              | Toggle the embedded `agy` terminal                |
| `:AgyContinue`      | Open `agy` resuming the most recent conversation  |
| `:AgySendFile`      | Send the current file as an `@mention`            |
| `:AgySendSelection` | Send the visual selection as context (`:'<,'>`)   |

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

## License

MIT
