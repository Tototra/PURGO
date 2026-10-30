//! Python: virtual environments, interpreters, packages, caches.

use crate::util::*;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use tauri::AppHandle;

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct PyPackage {
    pub name: String,
    pub version: String,
    pub size: u64,
}

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct PyEnv {
    pub path: String,
    pub name: String,
    pub kind: String,
    pub project: Option<String>,
    pub version: String,
    pub base_home: Option<String>,
    pub broken: bool,
    pub tool_owned: bool,
    pub last_used: Option<u64>,
    pub size: u64,
    pub packages: Vec<PyPackage>,
}

#[derive(Serialize, Clone, Debug)]
pub struct PyInterpreter {
    pub root: String,
    pub binary: String,
    pub version: String,
    pub source: String,
    pub removable: bool,
    pub size: u64,
    pub used_by: Vec<String>,
}

#[derive(Serialize)]
pub struct PyReport {
    pub envs: Vec<PyEnv>,
    pub interpreters: Vec<PyInterpreter>,
    pub caches: Vec<Category>,
    pub uv: bool,
}

const USER_ENV_DIRS: [&str; 6] = [".venvs", ".virtualenvs", ".pyenv", ".local", ".conda", ".tox"];
const PROJECT_CACHES: [&str; 6] = ["__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache", ".ipynb_checkpoints", ".hypothesis"];

pub fn uv_path() -> Option<PathBuf> {
    which("uv")
}

fn env_python(env: &Path) -> PathBuf {
    if cfg!(windows) {
        let s = env.join("Scripts/python.exe");
        if exists(&s) { s } else { env.join("python.exe") }
    } else {
        env.join("bin/python")
    }
}

fn site_packages(env: &Path) -> Vec<PathBuf> {
    let mut v = vec![];
    let lib = env.join("Lib/site-packages");
    if exists(&lib) { v.push(lib); }
    for c in children(&env.join("lib")) {
        if file_name(&c).starts_with("python") {
            let sp = c.join("site-packages");
            if exists(&sp) { v.push(sp); }
        }
    }
    v
}

fn parse_cfg(env: &Path) -> HashMap<String, String> {
    let mut d = HashMap::new();
    if let Ok(s) = std::fs::read_to_string(env.join("pyvenv.cfg")) {
        for l in s.lines() {
            if let Some((k, v)) = l.split_once('=') {
                d.insert(k.trim().to_lowercase(), v.trim().to_string());
            }
        }
    }
    d
}

fn refine(p: &Path, conda: bool) -> &'static str {
    let s = p.to_string_lossy().replace('\\', "/");
    if conda { return "Conda"; }
    if s.contains("/pypoetry/virtualenvs/") || s.contains("/pypoetry/Cache/virtualenvs/") { return "Poetry"; }
    if s.contains("/pipx/venvs/") { return "pipx"; }
    if s.contains("/.local/share/virtualenvs/") { return "Pipenv"; }
    if s.contains("/.virtualenvs/") || s.contains("/Envs/") { return "virtualenvwrapper"; }
    if s.contains("/.pyenv/versions/") { return "pyenv-virtualenv"; }
    if s.contains("/uv/tools/") { return "uv tool"; }
    if s.contains("/.tox/") || s.contains("/.nox/") { return "tox/nox"; }
    "venv"
}

pub fn packages(env: &Path) -> Vec<PyPackage> {
    let mut out = vec![];
    for sp in site_packages(env) {
        for d in children(&sp).into_iter().filter(|d| ext(d) == "dist-info") {
            let mut name = String::new();
            let mut version = String::new();
            if let Ok(meta) = std::fs::read_to_string(d.join("METADATA")) {
                for l in meta.lines().take(40) {
                    if let Some(v) = l.strip_prefix("Name: ") { name = v.into(); }
                    if let Some(v) = l.strip_prefix("Version: ") { version = v.into(); }
                    if !name.is_empty() && !version.is_empty() { break; }
                }
            }
            if name.is_empty() {
                let base = file_name(&d).trim_end_matches(".dist-info").to_string();
                let mut it = base.splitn(2, '-');
                name = it.next().unwrap_or("").into();
                version = it.next().unwrap_or("").into();
            }
            let size: u64 = std::fs::read_to_string(d.join("RECORD")).map(|r| r.lines().filter_map(|l| l.rsplit(',').next().and_then(|x| x.trim().parse::<u64>().ok())).sum()).unwrap_or(0);
            out.push(PyPackage { name, version, size });
        }
    }
    out.sort_by_key(|o| std::cmp::Reverse(o.size));
    out
}

