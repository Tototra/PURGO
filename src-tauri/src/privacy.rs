//! Browser traces (history, cookies, cache, sessions) and OS activity traces.

use crate::util::*;
use std::path::PathBuf;
use sysinfo::System;
use tauri::AppHandle;

pub struct Chromium {
    pub id: &'static str,
    pub name: &'static str,
    pub procs: &'static [&'static str],
    mac: &'static str,
    win_local: &'static str,
    win_roaming: &'static str,
    linux: &'static str,
}

pub const CHROMIUM: [Chromium; 7] = [
    Chromium { id: "chrome", name: "Google Chrome", procs: &["chrome", "google chrome"], mac: "Google/Chrome", win_local: "Google/Chrome/User Data", win_roaming: "", linux: "google-chrome" },
    Chromium { id: "chromium", name: "Chromium", procs: &["chromium"], mac: "Chromium", win_local: "Chromium/User Data", win_roaming: "", linux: "chromium" },
    Chromium { id: "brave", name: "Brave", procs: &["brave"], mac: "BraveSoftware/Brave-Browser", win_local: "BraveSoftware/Brave-Browser/User Data", win_roaming: "", linux: "BraveSoftware/Brave-Browser" },
    Chromium { id: "edge", name: "Microsoft Edge", procs: &["msedge", "microsoft edge"], mac: "Microsoft Edge", win_local: "Microsoft/Edge/User Data", win_roaming: "", linux: "microsoft-edge" },
    Chromium { id: "vivaldi", name: "Vivaldi", procs: &["vivaldi"], mac: "Vivaldi", win_local: "Vivaldi/User Data", win_roaming: "", linux: "vivaldi" },
    Chromium { id: "arc", name: "Arc", procs: &["arc"], mac: "Arc/User Data", win_local: "Packages/TheBrowserCompany.Arc_ttt1ap7aakyb4/LocalCache/Local/Arc/User Data", win_roaming: "", linux: "" },
    Chromium { id: "opera", name: "Opera", procs: &["opera"], mac: "com.operasoftware.Opera", win_local: "", win_roaming: "Opera Software/Opera Stable", linux: "opera" },
];

impl Chromium {
    /// The browser's user-data folder on this OS.
    pub fn root(&self) -> Option<PathBuf> {
        if cfg!(target_os = "macos") {
            (!self.mac.is_empty()).then(|| hp(&format!("Library/Application Support/{}", self.mac)))
        } else if cfg!(windows) {
            if !self.win_roaming.is_empty() { appdata(self.win_roaming) } else if !self.win_local.is_empty() { local_appdata(self.win_local) } else { None }
        } else {
            (!self.linux.is_empty()).then(|| hp(&format!(".config/{}", self.linux)))
        }
        .filter(|p| exists(p))
    }

    pub fn profiles(&self) -> Vec<PathBuf> {
        let Some(r) = self.root() else { return vec![] };
        if self.id == "opera" {
            return vec![r];
        }
        children(&r).into_iter().filter(|p| { let n = file_name(p); n == "Default" || n.starts_with("Profile ") }).collect()
    }

    fn cache_roots(&self) -> Vec<PathBuf> {
        if cfg!(target_os = "macos") {
            vec![hp(&format!("Library/Caches/{}", self.mac))]
        } else if cfg!(target_os = "linux") && !self.linux.is_empty() {
            vec![hp(&format!(".cache/{}", self.linux))]
        } else {
            vec![]
        }
    }
}

pub fn running(names: &[&str]) -> bool {
    let mut sys = System::new();
    sys.refresh_processes(sysinfo::ProcessesToUpdate::All, true);
    sys.processes().values().any(|p| {
        let n = p.name().to_string_lossy().to_lowercase();
        let n = n.trim_end_matches(".exe");
        names.iter().any(|x| n == *x || (x.len() > 4 && n.starts_with(x)))
    })
}

