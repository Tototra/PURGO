//! Settings, lifetime stats and the background watchdog (low disk, weekly clean, vanished Pythons).

use crate::util::*;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::sync::Mutex;
use std::time::Duration;
use tauri::AppHandle;
use tauri_plugin_notification::NotificationExt;

#[derive(Serialize, Deserialize, Clone)]
#[serde(default)]
pub struct Settings {
    pub alerts_enabled: bool,
    pub alert_gb: f64,
    pub auto_clean: bool,
    pub last_auto_clean: u64,
    pub lifetime_freed: u64,
    pub known_pythons: Vec<String>,
    pub reduce_motion: bool,
}

impl Default for Settings {
    fn default() -> Self {
        Settings {
            alerts_enabled: true,
            alert_gb: 10.0,
            auto_clean: false,
            last_auto_clean: 0,
            lifetime_freed: 0,
            known_pythons: vec![],
            reduce_motion: false,
        }
    }
}

static LOCK: Mutex<()> = Mutex::new(());

fn file() -> PathBuf {
    config("Purgo/settings.json")
}

pub fn load() -> Settings {
    std::fs::read(file()).ok().and_then(|d| serde_json::from_slice(&d).ok()).unwrap_or_default()
}

pub fn save(s: &Settings) {
    let f = file();
    if let Some(p) = f.parent() {
        let _ = std::fs::create_dir_all(p);
    }
    if let Ok(d) = serde_json::to_vec_pretty(s) {
        let _ = std::fs::write(f, d);
    }
}

pub fn update(f: impl FnOnce(&mut Settings)) -> Settings {
    let _g = LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let mut s = load();
    f(&mut s);
    save(&s);
    s
}

pub fn add_freed(b: u64) {
    if b > 0 {
        update(|s| s.lifetime_freed += b);
    }
}

#[tauri::command]
pub fn get_settings() -> Settings {
    load()
}

#[derive(Deserialize)]
pub struct SettingsPatch {
    alerts_enabled: Option<bool>,
    alert_gb: Option<f64>,
    auto_clean: Option<bool>,
    reduce_motion: Option<bool>,
}

#[tauri::command]
pub fn set_settings(patch: SettingsPatch) -> Settings {
    update(|s| {
        if let Some(v) = patch.alerts_enabled { s.alerts_enabled = v; }
        if let Some(v) = patch.alert_gb { s.alert_gb = v; }
        if let Some(v) = patch.auto_clean { s.auto_clean = v; }
        if let Some(v) = patch.reduce_motion { s.reduce_motion = v; }
    })
}

// ---------------------------------------------------------------- watchdog

pub fn notify(app: &AppHandle, title: &str, body: &str) {
    let _ = app.notification().builder().title(title).body(body).show();
}

fn current_pythons() -> Vec<String> {
    let mut v = vec![];
    for cellar in ["/opt/homebrew/Cellar", "/usr/local/Cellar", "/home/linuxbrew/.linuxbrew/Cellar"] {
        for c in children(&PathBuf::from(cellar)) {
            if file_name(&c).starts_with("python@") {
                v.extend(children(&c).into_iter().map(|p| p.to_string_lossy().to_string()));
            }
        }
    }
    let mut roots = vec![hp(".pyenv/versions"), hp(".local/share/uv/python")];
    if let Some(p) = appdata("uv/python") { roots.push(p); }
    if let Some(p) = local_appdata("Programs/Python") { roots.push(p); }
    for r in roots {
        for c in children(&r) {
            if !file_name(&c).starts_with('.') {
                v.push(c.to_string_lossy().to_string());
            }
        }
    }
    v
}

pub fn start_watchdog(app: AppHandle) {
    std::thread::spawn(move || {
        let mut alerted_low = false;
        std::thread::sleep(Duration::from_secs(8));
        loop {
            let s = load();
            if s.alerts_enabled {
                let (free, _) = crate::monitor::home_disk();
                let threshold = s.alert_gb * 1e9;
                if (free as f64) < threshold && !alerted_low {
                    alerted_low = true;
                    notify(&app, "Espace disque faible",
                           &format!("Il ne reste que {:.1} Go. Ouvre Purgo pour faire de la place.", free as f64 / 1e9));
                } else if (free as f64) > threshold * 1.2 {
                    alerted_low = false;
                }

                let now_py = current_pythons();
                if !s.known_pythons.is_empty() {
                    let gone: Vec<String> = s.known_pythons.iter().filter(|p| !now_py.contains(p))
                        .map(|p| file_name(&PathBuf::from(p))).collect();
                    if !gone.is_empty() {
                        notify(&app, "Une version de Python a disparu",
                               &format!("{} n'existe plus : des venv sont peut-être cassés. Vérifie dans Purgo › Python.", gone.join(", ")));
                    }
                }
                update(|x| x.known_pythons = now_py);
            }
            if s.auto_clean && now().saturating_sub(s.last_auto_clean) > 7 * 86400 {
                update(|x| x.last_auto_clean = now());
                let cats = crate::junk::scan_categories(None);
                let targets: Vec<(PathBuf, Option<u64>)> = cats.iter()
                    .filter(|c| c.id == "caches" || c.id == "logs" || c.id == "temp")
                    .flat_map(|c| c.items.iter().filter(|i| i.selected))
                    .flat_map(|i| i.paths.iter().map(move |p| (PathBuf::from(p), Some(i.size))))
                    .collect();
                let r = trash_many(&targets);
                if r.freed > 0 {
                    notify(&app, "Nettoyage automatique",
                           &format!("{:.1} Go de caches et journaux mis à la Corbeille.", r.freed as f64 / 1e9));
                }
            }
            std::thread::sleep(Duration::from_secs(900));
        }
    });
}
