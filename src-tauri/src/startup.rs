//! Startup items: Windows Run keys + Startup folders, Linux autostart + systemd --user, macOS launchd + login items.

use crate::util::*;
use serde::Serialize;
use std::path::{Path, PathBuf};

#[derive(Serialize, Clone, Debug)]
pub struct StartupItem {
    pub id: String,
    pub group: String,
    pub name: String,
    pub command: String,
    pub location: String,
    pub enabled: bool,
    pub can_toggle: bool,
    pub can_remove: bool,
    pub path: Option<String>,
    pub kind: String,
}

// ---------------------------------------------------------------- macOS

pub struct LaunchPlist {
    pub label: Option<String>,
    pub program: Option<String>,
    pub args: Vec<String>,
    pub disabled: bool,
}

pub fn read_launch_plist(p: &Path) -> LaunchPlist {
    let v = plist::Value::from_file(p).ok();
    let d = v.as_ref().and_then(|v| v.as_dictionary());
    let get_s = |k: &str| d.and_then(|d| d.get(k)).and_then(|v| v.as_string()).map(String::from);
    let args: Vec<String> = d.and_then(|d| d.get("ProgramArguments")).and_then(|v| v.as_array())
        .map(|a| a.iter().filter_map(|x| x.as_string().map(String::from)).collect()).unwrap_or_default();
    LaunchPlist {
        label: get_s("Label"),
        program: get_s("Program").or_else(|| args.first().cloned()),
        args,
        disabled: d.and_then(|d| d.get("Disabled")).and_then(|v| v.as_boolean()).unwrap_or(false),
    }
}

#[cfg(target_os = "macos")]
fn uid() -> u32 {
    use std::os::unix::fs::MetadataExt;
    std::fs::metadata(home()).map(|m| m.uid()).unwrap_or(501)
}

#[cfg(target_os = "macos")]
fn mac_items() -> Vec<StartupItem> {
    let mut out = vec![];
    let (c, o) = run("/usr/bin/osascript", &["-e", "tell application \"System Events\" to get the name of every login item"]);
    if c == 0 {
        for n in o.trim().split(", ").filter(|s| !s.is_empty()) {
            out.push(StartupItem { id: format!("login:{n}"), group: "Ouverture à la connexion".into(), name: n.into(),
                command: String::new(), location: "Éléments de connexion".into(), enabled: true, can_toggle: false,
                can_remove: true, path: None, kind: "login".into() });
        }
    }
    let disabled = |domain: &str| -> Vec<String> {
        run("/bin/launchctl", &["print-disabled", domain]).1.lines().filter_map(|l| {
            let t = l.trim();
            let (k, v) = t.split_once("\" => ")?;
            (v.starts_with("disabled") || v.starts_with("true")).then(|| k.trim_start_matches('"').to_string())
        }).collect()
    };
    let gui = format!("gui/{}", uid());
    let gui_dis = disabled(&gui);
    let sys_dis = disabled("system");
    for (dir, group, dom, dis) in [(hp("Library/LaunchAgents"), "Agents utilisateur", gui.clone(), &gui_dis),
                                   (PathBuf::from("/Library/LaunchAgents"), "Agents globaux", gui.clone(), &gui_dis),
                                   (PathBuf::from("/Library/LaunchDaemons"), "Démons système", "system".to_string(), &sys_dis)] {
        for f in children(&dir).into_iter().filter(|f| ext(f) == "plist") {
            let p = read_launch_plist(&f);
            let label = p.label.clone().unwrap_or_else(|| file_name(&f).trim_end_matches(".plist").to_string());
            let prog = p.program.clone().unwrap_or_default();
            let name = prog.find(".app/").map(|i| file_name(Path::new(&prog[..i + 4])).trim_end_matches(".app").to_string()).unwrap_or(label.clone());
            out.push(StartupItem { id: format!("launchd:{}", f.display()), group: group.into(), name, command: p.args.join(" "),
                location: label.clone(), enabled: !p.disabled && !dis.contains(&label), can_toggle: true, can_remove: true,
                path: Some(f.to_string_lossy().into()), kind: format!("launchd:{dom}") });
        }
    }
    out
}