pub fn make_env(u: &Path, conda: bool) -> PyEnv {
    let kind = refine(u, conda);
    let cfg = parse_cfg(u);
    let sp = site_packages(u);
    let mut version = cfg.get("version").or(cfg.get("version_info")).cloned().unwrap_or_default();
    if version.is_empty() {
        if let Some(lib) = sp.first().and_then(|p| p.parent()).map(file_name) {
            version = lib.trim_start_matches("python").to_string();
        }
    }
    if conda {
        if let Some(f) = children(&u.join("conda-meta")).into_iter().map(|p| file_name(&p)).find(|n| n.starts_with("python-") && n.ends_with(".json")) {
            version = f.split('-').nth(1).unwrap_or("").to_string();
        }
    }
    let rel = u.strip_prefix(home()).ok().map(|r| r.to_string_lossy().replace('\\', "/")).unwrap_or_default();
    let top = rel.split('/').next().unwrap_or("").to_string();
    let tool_owned = (top.starts_with('.') && !USER_ENV_DIRS.contains(&top.as_str())) || rel.starts_with("AppData/");
    let parent = u.parent().map(Path::to_path_buf).unwrap_or_default();
    let project = if tool_owned { None } else if kind == "venv" && parent != home() { Some(parent) } else if kind == "tox/nox" { parent.parent().map(Path::to_path_buf) } else { None };
    // pyvenv.cfg is read by the scan itself, so its access time would always say "today":
    // use the activation script instead (read when the venv is activated) and the bin folder.
    let bin = u.join(if cfg!(windows) { "Scripts" } else { "bin" });
    let mut dates = vec![atime(&bin.join(if cfg!(windows) { "activate.bat" } else { "activate" })), mtime(&bin)];
    dates.extend(sp.iter().map(|s| mtime(s)));
    let name = match &project { Some(p) => format!("{} › {}", file_name(p), file_name(u)), None => file_name(u) };
    PyEnv {
        path: u.to_string_lossy().into(),
        name,
        kind: kind.into(),
        project: project.map(|p| p.to_string_lossy().into()),
        version,
        base_home: cfg.get("home").cloned(),
        broken: !std::fs::metadata(env_python(u)).is_ok(),
        tool_owned,
        last_used: dates.into_iter().flatten().max(),
        size: 0,
        packages: vec![],
    }
}

fn conda_bases() -> Vec<PathBuf> {
    let mut v: Vec<PathBuf> = ["miniconda3", "anaconda3", "miniforge3", "mambaforge", "opt/anaconda3", "opt/miniconda3", "AppData/Local/miniconda3", "AppData/Local/anaconda3"]
        .iter().map(|r| hp(r)).collect();
    for p in ["/opt/homebrew/Caskroom/miniconda/base", "/opt/homebrew/Caskroom/miniforge/base", "/opt/miniconda3", "/opt/anaconda3", "/opt/conda", "C:/ProgramData/miniconda3", "C:/ProgramData/Anaconda3"] {
        v.push(PathBuf::from(p));
    }
    v.into_iter().filter(|p| exists(&p.join("conda-meta"))).collect()
}

fn version_of(bin: &Path) -> String {
    run(&bin.to_string_lossy(), &["--version"]).1.trim().trim_start_matches("Python ").to_string()
}

fn canon(p: &Path) -> String {
    std::fs::canonicalize(p).unwrap_or_else(|_| p.to_path_buf()).to_string_lossy().to_string()
}

