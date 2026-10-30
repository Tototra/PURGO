//! Cloud drive (iCloud / OneDrive), Organizer (Downloads/Desktop), Music projects, Tips.

use crate::util::*;
use serde::Serialize;
use std::path::{Path, PathBuf};
use tauri::AppHandle;

// ---------------------------------------------------------------- cloud

/// (display name, root folder) of the OS cloud drive with on-demand files.
pub fn cloud_root() -> Option<(&'static str, PathBuf)> {
    if cfg!(target_os = "macos") {
        let p = hp("Library/Mobile Documents/com~apple~CloudDocs");
        return exists(&p).then_some(("iCloud Drive", p));
    }
    if cfg!(windows) {
        for var in ["OneDriveConsumer", "OneDrive", "OneDriveCommercial"] {
            if let Some(p) = std::env::var_os(var).map(PathBuf::from).filter(|p| exists(p)) {
                return Some(("OneDrive", p));
            }
        }
    }
    None
}

#[derive(Serialize)]
pub struct CloudFolder {
    pub path: String,
    pub name: String,
    pub local: u64,
    pub total: u64,
}

fn measure(p: &Path) -> (u64, u64) {
    let mut l = 0;
    let mut t = 0;
    for e in walkdir::WalkDir::new(p).follow_links(false).into_iter().filter_map(|e| e.ok()).filter(|e| e.file_type().is_file()) {
        if let Ok(m) = e.metadata() {
            l += alloc_size(&m);
            t += m.len();
        }
    }
    (l, t)
}

#[derive(Serialize)]
pub struct CloudReport {
    pub name: Option<String>,
    pub root: Option<String>,
    pub folders: Vec<CloudFolder>,
}

#[tauri::command]
pub async fn cloud_scan(app: AppHandle) -> CloudReport {
    tauri::async_runtime::spawn_blocking(move || {
        let Some((name, root)) = cloud_root() else { return CloudReport { name: None, root: None, folders: vec![] } };
        let mut folders = vec![];
        for c in children(&root).into_iter().filter(|c| { let n = file_name(c); !n.starts_with('.') && n != "desktop.ini" }) {
            let r = std::fs::canonicalize(&c).unwrap_or(c.clone());
            progress(&app, "cloud", &file_name(&c), 0);
            let (local, total) = measure(&r);
            folders.push(CloudFolder { path: r.to_string_lossy().into(), name: file_name(&c), local, total });
        }
        folders.sort_by_key(|f| std::cmp::Reverse(f.local));
        CloudReport { name: Some(name.into()), root: Some(root.to_string_lossy().into()), folders }
    }).await.unwrap()
}

/// Keeps the files in the cloud and frees their local copy.
#[tauri::command]
pub async fn cloud_free(paths: Vec<String>) -> Vec<CloudFolder> {
    tauri::async_runtime::spawn_blocking(move || {
        let mut out = vec![];
        for p in paths {
            let before = measure(Path::new(&p)).0;
            if cfg!(target_os = "macos") {
                let _ = run("/usr/bin/brctl", &["evict", &p]);
            } else if cfg!(windows) {
                let _ = run("attrib", &["+U", "-P", &p]);
                let _ = run("attrib", &["+U", "-P", &format!("{p}\\*"), "/S", "/D"]);
            }
            std::thread::sleep(std::time::Duration::from_millis(1500));
            let (local, total) = measure(Path::new(&p));
            crate::settings::add_freed(before.saturating_sub(local));
            out.push(CloudFolder { name: file_name(Path::new(&p)), path: p, local, total });
        }
        out
    }).await.unwrap_or_default()
}

pub fn archive_root(sub: &str) -> PathBuf {
    match cloud_root() {
        Some((_, r)) => r.join(sub),
        None => hp(&format!("Archives/{sub}")),
    }
}

