#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]
use std::{
    env,
    path::PathBuf,
    process::{self, Command},
};
include!(concat!(env!("OUT_DIR"), "/payload.rs"));

fn launch() -> chta_launcher::Result<i32> {
    let base = env::var_os("LOCALAPPDATA").ok_or("LOCALAPPDATA is unavailable")?;
    let runtime = chta_launcher::install_runtime(
        PAYLOAD,
        PAYLOAD_HASH,
        &PathBuf::from(base).join("chta/runtime"),
    )?;
    let entrypoint = runtime.join("chta.exe");
    let args: Vec<_> = env::args_os().skip(1).collect();
    if args.first().is_some_and(|arg| arg == "--check-runtime") {
        let report = serde_json::json!({"ok":true,"version":RELEASE_VERSION,"runtime":runtime,"entrypoint":entrypoint});
        if let Some(output) = args.get(1) {
            std::fs::write(output, serde_json::to_vec(&report)?)?;
        } else {
            println!("{report}");
        }
        return Ok(0);
    }
    if fs_same(&entrypoint, &env::current_exe()?) {
        return Err("Launcher cannot contain itself as the desktop runtime".into());
    }
    let status = Command::new(&entrypoint)
        .current_dir(&runtime)
        .args(args)
        .status()?;
    Ok(status.code().unwrap_or(1))
}
fn fs_same(a: &std::path::Path, b: &std::path::Path) -> bool {
    std::fs::canonicalize(a).ok() == std::fs::canonicalize(b).ok()
}
fn main() {
    match launch() {
        Ok(code) => process::exit(code),
        Err(error) => {
            let message = format!("Could not open chta.\n\n{error}");
            #[cfg(windows)]
            unsafe {
                use windows_sys::Win32::UI::WindowsAndMessaging::{
                    MB_ICONERROR, MB_OK, MessageBoxW,
                };
                let text: Vec<u16> = message.encode_utf16().chain(Some(0)).collect();
                let title: Vec<u16> = "chta".encode_utf16().chain(Some(0)).collect();
                MessageBoxW(
                    std::ptr::null_mut(),
                    text.as_ptr(),
                    title.as_ptr(),
                    MB_OK | MB_ICONERROR,
                );
            }
            #[cfg(not(windows))]
            eprintln!("{message}");
            process::exit(1);
        }
    }
}