fn entry(kind: &str, icon: &str, paths: Vec<PathBuf>, selected: bool) -> Option<Item> {
    let ex: Vec<PathBuf> = paths.into_iter().filter(|p| exists(p)).collect();
    if ex.is_empty() {
        return None;
    }
    let size: u64 = sizes(&ex).iter().sum();
    let mut it = Item::new(&ex[0], kind, "", size, selected);
    it.id = format!("{}#{}", ex[0].to_string_lossy(), kind);
    it.paths = ex.iter().map(|p| p.to_string_lossy().to_string()).collect();
    it.meta = serde_json::json!({ "icon": icon });
    Some(it)
}

fn browser_category(id: &str, name: &str, procs: &[&str], items: Vec<Option<Item>>, note: &str) -> Option<Category> {
    let mut items: Vec<Item> = items.into_iter().flatten().collect();
    if items.is_empty() {
        return None;
    }
    let is_running = running(procs);
    for i in items.iter_mut() {
        if is_running {
            i.selected = false;
            i.badges.push(badge("Navigateur ouvert", "orange"));
        }
    }
    items.retain(|i| i.size > 0);
    if items.is_empty() {
        return None;
    }
    Some(Category {
        id: id.into(),
        name: name.into(),
        icon: "globe".into(),
        info: if is_running { format!("Ferme {name} pour pouvoir effacer ses données. {note}") } else { note.into() },
        items,
    })
}