// ---------------------------------------------------------------- Linux

fn desktop_field(text: &str, key: &str) -> Option<String> {
    text.lines().find_map(|l| l.strip_prefix(&format!("{key}=")).map(|v| v.trim().to_string()))
}

fn desktop_enabled(text: &str) -> bool {
    desktop_field(text, "Hidden").map(|v| v != "true").unwrap_or(true)
        && desktop_field(text, "X-GNOME-Autostart-enabled").map(|v| v != "false").unwrap_or(true)
}

#[cfg(target_os = "linux")]
fn linux_items() -> Vec<StartupItem> {
    let mut out = vec![];
    let user_dir = hp(".config/autostart");
    let mut seen = std::collections::HashSet::new();
    for (dir, system) in [(user_dir.clone(), false), (PathBuf::from("/etc/xdg/autostart"), true)] {
        for f in children(&dir).into_iter().filter(|f| ext(f) == "desktop") {
            let fname = file_name(&f);
            if !seen.insert(fname.clone()) {
                continue; // user copy overrides the system one
            }
            let text = std::fs::read_to_string(&f).unwrap_or_default();
            if desktop_field(&text, "OnlyShowIn").is_some() && system {
                // desktop-environment internals (e.g. GNOME's own services): keep but they are rarely worth touching
            }
            out.push(StartupItem {
                id: format!("autostart:{fname}"),
                group: if system { "Applications système au démarrage".into() } else { "Applications au démarrage".into() },
                name: desktop_field(&text, "Name").unwrap_or(fname.clone()),
                command: desktop_field(&text, "Exec").unwrap_or_default(),
                location: f.to_string_lossy().into(),
                enabled: desktop_enabled(&text),
                can_toggle: true,
                can_remove: !system,
                path: Some(f.to_string_lossy().into()),
                kind: "autostart".into(),
            });
        }
    }
    let (c, o) = run("systemctl", &["--user", "list-unit-files", "--type=service", "--state=enabled", "--no-legend", "--no-pager"]);
    if c == 0 {
        for l in lines(&o) {
            let unit = l.split_whitespace().next().unwrap_or("").to_string();
            if unit.is_empty() || unit.contains('@') {
                continue;
            }
            out.push(StartupItem { id: format!("systemd:{unit}"), group: "Services utilisateur (systemd)".into(),
                name: unit.trim_end_matches(".service").into(), command: String::new(), location: unit.clone(),
                enabled: true, can_toggle: true, can_remove: false, path: None, kind: "systemd".into() });
        }
    }
    out
}

// ---------------------------------------------------------------- Windows

#[cfg(windows)]
mod win {
    use super::*;
    use winreg::enums::*;
    use winreg::RegKey;

    pub const RUN: &str = "Software\\Microsoft\\Windows\\CurrentVersion\\Run";
    pub const RUN32: &str = "Software\\WOW6432Node\\Microsoft\\Windows\\CurrentVersion\\Run";
    pub const APPROVED: &str = "Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\StartupApproved";

    pub fn approved(hive: &RegKey, sub: &str, name: &str) -> bool {
        hive.open_subkey(format!("{APPROVED}\\{sub}"))
            .and_then(|k| k.get_raw_value(name))
            .map(|v| v.bytes.first().map(|b| b & 1 == 0).unwrap_or(true))
            .unwrap_or(true)
    }

