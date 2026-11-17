//! CHAT: a conversation with an LLM through its own command-line program, as installed and signed in
//! (claude: Claude Code; codex: ChatGPT's). Each message runs the program once (the conversation goes
//! on by its session); what it writes comes to the window line by line (`llm-line`), and `llm-done` when
//! it ends. They run in their own folder (Application Support/…/chat), with no tools: a conversation only.

use serde::Serialize;
use std::collections::HashMap;
use std::io::{BufRead, BufReader, Read, Write};
use std::process::{Child, Command, Stdio};
use std::sync::Mutex;
use tauri::{Emitter, Manager};

/// The programs running, by the message they answer.
#[derive(Default)]
pub struct Answers(Mutex<HashMap<u64, Child>>);

#[derive(Clone, Serialize)]
struct Line {
    id: u64,
    line: String,
}

#[derive(Clone, Serialize)]
struct Done {
    id: u64,
    code: i32,
    error: String,
}

/// The ones installed, of those it knows (found as the user's shell finds them).
#[tauri::command]
pub fn llm_available() -> Vec<String> {
    let out = Command::new("/bin/zsh")
        .args(["-lc", "for c in claude codex; do command -v $c >/dev/null 2>&1 && echo $c; done"])
        .stdin(Stdio::null())
        .output();
    out.map(|o| String::from_utf8_lossy(&o.stdout).lines().map(|l| l.trim().to_string()).filter(|l| l == "claude" || l == "codex").collect())
        .unwrap_or_default()
}

/// One message to `provider`, going on with `session` if there is one.
#[tauri::command]
pub fn llm_send(
    webview: tauri::Webview,
    answers: tauri::State<Answers>,
    id: u64,
    provider: String,
    prompt: String,
    session: Option<String>,
    model: Option<String>,
) -> Result<(), String> {
    let mut args: Vec<String> = match provider.as_str() {
        "claude" => {
            let mut a: Vec<String> = ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages", "--tools", "", "--strict-mcp-config"]
                .iter()
                .map(|s| s.to_string())
                .collect();
            if let Some(s) = session.filter(|s| !s.is_empty()) {
                a.extend(["--resume".into(), s]);
            }
            if let Some(m) = model.filter(|m| !m.is_empty()) {
                a.extend(["--model".into(), m]);
            }
            a
        }
        "codex" => {
            let mut a: Vec<String> = vec!["exec".into()];
            if let Some(s) = session.filter(|s| !s.is_empty()) {
                a.extend(["resume".into(), s]);
            }
            a.extend(["--skip-git-repo-check".into(), "--json".into(), "-".into()]);
            a
        }
        _ => return Err(format!("Unknown: {provider}")),
    };
    args.insert(0, provider.clone());

    let dir = webview.app_handle().path().app_data_dir().map_err(|e| e.to_string())?.join("chat");
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    // through the login shell: the PATH (nvm, Homebrew…) as in the terminal
    let mut child = Command::new("/bin/zsh")
        .arg("-lc")
        .arg("exec \"$@\"")
        .arg("reterm")
        .args(&args)
        .current_dir(&dir)
        // started from a Claude Code session, its own mark would stop claude here
        .env_remove("CLAUDECODE")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| e.to_string())?;
    // the message on its input, so nothing in it is taken for an option
    if let Some(mut stdin) = child.stdin.take() {
        let _ = stdin.write_all(prompt.as_bytes());
    }
    let stdout = child.stdout.take().ok_or("No output")?;
    let mut stderr = child.stderr.take().ok_or("No output")?;
    answers.0.lock().unwrap().insert(id, child);

    let app = webview.app_handle().clone();
    let label = webview.label().to_string();
    std::thread::spawn(move || {
        let errors = std::thread::spawn(move || {
            let mut text = String::new();
            let _ = stderr.read_to_string(&mut text);
            text
        });
        for line in BufReader::new(stdout).lines() {
            let Ok(line) = line else { break };
            let _ = app.emit_to(&label, "llm-line", Line { id, line });
        }
        let child = app.state::<Answers>().0.lock().unwrap().remove(&id);
        let code = child.and_then(|mut c| c.wait().ok()).and_then(|s| s.code()).unwrap_or(-1);
        let error = errors.join().unwrap_or_default();
        let error: String = error.lines().rev().take(6).collect::<Vec<_>>().into_iter().rev().collect::<Vec<_>>().join("\n");
        let _ = app.emit_to(&label, "llm-done", Done { id, code, error });
    });
    Ok(())
}

/// Stop the answer to `id`.
#[tauri::command]
pub fn llm_stop(answers: tauri::State<Answers>, id: u64) {
    if let Some(child) = answers.0.lock().unwrap().get_mut(&id) {
        let _ = child.kill();
    }
}
