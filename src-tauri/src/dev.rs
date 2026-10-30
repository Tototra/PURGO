//! Developer modules: Node.js, Git repositories, Docker, local AI models.

use crate::util::*;
use serde::Serialize;
use std::path::{Path, PathBuf};
use tauri::AppHandle;

// ---------------------------------------------------------------- Node.js

#[tauri::command]
pub async fn node_scan(app: AppHandle) -> Vec<Item> {
    tauri::async_runtime::spawn_blocking(move || {
        let mut out = vec![];
        let skip = home_skips();
        let dirs = find_dirs(&[home()], &SKIP_NAMES, &skip, |p| progress(&app, "node", &p.to_string_lossy(), 0),
            |p| file_name(p) == "node_modules" && exists(&p.parent().unwrap_or(p).join("package.json")));
        let mut total = 0u64;
        for d in dirs {
            let proj = d.parent().unwrap_or(&d).to_path_buf();
            let s = size_of(&d);
            total += s;
            progress(&app, "node", &d.to_string_lossy(), total);
            let touched = [mtime(&proj.join("package.json")), mtime(&proj)].into_iter().flatten().max();
            let mut it = Item::new(&d, format!("{} › node_modules", file_name(&proj)),
                format!("{} · npm install pour le recréer", tilde(&proj.to_string_lossy())), s, days_since(touched) > 90);
            it.meta = serde_json::json!({ "touched": touched });
            if days_since(touched) > 90 { it.badges.push(badge("Inactif +3 mois", "orange")); }
            out.push(it);
        }
        let nvm_root = if cfg!(windows) { appdata("nvm").unwrap_or_default() } else { hp(".nvm/versions/node") };
        let def = std::fs::read_to_string(hp(".nvm/alias/default")).unwrap_or_default().trim().to_string();
        for v in children(&nvm_root).into_iter().filter(|v| is_dir(v) && file_name(v).starts_with('v')) {
            let mut it = Item::new(&v, format!("Node {}", file_name(&v)), "Version installée avec nvm".to_string(), size_of(&v), false);
            if !def.is_empty() && file_name(&v).trim_start_matches('v').starts_with(def.trim_start_matches('v')) { it.badges.push(badge("Par défaut", "green")); }
            out.push(it);
        }
        let mut caches: Vec<(PathBuf, String, String)> = vec![];
        let c = |p: PathBuf, n: &str| (p, n.to_string(), "Cache global, retéléchargé à la demande".to_string());
        caches.push(c(hp(".npm/_cacache"), "Cache npm"));
        caches.push(c(cache("Yarn"), "Cache Yarn"));
        caches.push(c(hp(".cache/yarn"), "Cache Yarn"));
        caches.push(c(hp(".yarn/berry/cache"), "Cache Yarn Berry"));
        caches.push(c(hp("Library/pnpm/store"), "Store pnpm"));
        caches.push(c(hp(".local/share/pnpm/store"), "Store pnpm"));
        caches.push(c(hp(".bun/install/cache"), "Cache Bun"));
        caches.push(c(cache("ms-playwright"), "Navigateurs Playwright"));
        caches.push(c(hp(".cache/puppeteer"), "Chrome de Puppeteer"));
        caches.push(c(cache("node-gyp"), "En-têtes node-gyp"));
        for (rel, n) in [("npm-cache", "Cache npm"), ("Yarn/Cache", "Cache Yarn"), ("pnpm/store", "Store pnpm"), ("ms-playwright", "Navigateurs Playwright")] {
            if let Some(p) = local_appdata(rel) { caches.push(c(p, n)); }
        }
        caches.sort_by(|a, b| a.0.cmp(&b.0));
        caches.dedup_by(|a, b| a.0 == b.0);
        out.extend(named_items(caches, true));
        out.retain(|i| i.size > 0);
        out.sort_by_key(|o| std::cmp::Reverse(o.size));
        out
    }).await.unwrap_or_default()
}

// ---------------------------------------------------------------- Git

#[derive(Serialize)]
pub struct Repo {
    pub path: String,
    pub name: String,
    pub branch: String,
    pub last_commit: Option<u64>,
    pub ahead: u32,
    pub dirty: u32,
    pub upstream: bool,
    pub remote: Option<String>,
    pub web: Option<String>,
    pub size: u64,
    pub git_size: u64,
    pub saved: bool,
}

fn web_url(remote: &str) -> Option<String> {
    let mut r = remote.to_string();
    if r.starts_with("git@") { r = r.replacen(':', "/", 1).replacen("git@", "https://", 1); }
    if r.ends_with(".git") { r.truncate(r.len() - 4); }
    r.starts_with("http").then_some(r)
}

