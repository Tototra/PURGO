//! Installed applications and their leftovers, for each OS.

use crate::util::*;
use serde::Serialize;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

#[derive(Serialize, Clone, Debug, Default)]
pub struct App {
    pub id: String,
    pub name: String,
    pub version: String,
    pub publisher: String,
    pub source: String,
    pub size: u64,
    pub last_used: Option<u64>,
    pub installed: Option<u64>,
    pub path: Option<String>,
    #[serde(skip)]
    uninstall: String,
    #[serde(skip)]
    keys: Vec<String>,
}

static CACHE: Mutex<Vec<App>> = Mutex::new(vec![]);

fn parse_human(s: &str) -> u64 {
    let s = s.trim().replace(',', ".").replace('\u{a0}', " ");
    let mut num = String::new();
    let mut unit = String::new();
    for ch in s.chars() {
        if ch.is_ascii_digit() || ch == '.' { if unit.is_empty() { num.push(ch) } } else if !ch.is_whitespace() { unit.push(ch) }
    }
    let n: f64 = num.parse().unwrap_or(0.0);
    let m = match unit.to_lowercase().chars().next() { Some('k') => 1e3, Some('m') => 1e6, Some('g') => 1e9, Some('t') => 1e12, _ => 1.0 };
    (n * m) as u64
}

// ---------------------------------------------------------------- macOS

#[cfg(target_os = "macos")]
fn list_mac() -> Vec<App> {
    let mut urls = vec![];
    for root in [PathBuf::from("/Applications"), hp("Applications")] {
        for c in children(&root) {
            if ext(&c) == "app" { urls.push(c) } else if is_dir(&c) { urls.extend(children(&c).into_iter().filter(|x| ext(x) == "app")) }
        }
    }
    let s = sizes(&urls);
    urls.iter().zip(s).filter_map(|(u, size)| {
        let info = plist::Value::from_file(u.join("Contents/Info.plist")).ok()?;
        let d = info.as_dictionary()?;
        let id = d.get("CFBundleIdentifier").and_then(|v| v.as_string()).unwrap_or("").to_string();
        if id.starts_with("com.apple.") { return None; }
        let last = run("/usr/bin/mdls", &["-name", "kMDItemLastUsedDate", "-raw", &u.to_string_lossy()]).1;
        let last_used = parse_mdls_date(&last);
        Some(App {
            id: u.to_string_lossy().into(),
            name: file_name(u).trim_end_matches(".app").into(),
            version: d.get("CFBundleShortVersionString").and_then(|v| v.as_string()).unwrap_or("").into(),
            publisher: id.clone(),
            source: "Application".into(),
            size,
            last_used,
            installed: mtime(u),
            path: Some(u.to_string_lossy().into()),
            uninstall: "mac".into(),
            keys: vec![id, file_name(u).trim_end_matches(".app").into()],
        })
    }).collect()
}

#[cfg(target_os = "macos")]
fn parse_mdls_date(s: &str) -> Option<u64> {
    // "2026-10-20 14:02:11 +0000"
    let re = regex::Regex::new(r"(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})").ok()?;
    let c = re.captures(s)?;
    let n = |i: usize| c[i].parse::<i64>().unwrap_or(0);
    Some(days_from_civil(n(1), n(2), n(3)) as u64 * 86400 + (n(4) * 3600 + n(5) * 60 + n(6)) as u64)
}

/// Days since 1970-01-01 for a civil date (Howard Hinnant's algorithm).
pub fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let doy = (153 * (m + if m > 2 { -3 } else { 9 }) + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146097 + doe - 719468
}

// ---------------------------------------------------------------- Windows

