//! Space lens (folder sizes), large & old files, duplicates (SHA-256).

use crate::util::*;
use rayon::prelude::*;
use serde::Serialize;
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use tauri::AppHandle;
use walkdir::WalkDir;

#[derive(Serialize)]
pub struct Node {
    pub path: String,
    pub name: String,
    pub is_dir: bool,
    pub size: u64,
}

/// Roots offered by the space lens: home, every disk.
#[tauri::command]
pub fn lens_roots() -> Vec<(String, String)> {
    let mut v = vec![("Dossier personnel".to_string(), home().to_string_lossy().to_string())];
    for d in sysinfo::Disks::new_with_refreshed_list().list() {
        let mp = d.mount_point().to_string_lossy().to_string();
        if cfg!(target_os = "linux") && (mp.starts_with("/boot") || mp.starts_with("/snap") || mp.starts_with("/run") || mp.starts_with("/var/snap")) { continue; }
        if cfg!(target_os = "macos") && mp.starts_with("/System/Volumes") && mp != "/System/Volumes/Data" { continue; }
        let label = if mp == "/" { if cfg!(target_os = "macos") { "Macintosh HD".to_string() } else { "Disque système (/)".to_string() } } else { format!("{} ({mp})", d.name().to_string_lossy()) };
        if !v.iter().any(|(_, p)| *p == mp) { v.push((label, mp)); }
    }
    v
}

#[tauri::command]
pub async fn dir_children(path: String) -> Vec<Node> {
    tauri::async_runtime::spawn_blocking(move || {
        let kids: Vec<PathBuf> = children(Path::new(&path)).into_iter().filter(|p| { let n = file_name(p); n != ".DS_Store" && n != "desktop.ini" }).collect();
        let mut v: Vec<Node> = kids.par_iter().map(|p| Node {
            path: p.to_string_lossy().into(),
            name: file_name(p),
            is_dir: is_dir(p) && !is_symlink(p) && ext(p) != "app",
            size: size_of(p),
        }).collect();
        v.sort_by(|a, b| b.size.cmp(&a.size));
        v
    }).await.unwrap_or_default()
}

fn kind_of(e: &str) -> &'static str {
    match e {
        "mov" | "mp4" | "mkv" | "avi" | "m4v" | "webm" | "wmv" => "video",
        "wav" | "aif" | "aiff" | "mp3" | "flac" | "m4a" | "ogg" | "alac" => "audio",
        "zip" | "rar" | "7z" | "tar" | "gz" | "tgz" | "xz" | "bz2" | "dmg" | "iso" | "pkg" | "img" | "msi" | "exe" | "deb" | "rpm" | "appimage" | "vhdx" | "vdi" | "vmdk" | "qcow2" => "archive",
        "jpg" | "jpeg" | "png" | "heic" | "psd" | "tif" | "tiff" | "raw" | "cr2" | "nef" | "dng" => "image",
        "pdf" | "doc" | "docx" | "ppt" | "pptx" | "key" | "pages" | "xls" | "xlsx" | "numbers" => "document",
        _ => "other",
    }
}

fn skip_for_files(p: &Path) -> bool {
    let h = home();
    let n = file_name(p);
    n == ".Trash" || n == "$Recycle.Bin" || n == "node_modules" || n == ".git"
        || p == h.join("Library") || p == h.join("AppData") || p == h.join(".local/share/Trash")
        || (cfg!(target_os = "linux") && ["/proc", "/sys", "/dev", "/run"].iter().any(|v| p == Path::new(v)))
}

#[tauri::command]
pub async fn large_files(app: AppHandle, root: String, min_mb: u64) -> Vec<Item> {
    tauri::async_runtime::spawn_blocking(move || {
        let min = min_mb * 1_000_000;
        let mut out = vec![];
        let mut n = 0u64;
        let it = WalkDir::new(&root).follow_links(false).same_file_system(true).into_iter()
            .filter_entry(|e| !(e.file_type().is_dir() && (skip_for_files(e.path()) || (e.depth() > 0 && ext(e.path()) == "app"))));
        for e in it.filter_map(|e| e.ok()) {
            n += 1;
            if n % 3000 == 0 { progress(&app, "large", &e.path().to_string_lossy(), n); }
            if !e.file_type().is_file() { continue; }
            let Ok(m) = e.metadata() else { continue };
            let s = alloc_size(&m);
            if s < min { continue; }
            let accessed = secs(m.accessed()).max(secs(m.modified()));
            let p = e.path();
            let mut it = Item::new(p, file_name(p), tilde(&parent_str(p)), s, false);
            it.meta = serde_json::json!({ "kind": kind_of(&ext(p)), "accessed": accessed });
            out.push(it);
        }
        out.sort_by(|a, b| b.size.cmp(&a.size));
        out
    }).await.unwrap_or_default()
}

