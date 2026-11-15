use sha2::{Digest, Sha256};
use std::{
    env, fs,
    path::{Path, PathBuf},
    process::Command,
};

fn main() {
    println!("cargo:rerun-if-env-changed=CHTA_PAYLOAD_PATH");
    println!("cargo:rerun-if-env-changed=CHTA_RELEASE_VERSION");
    let out = PathBuf::from(env::var_os("OUT_DIR").unwrap());
    let version = env::var("CHTA_RELEASE_VERSION").unwrap_or_else(|_| "0.0.1+0".into());
    assert!(
        version
            .bytes()
            .all(|v| v.is_ascii_alphanumeric() || b".+-_".contains(&v)),
        "Invalid release version"
    );
    let body = if let Some(source) = env::var_os("CHTA_PAYLOAD_PATH") {
        let source = fs::canonicalize(source).expect("Desktop payload is missing");
        println!("cargo:rerun-if-changed={}", source.display());
        let payload = fs::read(&source).expect("Could not read desktop payload");
        format!(
            "const PAYLOAD: &[u8] = include_bytes!({:?});\nconst PAYLOAD_HASH: &str = {:?};\nconst RELEASE_VERSION: &str = {:?};",
            source,
            format!("{:x}", Sha256::digest(payload)),
            version
        )
    } else {
        assert_ne!(
            env::var("PROFILE").unwrap(),
            "release",
            "Release requires CHTA_PAYLOAD_PATH"
        );
        "const PAYLOAD: &[u8] = &[]; const PAYLOAD_HASH: &str = \"\"; const RELEASE_VERSION: &str = \"development\";".into()
    };
    fs::write(out.join("payload.rs"), body).unwrap();
    if env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("windows")
        && env::var("PROFILE").as_deref() == Ok("release")
    {
        resource(&out, &version);
    }
}
fn resource(out: &Path, version: &str) {
    let root = PathBuf::from(env::var_os("CARGO_MANIFEST_DIR").unwrap()).join("../../..");
    let icon =
        fs::canonicalize(root.join("apps/flutter_app/windows/runner/resources/app_icon.ico"))
            .unwrap();
    let numeric: Vec<u16> = version
        .split(|v: char| !v.is_ascii_digit())
        .filter(|v| !v.is_empty())
        .map(|v| v.parse().expect("Version component exceeds 65535"))
        .collect();
    assert_eq!(numeric.len(), 4, "Use major.minor.patch+build");
    let numbers = numeric
        .iter()
        .map(u16::to_string)
        .collect::<Vec<_>>()
        .join(",");
    let rc = format!(
        r#"1 ICON "{}"
1 VERSIONINFO
FILEVERSION {numbers}
PRODUCTVERSION {numbers}
FILEFLAGSMASK 0x3fL
FILEFLAGS 0x0L
FILEOS 0x40004L
FILETYPE 0x1L
BEGIN
 BLOCK "StringFileInfo"
 BEGIN
  BLOCK "040904e4"
  BEGIN
   VALUE "FileDescription", "chta\0"
   VALUE "ProductName", "chta\0"
   VALUE "InternalName", "chta\0"
   VALUE "OriginalFilename", "chta.exe\0"
   VALUE "FileVersion", "{version}\0"
   VALUE "ProductVersion", "{version}\0"
  END
 END
 BLOCK "VarFileInfo"
 BEGIN
  VALUE "Translation", 0x409, 1252
 END
END
"#,
        icon.to_string_lossy().replace('\\', "\\\\")
    );
    let rc_path = out.join("launcher.rc");
    fs::write(&rc_path, rc).unwrap();
    let base = PathBuf::from(
        env::var_os("ProgramFiles(x86)").unwrap_or_else(|| "C:\\Program Files (x86)".into()),
    )
    .join("Windows Kits/10/bin");
    let mut compilers: Vec<_> = fs::read_dir(base)
        .unwrap()
        .filter_map(|entry| entry.ok().map(|entry| entry.path().join("x64/rc.exe")))
        .filter(|path| path.is_file())
        .collect();
    compilers.sort();
    let compiler = compilers
        .last()
        .expect("Install Windows SDK to package the app icon");
    let resource = out.join("launcher.res");
    assert!(
        Command::new(compiler)
            .arg("/nologo")
            .arg("/fo")
            .arg(&resource)
            .arg(&rc_path)
            .status()
            .unwrap()
            .success(),
        "Resource compilation failed"
    );
    println!("cargo:rustc-link-arg={}", resource.display());
    println!("cargo:rerun-if-changed={}", icon.display());
}