pub fn interpreters(envs: &[PyEnv]) -> Vec<PyInterpreter> {
    let mut list: Vec<(PathBuf, PathBuf, String, bool, PathBuf)> = vec![]; // root, bin, source, removable, match_root
    let mut add = |root: PathBuf, bin: PathBuf, source: &str, removable: bool, m: Option<PathBuf>| {
        if bin.is_file() { list.push((root.clone(), bin, source.into(), removable, m.unwrap_or(root))); }
    };
    if cfg!(target_os = "macos") {
        let clt = PathBuf::from("/Library/Developer/CommandLineTools");
        add(clt.join("Library/Frameworks/Python3.framework"), clt.join("usr/bin/python3"), "macOS (outils de ligne de commande)", false, Some(clt));
        for v in children(&PathBuf::from("/Library/Frameworks/Python.framework/Versions")).into_iter().filter(|v| file_name(v) != "Current") {
            add(v.clone(), v.join("bin/python3"), "python.org", true, None);
        }
    }
    if cfg!(target_os = "linux") {
        let py3_minor = regex::Regex::new(r"^python3\.\d+$").unwrap();
        for c in children(&PathBuf::from("/usr/bin")) {
            let n = file_name(&c);
            if py3_minor.is_match(&n) {
                add(c.clone(), c.clone(), "Système (paquet de la distribution)", false, Some(PathBuf::from("/usr")));
            }
        }
    }
    if cfg!(windows) {
        if let Some(base) = local_appdata("Programs/Python") {
            for v in children(&base) { add(v.clone(), v.join("python.exe"), "python.org", false, None); }
        }
        for v in children(&hp(".pyenv/pyenv-win/versions")) { add(v.clone(), v.join("python.exe"), "pyenv-win", true, None); }
        if let Some(base) = appdata("uv/python") {
            for v in children(&base).into_iter().filter(|v| !file_name(v).starts_with('.') && !is_symlink(v)) { add(v.clone(), v.join("python.exe"), "uv", true, None); }
        }
    }
    for cellar in ["/opt/homebrew/Cellar", "/usr/local/Cellar", "/home/linuxbrew/.linuxbrew/Cellar"] {
        for c in children(&PathBuf::from(cellar)).into_iter().filter(|c| file_name(c).starts_with("python@")) {
            let minor = file_name(&c).trim_start_matches("python@").to_string();
            for v in children(&c).into_iter().filter(|v| is_dir(v)) {
                add(v.clone(), v.join(format!("bin/python{minor}")), &format!("Homebrew ({})", file_name(&c)), true, None);
            }
        }
    }
    for v in children(&hp(".pyenv/versions")).into_iter().filter(|v| !is_symlink(v)) { add(v.clone(), v.join("bin/python"), "pyenv", true, None); }
    for v in children(&hp(".local/share/uv/python")).into_iter().filter(|v| is_dir(v) && !is_symlink(v) && !file_name(v).starts_with('.')) {
        add(v.clone(), v.join("bin/python3"), "uv", true, None);
    }
    for b in conda_bases() {
        let bin = if cfg!(windows) { b.join("python.exe") } else { b.join("bin/python") };
        add(b.clone(), bin, "Conda (installation de base)", true, None);
    }

    let roots: Vec<PathBuf> = list.iter().map(|x| x.0.clone()).collect();
    let s = sizes(&roots);
    list.into_iter().zip(s).map(|((root, bin, source, removable, m), size)| {
        let mroot = canon(&m);
        let used_by = envs.iter().filter(|e| {
            if source.starts_with("Conda") && e.path.starts_with(&root.to_string_lossy().to_string()) && e.path != root.to_string_lossy() { return true; }
            let target = canon(&env_python(Path::new(&e.path)));
            let base = e.base_home.as_ref().map(|h| canon(Path::new(h))).unwrap_or_default();
            target.starts_with(&mroot) || (!base.is_empty() && base.starts_with(&mroot))
        }).map(|e| e.name.clone()).collect();
        let bin_s = bin.to_string_lossy().to_string();
        PyInterpreter { root: root.to_string_lossy().into(), version: version_of(&bin), binary: bin_s, source, removable, size, used_by }
    }).collect()
}

