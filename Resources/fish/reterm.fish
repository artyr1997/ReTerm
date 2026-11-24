# ReTerm's fish: read after the user's own config (fish -C), the marks around each command added
# (OSC 133, as zsh's): D the last command done (its status), 7 where the shell is, 6973 its PATH (for Tab),
# A ready for the next; C a command starts

set -g __reterm_status 0
function __reterm_postexec --on-event fish_postexec
    set -g __reterm_status $status
end
function __reterm_prompt --on-event fish_prompt
    printf '\e]133;D;%s\a\e]7;file://%s%s\a\e]6973;%s\a\e]133;A\a' $__reterm_status (hostname) $PWD (string join : $PATH)
end
function __reterm_preexec --on-event fish_preexec
    printf '\e]133;C\a'
end
