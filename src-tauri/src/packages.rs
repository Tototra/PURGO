//! Package managers: pending updates and cleanups (winget, Scoop, Chocolatey, APT, DNF, pacman,
//! Flatpak, Snap, Homebrew, npm, pipx).

use crate::util::*;
use serde::Serialize;
use tauri::AppHandle;

#[derive(Serialize, Clone)]
pub struct Outdated {
    pub id: String,
    pub name: String,
    pub current: String,
    pub latest: String,
}

#[derive(Serialize, Clone)]
pub struct PkgAction {
    pub id: String,
    pub title: String,
    pub info: String,
    pub estimate: Option<String>,
}

#[derive(Serialize, Clone)]
pub struct Manager {
    pub id: String,
    pub name: String,
    pub icon: String,
    pub outdated: Vec<Outdated>,
    pub actions: Vec<PkgAction>,
    pub note: Option<String>,
}

fn act(id: &str, title: &str, info: &str, estimate: Option<String>) -> PkgAction {
    PkgAction { id: id.into(), title: title.into(), info: info.into(), estimate }
}

fn brew(args: &str) -> (i32, String) {
    let Some(b) = which("brew") else { return (-1, "Homebrew absent".into()) };
    sh(&format!("HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 {} {args} 2>&1", quote(&b.to_string_lossy())))
}

/// Splits a fixed-width table (winget, snap…) using the header's column starts.
fn table(out: &str) -> Vec<Vec<String>> {
    let rows: Vec<&str> = out.lines().collect();
    let Some(sep) = rows.iter().position(|l| l.trim_start().starts_with("---")) else { return vec![] };
    if sep == 0 { return vec![]; }
    let header: Vec<char> = rows[sep - 1].chars().collect();
    let mut starts = vec![0usize];
    for i in 1..header.len() {
        if header[i] != ' ' && header[i - 1] == ' ' { starts.push(i); }
    }
    rows[sep + 1..].iter().filter(|l| !l.trim().is_empty()).map(|l| {
        let c: Vec<char> = l.chars().collect();
        starts.iter().enumerate().map(|(k, &s)| {
            let e = starts.get(k + 1).copied().unwrap_or(c.len()).min(c.len());
            if s >= c.len() { String::new() } else { c[s..e].iter().collect::<String>().trim().to_string() }
        }).collect()
    }).collect()
}