#[cfg(windows)]
fn list_windows() -> Vec<App> {
    use winreg::enums::*;
    use winreg::RegKey;
    let mut out: Vec<App> = vec![];
    let roots = [
        (HKEY_LOCAL_MACHINE, "SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall"),
        (HKEY_LOCAL_MACHINE, "SOFTWARE\\WOW6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall"),
        (HKEY_CURRENT_USER, "SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall"),
    ];
    let mut seen = std::collections::HashSet::new();
    for (hive, path) in roots {
        let Ok(k) = RegKey::predef(hive).open_subkey(path) else { continue };
        for sub in k.enum_keys().filter_map(|r| r.ok()) {
            let Ok(a) = k.open_subkey(&sub) else { continue };
            let s = |n: &str| a.get_value::<String, _>(n).unwrap_or_default();
            let name = s("DisplayName");
            let uninstall = { let q = s("QuietUninstallString"); if q.is_empty() { s("UninstallString") } else { q } };
            if name.is_empty() || uninstall.is_empty() { continue; }
            if a.get_value::<u32, _>("SystemComponent").unwrap_or(0) == 1 || !s("ParentKeyName").is_empty() { continue; }
            if !seen.insert(name.to_lowercase()) { continue; }
            let size = a.get_value::<u32, _>("EstimatedSize").map(|kb| kb as u64 * 1024).unwrap_or(0);
            let date = s("InstallDate");
            let installed = (date.len() == 8).then(|| {
                let y = date[0..4].parse().unwrap_or(1970);
                let m = date[4..6].parse().unwrap_or(1);
                let d = date[6..8].parse().unwrap_or(1);
                days_from_civil(y, m, d) as u64 * 86400
            });
            let loc = s("InstallLocation");
            let publisher = s("Publisher");
            out.push(App {
                id: format!("win:{sub}"),
                name: name.clone(),
                version: s("DisplayVersion"),
                publisher: publisher.clone(),
                source: "Programme".into(),
                size,
                last_used: None,
                installed,
                path: (!loc.is_empty()).then(|| loc.trim_matches('"').to_string()),
                uninstall,
                keys: vec![name, publisher],
            });
        }
    }
    let (c, o) = sh("Get-AppxPackage | Where-Object { -not $_.IsFramework -and $_.SignatureKind -eq 'Store' } | Select-Object Name,PackageFullName,Version,InstallLocation,PublisherId | ConvertTo-Json -Compress");
    if c == 0 {
        if let Ok(serde_json::Value::Array(arr)) = serde_json::from_str::<serde_json::Value>(o.trim()) {
            for a in arr {
                let name = a["Name"].as_str().unwrap_or("").to_string();
                if name.starts_with("Microsoft.") && (name.contains("VCLibs") || name.contains(".NET") || name.contains("UI.Xaml")) { continue; }
                let full = a["PackageFullName"].as_str().unwrap_or("").to_string();
                let pretty = name.split('.').last().unwrap_or(&name).to_string();
                out.push(App {
                    id: format!("appx:{full}"),
                    name: pretty.clone(),
                    version: a["Version"].as_str().unwrap_or("").into(),
                    publisher: name.clone(),
                    source: "Microsoft Store".into(),
                    size: 0,
                    path: a["InstallLocation"].as_str().map(String::from),
                    uninstall: format!("Remove-AppxPackage -Package '{full}'"),
                    keys: vec![pretty, name],
                    ..Default::default()
                });
            }
        }
    }
    out
}

// ---------------------------------------------------------------- Linux

