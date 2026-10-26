//! Cross-platform helpers: paths, sizes, trash, shell, admin elevation, progress events.

use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::UNIX_EPOCH;
use tauri::{AppHandle, Emitter};
use walkdir::WalkDir;

// ---------------------------------------------------------------- models

#[derive(Serialize, Deserialize, Clone, Default, Debug)]
pub struct Badge {
    pub text: String,
    pub color: String,
}

pub fn badge(text: impl Into<String>, color: &str) -> Badge {
    Badge { text: text.into(), color: color.into() }
}

/// A row the UI can show with a checkbox, a size and a "reveal" button.
#[derive(Serialize, Deserialize, Clone, Default, Debug)]
pub struct Item {
    pub id: String,
    pub name: String,
    pub detail: String,
    pub paths: Vec<String>,
    pub size: u64,
    pub selected: bool,
    #[serde(default)]
    pub badges: Vec<Badge>,
    #[serde(default)]
    pub meta: serde_json::Value,
}

impl Item {
    pub fn new(path: &Path, name: impl Into<String>, detail: impl Into<String>, size: u64, selected: bool) -> Self {
        let p = path.to_string_lossy().to_string();
        Item { id: p.clone(), name: name.into(), detail: detail.into(), paths: vec![p], size, selected, ..Default::default() }
    }
    pub fn from_path(path: &Path, selected: bool) -> Self {
        let size = size_of(path);
        Item::new(path, file_name(path), tilde(&parent_str(path)), size, selected)
    }
    pub fn with_badge(mut self, text: &str, color: &str) -> Self {
        self.badges.push(badge(text, color));
        self
    }
}

#[derive(Serialize, Clone, Debug)]
pub struct Category {
    pub id: String,
    pub name: String,
    pub icon: String,
    pub info: String,
    pub items: Vec<Item>,
}

impl Category {
    pub fn new(id: &str, name: &str, icon: &str, info: &str, mut items: Vec<Item>) -> Option<Self> {
        items.retain(|i| i.size > 0 || !i.badges.is_empty());
        if items.is_empty() {
            return None;
        }
        items.sort_by(|a, b| b.size.cmp(&a.size));
        Some(Category { id: id.into(), name: name.into(), icon: icon.into(), info: info.into(), items })
    }
}

// ---------------------------------------------------------------- paths

pub fn home() -> PathBuf {
    dirs::home_dir().unwrap_or_else(|| PathBuf::from("."))
}

/// Path relative to the home folder ("Downloads", ".cache/pip", …).
pub fn hp(rel: &str) -> PathBuf {
    let mut p = home();
    for part in rel.split('/') {
        if !part.is_empty() {
            p.push(part);
        }
    }
    p
}

pub fn join(base: &Path, rel: &str) -> PathBuf {
    let mut p = base.to_path_buf();
    for part in rel.split('/') {
        if !part.is_empty() {
            p.push(part);
        }
    }
    p
}

/// Windows %LOCALAPPDATA% / %APPDATA% / %PROGRAMDATA% (None elsewhere).
pub fn win_env(var: &str, rel: &str) -> Option<PathBuf> {
    if !cfg!(windows) {
        return None;
    }
    std::env::var_os(var).map(|v| join(&PathBuf::from(v), rel))
}
pub fn local_appdata(rel: &str) -> Option<PathBuf> {
    win_env("LOCALAPPDATA", rel)
}
pub fn appdata(rel: &str) -> Option<PathBuf> {
    win_env("APPDATA", rel)
}

/// OS cache dir (~/Library/Caches, ~/.cache, %LOCALAPPDATA%).
pub fn cache(rel: &str) -> PathBuf {
    join(&dirs::cache_dir().unwrap_or_else(|| hp(".cache")), rel)
}
/// OS config dir (~/Library/Application Support, ~/.config, %APPDATA%).
pub fn config(rel: &str) -> PathBuf {
    join(&dirs::config_dir().unwrap_or_else(|| hp(".config")), rel)
}
/// OS data dir (~/Library/Application Support, ~/.local/share, %APPDATA%).
pub fn data(rel: &str) -> PathBuf {
    join(&dirs::data_dir().unwrap_or_else(|| hp(".local/share")), rel)
}
/// OS local data dir (~/Library/Application Support, ~/.local/share, %LOCALAPPDATA%).
pub fn data_local(rel: &str) -> PathBuf {
    join(&dirs::data_local_dir().unwrap_or_else(|| hp(".local/share")), rel)
}