pub fn status(app: &AppHandle) -> Vec<Manager> {
    let mut v = vec![];
    let tick = |t: &str| progress(app, "packages", t, 0);

    if cfg!(windows) && which("winget").is_some() {
        tick("winget…");
        let (_, o) = run("winget", &["upgrade", "--accept-source-agreements", "--disable-interactivity"]);
        let outdated = table(&o).into_iter().filter(|r| r.len() >= 4 && !r[1].is_empty() && !r[0].contains("upgrades available") && !r[0].contains("mises à niveau"))
            .map(|r| Outdated { id: r[1].clone(), name: r[0].clone(), current: r[2].clone(), latest: r[3].clone() }).collect();
        v.push(Manager { id: "winget".into(), name: "winget".into(), icon: "shippingbox".into(), outdated,
            actions: vec![], note: Some("Le gestionnaire de paquets de Windows : il met aussi à jour beaucoup de programmes classiques.".into()) });
    }
    if cfg!(windows) && which("scoop").is_some() {
        tick("Scoop…");
        let (_, o) = sh("scoop status");
        let outdated = table(&o).into_iter().filter(|r| r.len() >= 3).map(|r| Outdated { id: r[0].clone(), name: r[0].clone(), current: r[1].clone(), latest: r[2].clone() }).collect();
        let cache = size_of(&hp("scoop/cache"));
        v.push(Manager { id: "scoop".into(), name: "Scoop".into(), icon: "cup".into(), outdated,
            actions: vec![act("cleanup", "Nettoyer Scoop", "Anciennes versions et cache de téléchargement.", (cache > 0).then(|| format!("{:.1} Go en cache", cache as f64 / 1e9)))], note: None });
    }
    if cfg!(windows) && which("choco").is_some() {
        tick("Chocolatey…");
        let (_, o) = run("choco", &["outdated", "-r"]);
        let outdated = o.lines().filter_map(|l| { let f: Vec<&str> = l.split('|').collect(); (f.len() >= 3).then(|| Outdated { id: f[0].into(), name: f[0].into(), current: f[1].into(), latest: f[2].into() }) }).collect();
        v.push(Manager { id: "choco".into(), name: "Chocolatey".into(), icon: "shippingbox".into(), outdated, actions: vec![], note: None });
    }

    if cfg!(target_os = "linux") {
        if which("apt-get").is_some() {
            tick("APT…");
            let (_, o) = run("apt", &["list", "--upgradable"]);
            let re = regex::Regex::new(r"^([^/\s]+)/\S+\s+(\S+)\s+\S+\s+\[[^:]+:\s*([^\]]+)\]").unwrap();
            let outdated = o.lines().filter_map(|l| re.captures(l).map(|c| Outdated { id: c[1].into(), name: c[1].into(), current: c[3].trim().into(), latest: c[2].into() })).collect();
            let (_, ar) = run("apt-get", &["-s", "autoremove"]);
            let n_auto = ar.lines().filter(|l| l.starts_with("Remv ")).count();
            let cache = size_of(&std::path::PathBuf::from("/var/cache/apt/archives"));
            v.push(Manager { id: "apt".into(), name: "APT".into(), icon: "shippingbox".into(), outdated, actions: vec![
                act("refresh", "Actualiser la liste", "Interroge les dépôts pour connaître les nouvelles versions (apt update).", None),
                act("autoremove", "Supprimer les paquets inutiles", "Dépendances installées automatiquement dont plus rien n'a besoin.", (n_auto > 0).then(|| format!("{n_auto} paquet(s)"))),
                act("cleanup", "Vider le cache APT", "Les .deb déjà installés gardés dans /var/cache/apt.", (cache > 0).then(|| format!("{:.0} Mo", cache as f64 / 1e6))),
            ], note: None });
        }
        if which("dnf").is_some() {
            tick("DNF…");
            let (_, o) = run("dnf", &["check-update", "-q"]);
            let outdated = o.lines().filter_map(|l| { let f: Vec<&str> = l.split_whitespace().collect(); (f.len() == 3 && f[0].contains('.')).then(|| Outdated { id: f[0].into(), name: f[0].rsplit_once('.').map(|x| x.0).unwrap_or(f[0]).into(), current: String::new(), latest: f[1].into() }) }).collect();
            v.push(Manager { id: "dnf".into(), name: "DNF".into(), icon: "shippingbox".into(), outdated, actions: vec![
                act("autoremove", "Supprimer les paquets inutiles", "dnf autoremove.", None),
                act("cleanup", "Vider le cache DNF", "dnf clean all.", None),
            ], note: None });
        }
        if which("pacman").is_some() {
            tick("pacman…");
            let (_, o) = if which("checkupdates").is_some() { run("checkupdates", &[]) } else { run("pacman", &["-Qu"]) };
            let outdated = o.lines().filter_map(|l| { let f: Vec<&str> = l.split_whitespace().collect(); (f.len() >= 4).then(|| Outdated { id: f[0].into(), name: f[0].into(), current: f[1].into(), latest: f[3].into() }) }).collect();
            let (_, orph) = run("pacman", &["-Qdtq"]);
            let n = orph.lines().count();
            v.push(Manager { id: "pacman".into(), name: "pacman".into(), icon: "shippingbox".into(), outdated, actions: vec![
                act("autoremove", "Supprimer les paquets orphelins", "pacman -Rns $(pacman -Qdtq).", (n > 0).then(|| format!("{n} paquet(s)"))),
                act("cleanup", "Vider le cache pacman", "pacman -Sc.", None),
            ], note: None });
        }
        if which("flatpak").is_some() {
            tick("Flatpak…");
            let (_, o) = run("flatpak", &["remote-ls", "--updates", "--columns=application,version"]);
            let outdated = o.lines().filter_map(|l| { let f: Vec<&str> = l.split('\t').collect(); (!f[0].is_empty()).then(|| Outdated { id: f[0].into(), name: f[0].rsplit('.').next().unwrap_or(f[0]).into(), current: String::new(), latest: f.get(1).copied().unwrap_or("").into() }) }).collect();
            v.push(Manager { id: "flatpak".into(), name: "Flatpak".into(), icon: "square.stack.3d.up".into(), outdated, actions: vec![
                act("autoremove", "Supprimer les runtimes inutilisés", "flatpak uninstall --unused.", None),
            ], note: None });
        }
        if which("snap").is_some() {
            tick("Snap…");
            let (_, o) = run("snap", &["refresh", "--list"]);
            let outdated = o.lines().skip(1).filter_map(|l| { let f: Vec<&str> = l.split_whitespace().collect(); (f.len() >= 2).then(|| Outdated { id: f[0].into(), name: f[0].into(), current: String::new(), latest: f[1].into() }) }).collect();
            v.push(Manager { id: "snap".into(), name: "Snap".into(), icon: "square.stack.3d.up".into(), outdated, actions: vec![
                act("cleanup", "Supprimer les anciennes versions", "Snap garde 2 à 3 anciennes versions de chaque app.", None),
            ], note: None });
        }
    }

    if which("brew").is_some() {
        tick("Homebrew…");
        let (_, o) = brew("outdated --verbose");
        let re = regex::Regex::new(r"^(\S+) \(([^)]+)\) [<!]=? (.+)$").unwrap();
        let outdated = o.lines().filter_map(|l| re.captures(l).map(|c| Outdated { id: c[1].into(), name: c[1].into(), current: c[2].into(), latest: c[3].into() })).collect();
        let (_, cl) = brew("cleanup --prune=all -n");
        let est = regex::Regex::new(r"approximately ([0-9.,]+\s?[KMGT]?B)").unwrap().captures(&cl).map(|c| c[1].to_string());
        let (_, ar) = brew("autoremove -n");
        let n = ar.lines().filter(|l| !l.starts_with("==>") && !l.trim().is_empty()).count();
        v.push(Manager { id: "brew".into(), name: "Homebrew".into(), icon: "mug".into(), outdated, actions: vec![
            act("cleanup", "Anciennes versions et cache", "brew cleanup --prune=all.", est),
            act("autoremove", "Dépendances orphelines", "brew autoremove.", (n > 0).then(|| format!("{n} paquet(s)"))),
        ], note: None });
    }

    if which("npm").is_some() {
        tick("npm (global)…");
        let (_, o) = run("npm", &["outdated", "-g", "--json"]);
        let outdated = serde_json::from_str::<serde_json::Value>(o.trim()).ok().and_then(|j| j.as_object().cloned()).map(|m| m.into_iter().map(|(k, v)| Outdated {
            id: k.clone(), name: k, current: v["current"].as_str().unwrap_or("").into(), latest: v["latest"].as_str().unwrap_or("").into() }).collect()).unwrap_or_default();
        v.push(Manager { id: "npm".into(), name: "npm (paquets globaux)".into(), icon: "hexagon".into(), outdated, actions: vec![], note: None });
    }
    if which("pipx").is_some() {
        v.push(Manager { id: "pipx".into(), name: "pipx".into(), icon: "chevron.left.forwardslash.chevron.right".into(), outdated: vec![],
            actions: vec![act("upgrade_all", "Mettre à jour tous les outils pipx", "pipx upgrade-all.", None)], note: None });
    }
    if cfg!(target_os = "macos") {
        tick("macOS…");
        let (_, o) = run("/usr/sbin/softwareupdate", &["-l"]);
        let outdated: Vec<Outdated> = o.lines().filter_map(|l| {
            let t = l.trim();
            let title = t.strip_prefix("Title: ")?.split(',').next()?.to_string();
            let ver = t.split("Version: ").nth(1).and_then(|x| x.split(',').next()).unwrap_or("").to_string();
            Some(Outdated { id: title.clone(), name: title, current: String::new(), latest: ver })
        }).collect();
        v.push(Manager { id: "macos".into(), name: "macOS".into(), icon: "apple.logo".into(), outdated, actions: vec![], note: Some("Installe les mises à jour de macOS depuis les Réglages.".into()) });
    }
    v
}