pub fn inspect(u: &Path) -> Repo {
    let p = u.to_string_lossy().to_string();
    let last_commit = run("git", &["-C", &p, "log", "-1", "--format=%ct"]).1.trim().parse::<u64>().ok();
    let (_, st) = run("git", &["-C", &p, "status", "--porcelain=v2", "--branch"]);
    let (mut branch, mut ahead, mut dirty, mut upstream) = ("?".to_string(), 0u32, 0u32, false);
    for l in st.lines() {
        if let Some(b) = l.strip_prefix("# branch.head ") { branch = b.into(); }
        else if let Some(ab) = l.strip_prefix("# branch.ab ") { upstream = true; ahead = ab.split_whitespace().next().unwrap_or("+0").trim_start_matches('+').parse().unwrap_or(0); }
        else if !l.starts_with('#') && !l.starts_with('!') && !l.is_empty() { dirty += 1; }
    }
    let (c, o) = run("git", &["-C", &p, "remote", "get-url", "origin"]);
    let remote = (c == 0 && !o.trim().is_empty()).then(|| o.trim().to_string());
    Repo {
        path: p,
        name: file_name(u),
        branch,
        last_commit,
        ahead,
        dirty,
        upstream,
        web: remote.as_deref().and_then(web_url),
        saved: remote.is_some() && upstream && ahead == 0 && dirty == 0,
        remote,
        size: size_of(u),
        git_size: size_of(&u.join(".git")),
    }
}

#[tauri::command]
pub async fn git_scan(app: AppHandle) -> Result<Vec<Repo>, String> {
    tauri::async_runtime::spawn_blocking(move || {
        if which("git").is_none() { return Err("Git n'est pas installé sur cet ordinateur.".to_string()); }
        let skip = home_skips();
        let h = home();
        let dirs = find_dirs(std::slice::from_ref(&h), &SKIP_NAMES, &skip, |p| progress(&app, "git", &p.to_string_lossy(), 0), |p| {
            let rel = p.strip_prefix(&h).map(|r| r.to_string_lossy().to_string()).unwrap_or_default();
            !rel.starts_with('.') && exists(&p.join(".git"))
        });
        let mut total = 0;
        let mut v = vec![];
        for d in dirs {
            let r = inspect(&d);
            total += r.size;
            progress(&app, "git", &r.path, total);
            v.push(r);
        }
        v.sort_by_key(|x| std::cmp::Reverse(x.size));
        Ok(v)
    }).await.map_err(|e| e.to_string())?
}

#[tauri::command]
pub async fn git_gc(path: String) -> Repo {
    tauri::async_runtime::spawn_blocking(move || {
        let _ = run("git", &["-C", &path, "gc", "--prune=now", "--quiet"]);
        inspect(Path::new(&path))
    }).await.unwrap()
}

// ---------------------------------------------------------------- Docker

fn docker_bin() -> Option<String> {
    which("docker").map(|p| p.to_string_lossy().to_string()).or_else(|| {
        [PathBuf::from("/Applications/Docker.app/Contents/Resources/bin/docker"), hp(".docker/bin/docker"), hp(".orbstack/bin/docker"),
         PathBuf::from("C:/Program Files/Docker/Docker/resources/bin/docker.exe")]
            .into_iter().find(|p| p.is_file()).map(|p| p.to_string_lossy().to_string())
    })
}

fn docker(args: &[&str]) -> (i32, String) {
    match docker_bin() { Some(b) => run(&b, args), None => (-1, "Docker n'est pas installé".into()) }
}

fn rows(args: &[&str]) -> Vec<serde_json::Value> {
    docker(args).1.lines().filter_map(|l| serde_json::from_str(l).ok()).collect()
}

#[derive(Serialize)]
pub struct DockerStatus {
    pub installed: bool,
    pub running: bool,
    pub usage: Vec<serde_json::Value>,
    pub items: Vec<Item>,
    pub disk_image: Option<(String, u64)>,
}