pub fn scan(app: &AppHandle) -> Vec<Category> {
    let mut out = vec![];

    if cfg!(target_os = "macos") {
        progress(app, "privacy", "Safari", 0);
        let s = hp("Library/Safari");
        let items = vec![
            entry("Historique", "clock", ["History.db", "History.db-wal", "History.db-shm", "History.db-lock"].iter().map(|f| s.join(f)).collect(), true),
            entry("Cookies", "cookie", vec![hp("Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies"), hp("Library/Cookies/Cookies.binarycookies")], true),
            entry("Cache", "internaldrive", vec![hp("Library/Caches/com.apple.Safari"), hp("Library/Containers/com.apple.Safari/Data/Library/Caches")], true),
            entry("Dernière session", "rectangle.stack", vec![s.join("LastSession.plist")], false),
        ];
        if let Some(c) = browser_category("safari", "Safari", &["safari"], items,
            "Si Safari n'apparaît pas, donne à Purgo l'accès complet au disque.") {
            out.push(c);
        }
    }

    for b in CHROMIUM.iter() {
        let profiles = b.profiles();
        if profiles.is_empty() {
            continue;
        }
        progress(app, "privacy", b.name, 0);
        let files = |names: &[&str]| -> Vec<PathBuf> { profiles.iter().flat_map(|p| names.iter().map(move |n| join(p, n))).collect() };
        let mut cache = b.cache_roots();
        cache.extend(files(&["Cache", "Code Cache", "GPUCache", "Service Worker/CacheStorage"]));
        let items = vec![
            entry("Historique", "clock", files(&["History", "History-journal", "Visited Links", "Top Sites", "Top Sites-journal", "Shortcuts", "Shortcuts-journal"]), true),
            entry("Cookies", "cookie", files(&["Cookies", "Cookies-journal", "Network/Cookies", "Network/Cookies-journal"]), true),
            entry("Cache", "internaldrive", cache, true),
            entry("Sessions et onglets", "rectangle.stack", files(&["Sessions", "Current Session", "Last Session", "Current Tabs", "Last Tabs"]), false),
        ];
        if let Some(c) = browser_category(b.id, b.name, b.procs, items, "") {
            out.push(c);
        }
    }

    // Firefox (history is skipped: it lives in the same file as bookmarks)
    let ff_root = if cfg!(target_os = "macos") {
        hp("Library/Application Support/Firefox/Profiles")
    } else if cfg!(windows) {
        appdata("Mozilla/Firefox/Profiles").unwrap_or_default()
    } else if exists(&hp(".mozilla/firefox")) {
        hp(".mozilla/firefox")
    } else {
        hp("snap/firefox/common/.mozilla/firefox")
    };
    let ff: Vec<PathBuf> = children(&ff_root).into_iter().filter(|p| is_dir(p) && exists(&p.join("prefs.js"))).collect();
    if !ff.is_empty() {
        progress(app, "privacy", "Firefox", 0);
        let files = |names: &[&str]| -> Vec<PathBuf> { ff.iter().flat_map(|p| names.iter().map(move |n| join(p, n))).collect() };
        let mut cache: Vec<PathBuf> = vec![];
        for p in &ff {
            let name = file_name(p);
            cache.push(if cfg!(target_os = "macos") {
                hp(&format!("Library/Caches/Firefox/Profiles/{name}"))
            } else if cfg!(windows) {
                local_appdata(&format!("Mozilla/Firefox/Profiles/{name}")).unwrap_or_default()
            } else {
                hp(&format!(".cache/mozilla/firefox/{name}"))
            });
        }
        let items = vec![
            entry("Cookies", "cookie", files(&["cookies.sqlite", "cookies.sqlite-wal"]), true),
            entry("Cache", "internaldrive", cache, true),
            entry("Historique des formulaires", "character.cursor.ibeam", files(&["formhistory.sqlite"]), true),
            entry("Sessions et onglets", "rectangle.stack", files(&["sessionstore.jsonlz4", "sessionstore-backups"]), false),
        ];
        if let Some(c) = browser_category("firefox", "Firefox", &["firefox"], items,
            "L'historique de Firefox n'est pas proposé : il est stocké avec tes favoris.") {
            out.push(c);
        }
    }

    // OS traces
    progress(app, "privacy", "Traces du système", 0);
    let shell_hist = vec![hp(".zsh_history"), hp(".bash_history"), hp(".python_history"), hp(".node_repl_history"), hp(".lesshst")];
    let mut sys = vec![];
    if cfg!(target_os = "macos") {
        let recents: Vec<PathBuf> = children(&hp("Library/Application Support/com.apple.sharedfilelist"))
            .into_iter().filter(|p| file_name(p).contains("Recent")).collect();
        sys.push(entry("Éléments récents", "clock", recents, true));
        sys.push(entry("Historique des téléchargements", "arrow.down.circle", vec![hp("Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2")], true));
    } else if cfg!(windows) {
        sys.push(entry("Éléments récents", "clock", appdata("Microsoft/Windows/Recent").map(|p| children(&p)).unwrap_or_default()
            .into_iter().filter(|p| !is_dir(p)).collect(), true));
        sys.push(entry("Historique PowerShell", "terminal", appdata("Microsoft/Windows/PowerShell/PSReadLine/ConsoleHost_history.txt").into_iter().collect(), false));
    } else {
        sys.push(entry("Fichiers récents", "clock", vec![hp(".local/share/recently-used.xbel")], true));
    }
    sys.push(entry("Historique du terminal", "terminal", shell_hist, false));
    if let Some(c) = browser_category("system", "Traces du système", &[], sys, "") {
        out.push(c);
    }
    out
}

#[tauri::command]
pub async fn scan_privacy(app: AppHandle) -> Vec<Category> {
    tauri::async_runtime::spawn_blocking(move || scan(&app)).await.unwrap_or_default()
}

#[tauri::command]
pub fn quit_browser(id: String) -> usize {
    let names: Vec<String> = match id.as_str() {
        "firefox" => vec!["firefox".into()],
        "safari" => vec!["safari".into()],
        _ => CHROMIUM.iter().find(|b| b.id == id).map(|b| b.procs.iter().map(|s| s.to_string()).collect()).unwrap_or_default(),
    };
    quit_app(names)
}

pub fn quit_app(names: Vec<String>) -> usize {
    let mut sys = System::new();
    sys.refresh_processes(sysinfo::ProcessesToUpdate::All, true);
    let mut n = 0;
    for p in sys.processes().values() {
        let pn = p.name().to_string_lossy().to_lowercase();
        let pn = pn.trim_end_matches(".exe").to_string();
        if names.iter().any(|x| { let x = x.to_lowercase(); pn == x || (x.len() > 4 && pn.starts_with(&x)) }) && p.kill_with(sysinfo::Signal::Term).unwrap_or_else(|| p.kill()) {
            n += 1;
        }
    }
    n
}
