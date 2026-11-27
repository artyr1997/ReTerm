# ReTerm (Swift)

ReTerm rewritten as a native Mac app (AppKit, SwiftTerm, no web view). TERM: the shell as a conversation
(each command a message, its answer under it; vim, htop… with the whole column, and python, node, ssh… too, with the keys: a program reading key by key, the terminal out of its line mode), CHAT: claude / codex through
their own programs (a conversation, as a TERM session, deleted with ⇧⌘⌫ or a right click on it on the left), HOMO: Telegram through TDLib (`brew install tdlib`). It keeps what it kept before (sessions,
conversations, the Telegram app's keys), brought over once from the old app's storage.

The shell (zsh, bash or fish) and CHAT's program (Claude Code, ChatGPT's codex, Gemini CLI, DeepSeek through
Ollama) are chosen on the left column, a dash each as ReSurf's tabs (the chosen one long; one not installed
faint, and how to install it said at the foot when it is pointed at or clicked); the chosen one's name stands
at the window's foot. Another shell chosen: the one before ends (its session kept on the left), the new one
starts where it was. bash and fish get ReTerm's marks as zsh does (Resources/bash/bashrc, read in place of
~/.bashrc after the login files; Resources/fish/reterm.fish, read after the user's config). Gemini and DeepSeek
keep no session here: the conversation so far goes with each message.

    ./build.sh            # build/ReTerm.app
    ./build.sh --install  # into /Applications/ReSpace
    build/ReTerm.app/Contents/MacOS/ReTerm --render <dir>   # the three as pictures, from made-up ones
