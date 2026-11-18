# ReTerm

A terminal for macOS in the style of ReNote: the paper is the terminal, nothing else on it. Rust (Tauri)
runs the shell in a pseudo-terminal; the page draws it with xterm.js in the paper's ink.

Four side buttons, as the other Re apps have:

- **TERM** (⌘⇧T): the terminal as a conversation. Each command a message on the right, the shell's answer
  under it in its colours; the line to type at the bottom (↑ ↓ history from ~/.zsh_history, Tab completes
  commands and paths, Shift+Enter a new line). The user's zsh with their own files; ReTerm adds marks
  (OSC 133, src-tauri/src/zsh) around each command. vim, htop, less… take the whole area while they run.
  Another shell than zsh: a plain terminal.
- **HOMO** (⌘⇧H): Telegram, through TDLib (`brew install tdlib`). Signed in once with the app's api_id and
  api_hash (my.telegram.org), the phone, its code and the password if any. Chats on the left (⌥↑ ⌥↓).
- **CHAT** (⌘⇧C): an LLM through its own CLI, signed in as in the terminal: claude (Claude Code), codex
  (ChatGPT's), Tab between them. The conversation goes on by its session; ⌘K a new one.
- **FULL** (⌘⇧F): the one shown has the whole window, the buttons go.

- The other Re apps' lettering (Noto Sans JP; M PLUS 1p on glass), the terminal's grid too; the buttons in the desk's language (ReDesk), with its flap.
- Light or dark as the Mac is, glass when ReDesk says so; quiet ANSI colours in the ink's tone.
- When the shell ends, the window closes; the last window closed quits ReTerm.
- Keys: ⌘N new window · ⌘W close · ⌘K / Ctrl+L clear · Ctrl+C stop · ⌘+ / ⌘− / ⌘0 lettering size
- Rounded corners, no shadow, ReDesk's tiling, pin and glass, as the other Re apps.

The icon's 金 is set in Yuji Boku (SIL Open Font License).

## Run

```sh
npm install
npm run desktop                          # dev window with live reload
npm run tauri build -- --bundles app     # ReTerm.app in src-tauri/target/release/bundle/macos/
```
