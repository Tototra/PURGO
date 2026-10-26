//! System junk: caches, logs, temp files, installers, crash dumps… for each OS.

use crate::util::*;
use std::path::PathBuf;
use tauri::AppHandle;

fn kids_except(dir: PathBuf, skip_prefixes: &[&str]) -> Vec<PathBuf> {
    children(&dir)
        .into_iter()
        .filter(|c| {
            let n = file_name(c);
            n != ".DS_Store" && n != ".localized" && n != "desktop.ini" && !skip_prefixes.iter().any(|p| n.starts_with(p))
        })
        .collect()
}

fn some(v: Option<PathBuf>) -> Vec<PathBuf> {
    v.into_iter().collect()
}

fn installers() -> Vec<PathBuf> {
    let exts = ["dmg", "pkg", "mpkg", "iso", "exe", "msi", "msix", "deb", "rpm", "appimage", "run"];
    let mut v = vec![];
    for d in [hp("Downloads"), hp("Desktop")] {
        for c in children(&d) {
            if exts.contains(&ext(&c).as_str()) {
                v.push(c);
            }
        }
    }
    v
}

fn old_screenshots() -> Vec<PathBuf> {
    let mut v = vec![];
    for d in [hp("Desktop"), hp("Pictures/Screenshots"), hp("Pictures/Captures d'écran"), hp("Images/Captures d’écran"),
              hp("Pictures/Captures d’écran"), hp("Images/Screenshots")] {
        for c in children(&d) {
            let n = file_name(&c).to_lowercase();
            let is_shot = n.starts_with("capture d") || n.starts_with("screenshot") || n.starts_with("capture") ||
                          n.starts_with("enregistrement de l") || n.starts_with("screen recording");
            if is_shot && days_since(mtime(&c)) > 30 {
                v.push(c);
            }
        }
    }
    v
}

pub fn dev_cache_paths() -> Vec<(PathBuf, String, String)> {
    let mut v: Vec<(PathBuf, String, String)> = vec![];
    let mut add = |p: PathBuf, n: &str| v.push((p, n.to_string(), "Cache de développement, retéléchargé si besoin".to_string()));
    add(hp(".npm/_cacache"), "Cache npm");
    add(cache("pip"), "Cache pip");
    add(hp(".cache/pip"), "Cache pip");
    add(cache("uv"), "Cache uv");
    add(hp(".cache/uv"), "Cache uv");
    add(hp(".gradle/caches"), "Cache Gradle");
    add(hp(".cargo/registry/cache"), "Cache Cargo");
    add(hp("go/pkg/mod/cache"), "Cache Go");
    add(cache("go-build"), "Cache de compilation Go");
    add(hp(".bun/install/cache"), "Cache Bun");
    add(cache("Yarn"), "Cache Yarn");
    add(cache("yarn"), "Cache Yarn");
    add(hp("Library/Developer/Xcode/DerivedData"), "Xcode DerivedData");
    add(hp("Library/Developer/CoreSimulator/Caches"), "Caches du simulateur iOS");
    add(hp(".nuget/packages"), "Paquets NuGet");
    if let Some(p) = local_appdata("npm-cache") { add(p, "Cache npm"); }
    if let Some(p) = local_appdata("NuGet/v3-cache") { add(p, "Cache NuGet"); }
    // de-duplicate
    let mut seen = std::collections::HashSet::new();
    v.retain(|x| seen.insert(x.0.clone()));
    v
}

fn push(cats: &mut Vec<Category>, c: Category, app: Option<&AppHandle>) {
    let name = c.name.clone();
    cats.push(c);
    if let Some(a) = app {
        let total: u64 = cats.iter().flat_map(|c| c.items.iter()).map(|i| i.size).sum();
        progress(a, "junk", &name, total);
    }
}