pub fn tilde(s: &str) -> String {
    let h = home().to_string_lossy().to_string();
    if s.starts_with(&h) {
        format!("~{}", &s[h.len()..])
    } else {
        s.to_string()
    }
}

pub fn file_name(p: &Path) -> String {
    p.file_name().map(|s| s.to_string_lossy().to_string()).unwrap_or_else(|| p.to_string_lossy().to_string())
}

pub fn parent_str(p: &Path) -> String {
    p.parent().map(|x| x.to_string_lossy().to_string()).unwrap_or_default()
}

pub fn exists(p: &Path) -> bool {
    std::fs::symlink_metadata(p).is_ok()
}

pub fn is_dir(p: &Path) -> bool {
    std::fs::metadata(p).map(|m| m.is_dir()).unwrap_or(false)
}

pub fn is_symlink(p: &Path) -> bool {
    std::fs::symlink_metadata(p).map(|m| m.file_type().is_symlink()).unwrap_or(false)
}

pub fn children(p: &Path) -> Vec<PathBuf> {
    std::fs::read_dir(p).map(|rd| rd.filter_map(|e| e.ok().map(|e| e.path())).collect()).unwrap_or_default()
}

pub fn ext(p: &Path) -> String {
    p.extension().map(|e| e.to_string_lossy().to_lowercase()).unwrap_or_default()
}

pub fn secs(t: std::io::Result<std::time::SystemTime>) -> Option<u64> {
    t.ok().and_then(|t| t.duration_since(UNIX_EPOCH).ok()).map(|d| d.as_secs())
}
pub fn mtime(p: &Path) -> Option<u64> {
    std::fs::metadata(p).ok().and_then(|m| secs(m.modified()))
}
pub fn atime(p: &Path) -> Option<u64> {
    std::fs::metadata(p).ok().and_then(|m| secs(m.accessed()))
}
pub fn now() -> u64 {
    std::time::SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}
pub fn days_since(t: Option<u64>) -> u64 {
    t.map(|t| now().saturating_sub(t) / 86400).unwrap_or(99999)
}

// ---------------------------------------------------------------- sizes

/// Bytes really used on disk (cloud-only placeholders count as 0).
pub fn alloc_size(m: &std::fs::Metadata) -> u64 {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        m.blocks() * 512
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        // OFFLINE | RECALL_ON_OPEN | RECALL_ON_DATA_ACCESS = OneDrive "online-only" files
        if m.file_attributes() & (0x1000 | 0x40000 | 0x400000) != 0 {
            0
        } else {
            m.len()
        }
    }
    #[cfg(not(any(unix, windows)))]
    {
        m.len()
    }
}

const VIRTUAL: [&str; 4] = ["/proc", "/sys", "/dev", "/run"];

pub fn size_of(p: &Path) -> u64 {
    if cfg!(target_os = "linux") && VIRTUAL.iter().any(|v| p == Path::new(v)) {
        return 0;
    }
    let m = match std::fs::symlink_metadata(p) {
        Ok(m) => m,
        Err(_) => return 0,
    };
    if m.file_type().is_symlink() {
        return 0;
    }
    if m.is_file() {
        return alloc_size(&m);
    }
    WalkDir::new(p)
        .follow_links(false)
        .same_file_system(true)
        .into_iter()
        .filter_map(|e| e.ok())
        .filter(|e| e.file_type().is_file())
        .filter_map(|e| e.metadata().ok())
        .map(|m| alloc_size(&m))
        .sum()
}

pub fn sizes(paths: &[PathBuf]) -> Vec<u64> {
    use rayon::prelude::*;
    paths.par_iter().map(|p| size_of(p)).collect()
}