    pub fn items() -> Vec<StartupItem> {
        let mut out = vec![];
        let hkcu = RegKey::predef(HKEY_CURRENT_USER);
        let hklm = RegKey::predef(HKEY_LOCAL_MACHINE);
        for (hive, hname, key, sub, group) in [(&hkcu, "HKCU", RUN, "Run", "Programmes au démarrage (utilisateur)"),
                                               (&hklm, "HKLM", RUN, "Run", "Programmes au démarrage (tous les utilisateurs)"),
                                               (&hklm, "HKLM", RUN32, "Run32", "Programmes au démarrage (32 bits)")] {
            if let Ok(k) = hive.open_subkey(key) {
                for (name, val) in k.enum_values().filter_map(|r| r.ok()) {
                    let cmd = val.to_string().trim_matches('"').to_string();
                    out.push(StartupItem {
                        id: format!("reg:{hname}:{sub}:{name}"),
                        group: group.into(),
                        name: name.clone(),
                        command: cmd,
                        location: format!("{hname}\\{key}"),
                        enabled: approved(hive, sub, &name),
                        can_toggle: true,
                        can_remove: true,
                        path: None,
                        kind: format!("reg:{hname}:{sub}"),
                    });
                }
            }
        }
        for (dir, hname, group) in [(appdata("Microsoft/Windows/Start Menu/Programs/Startup"), "HKCU", "Dossier Démarrage (utilisateur)"),
                                    (std::env::var_os("PROGRAMDATA").map(|p| join(&PathBuf::from(p), "Microsoft/Windows/Start Menu/Programs/StartUp")), "HKLM", "Dossier Démarrage (tous)")] {
            let Some(dir) = dir else { continue };
            let hive = if hname == "HKCU" { &hkcu } else { &hklm };
            for f in children(&dir).into_iter().filter(|f| file_name(f) != "desktop.ini") {
                let n = file_name(&f);
                out.push(StartupItem {
                    id: format!("folder:{}", f.display()),
                    group: group.into(),
                    name: n.trim_end_matches(".lnk").into(),
                    command: f.to_string_lossy().into(),
                    location: dir.to_string_lossy().into(),
                    enabled: approved(hive, "StartupFolder", &n),
                    can_toggle: true,
                    can_remove: hname == "HKCU",
                    path: Some(f.to_string_lossy().into()),
                    kind: format!("folder:{hname}"),
                });
            }
        }
        out
    }

    pub fn set_approved(hname: &str, sub: &str, name: &str, on: bool) -> Result<(), String> {
        let first = if on { "02" } else { "03" };
        if hname == "HKCU" {
            let hkcu = RegKey::predef(HKEY_CURRENT_USER);
            let (k, _) = hkcu.create_subkey(format!("{APPROVED}\\{sub}")).map_err(|e| e.to_string())?;
            let mut bytes = vec![0u8; 12];
            bytes[0] = if on { 2 } else { 3 };
            k.set_raw_value(name, &winreg::RegValue { vtype: REG_BINARY, bytes: bytes.into() }).map_err(|e| e.to_string())
        } else {
            let (c, o) = admin(&format!("reg add \"HKLM\\{APPROVED}\\{sub}\" /v \"{name}\" /t REG_BINARY /d {first}0000000000000000000000 /f"));
            if c == 0 { Ok(()) } else { Err(o) }
        }
    }

    pub fn delete_value(hname: &str, sub: &str, name: &str) -> Result<(), String> {
        let key = if sub == "Run32" { RUN32 } else { RUN };
        if hname == "HKCU" {
            RegKey::predef(HKEY_CURRENT_USER).open_subkey_with_flags(key, KEY_SET_VALUE)
                .and_then(|k| k.delete_value(name)).map_err(|e| e.to_string())
        } else {
            let (c, o) = admin(&format!("reg delete \"HKLM\\{key}\" /v \"{name}\" /f"));
            if c == 0 { Ok(()) } else { Err(o) }
        }
    }
}

// ---------------------------------------------------------------- commands

pub fn list() -> Vec<StartupItem> {
    #[cfg(target_os = "macos")]
    return mac_items();
    #[cfg(target_os = "linux")]
    return linux_items();
    #[cfg(windows)]
    return win::items();
    #[allow(unreachable_code)]
    vec![]
}

#[tauri::command]
pub async fn startup_list() -> Vec<StartupItem> {
    tauri::async_runtime::spawn_blocking(list).await.unwrap_or_default()
}

fn find(id: &str) -> Result<StartupItem, String> {
    list().into_iter().find(|i| i.id == id).ok_or_else(|| "Élément introuvable".to_string())
}

