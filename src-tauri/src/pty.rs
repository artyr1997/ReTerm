//! Each window's shell: the user's login shell in a pseudo-terminal. What it writes goes to its window as
//! `pty-data` events (text, never a character cut in two); the keys come back by pty_write. When the shell
//! ends, the window hears `pty-exit` and closes; when the window goes, its shell goes with it.

use portable_pty::{native_pty_system, Child, CommandBuilder, MasterPty, PtySize};
use std::collections::HashMap;
use std::io::{Read, Write};
use std::sync::Mutex;
use tauri::{Emitter, Manager};

static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);

struct Terminal {
    /// which shell of the window's it is: one started again replaces it
    id: u64,
    master: Box<dyn MasterPty + Send>,
    writer: Box<dyn Write + Send>,
    child: Box<dyn Child + Send + Sync>,
}

/// The shells, by their window's label.
#[derive(Default)]
pub struct Terminals(Mutex<HashMap<String, Terminal>>);

fn size(cols: u16, rows: u16) -> PtySize {
    PtySize { rows: rows.max(1), cols: cols.max(1), pixel_width: 0, pixel_height: 0 }
}

/// ReTerm's zsh files (zsh/): the user's own are read through them, and the marks around each command added.
fn zsh_files(app: &tauri::AppHandle) -> Option<std::path::PathBuf> {
    let dir = app.path().app_data_dir().ok()?.join("zsh");
    std::fs::create_dir_all(&dir).ok()?;
    for (name, text) in [
        (".zshenv", include_str!("zsh/zshenv")),
        (".zprofile", include_str!("zsh/zprofile")),
        (".zshrc", include_str!("zsh/zshrc")),
        (".zlogin", include_str!("zsh/zlogin")),
    ] {
        std::fs::write(dir.join(name), text).ok()?;
    }
    Some(dir)
}

/// The window's shell, started at the page's size (a page loaded again starts a new one). `chat`: each
/// command to be shown as a message (zsh only, its marks); whether it is.
#[tauri::command]
pub fn pty_open(webview: tauri::Webview, terminals: tauri::State<Terminals>, cols: u16, rows: u16, chat: bool) -> Result<bool, String> {
    let label = webview.label().to_string();
    if let Some(mut old) = terminals.0.lock().unwrap().remove(&label) {
        let _ = old.child.kill();
    }

    let pair = native_pty_system().openpty(size(cols, rows)).map_err(|e| e.to_string())?;
    let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/zsh".into());
    let mut command = CommandBuilder::new(&shell);
    // a login shell, as Terminal opens one: the user's profile is read
    command.arg("-l");
    if let Some(home) = dirs::home_dir() {
        command.cwd(home);
    }
    command.env("TERM", "xterm-256color");
    command.env("COLORTERM", "truecolor");
    command.env("TERM_PROGRAM", "ReTerm");
    // opened from the Dock an app has no LANG: without it the shell can't write anything but ASCII
    if std::env::var("LANG").map(|l| l.is_empty()).unwrap_or(true) {
        command.env("LANG", "en_US.UTF-8");
    }
    let mut marked = false;
    if chat && shell.rsplit('/').next() == Some("zsh") {
        if let Some(dir) = zsh_files(webview.app_handle()) {
            let user = std::env::var("ZDOTDIR").ok().filter(|d| !d.is_empty())
                .or_else(|| dirs::home_dir().map(|h| h.to_string_lossy().into_owned()))
                .unwrap_or_default();
            command.env("RETERM_USER_ZDOTDIR", user);
            command.env("ZDOTDIR", dir);
            marked = true;
        }
    }
    let child = pair.slave.spawn_command(command).map_err(|e| e.to_string())?;
    drop(pair.slave);

    let mut reader = pair.master.try_clone_reader().map_err(|e| e.to_string())?;
    let writer = pair.master.take_writer().map_err(|e| e.to_string())?;
    let app = webview.app_handle().clone();
    let to = label.clone();
    let id = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    std::thread::spawn(move || {
        let mut buffer = [0u8; 65536];
        // the start of a character the last read cut off
        let mut held: Vec<u8> = Vec::new();
        loop {
            let n = match reader.read(&mut buffer) {
                Ok(0) | Err(_) => break,
                Ok(n) => n,
            };
            held.extend_from_slice(&buffer[..n]);
            let whole = match std::str::from_utf8(&held) {
                Ok(_) => held.len(),
                // cut off at the end: kept for the next read; broken inside: written as it is
                Err(e) if e.error_len().is_none() => e.valid_up_to(),
                Err(_) => held.len(),
            };
            let text = String::from_utf8_lossy(&held[..whole]).into_owned();
            held.drain(..whole);
            if !text.is_empty() {
                let _ = app.emit_to(&to, "pty-data", text);
            }
        }
        // ended by itself (not replaced, not its window gone): the window closes
        let mine = app.state::<Terminals>().0.lock().unwrap().get(&to).is_some_and(|t| t.id == id);
        if mine {
            let _ = app.emit_to(&to, "pty-exit", ());
        }
    });

    terminals.0.lock().unwrap().insert(label, Terminal { id, master: pair.master, writer, child });
    Ok(marked)
}