/// Items for every existing path, computed in parallel.
pub fn items_for(paths: Vec<PathBuf>, selected: bool) -> Vec<Item> {
    let ex: Vec<PathBuf> = paths.into_iter().filter(|p| exists(p)).collect();
    let s = sizes(&ex);
    ex.iter().zip(s).map(|(p, s)| Item::new(p, file_name(p), tilde(&parent_str(p)), s, selected)).collect()
}

/// Same, with a friendly name for each path.
pub fn named_items(list: Vec<(PathBuf, String, String)>, selected: bool) -> Vec<Item> {
    let ex: Vec<(PathBuf, String, String)> = list.into_iter().filter(|(p, _, _)| exists(p)).collect();
    let paths: Vec<PathBuf> = ex.iter().map(|x| x.0.clone()).collect();
    let s = sizes(&paths);
    ex.into_iter().zip(s).map(|((p, n, d), s)| Item::new(&p, n, d, s, selected)).collect()
}

// ---------------------------------------------------------------- walking

pub const SKIP_NAMES: [&str; 18] = [
    "node_modules", ".git", "site-packages", "__pycache__", ".Trash", ".npm", ".rustup", ".cargo", ".ollama",
    ".docker", ".gradle", ".m2", "DerivedData", "$Recycle.Bin", ".Trash-1000", ".venv-cache", "System Volume Information",
    ".cache",
];

/// Top-level folders of the home that never hold projects.
pub fn home_skips() -> Vec<PathBuf> {
    ["Library", "AppData", ".Trash", "Music", "Pictures", "Movies", "Videos", "Applications", ".var", "snap",
     ".local/share/Trash", ".local/share/Steam", ".steam", ".wine"]
        .iter()
        .map(|r| hp(r))
        .collect()
}

/// Finds folders matching `matcher` (without descending into them).
pub fn find_dirs(roots: &[PathBuf], skip_names: &[&str], skip_paths: &[PathBuf], mut tick: impl FnMut(&Path), mut matcher: impl FnMut(&Path) -> bool) -> Vec<PathBuf> {
    let mut out = vec![];
    let mut n = 0u64;
    for root in roots {
        let mut it = WalkDir::new(root).follow_links(false).into_iter();
        loop {
            let e = match it.next() {
                None => break,
                Some(Err(_)) => continue,
                Some(Ok(e)) => e,
            };
            if !e.file_type().is_dir() {
                continue;
            }
            let p = e.path();
            if e.depth() > 0 {
                if matcher(p) {
                    out.push(p.to_path_buf());
                    it.skip_current_dir();
                    continue;
                }
                let name = e.file_name().to_string_lossy();
                if skip_names.iter().any(|s| *s == name) || skip_paths.iter().any(|s| s == p) {
                    it.skip_current_dir();
                    continue;
                }
            }
            n += 1;
            if n % 300 == 0 {
                tick(p);
            }
        }
    }
    out
}

// ---------------------------------------------------------------- progress

pub fn progress(app: &AppHandle, module: &str, text: &str, bytes: u64) {
    let _ = app.emit("progress", serde_json::json!({ "module": module, "text": tilde(text), "bytes": bytes }));
}

// ---------------------------------------------------------------- shell

fn command(bin: &str) -> Command {
    #[allow(unused_mut)]
    let mut c = Command::new(bin);
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        c.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
    }
    c.env("PATH", extended_path());
    c
}

/// GUI apps get a minimal PATH on macOS/Linux; add the usual tool folders.
pub fn extended_path() -> String {
    let cur = std::env::var("PATH").unwrap_or_default();
    if cfg!(windows) {
        return cur;
    }
    let extra = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin", "/snap/bin",
                 "/home/linuxbrew/.linuxbrew/bin"];
    let mut parts: Vec<String> = cur.split(':').map(String::from).collect();
    for e in extra {
        if !parts.iter().any(|p| p == e) {
            parts.push(e.to_string());
        }
    }
    for rel in [".local/bin", ".cargo/bin", ".pyenv/bin", ".bun/bin"] {
        parts.push(hp(rel).to_string_lossy().to_string());
    }
    parts.join(":")
}

