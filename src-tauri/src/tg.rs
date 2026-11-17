//! HOMO: Telegram, through TDLib (Telegram's own library: `brew install tdlib`), loaded when first asked for.
//! One client for the app; what it says (JSON) goes to every window as a `tg` event, and the windows ask it
//! by tg_send (JSON, an "@extra" of their own to know their answers). Its database is kept in
//! Application Support/…/telegram, so the account stays signed in.

use libloading::{Library, Symbol};
use std::ffi::{c_char, c_int, CStr, CString};
use std::sync::OnceLock;
use tauri::{Emitter, Manager};

struct Td {
    _lib: &'static Library,
    client: c_int,
    send: unsafe extern "C" fn(c_int, *const c_char),
}

// SAFETY: TDLib's JSON interface may be used from any thread
unsafe impl Send for Td {}
unsafe impl Sync for Td {}

static TD: OnceLock<Result<Td, String>> = OnceLock::new();

const PLACES: [&str; 3] = ["/opt/homebrew/lib/libtdjson.dylib", "/usr/local/lib/libtdjson.dylib", "libtdjson.dylib"];

fn start(app: &tauri::AppHandle) -> Result<Td, String> {
    let lib = PLACES
        .iter()
        .find_map(|p| unsafe { Library::new(p).ok() })
        .ok_or("TDLib isn't installed: brew install tdlib")?;
    // kept for the app's life: the functions point into it
    let lib: &'static Library = Box::leak(Box::new(lib));
    // SAFETY: TDLib's exported C functions, with their own signatures (td_json_client.h)
    let (client, send, receive) = unsafe {
        let create: Symbol<unsafe extern "C" fn() -> c_int> = lib.get(b"td_create_client_id").map_err(|e| e.to_string())?;
        let send: Symbol<unsafe extern "C" fn(c_int, *const c_char)> = lib.get(b"td_send").map_err(|e| e.to_string())?;
        let receive: Symbol<unsafe extern "C" fn(f64) -> *const c_char> = lib.get(b"td_receive").map_err(|e| e.to_string())?;
        let execute: Symbol<unsafe extern "C" fn(*const c_char) -> *const c_char> = lib.get(b"td_execute").map_err(|e| e.to_string())?;
        // quiet: only its errors in the log
        let quiet = CString::new(r#"{"@type":"setLogVerbosityLevel","new_verbosity_level":1}"#).unwrap();
        execute(quiet.as_ptr());
        (create(), *send, *receive)
    };
    let app = app.clone();
    std::thread::spawn(move || loop {
        // SAFETY: the text is TDLib's until the next td_receive: copied at once
        let text = unsafe { receive(5.0) };
        if text.is_null() {
            continue;
        }
        let json = unsafe { CStr::from_ptr(text) }.to_string_lossy().into_owned();
        let _ = app.emit("tg", json);
    });
    Ok(Td { _lib: lib, client, send })
}

/// TDLib started (once), and where it keeps its database; an error if it isn't installed.
#[tauri::command]
pub fn tg_start(app: tauri::AppHandle) -> Result<String, String> {
    let td = TD.get_or_init(|| start(&app));
    td.as_ref().map_err(|e| e.clone())?;
    let dir = app.path().app_data_dir().map_err(|e| e.to_string())?.join("telegram");
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    Ok(dir.to_string_lossy().into_owned())
}

/// A request to TDLib (JSON); its answer comes as a `tg` event.
#[tauri::command]
pub fn tg_send(json: String) -> Result<(), String> {
    let td = TD.get().ok_or("Not started")?.as_ref().map_err(|e| e.clone())?;
    let text = CString::new(json).map_err(|e| e.to_string())?;
    // SAFETY: a live client of TDLib's, and a NUL-ended string it copies
    unsafe { (td.send)(td.client, text.as_ptr()) };
    Ok(())
}
