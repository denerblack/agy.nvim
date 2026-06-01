# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project aims to
follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Embedded `agy` (Antigravity CLI) running in a full-height editor split (right
  by default, configurable to left), toggleable from anywhere, with a persistent
  session that survives hiding the window.
- Automatic context: opening agy attaches the active file as an `@mention`
  (confirmed through agy's file picker), and the selected line range when opened
  from visual mode. Waits for the TUI to finish booting before typing and leaves
  the prompt ready without submitting.
- Follows the active file: returning to the agy split after switching files
  refreshes the mention to the file you are now editing (never clobbering a
  question you are typing).
- Auto-reload of buffers when agy edits files on disk.
- Commands: `:Agy`, `:AgyContinue`, `:AgySendFile`, `:AgySendSelection`,
  `:AgyMcpInstall`. All accept a range, so they are safe from visual mode.
- MCP bridge (optional): a zero-dependency Node MCP server
  (`mcp/nvim-mcp-server.mjs`) that connects back to the host Neovim over `$NVIM`
  and exposes the tools `neovim_active_file`, `neovim_selection`,
  `neovim_open_files`, and `neovim_diagnostics`. `:AgyMcpInstall` registers it in
  `~/.gemini/config/mcp_config.json`.

### Changed

- Use a full-height editor split instead of the initial floating window.
- Route the visual send-selection keymap through the range-aware
  `:AgySendSelection` command (range-safe idiom).
- `:Agy` sends the selection when given a range, otherwise toggles.
- Mention injection polls agy's asynchronous file picker until the match is
  listed before confirming, instead of relying on a fixed delay.
- Reuse an existing agy window instead of opening a second split when a session
  is already on screen.

### Fixed

- Auto-context never landing because it was typed before the agy TUI finished
  booting and before the `@file` picker was confirmed.
- `E481: No range allowed` when running `:Agy` (and other commands) from a visual
  selection, where `:` auto-inserts the `'<,'>` range.
