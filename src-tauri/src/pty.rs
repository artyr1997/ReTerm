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

/// The window's shell, started at the page's size (a page loaded again starts a new one).
#[tauri::command]
pub fn pty_open(webview: tauri::Webview, terminals: tauri::State<Terminals>, cols: u16, rows: u16) -> Result<(), String> {
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
    Ok(())
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