pub fn scan_categories(app: Option<&AppHandle>) -> Vec<Category> {
    let tick = |t: &str| {
        if let Some(a) = app {
            progress(a, "junk", t, 0);
        }
    };
    let mut cats = vec![];

    // --- application caches
    tick("Caches des applications…");
    let caches: Vec<PathBuf> = if cfg!(target_os = "macos") {
        kids_except(hp("Library/Caches"), &["com.apple.", "CloudKit", "com.purgo", "FamilyCircle", "GeoServices"])
    } else if cfg!(windows) {
        let mut v = vec![];
        for rel in ["Microsoft/Windows/INetCache", "D3DSCache", "NVIDIA/DXCache", "NVIDIA/GLCache", "AMD/DxCache",
                    "Spotify/Storage", "Spotify/Data", "Microsoft/Windows/Explorer/ThumbCacheToDelete",
                    "Packages/Microsoft.Windows.Photos_8wekyb3d8bbwe/LocalCache", "Steam/htmlcache"] {
            v.extend(some(local_appdata(rel)));
        }
        for rel in ["discord/Cache", "discord/Code Cache", "Slack/Cache", "Slack/Service Worker/CacheStorage",
                    "Microsoft/Teams/Cache", "Code/Cache", "Code/CachedData", "Code/CachedExtensionVSIXs"] {
            v.extend(some(appdata(rel)));
        }
        v
    } else {
        kids_except(hp(".cache"), &["fontconfig", "mesa_shader_cache_db", "ibus", "dconf"])
    };
    let caches = caches.into_iter().filter(|p| {
        // keep dev caches in their own category
        !dev_cache_paths().iter().any(|(d, _, _)| d == p)
    }).collect();
    if let Some(c) = Category::new("caches", "Caches des applications", "internaldrive",
        "Fichiers temporaires recréés automatiquement par tes applications.", items_for(caches, true)) {
        push(&mut cats, c, app);
    }

    // --- temporary files
    tick("Fichiers temporaires…");
    let temp: Vec<PathBuf> = if cfg!(windows) {
        let mut v = kids_except(std::env::temp_dir(), &[]);
        if let Some(p) = local_appdata("Temp") {
            if p != std::env::temp_dir() { v.extend(kids_except(p, &[])); }
        }
        v.retain(|p| days_since(mtime(p)) >= 1);
        v
    } else if cfg!(target_os = "linux") {
        children(&PathBuf::from("/tmp")).into_iter()
            .filter(|p| days_since(mtime(p)) >= 2 && owned_by_me(p))
            .collect()
    } else {
        vec![]
    };
    if let Some(c) = Category::new("temp", "Fichiers temporaires", "clock.arrow.circlepath",
        "Fichiers laissés dans le dossier temporaire depuis plus d'un jour.", items_for(temp, true)) {
        push(&mut cats, c, app);
    }

    // --- logs & crash reports
    tick("Journaux et rapports de plantage…");
    let logs: Vec<PathBuf> = if cfg!(target_os = "macos") {
        kids_except(hp("Library/Logs"), &[])
    } else if cfg!(windows) {
        let mut v = vec![];
        for rel in ["CrashDumps", "Microsoft/Windows/WER/ReportArchive", "Microsoft/Windows/WER/ReportQueue"] {
            v.extend(some(local_appdata(rel)));
        }
        v
    } else {
        let mut v = vec![hp(".xsession-errors"), hp(".xsession-errors.old"), hp(".local/share/xorg")];
        v.extend(children(&hp(".local/state")).into_iter().flat_map(|d| {
            children(&d).into_iter().filter(|p| file_name(p).ends_with(".log") || file_name(p) == "log" || file_name(p) == "logs")
        }));
        v
    };
    if let Some(c) = Category::new("logs", "Journaux et rapports de plantage", "doc.text",
        "Historique technique des applications, inutile au quotidien.", items_for(logs, true)) {
        push(&mut cats, c, app);
    }

    // --- installers
    tick("Installeurs téléchargés…");
    if let Some(c) = Category::new("installers", "Installeurs téléchargés", "shippingbox",
        "Fichiers .dmg, .exe, .msi, .deb, .AppImage… restés dans Téléchargements et sur le Bureau.", items_for(installers(), true)) {
        push(&mut cats, c, app);
    }

    // --- OS-specific big items
    if cfg!(target_os = "macos") {
        let mac_inst: Vec<PathBuf> = children(&PathBuf::from("/Applications")).into_iter()
            .filter(|p| { let n = file_name(p); n.starts_with("Install macOS") || n.starts_with("Installer macOS") }).collect();
        if let Some(c) = Category::new("macos", "Installeurs de macOS", "apple.logo",
            "Les apps « Installer macOS » restées après une mise à jour (environ 12 Go chacune).", items_for(mac_inst, true)) {
            push(&mut cats, c, app);
        }
        if let Some(c) = Category::new("mail", "Pièces jointes Mail", "paperclip",
            "Copies locales des pièces jointes ouvertes depuis Mail (elles restent dans les e-mails).",
            items_for(vec![hp("Library/Containers/com.apple.mail/Data/Library/Mail Downloads")], true)) {
            push(&mut cats, c, app);
        }
        if let Some(c) = Category::new("messages", "Pièces jointes de Messages", "message",
            "Photos et fichiers reçus dans Messages. Ils disparaîtront aussi des conversations.",
            items_for(children(&hp("Library/Messages/Attachments")), false)) {
            push(&mut cats, c, app);
        }
        if let Some(c) = Category::new("ios", "Sauvegardes iPhone / iPad", "iphone",
            "Sauvegardes locales d'appareils. À garder si tu n'utilises pas la sauvegarde iCloud.",
            items_for(children(&hp("Library/Application Support/MobileSync/Backup")), false)) {
            push(&mut cats, c, app);
        }
    }
    if cfg!(windows) {
        let mut big = vec![];
        for p in ["C:/Windows.old", "C:/$WINDOWS.~BT", "C:/$Windows.~WS", "C:/Windows/SoftwareDistribution/Download",
                  "C:/ProgramData/Microsoft/Windows/WER/ReportArchive", "C:/Windows/Temp"] {
            big.push(PathBuf::from(p));
        }
        if let Some(c) = Category::new("winsys", "Fichiers système de Windows", "windows",
            "Ancienne installation (Windows.old), mises à jour téléchargées, temporaires système. Demande les droits administrateur.",
            items_for(big, false)) {
            push(&mut cats, c, app);
        }
        if let Some(c) = Category::new("ios", "Sauvegardes iPhone / iPad", "iphone",
            "Sauvegardes iTunes locales.", items_for([appdata("Apple Computer/MobileSync/Backup"), Some(hp("Apple/MobileSync/Backup"))]
                .into_iter().flatten().flat_map(|d| children(&d)).collect(), false)) {
            push(&mut cats, c, app);
        }
    }
    if cfg!(target_os = "linux") {
        let mut v = vec![hp(".local/share/recently-used.xbel.bak")];
        v.extend(children(&hp(".local/share/flatpak/.removed")));
        if let Some(c) = Category::new("linuxsys", "Restes de Flatpak et divers", "shippingbox",
            "Anciennes versions Flatpak supprimées mais encore présentes.", items_for(v, true)) {
            push(&mut cats, c, app);
        }
    }

    // --- screenshots
    if let Some(c) = Category::new("screens", "Vieilles captures d'écran", "camera.viewfinder",
        "Captures et enregistrements d'écran de plus de 30 jours.", items_for(old_screenshots(), false)) {
        push(&mut cats, c, app);
    }

    // --- dev caches
    tick("Caches de développement…");
    if let Some(c) = Category::new("dev", "Caches de développement", "hammer",
        "npm, pip, uv, Gradle, Cargo, Go, Xcode… retéléchargés si besoin.", named_items(dev_cache_paths(), false)) {
        push(&mut cats, c, app);
    }
    cats
}

#[cfg(unix)]
fn owned_by_me(p: &std::path::Path) -> bool {
    use std::os::unix::fs::MetadataExt;
    let me = std::fs::metadata(home()).map(|m| m.uid()).unwrap_or(u32::MAX);
    std::fs::symlink_metadata(p).map(|m| m.uid() == me).unwrap_or(false)
}
#[cfg(not(unix))]
fn owned_by_me(_p: &std::path::Path) -> bool {
    false
}

#[tauri::command]
pub async fn scan_junk(app: AppHandle) -> Vec<Category> {
    tauri::async_runtime::spawn_blocking(move || scan_categories(Some(&app))).await.unwrap_or_default()
}