pub fn unique(p: &Path) -> PathBuf {
    let mut c = p.to_path_buf();
    let mut i = 2;
    while exists(&c) {
        let stem = p.file_stem().map(|s| s.to_string_lossy().to_string()).unwrap_or_default();
        let e = p.extension().map(|e| format!(".{}", e.to_string_lossy())).unwrap_or_default();
        c = p.with_file_name(format!("{stem} {i}{e}"));
        i += 1;
    }
    c
}

/// Moves a file or folder, falling back to copy + trash across volumes.
pub fn move_item(src: &Path, dest: &Path) -> Result<(), String> {
    if let Some(p) = dest.parent() { std::fs::create_dir_all(p).map_err(|e| e.to_string())?; }
    if std::fs::rename(src, dest).is_ok() { return Ok(()); }
    let (c, o) = if cfg!(windows) {
        sh(&format!("Move-Item -LiteralPath {} -Destination {}", quote(&src.to_string_lossy()), quote(&dest.to_string_lossy())))
    } else {
        run("mv", &[&src.to_string_lossy(), &dest.to_string_lossy()])
    };
    if c == 0 { Ok(()) } else { Err(o) }
}

#[tauri::command]
pub async fn cloud_send(src: String) -> Result<String, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let s = PathBuf::from(&src);
        let dest = unique(&archive_root("Archives Purgo").join(file_name(&s)));
        move_item(&s, &dest)?;
        Ok(dest.to_string_lossy().into())
    }).await.map_err(|e| e.to_string())?
}

// ---------------------------------------------------------------- organizer

const CATEGORIES: [(&str, &[&str]); 8] = [
    ("Documents", &["pdf", "doc", "docx", "pages", "txt", "rtf", "md", "odt", "ods", "odp", "xls", "xlsx", "csv", "numbers", "ppt", "pptx", "key", "epub"]),
    ("Images", &["jpg", "jpeg", "png", "gif", "heic", "webp", "svg", "psd", "ai", "tif", "tiff", "bmp", "xcf", "kra"]),
    ("Audio", &["wav", "aif", "aiff", "mp3", "flac", "m4a", "ogg", "als", "alp", "mid", "midi", "adg", "adv", "flp", "fst", "zpl"]),
    ("Vidéos", &["mov", "mp4", "mkv", "avi", "m4v", "webm", "wmv"]),
    ("Archives", &["zip", "rar", "7z", "tar", "gz", "tgz", "xz", "bz2", "zst"]),
    ("Installeurs", &["dmg", "pkg", "mpkg", "iso", "exe", "msi", "msix", "deb", "rpm", "appimage", "app", "flatpakref"]),
    ("Code", &["py", "ipynb", "js", "ts", "json", "html", "css", "swift", "sh", "ps1", "sql", "java", "c", "cpp", "rb", "go", "rs", "yaml", "yml", "toml"]),
    ("Polices", &["ttf", "otf", "woff", "woff2"]),
];

fn category(p: &Path) -> &'static str {
    let n = file_name(p).to_lowercase();
    if n.starts_with("capture d") || n.starts_with("screenshot") || n.starts_with("enregistrement de l") || n.starts_with("screen recording") {
        return "Captures d'écran";
    }
    let e = ext(p);
    if is_dir(p) && e != "app" { return "Dossiers"; }
    CATEGORIES.iter().find(|(_, exts)| exts.contains(&e.as_str())).map(|(n, _)| *n).unwrap_or("Autres")
}

#[derive(Serialize, serde::Deserialize, Clone)]
pub struct MovePlan {
    pub src: String,
    pub dest: String,
    pub category: String,
    pub size: u64,
    pub selected: bool,
}