#[cfg(target_os = "linux")]
fn list_linux() -> Vec<App> {
    let mut out: Vec<App> = vec![];
    // Flatpak
    let (c, o) = run("flatpak", &["list", "--app", "--columns=application,name,version,size,installation"]);
    if c == 0 {
        for l in o.lines() {
            let f: Vec<&str> = l.split('\t').collect();
            if f.len() < 4 { continue; }
            out.push(App {
                id: format!("flatpak:{}", f[0]),
                name: f[1].into(),
                version: f[2].into(),
                publisher: f[0].into(),
                source: format!("Flatpak{}", f.get(4).map(|i| if *i == "user" { " (utilisateur)" } else { "" }).unwrap_or("")),
                size: parse_human(f[3]),
                last_used: mtime(&hp(&format!(".var/app/{}", f[0]))),
                uninstall: format!("flatpak uninstall -y {}", f[0]),
                keys: vec![f[0].into(), f[1].into()],
                ..Default::default()
            });
        }
    }
    // Snap
    let (c, o) = run("snap", &["list"]);
    if c == 0 {
        for l in o.lines().skip(1) {
            let f: Vec<&str> = l.split_whitespace().collect();
            if f.len() < 4 { continue; }
            let notes = f.last().copied().unwrap_or("");
            if notes.contains("base") || notes.contains("snapd") || notes.contains("core") || f[0].starts_with("gnome-") || f[0].starts_with("gtk-") || f[0] == "bare" { continue; }
            let snapfile = PathBuf::from(format!("/var/lib/snapd/snaps/{}_{}.snap", f[0], f[2]));
            out.push(App {
                id: format!("snap:{}", f[0]),
                name: f[0].into(),
                version: f[1].into(),
                publisher: f.get(4).copied().unwrap_or("").into(),
                source: "Snap".into(),
                size: std::fs::metadata(&snapfile).map(|m| m.len()).unwrap_or(0),
                last_used: mtime(&hp(&format!("snap/{}", f[0]))),
                uninstall: format!("ADMIN:snap remove {}", f[0]),
                keys: vec![f[0].into()],
                ..Default::default()
            });
        }
    }
    // Native packages behind the visible .desktop launchers
    #[allow(clippy::type_complexity)]
    let (pm, query): (&str, fn(&str) -> Option<(String, String, u64)>) = if which("dpkg-query").is_some() {
        ("apt", |p| {
            let (c, o) = run("dpkg", &["-S", p]);
            if c != 0 { return None; }
            let pkg = o.lines().next()?.split(':').next()?.trim().to_string();
            let (_, info) = run("dpkg-query", &["-W", "-f=${Version}\t${Installed-Size}", &pkg]);
            let mut it = info.split('\t');
            let v = it.next().unwrap_or("").to_string();
            let kb: u64 = it.next().and_then(|x| x.trim().parse().ok()).unwrap_or(0);
            Some((pkg, v, kb * 1024))
        })
    } else if which("rpm").is_some() {
        ("dnf", |p| {
            let (c, o) = run("rpm", &["-qf", "--qf", "%{NAME}\t%{VERSION}\t%{SIZE}\n", p]);
            if c != 0 { return None; }
            let l = o.lines().next()?;
            let f: Vec<&str> = l.split('\t').collect();
            Some((f.first()?.to_string(), f.get(1).unwrap_or(&"").to_string(), f.get(2).and_then(|x| x.parse().ok()).unwrap_or(0)))
        })
    } else if which("pacman").is_some() {
        ("pacman", |p| {
            let (c, o) = run("pacman", &["-Qo", "-q", p]);
            if c != 0 { return None; }
            let pkg = o.lines().next()?.trim().to_string();
            let (_, info) = run("pacman", &["-Qi", &pkg]);
            let get = |k: &str| info.lines().find(|l| l.starts_with(k)).and_then(|l| l.split_once(':')).map(|x| x.1.trim().to_string()).unwrap_or_default();
            Some((pkg, get("Version"), parse_human(&get("Installed Size"))))
        })
    } else {
        ("", |_| None)
    };
    if !pm.is_empty() {
        let mut seen = std::collections::HashSet::new();
        for f in children(&PathBuf::from("/usr/share/applications")).into_iter().filter(|f| ext(f) == "desktop") {
            let text = std::fs::read_to_string(&f).unwrap_or_default();
            if text.contains("NoDisplay=true") || text.contains("OnlyShowIn=") { continue; }
            let name = text.lines().find_map(|l| l.strip_prefix("Name=")).unwrap_or("").to_string();
            let Some((pkg, ver, size)) = query(&f.to_string_lossy()) else { continue };
            if !seen.insert(pkg.clone()) { continue; }
            if ["gnome-shell", "nautilus", "gnome-control-center", "plasma-workspace", "systemsettings", "xdg-utils", "desktop-file-utils"].contains(&pkg.as_str()) { continue; }
            let cmd = match pm { "apt" => format!("ADMIN:apt-get remove -y {pkg}"), "dnf" => format!("ADMIN:dnf remove -y {pkg}"), _ => format!("ADMIN:pacman -R --noconfirm {pkg}") };
            out.push(App {
                id: format!("{pm}:{pkg}"),
                name: if name.is_empty() { pkg.clone() } else { name.clone() },
                version: ver,
                publisher: pkg.clone(),
                source: format!("Paquet {}", match pm { "apt" => "APT", "dnf" => "RPM", _ => "pacman" }),
                size,
                uninstall: cmd,
                keys: vec![pkg, name, file_name(&f).trim_end_matches(".desktop").to_string()],
                ..Default::default()
            });
        }
    }
    // AppImages
    for d in [hp("Applications"), hp("AppImages"), hp("Downloads"), hp(".local/bin")] {
        for f in children(&d).into_iter().filter(|f| ext(f) == "appimage") {
            let n = file_name(&f);
            let pretty = n.split(['-', '_', '.']).next().unwrap_or(&n).to_string();
            out.push(App {
                id: format!("appimage:{}", f.display()),
                name: pretty.clone(),
                source: "AppImage".into(),
                size: size_of(&f),
                last_used: atime(&f),
                installed: mtime(&f),
                path: Some(f.to_string_lossy().into()),
                uninstall: "TRASH".into(),
                keys: vec![pretty],
                ..Default::default()
            });
        }
    }
    out
}