#[tauri::command]
pub async fn docker_status() -> DockerStatus {
    tauri::async_runtime::spawn_blocking(|| {
        let img = [hp("Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw"), hp(".docker/desktop/vms/0/data/Docker.raw")]
            .into_iter().chain([local_appdata("Docker/wsl/disk/docker_data.vhdx"), local_appdata("Docker/wsl/data/ext4.vhdx")].into_iter().flatten())
            .find(|p| exists(p)).map(|p| (p.to_string_lossy().to_string(), size_of(&p)));
        let installed = docker_bin().is_some();
        if !installed || docker(&["info", "--format", "{{.ServerVersion}}"]).0 != 0 {
            return DockerStatus { installed, running: false, usage: vec![], items: vec![], disk_image: img };
        }
        let mut items = vec![];
        for r in rows(&["ps", "-a", "--filter", "status=exited", "--filter", "status=created", "--format", "{{json .}}"]) {
            let mut it = Item { id: format!("container:{}", r["ID"].as_str().unwrap_or("")), name: r["Names"].as_str().unwrap_or("?").into(),
                detail: format!("Conteneur arrêté · {} · {}", r["Image"].as_str().unwrap_or(""), r["Status"].as_str().unwrap_or("")), selected: true, ..Default::default() };
            it.meta = serde_json::json!({ "kind": "container", "ref": r["ID"], "size": r["Size"] });
            items.push(it);
        }
        for r in rows(&["images", "--format", "{{json .}}"]) {
            let dangling = r["Repository"].as_str() == Some("<none>");
            let mut it = Item { id: format!("image:{}", r["ID"].as_str().unwrap_or("")), name: format!("{}:{}", r["Repository"].as_str().unwrap_or("?"), r["Tag"].as_str().unwrap_or("")),
                detail: format!("Image · créée {}", r["CreatedSince"].as_str().unwrap_or("")), selected: dangling, ..Default::default() };
            if dangling { it.badges.push(badge("Orpheline", "orange")); }
            it.meta = serde_json::json!({ "kind": "image", "ref": r["ID"], "size": r["Size"] });
            items.push(it);
        }
        for r in rows(&["volume", "ls", "-f", "dangling=true", "--format", "{{json .}}"]) {
            let mut it = Item { id: format!("volume:{}", r["Name"].as_str().unwrap_or("")), name: r["Name"].as_str().unwrap_or("?").into(),
                detail: "Volume utilisé par aucun conteneur".into(), ..Default::default() };
            it.meta = serde_json::json!({ "kind": "volume", "ref": r["Name"], "size": "" });
            items.push(it);
        }
        DockerStatus { installed, running: true, usage: rows(&["system", "df", "--format", "{{json .}}"]), items, disk_image: img }
    }).await.unwrap()
}

#[tauri::command]
pub async fn docker_cmd(args: Vec<String>) -> Result<String, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let allowed = ["system", "image", "container", "volume", "builder", "rm", "rmi"];
        if !args.first().map(|a| allowed.contains(&a.as_str())).unwrap_or(false) { return Err("Commande refusée".into()); }
        let a: Vec<&str> = args.iter().map(String::as_str).collect();
        let (c, o) = docker(&a);
        let reclaimed = o.lines().find(|l| l.contains("reclaimed space")).map(String::from).unwrap_or_else(|| "Terminé".into());
        if c == 0 { Ok(reclaimed) } else { Err(o) }
    }).await.map_err(|e| e.to_string())?
}

#[tauri::command]
pub fn docker_start() {
    if cfg!(target_os = "macos") {
        let _ = run("/usr/bin/open", &["-a", "Docker"]);
    } else if cfg!(windows) {
        let _ = sh("Start-Process 'C:\\Program Files\\Docker\\Docker\\Docker Desktop.exe'");
    } else {
        let _ = run("systemctl", &["--user", "start", "docker-desktop"]);
    }
}

// ---------------------------------------------------------------- AI models

pub fn ollama_root() -> PathBuf {
    if let Ok(p) = std::env::var("OLLAMA_MODELS") { return PathBuf::from(p); }
    let user = hp(".ollama/models");
    if exists(&user) || !cfg!(target_os = "linux") { user } else { PathBuf::from("/usr/share/ollama/.ollama/models") }
}

struct Manifest { name: String, path: PathBuf, digests: Vec<String>, size: u64 }