#[tauri::command]
pub async fn organize_plan(folder: String, mode: String, days: u64, include_folders: bool) -> Vec<MovePlan> {
    tauri::async_runtime::spawn_blocking(move || {
        let f = PathBuf::from(&folder);
        let names: Vec<&str> = CATEGORIES.iter().map(|c| c.0).chain(["Captures d'écran", "Autres", "Dossiers"]).collect();
        let kids: Vec<PathBuf> = children(&f).into_iter().filter(|c| { let n = file_name(c); !n.starts_with('.') && n != "desktop.ini" && !names.contains(&n.as_str()) }).collect();
        let s = sizes(&kids);
        let mut v = vec![];
        for (c, size) in kids.into_iter().zip(s) {
            if mode == "sort" {
                let cat = category(&c);
                if cat == "Dossiers" && !include_folders { continue; }
                v.push(MovePlan { dest: f.join(cat).join(file_name(&c)).to_string_lossy().into(), src: c.to_string_lossy().into(), category: cat.into(), size, selected: true });
            } else {
                let t = [mtime(&c), atime(&c)].into_iter().flatten().max().unwrap_or(now());
                if days_since(Some(t)) < days { continue; }
                let d = t / 86400;
                let (y, m) = civil_month(d as i64);
                let month = format!("{y}-{m:02}");
                let root = archive_root(&format!("Archives {}", file_name(&f)));
                v.push(MovePlan { dest: root.join(&month).join(file_name(&c)).to_string_lossy().into(), src: c.to_string_lossy().into(), category: month, size, selected: true });
            }
        }
        v.sort_by(|a, b| a.category.cmp(&b.category).then(b.size.cmp(&a.size)));
        v
    }).await.unwrap_or_default()
}

fn civil_month(days: i64) -> (i64, i64) {
    let z = days + 719468;
    let era = if z >= 0 { z } else { z - 146096 } / 146097;
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    (if m <= 2 { y + 1 } else { y }, m)
}

fn log_file() -> PathBuf {
    config("Purgo/last-organize.json")
}

#[tauri::command]
pub async fn organize_apply(plans: Vec<MovePlan>) -> (usize, usize) {
    tauri::async_runtime::spawn_blocking(move || {
        let mut log = vec![];
        let mut errors = 0;
        for p in plans.iter().filter(|p| p.selected) {
            let dest = unique(Path::new(&p.dest));
            match move_item(Path::new(&p.src), &dest) {
                Ok(_) => log.push(serde_json::json!({ "from": p.src, "to": dest.to_string_lossy() })),
                Err(_) => errors += 1,
            }
        }
        let f = log_file();
        let _ = std::fs::create_dir_all(f.parent().unwrap());
        let _ = std::fs::write(&f, serde_json::to_vec(&log).unwrap_or_default());
        (log.len(), errors)
    }).await.unwrap_or((0, 0))
}

#[tauri::command]
pub fn organize_can_undo() -> bool {
    exists(&log_file())
}

#[tauri::command]
pub async fn organize_undo() -> usize {
    tauri::async_runtime::spawn_blocking(|| {
        let Ok(d) = std::fs::read(log_file()) else { return 0 };
        let log: Vec<serde_json::Value> = serde_json::from_slice(&d).unwrap_or_default();
        let mut n = 0;
        for m in log.iter().rev() {
            if let (Some(f), Some(t)) = (m["from"].as_str(), m["to"].as_str()) {
                if move_item(Path::new(t), Path::new(f)).is_ok() { n += 1; }
            }
        }
        let _ = std::fs::remove_file(log_file());
        n
    }).await.unwrap_or(0)
}

// ---------------------------------------------------------------- music

#[derive(Serialize)]
pub struct MusicProject {
    pub path: String,
    pub name: String,
    pub daw: String,
    pub sets: usize,
    pub size: u64,
    pub backup: u64,
    pub backup_path: Option<String>,
    pub modified: Option<u64>,
}

