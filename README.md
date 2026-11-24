# ReTerm (Swift)

ReTerm rewritten as a native Mac app (AppKit, SwiftTerm, no web view). TERM: the shell as a conversation
(each command a message, its answer under it; vim, htop… with the whole column), CHAT: claude / codex through
their own programs (a conversation deleted with ⇧⌘⌫ or a right click on it on the left), HOMO: Telegram through TDLib (`brew install tdlib`). It keeps what it kept before (sessions,
conversations, the Telegram app's keys), brought over once from the old app's storage.

    ./build.sh            # build/ReTerm.app
    ./build.sh --install  # into /Applications/ReSpace
    build/ReTerm.app/Contents/MacOS/ReTerm --render <dir>   # the three as pictures, from made-up ones