#[tauri::command]
pub async fn packages_status(app: AppHandle) -> Vec<Manager> {
    tauri::async_runtime::spawn_blocking(move || status(&app)).await.unwrap_or_default()
}

#[tauri::command]
pub async fn package_action(manager: String, action: String, target: Option<String>) -> Result<String, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let t = target.clone().unwrap_or_default();
        let q = quote(&t);
        let (c, o) = match (manager.as_str(), action.as_str()) {
            ("winget", "upgrade_all") => run("winget", &["upgrade", "--all", "--silent", "--accept-source-agreements", "--accept-package-agreements", "--disable-interactivity"]),
            ("winget", "upgrade") => run("winget", &["upgrade", "--id", &t, "-e", "--silent", "--accept-source-agreements", "--accept-package-agreements", "--disable-interactivity"]),
            ("scoop", "upgrade_all") => sh("scoop update *"),
            ("scoop", "upgrade") => sh(&format!("scoop update {q}")),
            ("scoop", "cleanup") => sh("scoop cleanup *; scoop cache rm *"),
            ("choco", "upgrade_all") => admin("choco upgrade all -y"),
            ("choco", "upgrade") => admin(&format!("choco upgrade {q} -y")),
            ("apt", "refresh") => admin("apt-get update"),
            ("apt", "upgrade_all") => admin("apt-get update && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y"),
            ("apt", "upgrade") => admin(&format!("DEBIAN_FRONTEND=noninteractive apt-get install --only-upgrade -y {q}")),
            ("apt", "autoremove") => admin("apt-get autoremove -y"),
            ("apt", "cleanup") => admin("apt-get clean"),
            ("dnf", "upgrade_all") => admin("dnf upgrade -y"),
            ("dnf", "upgrade") => admin(&format!("dnf upgrade -y {q}")),
            ("dnf", "autoremove") => admin("dnf autoremove -y"),
            ("dnf", "cleanup") => admin("dnf clean all"),
            ("pacman", "upgrade_all") => admin("pacman -Syu --noconfirm"),
            ("pacman", "autoremove") => admin("o=$(pacman -Qdtq); [ -n \"$o\" ] && pacman -Rns --noconfirm $o; true"),
            ("pacman", "cleanup") => admin("pacman -Sc --noconfirm"),
            ("flatpak", "upgrade_all") => run("flatpak", &["update", "-y", "--noninteractive"]),
            ("flatpak", "upgrade") => run("flatpak", &["update", "-y", "--noninteractive", &t]),
            ("flatpak", "autoremove") => run("flatpak", &["uninstall", "--unused", "-y", "--noninteractive"]),
            ("snap", "upgrade_all") => admin("snap refresh"),
            ("snap", "upgrade") => admin(&format!("snap refresh {q}")),
            ("snap", "cleanup") => admin("snap list --all | awk '/disabled/{print $1, $3}' | while read n r; do snap remove \"$n\" --revision=\"$r\"; done"),
            ("brew", "upgrade_all") => brew("upgrade"),
            ("brew", "upgrade") => brew(&format!("upgrade {q}")),
            ("brew", "cleanup") => brew("cleanup --prune=all"),
            ("brew", "autoremove") => brew("autoremove"),
            ("brew", "uninstall") => brew(&format!("uninstall {q}")),
            ("brew", "uninstall_cask") => brew(&format!("uninstall --cask {q}")),
            ("npm", "upgrade_all") => run("npm", &["update", "-g"]),
            ("npm", "upgrade") => run("npm", &["install", "-g", &format!("{t}@latest")]),
            ("pipx", "upgrade_all") => run("pipx", &["upgrade-all"]),
            ("macos", _) => {
                let _ = run("/usr/bin/open", &["x-apple.systempreferences:com.apple.Software-Update-Settings.extension"]);
                (0, "Réglages ouverts".into())
            }
            _ => (-1, "Action non prise en charge".into()),
        };
        let tail: String = o.trim().chars().rev().take(400).collect::<String>().chars().rev().collect();
        if c == 0 { Ok(tail) } else { Err(if tail.is_empty() { "Échec ou annulé".into() } else { tail }) }
    })
    .await
    .map_err(|e| e.to_string())?
}