#[tauri::command]
pub async fn music_scan(app: AppHandle) -> Vec<MusicProject> {
    tauri::async_runtime::spawn_blocking(move || {
        let skip: Vec<PathBuf> = home_skips().into_iter().filter(|p| file_name(p) != "Music").collect();
        let dirs = find_dirs(&[home()], &SKIP_NAMES, &skip, |p| progress(&app, "music", &p.to_string_lossy(), 0),
            |p| exists(&p.join("Ableton Project Info")));
        let mut v: Vec<MusicProject> = dirs.iter().map(|d| {
            let sets: Vec<PathBuf> = children(d).into_iter().filter(|f| ext(f) == "als").collect();
            let b = d.join("Backup");
            MusicProject {
                path: d.to_string_lossy().into(),
                name: file_name(d),
                daw: "Ableton Live".into(),
                sets: sets.len(),
                size: size_of(d),
                backup: size_of(&b),
                backup_path: exists(&b).then(|| b.to_string_lossy().into()),
                modified: sets.iter().filter_map(|s| mtime(s)).max(),
            }
        }).collect();
        // FL Studio keeps automatic backups in one folder
        for fl in [hp("Documents/Image-Line/FL Studio/Projects/Backup"), hp("Documents/Image-Line/Data/FL Studio/Projects/Backup")] {
            if exists(&fl) {
                let s = size_of(&fl);
                v.push(MusicProject { path: fl.to_string_lossy().into(), name: "Sauvegardes automatiques".into(), daw: "FL Studio".into(),
                    sets: children(&fl).len(), size: s, backup: s, backup_path: Some(fl.to_string_lossy().into()), modified: mtime(&fl) });
            }
        }
        v.sort_by_key(|x| std::cmp::Reverse(x.modified));
        v
    }).await.unwrap_or_default()
}

#[tauri::command]
pub async fn music_archive(paths: Vec<String>) -> Result<usize, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let root = archive_root("Archives Musique");
        let mut n = 0;
        for p in paths {
            let s = PathBuf::from(&p);
            if move_item(&s, &unique(&root.join(file_name(&s)))).is_ok() { n += 1; }
        }
        Ok(n)
    }).await.map_err(|e| e.to_string())?
}

// ---------------------------------------------------------------- tips

#[derive(Serialize)]
pub struct Tip {
    pub id: &'static str,
    pub icon: &'static str,
    pub title: String,
    pub detail: String,
    pub action: &'static str,
    pub done: Option<bool>,
}

fn tip(id: &'static str, icon: &'static str, title: &str, detail: &str, action: &'static str, done: Option<bool>) -> Tip {
    Tip { id, icon, title: title.into(), detail: detail.into(), action, done }
}

#[cfg(windows)]
fn storage_sense_on() -> bool {
    use winreg::{enums::*, RegKey};
    RegKey::predef(HKEY_CURRENT_USER)
        .open_subkey("Software\\Microsoft\\Windows\\CurrentVersion\\StorageSense\\Parameters\\StoragePolicy")
        .and_then(|k| k.get_value::<u32, _>("01")).map(|v| v == 1).unwrap_or(false)
}