#[cfg(windows)]
fn cmd_line(line: &str) -> (i32, String) {
    use std::os::windows::process::CommandExt;
    match std::process::Command::new("cmd").raw_arg("/C").raw_arg(line).output() {
        Ok(o) => (o.status.code().unwrap_or(-1), String::from_utf8_lossy(&o.stderr).to_string()),
        Err(e) => (-1, e.to_string()),
    }
}
#[cfg(not(windows))]
fn cmd_line(line: &str) -> (i32, String) {
    sh(line)
}

// ---------------------------------------------------------------- shared

pub fn list() -> Vec<App> {
    #[cfg(target_os = "macos")]
    let v = list_mac();
    #[cfg(windows)]
    let v = list_windows();
    #[cfg(target_os = "linux")]
    let v = list_linux();
    #[cfg(not(any(target_os = "macos", windows, target_os = "linux")))]
    let v: Vec<App> = vec![];
    let mut v = v;
    v.sort_by_key(|a| a.name.to_lowercase());
    *CACHE.lock().unwrap_or_else(|e| e.into_inner()) = v.clone();
    v
}

fn get(id: &str) -> Option<App> {
    CACHE.lock().unwrap_or_else(|e| e.into_inner()).iter().find(|a| a.id == id).cloned()
}

fn norm(s: &str) -> String {
    s.to_lowercase().chars().filter(|c| c.is_alphanumeric() || *c == '.').collect()
}

/// Folders and files the app left in user/system data locations.
pub fn leftovers(app: &App) -> Vec<Item> {
    let keys: Vec<String> = app.keys.iter().map(|k| norm(k)).filter(|k| k.len() >= 4).collect();
    if keys.is_empty() {
        return vec![];
    }
    let roots: Vec<PathBuf> = if cfg!(target_os = "macos") {
        ["Library/Application Support", "Library/Caches", "Library/Preferences", "Library/Preferences/ByHost", "Library/Containers",
         "Library/Group Containers", "Library/Logs", "Library/Saved Application State", "Library/HTTPStorages", "Library/WebKit",
         "Library/Cookies", "Library/LaunchAgents", "Library/Application Scripts"].iter().map(|r| hp(r))
            .chain(["/Library/Application Support", "/Library/Caches", "/Library/Preferences", "/Library/LaunchAgents",
                    "/Library/LaunchDaemons", "/Library/PrivilegedHelperTools"].iter().map(PathBuf::from)).collect()
    } else if cfg!(windows) {
        let mut v: Vec<PathBuf> = [appdata(""), local_appdata(""), local_appdata("Programs")].into_iter().flatten().collect();
        if let Some(p) = std::env::var_os("PROGRAMDATA") { v.push(PathBuf::from(p)); }
        if let Some(p) = local_appdata("Packages") { v.push(p); }
        v
    } else {
        vec![hp(".config"), hp(".local/share"), hp(".cache"), hp(".local/state"), hp(".var/app"), hp("snap")]
    };
    let mut found = vec![];
    for r in roots {
        for c in children(&r) {
            let n = norm(&file_name(&c));
            let n2 = n.trim_end_matches(".plist").trim_end_matches(".savedstate").to_string();
            if keys.iter().any(|k| n2 == *k || n2.starts_with(&format!("{k}.")) || (k.contains('.') && n2.contains(k.as_str()))) {
                found.push(c);
            }
        }
    }
    if let Some(p) = &app.path {
        if cfg!(windows) && exists(Path::new(p)) && !app.id.starts_with("appx:") {
            found.push(PathBuf::from(p));
        }
    }
    found.sort();
    found.dedup();
    let mut items = items_for(found, true);
    for i in items.iter_mut() {
        if !i.paths[0].starts_with(&home().to_string_lossy().to_string()) {
            i.badges.push(badge("Système", "gray"));
            i.selected = false;
        }
    }
    items.sort_by_key(|i| std::cmp::Reverse(i.size));
    items
}

#[tauri::command]
pub async fn apps_list() -> Vec<App> {
    tauri::async_runtime::spawn_blocking(list).await.unwrap_or_default()
}