fn broken_kernels() -> Vec<Item> {
    let roots: Vec<PathBuf> = [Some(hp("Library/Jupyter/kernels")), Some(hp(".local/share/jupyter/kernels")), appdata("jupyter/kernels"),
        Some(PathBuf::from("/usr/local/share/jupyter/kernels")), Some(PathBuf::from("/opt/homebrew/share/jupyter/kernels"))].into_iter().flatten().collect();
    let mut out = vec![];
    for r in roots {
        for k in children(&r) {
            let Ok(d) = std::fs::read(k.join("kernel.json")) else { continue };
            let Ok(j) = serde_json::from_slice::<serde_json::Value>(&d) else { continue };
            let exe = j["argv"][0].as_str().unwrap_or("");
            if Path::new(exe).is_absolute() && !exists(Path::new(exe)) {
                let mut it = Item::new(&k, j["display_name"].as_str().unwrap_or(&file_name(&k)).to_string(), format!("Pointe vers {}, qui n'existe plus", tilde(exe)), size_of(&k), true);
                it.badges.push(badge("Cassé", "red"));
                out.push(it);
            }
        }
    }
    out
}

fn caches(project_caches: Vec<PathBuf>) -> Vec<Category> {
    let mut pkg: Vec<PathBuf> = vec![cache("pip"), hp(".cache/pip"), cache("uv"), hp(".cache/uv"), cache("pypoetry/cache"), cache("pypoetry/artifacts"),
        hp(".cache/pypoetry/cache"), hp(".cache/pypoetry/artifacts"), cache("pipenv"), hp(".cache/pipenv"), cache("pdm"), hp(".cache/pre-commit")];
    pkg.extend([local_appdata("pip/Cache"), local_appdata("uv/cache"), local_appdata("pypoetry/Cache/cache"), local_appdata("pypoetry/Cache/artifacts")].into_iter().flatten());
    pkg.extend(conda_bases().into_iter().map(|b| b.join("pkgs")));
    pkg.sort();
    pkg.dedup();
    let mut v = vec![];
    v.extend(Category::new("pkg", "Caches de téléchargement de paquets", "shippingbox", "pip, uv, Poetry, Pipenv, Conda… Retéléchargés si besoin.", items_for(pkg, true)));
    v.extend(Category::new("proj", "Caches dans tes projets", "folder.badge.gearshape", "__pycache__, .pytest_cache, .mypy_cache, .ruff_cache, .ipynb_checkpoints. Recréés automatiquement.", items_for(project_caches, true)));
    v.extend(Category::new("ml", "Modèles de machine learning téléchargés", "brain", "Hugging Face, PyTorch Hub, Keras, Whisper. Lourds, mais à retélécharger si tu les supprimes.",
        items_for(vec![hp(".cache/huggingface"), hp(".cache/torch"), hp(".keras"), hp(".cache/whisper")], false)));
    v.extend(Category::new("kernels", "Noyaux Jupyter cassés", "exclamationmark.triangle", "Ils apparaissent dans Jupyter mais pointent vers un environnement supprimé.", broken_kernels()));
    v
}

pub fn scan(app: &AppHandle) -> PyReport {
    let mut found: Vec<(PathBuf, bool)> = vec![];
    let mut proj_caches = vec![];
    let skip = home_skips();
    let mut skip_names: Vec<&str> = SKIP_NAMES.iter().copied().filter(|n| *n != "__pycache__").collect();
    skip_names.push("site-packages");
    let _ = find_dirs(&[home()], &skip_names, &skip, |p| progress(app, "python", &p.to_string_lossy(), 0), |p| {
        let n = file_name(p);
        if PROJECT_CACHES.contains(&n.as_str()) { proj_caches.push(p.to_path_buf()); return true; }
        if exists(&p.join("pyvenv.cfg")) { found.push((p.to_path_buf(), false)); return true; }
        if exists(&p.join("conda-meta")) { found.push((p.to_path_buf(), true)); return true; }
        false
    });
    // locations outside the walk
    let mut extra_roots = vec![cache("pypoetry/virtualenvs"), hp(".cache/pypoetry/virtualenvs"), hp(".local/share/virtualenvs"), hp(".local/pipx/venvs"),
                               hp(".local/share/pipx/venvs"), hp(".local/share/uv/tools"), hp(".virtualenvs"), hp("Envs")];
    extra_roots.extend([local_appdata("pypoetry/Cache/virtualenvs"), appdata("uv/tools"), local_appdata("pipx/pipx/venvs")].into_iter().flatten());
    for r in extra_roots {
        for c in children(&r) {
            if exists(&c.join("pyvenv.cfg")) && !found.iter().any(|f| f.0 == c) { found.push((c, false)); }
        }
    }
    for b in conda_bases() {
        if !found.iter().any(|f| f.0 == b) { found.push((b.clone(), true)); }
        for e in children(&b.join("envs")) {
            if exists(&e.join("conda-meta")) && !found.iter().any(|f| f.0 == e) { found.push((e, true)); }
        }
    }
    for v in children(&hp(".pyenv/versions")) {
        for e in children(&v.join("envs")) {
            if exists(&e.join("pyvenv.cfg")) && !found.iter().any(|f| f.0 == e) { found.push((e, false)); }
        }
    }

    let mut envs: Vec<PyEnv> = found.iter().map(|(p, c)| make_env(p, *c)).collect();
    let mut total = 0u64;
    for e in envs.iter_mut() {
        let p = PathBuf::from(&e.path);
        e.size = size_of(&p);
        e.packages = packages(&p);
        total += e.size;
        progress(app, "python", &e.path, total);
    }
    envs.sort_by(|a, b| a.path.cmp(&b.path));
    progress(app, "python", "Interpréteurs Python…", total);
    let interpreters = interpreters(&envs);
    progress(app, "python", "Caches Python…", total);
    PyReport { envs, interpreters, caches: caches(proj_caches), uv: uv_path().is_some() }
}