#[tauri::command]
pub async fn tips_list() -> Vec<Tip> {
    tauri::async_runtime::spawn_blocking(|| {
        let mut v = vec![];
        let uv = which("uv").is_some();
        if cfg!(windows) {
            #[cfg(windows)]
            v.push(tip("storagesense", "trash.slash", "Activer l'Assistant de stockage",
                "Windows vide tout seul la Corbeille (après 30 jours) et les fichiers temporaires chaque semaine.", "Activer", Some(storage_sense_on())));
            let hib = PathBuf::from("C:/hiberfil.sys");
            let hib_size = std::fs::metadata(&hib).map(|m| m.len()).unwrap_or(0);
            v.push(tip("hibernate", "moon.zzz", "Désactiver la mise en veille prolongée",
                &format!("Le fichier hiberfil.sys réserve {:.1} Go (environ la taille de ta RAM). À éviter sur un portable que tu laisses souvent en veille longue : cela désactive aussi le démarrage rapide.", hib_size as f64 / 1e9),
                "Désactiver", Some(!exists(&hib))));
            v.push(tip("compactos", "archivebox", "Compresser les fichiers de Windows (CompactOS)",
                "Windows compresse ses propres fichiers système : 2 à 4 Go gagnés, sans effet visible sur un PC récent.", "Compresser", None));
            v.push(tip("onedrive", "icloud", "OneDrive : fichiers à la demande",
                "Les fichiers OneDrive restent visibles mais ne sont téléchargés que quand tu les ouvres. OneDrive › Paramètres › Synchronisation › Fichiers à la demande.", "Ouvrir les réglages", None));
            v.push(tip("restore", "clock.arrow.circlepath", "Limiter les points de restauration",
                "Les points de restauration peuvent occuper jusqu'à 10 % du disque. Protection du système › Configurer › utilisation maximale 3 à 5 %.", "Ouvrir", None));
            v.push(tip("storage", "internaldrive", "Voir le résumé de stockage de Windows", "Pour comparer avec Purgo.", "Ouvrir", None));
        } else if cfg!(target_os = "macos") {
            let trash30 = run("/usr/bin/defaults", &["read", "com.apple.finder", "FXRemoveOldTrashItems"]).1.trim() == "1";
            v.push(tip("trash30", "trash.slash", "Vider la Corbeille automatiquement après 30 jours", "Le Finder supprime ce qui traîne depuis plus d'un mois.", "Activer", Some(trash30)));
            let loc = run("/usr/bin/defaults", &["read", "com.apple.screencapture", "location"]).1;
            v.push(tip("screens", "camera.viewfinder", "Ranger les captures d'écran dans leur propre dossier", "Elles iront dans Images › Captures d'écran au lieu du Bureau.", "Configurer", Some(loc.contains("Captures"))));
            v.push(tip("icloud", "icloud", "Optimiser le stockage du Mac (iCloud Drive)", "macOS ne garde en local que les fichiers iCloud récents quand le disque se remplit.", "Ouvrir les réglages", None));
            v.push(tip("photos", "photo", "Photos : optimiser le stockage", "Les originaux restent dans iCloud. Photos › Réglages › iCloud.", "Ouvrir Photos", None));
            v.push(tip("messages", "message", "Messages : ne garder que la dernière année", "Messages › Réglages › Général › Conserver les messages : 1 an.", "Ouvrir Messages", None));
            v.push(tip("storage", "internaldrive", "Voir le résumé de stockage de macOS", "Pour comparer avec Purgo.", "Ouvrir", None));
        } else {
            if which("gsettings").is_some() {
                let on = run("gsettings", &["get", "org.gnome.desktop.privacy", "remove-old-trash-files"]).1.trim() == "true";
                v.push(tip("gnometrash", "trash.slash", "Vider la Corbeille et les temporaires après 30 jours",
                    "GNOME supprime tout seul les vieux fichiers de la Corbeille et du dossier temporaire.", "Activer", Some(on)));
            }
            let journald = exists(Path::new("/etc/systemd/journald.conf.d/purgo.conf"));
            v.push(tip("journald", "doc.text", "Limiter la taille des journaux système à 300 Mo",
                "Par défaut, journald peut occuper jusqu'à 4 Go.", "Limiter", Some(journald)));
            if which("snap").is_some() {
                let r = run("snap", &["get", "system", "refresh.retain"]).1.trim().to_string();
                v.push(tip("snapretain", "clock.arrow.circlepath", "Ne garder que 2 versions de chaque Snap",
                    "Snap garde 3 anciennes versions de chaque app par défaut.", "Appliquer", Some(r == "2")));
            }
            v.push(tip("storage", "internaldrive", "Analyser le disque avec l'outil du système", "Ouvre l'analyseur d'utilisation des disques (Baobab / Filelight).", "Ouvrir", None));
        }
        v.push(tip("uv", "bolt", "Utiliser uv pour tes environnements Python",
            "uv crée un venv en une seconde et partage les paquets entre projets au lieu de les recopier : un seul torch sur le disque pour tous tes projets.",
            "Installer uv", Some(uv)));
        v.push(tip("ableton", "waveform", "Ableton Live : limiter le cache de décodage",
            "Live décompresse les MP3/FLAC dans un cache qui grossit sans fin. Réglages › Fichier/Dossier › Cache de décodage : taille maximale 2 Go.", "", None));
        v
    }).await.unwrap_or_default()
}