#[tauri::command]
pub async fn app_leftovers(id: String) -> Vec<Item> {
    tauri::async_runtime::spawn_blocking(move || get(&id).map(|a| leftovers(&a)).unwrap_or_default()).await.unwrap_or_default()
}

/// Runs the app's own uninstaller (or trashes it), then trashes the selected leftovers.
#[tauri::command]
pub async fn app_uninstall(id: String, extra: Vec<String>, keep_app: bool) -> Result<String, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let app = get(&id).ok_or("Application introuvable, actualise la liste")?;
        let mut freed = 0u64;
        if !keep_app {
            let _ = crate::privacy::quit_app(vec![app.name.clone()]);
            let u = app.uninstall.clone();
            let (c, o) = if u == "mac" || u == "TRASH" {
                let p = PathBuf::from(app.path.clone().unwrap_or_default());
                let r = trash_many(&[(p, Some(app.size))]);
                freed += r.freed;
                if r.errors.is_empty() { (0, String::new()) } else { (1, r.errors.join(", ")) }
            } else if let Some(cmd) = u.strip_prefix("ADMIN:") {
                admin(cmd)
            } else if u.starts_with("Remove-AppxPackage") || u.starts_with("flatpak") {
                sh(&u)
            } else if cfg!(windows) {
                let fixed = regex::Regex::new(r"(?i)msiexec(\.exe)?\s+/i\s*").unwrap().replace(&u, "MsiExec.exe /X").to_string();
                cmd_line(&fixed)
            } else {
                sh(&u)
            };
            if c != 0 {
                return Err(format!("Le désinstallateur a échoué ou a été annulé. {}", o.trim().chars().take(300).collect::<String>()));
            }
            if u != "mac" && u != "TRASH" {
                freed += app.size;
                crate::settings::add_freed(app.size);
            }
        }
        let r = trash_many(&extra.iter().map(|p| (PathBuf::from(p), None)).collect::<Vec<_>>());
        freed += r.freed;
        let mut msg = if keep_app { format!("{} réinitialisé", app.name) } else { format!("{} désinstallé", app.name) };
        msg.push_str(&format!(" · {:.2} Go libérés", freed as f64 / 1e9));
        if !r.errors.is_empty() { msg.push_str(&format!(" · {} élément(s) ignoré(s)", r.errors.len())); }
        Ok(msg)
    })
    .await
    .map_err(|e| e.to_string())?
}

/// Data left by Flatpak apps that are no longer installed (Linux) / by deleted apps (macOS).
#[tauri::command]
pub async fn app_orphans() -> Vec<Item> {
    tauri::async_runtime::spawn_blocking(|| {
        let apps = list();
        let mut v = vec![];
        if cfg!(target_os = "linux") {
            let ids: Vec<String> = apps.iter().filter_map(|a| a.id.strip_prefix("flatpak:").map(String::from)).collect();
            for d in children(&hp(".var/app")) {
                if !ids.contains(&file_name(&d)) { v.push(d); }
            }
            let snaps: Vec<String> = apps.iter().filter_map(|a| a.id.strip_prefix("snap:").map(String::from)).collect();
            if which("snap").is_some() {
                for d in children(&hp("snap")) {
                    let n = file_name(&d);
                    if !snaps.contains(&n) && run("snap", &["list", &n]).0 != 0 { v.push(d); }
                }
            }
        }
        if cfg!(target_os = "macos") {
            let ids: Vec<String> = apps.iter().map(|a| a.publisher.to_lowercase()).filter(|s| !s.is_empty()).collect();
            let re = regex::Regex::new(r"^[a-z0-9-]+\.[a-z0-9-]+\.[a-z0-9._-]+$").unwrap();
            for r in ["Library/Application Support", "Library/Caches", "Library/Containers", "Library/Preferences", "Library/Saved Application State", "Library/HTTPStorages"] {
                for c in children(&hp(r)) {
                    let n = file_name(&c).to_lowercase();
                    let n = n.trim_end_matches(".plist").trim_end_matches(".savedstate").to_string();
                    if !re.is_match(&n) || n.starts_with("com.apple.") || n.starts_with("group.") { continue; }
                    if !ids.iter().any(|id| n == *id || n.starts_with(&format!("{id}.")) || id.starts_with(&format!("{n}."))) { v.push(c); }
                }
            }
        }
        let mut items = items_for(v, false);
        items.sort_by_key(|i| std::cmp::Reverse(i.size));
        items
    }).await.unwrap_or_default()
}