#[tauri::command]
pub async fn python_scan(app: AppHandle) -> PyReport {
    tauri::async_runtime::spawn_blocking(move || scan(&app)).await.unwrap()
}

#[tauri::command]
pub async fn python_refresh_env(path: String, kind: String) -> PyEnv {
    tauri::async_runtime::spawn_blocking(move || {
        let p = PathBuf::from(&path);
        let mut e = make_env(&p, kind == "Conda");
        e.size = size_of(&p);
        e.packages = packages(&p);
        e
    }).await.unwrap()
}

#[tauri::command]
pub async fn python_uninstall(env: String, package: String) -> Result<String, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let py = env_python(Path::new(&env)).to_string_lossy().to_string();
        let (c, o) = run(&py, &["-m", "pip", "uninstall", "-y", &package]);
        if c == 0 { return Ok(o); }
        if let Some(uv) = uv_path() {
            let (c2, o2) = run(&uv.to_string_lossy(), &["pip", "uninstall", "--python", &py, &package]);
            if c2 == 0 { return Ok(o2); }
            return Err(o2);
        }
        Err(o)
    }).await.map_err(|e| e.to_string())?
}

pub fn save_requirements(env: &PyEnv) -> Option<PathBuf> {
    let pkgs = if env.packages.is_empty() { packages(Path::new(&env.path)) } else { env.packages.clone() };
    if pkgs.is_empty() { return None; }
    let minor: String = env.version.split('.').take(2).collect::<Vec<_>>().join(".");
    let mut lines: Vec<String> = pkgs.iter().map(|p| format!("{}=={}", p.name, p.version)).collect();
    lines.sort_by_key(|l| l.to_lowercase());
    let text = format!("# Sauvegardé par Purgo\n# Environnement : {} · Python {}\n# Pour le recréer : uv venv --python {} && uv pip install -r <ce fichier>\n\n{}\n",
                       tilde(&env.path), env.version, minor, lines.join("\n"));
    let dir = env.project.as_ref().map(PathBuf::from).unwrap_or_else(|| hp("Documents/Purgo/requirements"));
    let _ = std::fs::create_dir_all(&dir);
    let base = file_name(Path::new(&env.path)).trim_matches('.').to_string();
    let f = dir.join(format!("requirements-{}-purgo.txt", if base.is_empty() { "venv".into() } else { base }));
    std::fs::write(&f, text).ok().map(|_| f)
}

#[tauri::command]
pub async fn python_save_requirements(env: PyEnv) -> Result<String, String> {
    tauri::async_runtime::spawn_blocking(move || save_requirements(&env).map(|p| p.to_string_lossy().to_string()).ok_or("Aucun paquet à sauvegarder".to_string()))
        .await.map_err(|e| e.to_string())?
}