#[tauri::command]
pub async fn tip_apply(id: String) -> Result<String, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let (c, o) = match id.as_str() {
            "storagesense" => {
                #[cfg(windows)]
                {
                    use winreg::{enums::*, RegKey};
                    let (k, _) = RegKey::predef(HKEY_CURRENT_USER)
                        .create_subkey("Software\\Microsoft\\Windows\\CurrentVersion\\StorageSense\\Parameters\\StoragePolicy").map_err(|e| e.to_string())?;
                    for (n, v) in [("01", 1u32), ("2048", 7), ("04", 1), ("08", 1), ("256", 30), ("32", 1)] { let _ = k.set_value(n, &v); }
                }
                (0, String::new())
            }
            "hibernate" => admin("powercfg /h off"),
            "compactos" => admin("compact /compactos:always"),
            "onedrive" => sh("Start-Process ms-settings:storagesense"),
            "restore" => sh("Start-Process SystemPropertiesProtection.exe"),
            "storage" => {
                if cfg!(windows) { sh("Start-Process ms-settings:storagesense") }
                else if cfg!(target_os = "macos") { run("/usr/bin/open", &["x-apple.systempreferences:com.apple.settings.Storage"]) }
                else {
                    ["baobab", "filelight", "qdirstat"].iter().find_map(|t| which(t)).map(|b| { let _ = std::process::Command::new(b).spawn(); (0, String::new()) })
                        .unwrap_or((-1, "Aucun analyseur de disque installé".into()))
                }
            }
            "trash30" => run("/usr/bin/defaults", &["write", "com.apple.finder", "FXRemoveOldTrashItems", "-bool", "true"]),
            "screens" => {
                let dir = hp("Pictures/Captures d'écran");
                let _ = std::fs::create_dir_all(&dir);
                let r = run("/usr/bin/defaults", &["write", "com.apple.screencapture", "location", &dir.to_string_lossy()]);
                let _ = run("/usr/bin/killall", &["SystemUIServer"]);
                r
            }
            "icloud" => run("/usr/bin/open", &["x-apple.systempreferences:com.apple.preferences.AppleIDPrefPane"]),
            "photos" => run("/usr/bin/open", &["-a", "Photos"]),
            "messages" => run("/usr/bin/open", &["-a", "Messages"]),
            "gnometrash" => {
                let _ = run("gsettings", &["set", "org.gnome.desktop.privacy", "old-files-age", "uint32 30"]);
                let _ = run("gsettings", &["set", "org.gnome.desktop.privacy", "remove-old-temp-files", "true"]);
                run("gsettings", &["set", "org.gnome.desktop.privacy", "remove-old-trash-files", "true"])
            }
            "journald" => admin("mkdir -p /etc/systemd/journald.conf.d && printf '[Journal]\\nSystemMaxUse=300M\\n' > /etc/systemd/journald.conf.d/purgo.conf && systemctl restart systemd-journald && journalctl --vacuum-size=300M"),
            "snapretain" => admin("snap set system refresh.retain=2"),
            "uv" => {
                if cfg!(windows) && which("winget").is_some() { run("winget", &["install", "--id=astral-sh.uv", "-e", "--accept-source-agreements", "--accept-package-agreements", "--disable-interactivity"]) }
                else if which("brew").is_some() { run("brew", &["install", "uv"]) }
                else if which("pipx").is_some() { run("pipx", &["install", "uv"]) }
                else { (-1, "Installe d'abord Homebrew, pipx ou winget, puis réessaie.".into()) }
            }
            _ => (-1, "Conseil inconnu".into()),
        };
        if c == 0 { Ok("Fait".into()) } else { Err(o) }
    }).await.map_err(|e| e.to_string())?
}