pub fn which(name: &str) -> Option<PathBuf> {
    let sep = if cfg!(windows) { ';' } else { ':' };
    let exts: Vec<String> = if cfg!(windows) {
        vec![".exe".into(), ".cmd".into(), ".bat".into(), "".into()]
    } else {
        vec!["".into()]
    };
    let mut dirs: Vec<PathBuf> = extended_path().split(sep).map(PathBuf::from).collect();
    if cfg!(windows) {
        if let Some(p) = local_appdata("Microsoft/WindowsApps") {
            dirs.push(p);
        }
        dirs.push(hp("scoop/shims"));
        dirs.push(PathBuf::from("C:/ProgramData/chocolatey/bin"));
        dirs.push(hp(".cargo/bin"));
        dirs.push(hp(".local/bin"));
    }
    for d in dirs {
        for e in &exts {
            let c = d.join(format!("{name}{e}"));
            if c.is_file() {
                return Some(c);
            }
        }
    }
    None
}

pub fn run(bin: &str, args: &[&str]) -> (i32, String) {
    let path = if Path::new(bin).is_absolute() { Some(PathBuf::from(bin)) } else { which(bin) };
    let Some(path) = path else { return (-1, format!("{bin} introuvable")) };
    match command(&path.to_string_lossy()).args(args).output() {
        Ok(o) => {
            let mut s = String::from_utf8_lossy(&o.stdout).to_string();
            s.push_str(&String::from_utf8_lossy(&o.stderr));
            (o.status.code().unwrap_or(-1), s)
        }
        Err(e) => (-1, e.to_string()),
    }
}

/// Runs a shell command line (sh on Unix, PowerShell on Windows).
pub fn sh(cmd: &str) -> (i32, String) {
    if cfg!(windows) {
        run("powershell", &["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", cmd])
    } else {
        run("/bin/sh", &["-c", cmd])
    }
}

/// Runs a command with administrator rights (password prompt / UAC).
pub fn admin(cmd: &str) -> (i32, String) {
    if cfg!(target_os = "macos") {
        let esc = cmd.replace('\\', "\\\\").replace('"', "\\\"");
        run("/usr/bin/osascript", &["-e", &format!("do shell script \"{esc}\" with administrator privileges")])
    } else if cfg!(windows) {
        let esc = cmd.replace('\'', "''");
        sh(&format!("$p = Start-Process -FilePath cmd.exe -ArgumentList '/c {esc}' -Verb RunAs -Wait -PassThru -WindowStyle Hidden; exit $p.ExitCode"))
    } else if which("pkexec").is_some() {
        run("pkexec", &["/bin/sh", "-c", cmd])
    } else {
        (-1, "pkexec est introuvable : impossible d'obtenir les droits administrateur.".into())
    }
}

pub fn quote(s: &str) -> String {
    if cfg!(windows) {
        format!("\"{}\"", s.replace('"', "\\\""))
    } else {
        format!("'{}'", s.replace('\'', "'\\''"))
    }
}

pub fn lines(s: &str) -> Vec<String> {
    s.lines().map(|l| l.trim_end().to_string()).filter(|l| !l.trim().is_empty()).collect()
}

pub fn os_name() -> &'static str {
    if cfg!(windows) {
        "windows"
    } else if cfg!(target_os = "macos") {
        "macos"
    } else {
        "linux"
    }
}

// ---------------------------------------------------------------- trash

#[derive(Serialize)]
pub struct TrashResult {
    pub freed: u64,
    pub moved: usize,
    pub errors: Vec<String>,
}

pub fn trash_many(paths: &[(PathBuf, Option<u64>)]) -> TrashResult {
    let mut r = TrashResult { freed: 0, moved: 0, errors: vec![] };
    for (p, size) in paths {
        if !exists(p) {
            continue;
        }
        let s = size.unwrap_or_else(|| size_of(p));
        match trash::delete(p) {
            Ok(_) => {
                r.freed += s;
                r.moved += 1;
            }
            Err(e) => r.errors.push(format!("{} : {}", file_name(p), e)),
        }
    }
    crate::settings::add_freed(r.freed);
    r
}