/// What was typed (or pasted), to the shell.
#[tauri::command]
pub fn pty_write(webview: tauri::Webview, terminals: tauri::State<Terminals>, data: String) -> Result<(), String> {
    let mut all = terminals.0.lock().unwrap();
    let terminal = all.get_mut(webview.label()).ok_or("No shell")?;
    terminal.writer.write_all(data.as_bytes()).map_err(|e| e.to_string())?;
    terminal.writer.flush().map_err(|e| e.to_string())
}

/// The page's new size, in characters.
#[tauri::command]
pub fn pty_resize(webview: tauri::Webview, terminals: tauri::State<Terminals>, cols: u16, rows: u16) -> Result<(), String> {
    let all = terminals.0.lock().unwrap();
    let terminal = all.get(webview.label()).ok_or("No shell")?;
    terminal.master.resize(size(cols, rows)).map_err(|e| e.to_string())
}

/// The window is gone: its shell ends.
pub fn close_window(window: &tauri::Window) {
    let terminals = window.state::<Terminals>();
    if let Some(mut terminal) = terminals.0.lock().unwrap().remove(window.label()) {
        let _ = terminal.child.kill();
    }
}

/// The commands typed before (zsh's history, oldest first, each once: where it was last).
#[tauri::command]
pub fn history() -> Vec<String> {
    let Some(path) = dirs::home_dir().map(|h| h.join(".zsh_history")) else { return vec![] };
    let Ok(bytes) = std::fs::read(path) else { return vec![] };
    // zsh "metafies" some bytes: 0x83 and the next one xor 32
    let mut plain = Vec::with_capacity(bytes.len());
    let mut it = bytes.into_iter();
    while let Some(b) = it.next() {
        if b == 0x83 {
            if let Some(n) = it.next() {
                plain.push(n ^ 32);
            }
        } else {
            plain.push(b);
        }
    }
    let text = String::from_utf8_lossy(&plain);
    let mut all: Vec<String> = Vec::new();
    let mut current = String::new();
    for line in text.lines() {
        if current.is_empty() {
            // ": 1700000000:0;the command" (extended history), or just the command
            let line = if line.starts_with(": ") { line.split_once(';').map(|(_, c)| c).unwrap_or(line) } else { line };
            current.push_str(line);
        } else {
            current.push('\n');
            current.push_str(line);
        }
        // a line ending with a backslash goes on
        if current.ends_with('\\') {
            current.pop();
            continue;
        }
        if !current.trim().is_empty() {
            all.push(std::mem::take(&mut current));
        }
        current.clear();
    }
    let mut seen = std::collections::HashSet::new();
    let mut kept: Vec<String> = all.into_iter().rev().filter(|c| seen.insert(c.clone())).take(5000).collect();
    kept.reverse();
    kept
}

/// Tab: what the word being typed can become. The first word of the line: the commands on the PATH (and
/// folders); any other: the files and folders it starts. Each written whole, as it goes into the line.
#[tauri::command]
pub fn complete(cwd: String, word: String, command: bool, path: String) -> Vec<String> {
    let escape = |name: &str| {
        let mut out = String::new();
        for c in name.chars() {
            if " '\"()&;|<>$`\\!*?[]#{}".contains(c) {
                out.push('\\');
            }
            out.push(c);
        }
        out
    };
    let unescaped = {
        let mut out = String::new();
        let mut chars = word.chars();
        while let Some(c) = chars.next() {
            if c == '\\' {
                if let Some(n) = chars.next() {
                    out.push(n);
                }
            } else {
                out.push(c);
            }
        }
        out
    };
    let mut found = std::collections::BTreeSet::new();
    if command && !unescaped.contains('/') {
        for dir in path.split(':').filter(|d| !d.is_empty()) {
            let Ok(entries) = std::fs::read_dir(dir) else { continue };
            for entry in entries.flatten() {
                let name = entry.file_name().to_string_lossy().into_owned();
                if name.starts_with(&unescaped) {
                    found.insert(escape(&name));
                }
            }
        }
    }
    // the folder it is in, as typed (kept), and the start of the name
    let (folder, start) = match word.rfind('/') {
        Some(i) => (&word[..=i], unescaped.rsplit('/').next().unwrap_or("")),
        None => ("", unescaped.as_str()),
    };
    let unescaped_folder = &unescaped[..unescaped.len() - start.len()];
    let mut base = std::path::PathBuf::from(&cwd);
    if let Some(rest) = unescaped_folder.strip_prefix('~') {
        if let Some(home) = dirs::home_dir() {
            base = home.join(rest.trim_start_matches('/'));
        }
    } else if !unescaped_folder.is_empty() {
        base = base.join(unescaped_folder);
    }
    if let Ok(entries) = std::fs::read_dir(&base) {
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            if !name.starts_with(start) || (name.starts_with('.') && !start.starts_with('.')) {
                continue;
            }
            let dir = std::fs::metadata(entry.path()).map(|m| m.is_dir()).unwrap_or(false);
            if command && !dir && folder.is_empty() {
                continue;
            }
            found.insert(format!("{folder}{}{}", escape(&name), if dir { "/" } else { "" }));
        }
    }
    found.into_iter().take(300).collect()
}

/// The home folder, for the place shown under the conversation (~ for it).
#[tauri::command]
pub fn home_dir() -> String {
    dirs::home_dir().map(|h| h.to_string_lossy().into_owned()).unwrap_or_default()
}