fn manifests() -> Vec<Manifest> {
    let mroot = ollama_root().join("manifests");
    let mut out = vec![];
    for e in walkdir::WalkDir::new(&mroot).into_iter().filter_map(|e| e.ok()).filter(|e| e.file_type().is_file()) {
        let Ok(d) = std::fs::read(e.path()) else { continue };
        let Ok(j) = serde_json::from_slice::<serde_json::Value>(&d) else { continue };
        let mut layers: Vec<serde_json::Value> = j["layers"].as_array().cloned().unwrap_or_default();
        if !j["config"].is_null() { layers.push(j["config"].clone()); }
        let digests = layers.iter().filter_map(|l| l["digest"].as_str().map(String::from)).collect();
        let size = layers.iter().filter_map(|l| l["size"].as_u64()).sum();
        let rel = e.path().strip_prefix(&mroot).map(|r| r.to_string_lossy().replace('\\', "/")).unwrap_or_default();
        let mut comps: Vec<&str> = rel.split('/').collect();
        if comps.first() == Some(&"registry.ollama.ai") { comps.remove(0); }
        if comps.first() == Some(&"library") { comps.remove(0); }
        let tag = comps.pop().unwrap_or("latest");
        out.push(Manifest { name: format!("{}:{tag}", comps.join("/")), path: e.path().to_path_buf(), digests, size });
    }
    out
}

fn blob(d: &str) -> PathBuf {
    ollama_root().join("blobs").join(d.replace(':', "-"))
}

#[tauri::command]
pub async fn ai_scan(app: AppHandle) -> Vec<Item> {
    tauri::async_runtime::spawn_blocking(move || {
        let mut out: Vec<Item> = vec![];
        let mut add = |p: &Path, name: String, source: &str, size: Option<u64>| {
            let s = size.unwrap_or_else(|| size_of(p));
            if s == 0 { return; }
            let used = atime(p).max(mtime(p));
            let mut it = Item::new(p, name, source.to_string(), s, false);
            it.meta = serde_json::json!({ "used": used, "source": source });
            out.push(it);
            progress(&app, "ai", &p.to_string_lossy(), out.iter().map(|i| i.size).sum());
        };
        for m in manifests() { add(&m.path, m.name.clone(), "Ollama", Some(m.size)); }
        for c in children(&hp(".cache/huggingface/hub")) {
            let n = file_name(&c);
            for (pre, label) in [("models--", "Hugging Face"), ("datasets--", "Hugging Face (dataset)"), ("spaces--", "Hugging Face (space)")] {
                if let Some(rest) = n.strip_prefix(pre) { add(&c, rest.replace("--", "/"), label, None); }
            }
        }
        for r in [hp(".lmstudio/models"), hp(".cache/lm-studio/models")] {
            for p in children(&r).into_iter().filter(|p| is_dir(p)) {
                for m in children(&p).into_iter().filter(|m| is_dir(m)) { add(&m, format!("{}/{}", file_name(&p), file_name(&m)), "LM Studio", None); }
            }
        }
        for f in children(&hp(".cache/whisper")) { add(&f, file_name(&f), "Whisper", None); }
        let gpt4all = if cfg!(target_os = "macos") { hp("Library/Application Support/nomic.ai/GPT4All") } else if cfg!(windows) { local_appdata("nomic.ai/GPT4All").unwrap_or_default() } else { hp(".local/share/nomic.ai/GPT4All") };
        for f in children(&gpt4all).into_iter().filter(|f| ext(f) == "gguf" || ext(f) == "bin") { add(&f, file_name(&f), "GPT4All", None); }
        for f in children(&hp(".cache/torch/hub/checkpoints")) { add(&f, file_name(&f), "PyTorch Hub", None); }
        for f in children(&hp(".cache/torch/sentence_transformers")) { add(&f, file_name(&f), "Sentence Transformers", None); }
        out.sort_by_key(|o| std::cmp::Reverse(o.size));
        out
    }).await.unwrap_or_default()
}

/// Deleting an Ollama model = its manifest + the blobs no other model uses.
#[tauri::command]
pub async fn ai_delete(paths: Vec<String>, sizes: Vec<u64>) -> TrashResult {
    tauri::async_runtime::spawn_blocking(move || {
        let all = manifests();
        let sel: Vec<String> = paths.iter().filter(|p| all.iter().any(|m| m.path.to_string_lossy() == **p)).cloned().collect();
        let keep: std::collections::HashSet<String> = all.iter().filter(|m| !sel.contains(&m.path.to_string_lossy().to_string())).flat_map(|m| m.digests.clone()).collect();
        let drop: std::collections::HashSet<String> = all.iter().filter(|m| sel.contains(&m.path.to_string_lossy().to_string())).flat_map(|m| m.digests.clone()).filter(|d| !keep.contains(d)).collect();
        let mut targets: Vec<(PathBuf, Option<u64>)> = paths.iter().zip(sizes.iter()).map(|(p, s)| (PathBuf::from(p), Some(*s))).collect();
        targets.extend(drop.iter().map(|d| (blob(d), Some(0))));
        trash_many(&targets)
    }).await.unwrap()
}