#[tauri::command]
pub async fn trash_paths(paths: Vec<String>, sizes: Option<Vec<u64>>) -> TrashResult {
    tauri::async_runtime::spawn_blocking(move || {
        let list: Vec<(PathBuf, Option<u64>)> = paths
            .iter()
            .enumerate()
            .map(|(i, p)| (PathBuf::from(p), sizes.as_ref().and_then(|s| s.get(i).copied())))
            .collect();
        trash_many(&list)
    })
    .await
    .unwrap_or(TrashResult { freed: 0, moved: 0, errors: vec!["erreur interne".into()] })
}

#[derive(Serialize)]
pub struct TrashInfo {
    size: Option<u64>,
    count: Option<usize>,
}

#[tauri::command]
pub async fn trash_info() -> TrashInfo {
    tauri::async_runtime::spawn_blocking(|| {
        if cfg!(target_os = "macos") {
            TrashInfo { size: Some(size_of(&hp(".Trash"))), count: None }
        } else if cfg!(target_os = "linux") {
            TrashInfo { size: Some(size_of(&hp(".local/share/Trash"))), count: None }
        } else {
            #[cfg(any(windows, all(unix, not(target_os = "macos"))))]
            {
                return TrashInfo { size: None, count: trash::os_limited::list().ok().map(|l| l.len()) };
            }
            #[allow(unreachable_code)]
            TrashInfo { size: None, count: None }
        }
    })
    .await
    .unwrap_or(TrashInfo { size: None, count: None })
}

#[tauri::command]
pub async fn empty_trash() -> Result<(), String> {
    tauri::async_runtime::spawn_blocking(|| {
        #[cfg(target_os = "macos")]
        {
            let (c, o) = run("/usr/bin/osascript", &["-e", "tell application \"Finder\" to empty trash"]);
            return if c == 0 { Ok(()) } else { Err(o) };
        }
        #[cfg(not(target_os = "macos"))]
        {
            let items = trash::os_limited::list().map_err(|e| e.to_string())?;
            trash::os_limited::purge_all(items).map_err(|e| e.to_string())
        }
    })
    .await
    .map_err(|e| e.to_string())?
}

// ---------------------------------------------------------------- misc commands

#[derive(Serialize)]
pub struct PlatformInfo {
    os: &'static str,
    home: String,
    user: String,
    cloud: Option<String>,
    hostname: String,
}

#[tauri::command]
pub fn platform_info() -> PlatformInfo {
    let user = std::env::var("USER").or_else(|_| std::env::var("USERNAME")).unwrap_or_default();
    PlatformInfo {
        os: os_name(),
        home: home().to_string_lossy().to_string(),
        user,
        cloud: crate::storage::cloud_root().map(|(name, _)| name.to_string()),
        hostname: sysinfo::System::host_name().unwrap_or_default(),
    }
}

#[tauri::command]
pub fn open_terminal(path: String) -> Result<(), String> {
    let r = if cfg!(target_os = "macos") {
        run("/usr/bin/open", &["-a", "Terminal", &path])
    } else if cfg!(windows) {
        if which("wt").is_some() {
            run("wt", &["-d", &path])
        } else {
            sh(&format!("Start-Process powershell -WorkingDirectory {}", quote(&path)))
        }
    } else {
        let mut res = (-1, String::from("Aucun terminal trouvé"));
        for t in ["x-terminal-emulator", "gnome-terminal", "konsole", "xfce4-terminal", "kitty", "alacritty", "xterm"] {
            if let Some(b) = which(t) {
                let ok = Command::new(b).current_dir(&path).spawn().is_ok();
                if ok {
                    res = (0, String::new());
                    break;
                }
            }
        }
        res
    };
    if r.0 == 0 { Ok(()) } else { Err(r.1) }
}

#[tauri::command]
pub fn open_path(path: String) -> Result<(), String> {
    let r = if cfg!(target_os = "macos") {
        run("/usr/bin/open", &[&path])
    } else if cfg!(windows) {
        run("explorer", &[&path])
    } else {
        Command::new("xdg-open").arg(&path).spawn().map(|_| (0, String::new())).unwrap_or((-1, "xdg-open".into()))
    };
    if r.0 == 0 || cfg!(windows) { Ok(()) } else { Err(r.1) }
}