pub fn set_enabled(item: &StartupItem, on: bool) -> Result<(), String> {
    let kind = item.kind.as_str();
    if let Some(dom) = kind.strip_prefix("launchd:") {
        let p = item.path.clone().unwrap_or_default();
        let cmd = if on {
            format!("launchctl enable {dom}/{}; launchctl bootstrap {dom} {} 2>/dev/null; true", item.location, quote(&p))
        } else {
            format!("launchctl disable {dom}/{}; launchctl bootout {dom} {} 2>/dev/null; true", item.location, quote(&p))
        };
        let (c, o) = if dom == "system" { admin(&cmd) } else { sh(&cmd) };
        return if c == 0 { Ok(()) } else { Err(o) };
    }
    if kind == "autostart" {
        let src = PathBuf::from(item.path.clone().unwrap_or_default());
        let user = hp(".config/autostart").join(file_name(&src));
        let text = std::fs::read_to_string(&src).map_err(|e| e.to_string())?;
        let mut kept: Vec<String> = text.lines().filter(|l| !l.starts_with("Hidden=") && !l.starts_with("X-GNOME-Autostart-enabled=")).map(String::from).collect();
        kept.push(format!("Hidden={}", if on { "false" } else { "true" }));
        kept.push(format!("X-GNOME-Autostart-enabled={}", if on { "true" } else { "false" }));
        let _ = std::fs::create_dir_all(user.parent().unwrap());
        return std::fs::write(&user, kept.join("\n") + "\n").map_err(|e| e.to_string());
    }
    if kind == "systemd" {
        let (c, o) = run("systemctl", &["--user", if on { "enable" } else { "disable" }, "--now", &item.location]);
        return if c == 0 { Ok(()) } else { Err(o) };
    }
    #[cfg(windows)]
    {
        if let Some(rest) = kind.strip_prefix("reg:") {
            let (h, sub) = rest.split_once(':').unwrap_or(("HKCU", "Run"));
            return win::set_approved(h, sub, &item.name, on);
        }
        if let Some(h) = kind.strip_prefix("folder:") {
            let n = file_name(Path::new(item.path.as_deref().unwrap_or("")));
            return win::set_approved(h, "StartupFolder", &n, on);
        }
    }
    let _ = on;
    Err("Ce type d'élément ne peut pas être modifié".into())
}

#[tauri::command]
pub async fn startup_toggle(id: String, on: bool) -> Result<(), String> {
    tauri::async_runtime::spawn_blocking(move || set_enabled(&find(&id)?, on)).await.map_err(|e| e.to_string())?
}

pub fn remove(item: &StartupItem) -> Result<(), String> {
    let kind = item.kind.as_str();
    if kind == "login" {
        let esc = item.name.replace('"', "\\\"");
        let (c, o) = run("/usr/bin/osascript", &["-e", &format!("tell application \"System Events\" to delete login item \"{esc}\"")]);
        return if c == 0 { Ok(()) } else { Err(o) };
    }
    if kind.starts_with("launchd:") {
        let _ = set_enabled(item, false);
    }
    #[cfg(windows)]
    if let Some(rest) = kind.strip_prefix("reg:") {
        let (h, sub) = rest.split_once(':').unwrap_or(("HKCU", "Run"));
        return win::delete_value(h, sub, &item.name);
    }
    if let Some(p) = &item.path {
        let r = trash_many(&[(PathBuf::from(p), Some(0))]);
        return if r.errors.is_empty() { Ok(()) } else { Err(r.errors.join(", ")) };
    }
    Err("Cet élément ne peut pas être retiré, seulement désactivé".into())
}

#[tauri::command]
pub async fn startup_remove(id: String) -> Result<(), String> {
    tauri::async_runtime::spawn_blocking(move || remove(&find(&id)?)).await.map_err(|e| e.to_string())?
}

#[tauri::command]
pub fn open_startup_settings() {
    if cfg!(windows) {
        let _ = sh("Start-Process ms-settings:startupapps");
    } else if cfg!(target_os = "macos") {
        let _ = run("/usr/bin/open", &["x-apple.systempreferences:com.apple.LoginItems-Settings.extension"]);
    } else {
        for t in ["gnome-session-properties", "gnome-tweaks"] {
            if let Some(b) = which(t) {
                let _ = std::process::Command::new(b).spawn();
                break;
            }
        }
    }
}