#[tauri::command]
pub async fn python_trash_envs(envs: Vec<PyEnv>, save: bool) -> TrashResult {
    tauri::async_runtime::spawn_blocking(move || {
        if save {
            for e in envs.iter().filter(|e| !e.tool_owned) { let _ = save_requirements(e); }
        }
        trash_many(&envs.iter().map(|e| (PathBuf::from(&e.path), Some(e.size))).collect::<Vec<_>>())
    }).await.unwrap()
}

#[tauri::command]
pub async fn python_recreate(env: PyEnv) -> Result<String, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let proj = PathBuf::from(env.project.clone().ok_or("Aucun projet associé à cet environnement")?);
        let minor: String = env.version.split('.').take(2).collect::<Vec<_>>().join(".");
        let req = if exists(&proj.join("requirements.txt")) { Some(proj.join("requirements.txt")) } else { save_requirements(&env) };
        let r = trash_many(&[(PathBuf::from(&env.path), Some(env.size))]);
        if !r.errors.is_empty() { return Err("Impossible de déplacer l'ancien environnement".into()); }
        let envp = env.path.clone();
        let newpy = env_python(Path::new(&envp)).to_string_lossy().to_string();
        let (c, o) = if let Some(uv) = uv_path() {
            let uv = uv.to_string_lossy().to_string();
            if exists(&proj.join("uv.lock")) && file_name(Path::new(&envp)) == ".venv" {
                let out = std::process::Command::new(&uv).arg("sync").current_dir(&proj).env("PATH", extended_path()).output();
                out.map(|o| (o.status.code().unwrap_or(-1), String::from_utf8_lossy(&o.stderr).to_string())).unwrap_or((-1, "uv".into()))
            } else {
                let mut args = vec!["venv".to_string()];
                if !minor.is_empty() { args.push("--python".into()); args.push(minor.clone()); }
                args.push(envp.clone());
                let a: Vec<&str> = args.iter().map(String::as_str).collect();
                let (c, o) = run(&uv, &a);
                if c != 0 { (c, o) } else if let Some(req) = &req {
                    run(&uv, &["pip", "install", "--python", &newpy, "-r", &req.to_string_lossy()])
                } else if exists(&proj.join("pyproject.toml")) {
                    run(&uv, &["pip", "install", "--python", &newpy, "-e", &proj.to_string_lossy()])
                } else { (0, o) }
            }
        } else {
            let base = if cfg!(windows) { "py".to_string() } else { which(&format!("python{minor}")).or(which("python3")).map(|p| p.to_string_lossy().to_string()).unwrap_or("python3".into()) };
            let (c, o) = if cfg!(windows) { run(&base, &[&format!("-{minor}"), "-m", "venv", &envp]) } else { run(&base, &["-m", "venv", &envp]) };
            if c != 0 { (c, o) } else if let Some(req) = &req { run(&newpy, &["-m", "pip", "install", "-r", &req.to_string_lossy()]) } else { (0, o) }
        };
        if c == 0 { Ok(format!("{} recréé à neuf", env.name)) } else { Err(o.chars().rev().take(300).collect::<String>().chars().rev().collect()) }
    }).await.map_err(|e| e.to_string())?
}

#[tauri::command]
pub async fn python_remove_interpreter(root: String, source: String, size: u64) -> Result<String, String> {
    tauri::async_runtime::spawn_blocking(move || {
        if source.starts_with("Homebrew") {
            let formula = Path::new(&root).parent().map(file_name).unwrap_or_default();
            let b = which("brew").ok_or("Homebrew introuvable")?;
            let (c, o) = run(&b.to_string_lossy(), &["uninstall", "--ignore-dependencies", &formula]);
            return if c == 0 { Ok(format!("{formula} désinstallé")) } else { Err(o) };
        }
        let r = trash_many(&[(PathBuf::from(&root), Some(size))]);
        if r.errors.is_empty() { Ok("Interpréteur mis à la Corbeille".into()) } else { Err(r.errors.join(", ")) }
    }).await.map_err(|e| e.to_string())?
}

#[tauri::command]
pub fn activate_command(env: PyEnv) -> String {
    if env.kind == "Conda" {
        format!("conda activate {}", quote(&env.path))
    } else if cfg!(windows) {
        format!("{}\\Scripts\\Activate.ps1", env.path)
    } else {
        format!("source {}", quote(&format!("{}/bin/activate", env.path)))
    }
}