/// Homebrew top-level packages with their size (macOS / Linuxbrew).
#[tauri::command]
pub async fn brew_installed() -> Vec<Item> {
    tauri::async_runtime::spawn_blocking(|| {
        if which("brew").is_none() { return vec![]; }
        let prefix = brew("--prefix").1.trim().to_string();
        let leaves: Vec<String> = lines(&brew("leaves").1);
        let casks: Vec<String> = lines(&brew("list --cask -1").1).into_iter().filter(|l| !l.starts_with("Warning")).collect();
        let mut v = vec![];
        for f in leaves {
            let p = join(&std::path::PathBuf::from(&prefix), &format!("Cellar/{f}"));
            let mut it = Item::new(&p, f.clone(), format!("Installé {}", mtime(&p).map(|_| "via Homebrew").unwrap_or("")), size_of(&p), false);
            it.meta = serde_json::json!({ "installed": mtime(&p), "cask": false, "name": f });
            v.push(it);
        }
        for c in casks {
            let p = join(&std::path::PathBuf::from(&prefix), &format!("Caskroom/{c}"));
            let mut it = Item::new(&p, c.clone(), "Application (cask)".to_string(), size_of(&p), false).with_badge("App", "blue");
            it.meta = serde_json::json!({ "installed": mtime(&p), "cask": true, "name": c });
            v.push(it);
        }
        v.sort_by(|a, b| b.size.cmp(&a.size));
        v
    }).await.unwrap_or_default()
}

#[tauri::command]
pub fn open_os_updates() {
    if cfg!(windows) {
        let _ = sh("Start-Process ms-settings:windowsupdate");
    } else if cfg!(target_os = "macos") {
        let _ = run("/usr/bin/open", &["x-apple.systempreferences:com.apple.Software-Update-Settings.extension"]);
    } else {
        for t in ["gnome-software", "plasma-discover", "update-manager", "mintupdate"] {
            if let Some(b) = which(t) {
                let _ = std::process::Command::new(b).spawn();
                break;
            }
        }
    }
}
