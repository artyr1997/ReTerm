# ReTerm

A terminal for macOS in the style of ReNote: the paper is the terminal, nothing else on it. Rust (Tauri)
runs the shell in a pseudo-terminal; the page draws it with xterm.js in the paper's ink.

- The user's login shell (`$SHELL -l`), from the home folder; `TERM=xterm-256color`, true colour.
- M PLUS 1 Code, monospaced with Japanese (wide characters take two cells).
- Light or dark as the Mac is, glass when ReDesk says so; quiet ANSI colours in the ink's tone.
- When the shell ends, the window closes; the last window closed quits ReTerm.
- Keys: ⌘N new window · ⌘W close · ⌘C / ⌘V copy / paste · ⌘K clear · ⌘+ / ⌘− / ⌘0 lettering size ·
  ⌘← / ⌘→ start / end of the line · ⌘⌫ the line gone · ⌥← / ⌥→ word by word
- Rounded corners, no shadow, ReDesk's tiling, pin and glass, as the other Re apps.

The icon's 金 is set in Yuji Boku (SIL Open Font License).

## Run

```sh
npm install
npm run desktop                          # dev window with live reload
npm run tauri build -- --bundles app     # ReTerm.app in src-tauri/target/release/bundle/macos/
```
