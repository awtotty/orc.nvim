# Orchid — Neovim Plugin

A neovim plugin for orchestrating AI coding agents across git worktrees.

## Core Concept

Manage multiple Claude Code (or other CLI) sessions, each isolated in its own git worktree. Prompt agents from any buffer with optional line selection for context. Get notified when agents need attention.

## MVP Features

### 1. Room Management (`lua/orchid/rooms.lua`)

A "room" is a git worktree + a persistent hidden terminal buffer running Claude Code.

- **State**: Table mapping room name → `{bufnr, worktree_path, branch, status}`
- **Create room**: `git worktree add` a new branch, open a terminal buffer with `jobstart` running `claude` in that worktree, hide the buffer
- **Toggle room**: Show/hide a room's terminal in a split or float
- **Delete room**: Kill the terminal job, `git worktree remove`, clean up state
- **List rooms**: Show all rooms with their status (active, needs attention, etc.)

### 2. Prompt with Context (`lua/orchid/prompt.lua`)

Send prompts to any room's terminal, optionally with selected code as reference.

- **Visual select → prompt**: Grab selection, format as fenced code block with filename and line range, open a small prompt input (float or cmdline), concatenate context + user prompt, send to the target room's terminal via `chansend()`
- **Prompt without selection**: Just open prompt input and send to active room
- **Format**:
  ```
  In `src/foo.rs:12-24`:
  ```rust
  <selected code>
  ```

  <user's prompt>
  ```

### 3. Signal File Notifications (`lua/orchid/signal.lua`)

Convention-based notification system. Claude is instructed to write to `.claude/signal` in its worktree when it needs human input or finishes a task.

- **File watching**: Use `vim.uv.new_fs_event()` to watch each worktree's signal file
- **Signal format**: Simple line-based, e.g. `DONE: implemented the feature`, `QUESTION: should I use X or Y?`, `BLOCKED: tests failing`
- **Notification display**: `vim.notify()` with the signal content, linking to the room

## File Structure

```
orchid/
├── lua/
│   └── orchid/
│       ├── init.lua       -- Setup, config defaults, public API
│       ├── rooms.lua      -- Worktree CRUD, terminal lifecycle, state
│       ├── prompt.lua     -- Visual selection capture, prompt input, send
│       └── signal.lua     -- File watchers, notification routing
└── plugin/
    └── orchid.lua         -- User commands and default keymaps
```

## Commands

- `:OrchidCreate <name>` — Create a new room (worktree + branch + terminal)
- `:OrchidToggle [name]` — Toggle the terminal for a room (default: current/last active)
- `:OrchidDelete <name>` — Tear down a room
- `:OrchidList` — Show all rooms and their status
- `:OrchidPrompt [name]` — Open prompt input for a room (works with visual selection)
- `:OrchidSwitch <name>` — Set the active room for prompts

## Dependencies

- Neovim >= 0.10
- git (with worktree support)
- A CLI agent (claude, codex, etc.) — configurable

## Config

```lua
require("orchid").setup({
  cli = "claude",           -- CLI command to run in each room
  worktree_base = ".orchid",     -- Where to put worktrees (relative to repo root)
  signal_file = ".claude/signal",  -- Signal file path within worktree
  terminal_direction = "float",    -- "float", "vertical", "horizontal"
})
```

## Build Order

1. `rooms.lua` — Get worktree + terminal lifecycle working
2. `plugin/orchid.lua` + `init.lua` — Wire up commands and config
3. `prompt.lua` — Visual select → prompt → send
4. `signal.lua` — File watching and notifications