fn hash(p: &Path, partial: bool) -> Option<String> {
    let mut f = std::fs::File::open(p).ok()?;
    let mut h = Sha256::new();
    let mut buf = vec![0u8; 1 << 16];
    if partial {
        let n = f.read(&mut buf).ok()?;
        h.update(&buf[..n]);
        let len = f.metadata().ok()?.len();
        if len > 131072 {
            f.seek(SeekFrom::Start(len - 65536)).ok()?;
            let n = f.read(&mut buf).ok()?;
            h.update(&buf[..n]);
        }
    } else {
        loop {
            let n = f.read(&mut buf).ok()?;
            if n == 0 { break; }
            h.update(&buf[..n]);
        }
    }
    Some(format!("{:x}", h.finalize()))
}

#[derive(Serialize)]
pub struct DupGroup {
    pub size: u64,
    pub files: Vec<Item>,
}

#[tauri::command]
pub async fn duplicates(app: AppHandle, root: String, min_kb: u64) -> Vec<DupGroup> {
    tauri::async_runtime::spawn_blocking(move || {
        let min = min_kb * 1000;
        let mut by_size: HashMap<u64, Vec<(PathBuf, u64)>> = HashMap::new();
        let mut n = 0u64;
        let it = WalkDir::new(&root).follow_links(false).same_file_system(true).into_iter()
            .filter_entry(|e| !(e.file_type().is_dir() && (skip_for_files(e.path()) || (e.depth() > 0 && ext(e.path()) == "app"))));
        for e in it.filter_map(|e| e.ok()) {
            if !e.file_type().is_file() { continue; }
            let Ok(m) = e.metadata() else { continue };
            if m.len() < min.max(1) || alloc_size(&m) == 0 { continue; }
            n += 1;
            if n % 2000 == 0 { progress(&app, "dups", &format!("{n} fichiers indexés"), 0); }
            let created = secs(m.created()).or(secs(m.modified())).unwrap_or(0);
            by_size.entry(m.len()).or_default().push((e.path().to_path_buf(), created));
        }
        let candidates: Vec<(u64, Vec<(PathBuf, u64)>)> = by_size.into_iter().filter(|(_, v)| v.len() > 1).collect();
        let total = candidates.len();
        let done = std::sync::atomic::AtomicUsize::new(0);
        let mut groups: Vec<DupGroup> = candidates.into_par_iter().flat_map(|(size, files)| {
            let d = done.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            if d % 50 == 0 { progress(&app, "dups", &format!("Comparaison {d}/{total}"), 0); }
            let mut partial: HashMap<String, Vec<(PathBuf, u64)>> = HashMap::new();
            for f in files { if let Some(h) = hash(&f.0, true) { partial.entry(h).or_default().push(f); } }
            let mut out = vec![];
            for (_, p) in partial.into_iter().filter(|(_, v)| v.len() > 1) {
                let mut full: HashMap<String, Vec<(PathBuf, u64)>> = HashMap::new();
                for f in p { if let Some(h) = hash(&f.0, false) { full.entry(h).or_default().push(f); } }
                for (_, mut same) in full.into_iter().filter(|(_, v)| v.len() > 1) {
                    same.sort_by_key(|x| x.1);
                    let files = same.iter().enumerate().map(|(i, (p, _))| {
                        let mut it = Item::new(p, file_name(p), tilde(&parent_str(p)), size, i != 0);
                        if i == 0 { it.badges.push(badge("Original (le plus ancien)", "green")); }
                        it
                    }).collect();
                    out.push(DupGroup { size, files });
                }
            }
            out
        }).collect();
        groups.sort_by(|a, b| (b.size * (b.files.len() as u64 - 1)).cmp(&(a.size * (a.files.len() as u64 - 1))));
        groups
    }).await.unwrap_or_default()
}
