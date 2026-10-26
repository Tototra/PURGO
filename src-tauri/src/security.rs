//! Security scan: known adware families, suspicious startup entries, scheduled tasks,
//! shell profile hooks, browser extensions, and the OS antivirus status.

use crate::util::*;
use regex::Regex;
use serde::Serialize;
use std::path::PathBuf;
use tauri::AppHandle;

pub const SIGNATURES: [&str; 44] = [
    "mackeeper", "genieo", "pirrit", "shlayer", "bundlore", "adload", "vsearch", "conduit", "installmac", "crossrider",
    "searchmine", "searchbaron", "safefinder", "spigot", "mughthesec", "advancedmaccleaner", "advanced mac cleaner",
    "mac auto fixer", "smart mac booster", "mac cleanup pro", "surfbuddy", "chumsearch", "weknow", "searchpulse",
    "operativeupdate", "mmsearch", "pcvark", "zeobit", "macbooster", "searchmarquis", "trovi", "yontoo", "maxofferdeal",
    // Windows / cross-platform PUPs
    "opencandy", "installcore", "babylon toolbar", "ask toolbar", "mywebsearch", "superfish", "browsefox", "wajam",
    "reimage repair", "driver booster", "pc optimizer pro",
];

fn signature(s: &str) -> Option<&'static str> {
    let l = s.to_lowercase();
    SIGNATURES.iter().copied().find(|sig| l.contains(sig))
}

fn suspicious_cmd(cmd: &str) -> Option<String> {
    let l = cmd.to_lowercase();
    let mut why = vec![];
    if Regex::new(r"(curl|wget)[^|;]*\|\s*(ba|z)?sh").unwrap().is_match(&l) { why.push("télécharge et exécute un script"); }
    if l.contains("base64 -d") || l.contains("base64 --decode") || Regex::new(r"-e(nc|ncodedcommand)?\s+[a-z0-9+/=]{20,}").unwrap().is_match(&l) {
        why.push("exécute du code encodé");
    }
    if l.contains("/tmp/") || l.contains("/private/tmp") || l.contains("\\temp\\") || l.contains("\\appdata\\local\\temp") || l.contains("/users/shared") {
        why.push("se lance depuis un dossier temporaire");
    }
    if l.contains("mshta") || l.contains("/dev/tcp/") || (l.contains("wscript") && l.contains("appdata")) || (l.contains("rundll32") && l.contains("appdata")) {
        why.push("utilise une technique courante des logiciels malveillants");
    }
    if l.contains("osascript -e") && (l.contains("curl") || l.contains("do shell script")) {
        why.push("exécute un script AppleScript à la volée");
    }
    (!why.is_empty()).then(|| why.join(" · "))
}

#[derive(Serialize)]
pub struct SecurityReport {
    pub antivirus: Option<String>,
    pub antivirus_ok: Option<bool>,
    pub can_scan: bool,
    pub threats: Vec<Item>,
}

fn threat(name: &str, reason: &str, category: &str, sev: &str, path: Option<String>, kind: &str, extra: serde_json::Value) -> Item {
    let (label, color) = match sev {
        "known" => ("Menace connue", "red"),
        "suspicious" => ("Suspect", "orange"),
        _ => ("À vérifier", "gray"),
    };
    Item {
        id: format!("{kind}:{}:{name}", path.clone().unwrap_or_default()),
        name: name.into(),
        detail: format!("{reason} · {category}"),
        paths: path.into_iter().collect(),
        size: 0,
        selected: sev != "info",
        badges: vec![badge(label, color)],
        meta: serde_json::json!({ "severity": sev, "kind": kind, "extra": extra }),
    }
}

pub fn scan(app: &AppHandle) -> SecurityReport {
    let mut threats = vec![];

    // 1. Startup entries (all OS)
    progress(app, "security", "Éléments lancés au démarrage…", 0);
    for s in crate::startup::list() {
        let hay = format!("{} {} {}", s.name, s.command, s.location);
        if let Some(sig) = signature(&hay) {
            threats.push(threat(&s.name, &format!("Correspond à la famille « {sig} »"), &s.group, "known", s.path.clone(), "startup", serde_json::json!({ "id": s.id })));
        } else if let Some(why) = suspicious_cmd(&s.command) {
            threats.push(threat(&s.name, &capitalize(&why), &s.group, "suspicious", s.path.clone(), "startup", serde_json::json!({ "id": s.id })));
        }
    }

    // 2. Browser extensions (Chromium family)
    progress(app, "security", "Extensions de navigateur…", 0);
    for b in crate::privacy::CHROMIUM.iter() {
        for prof in b.profiles() {
            for ext_dir in children(&prof.join("Extensions")) {
                for ver in children(&ext_dir) {
                    let Ok(d) = std::fs::read(ver.join("manifest.json")) else { continue };
                    let Ok(j) = serde_json::from_slice::<serde_json::Value>(&d) else { continue };
                    let n = j["name"].as_str().unwrap_or("").to_string();
                    if let Some(sig) = signature(&n) {
                        threats.push(threat(&n, &format!("Extension de la famille « {sig} »"), &format!("Extension {}", b.name), "known",
                            Some(ext_dir.to_string_lossy().into()), "file", serde_json::Value::Null));
                    }
                }
            }
        }
    }

    // 3. OS specific
    let mut antivirus = None;
    let mut antivirus_ok = None;
    let mut can_scan = false;

    if cfg!(target_os = "macos") {
        progress(app, "security", "Applications (Gatekeeper)…", 0);
        for a in children(&PathBuf::from("/Applications")).into_iter().filter(|p| ext(p) == "app") {
            let n = file_name(&a);
            if let Some(sig) = signature(&n) {
                threats.push(threat(&n, &format!("Correspond à la famille « {sig} »"), "Application", "known", Some(a.to_string_lossy().into()), "file", serde_json::Value::Null));
            } else if run("/usr/sbin/spctl", &["--assess", "--type", "execute", &a.to_string_lossy()]).0 != 0 {
                threats.push(threat(&n, "Refusée par Gatekeeper : non notarisée, modifiée ou d'origine inconnue", "Application", "info", Some(a.to_string_lossy().into()), "file", serde_json::Value::Null));
            }
        }
        for dir in [hp("Library/Application Support"), PathBuf::from("/Library/Application Support")] {
            for c in children(&dir) {
                if let Some(sig) = signature(&file_name(&c)) {
                    threats.push(threat(&file_name(&c), &format!("Correspond à la famille « {sig} »"), "Données d'application", "known", Some(c.to_string_lossy().into()), "file", serde_json::Value::Null));
                }
            }
        }
        let xp = ["/Library/Apple/System/Library/CoreServices/XProtect.bundle/Contents/Info.plist"]
            .iter().find_map(|p| plist::Value::from_file(p).ok())
            .and_then(|v| v.as_dictionary().and_then(|d| d.get("CFBundleShortVersionString")).and_then(|x| x.as_string()).map(String::from));
        antivirus = Some(format!("XProtect {}", xp.unwrap_or_default()).trim().to_string());
        antivirus_ok = Some(true);
    }

    if cfg!(windows) {
        progress(app, "security", "Windows Defender…", 0);
        let (c, o) = sh("Get-MpComputerStatus | Select-Object AntivirusEnabled,RealTimeProtectionEnabled,AntivirusSignatureLastUpdated,QuickScanEndTime | ConvertTo-Json -Compress");
        if c == 0 {
            if let Ok(j) = serde_json::from_str::<serde_json::Value>(o.trim()) {
                let on = j["AntivirusEnabled"].as_bool().unwrap_or(false) && j["RealTimeProtectionEnabled"].as_bool().unwrap_or(false);
                antivirus = Some(if on { "Microsoft Defender actif, protection en temps réel activée".into() } else { "Microsoft Defender : protection en temps réel désactivée".into() });
                antivirus_ok = Some(on);
                can_scan = true;
            }
        }
        if antivirus.is_none() {
            antivirus = Some("Un antivirus tiers gère la protection".into());
        }
        progress(app, "security", "Tâches planifiées…", 0);
        let (c, o) = run("schtasks", &["/query", "/fo", "CSV", "/v"]);
        if c == 0 {
            let mut hdr: Vec<String> = vec![];
            for l in o.lines() {
                let cols: Vec<String> = l.split("\",\"").map(|x| x.trim_matches('"').to_string()).collect();
                if cols.first().map(|x| x == "HostName").unwrap_or(false) {
                    hdr = cols;
                    continue;
                }
                let name_i = hdr.iter().position(|h| h == "TaskName").unwrap_or(1);
                let run_i = hdr.iter().position(|h| h == "Task To Run").unwrap_or(8);
                let (Some(name), Some(cmd)) = (cols.get(name_i), cols.get(run_i)) else { continue };
                if name.starts_with("\\Microsoft\\") {
                    continue;
                }
                if let Some(sig) = signature(&format!("{name} {cmd}")) {
                    threats.push(threat(name, &format!("Correspond à la famille « {sig} »"), "Tâche planifiée", "known", None, "task", serde_json::json!({ "task": name })));
                } else if let Some(why) = suspicious_cmd(cmd) {
                    threats.push(threat(name, &capitalize(&why), "Tâche planifiée", "suspicious", None, "task", serde_json::json!({ "task": name })));
                }
            }
            let mut seen = std::collections::HashSet::new();
            threats.retain(|t| seen.insert(t.id.clone()));
        }
        if let Some(pf) = std::env::var_os("ProgramFiles") {
            for c in children(&PathBuf::from(pf)) {
                if let Some(sig) = signature(&file_name(&c)) {
                    threats.push(threat(&file_name(&c), &format!("Logiciel de la famille « {sig} »"), "Programme installé", "known", Some(c.to_string_lossy().into()), "info", serde_json::Value::Null));
                }
            }
        }
    }

    if cfg!(target_os = "linux") {
        progress(app, "security", "Fichiers de démarrage du shell…", 0);
        for rc in [".bashrc", ".profile", ".bash_profile", ".zshrc", ".zprofile", ".config/fish/config.fish"] {
            let p = hp(rc);
            let Ok(text) = std::fs::read_to_string(&p) else { continue };
            for (i, l) in text.lines().enumerate() {
                if l.trim_start().starts_with('#') { continue; }
                if let Some(why) = suspicious_cmd(l) {
                    threats.push(threat(&format!("{rc}, ligne {}", i + 1), &capitalize(&why), "Profil du shell", "suspicious",
                        Some(p.to_string_lossy().into()), "rc", serde_json::json!({ "line": l.trim() })));
                }
            }
        }
        progress(app, "security", "Tâches cron…", 0);
        let (c, o) = run("crontab", &["-l"]);
        if c == 0 {
            for l in o.lines().filter(|l| !l.trim_start().starts_with('#')) {
                if let Some(why) = suspicious_cmd(l) {
                    threats.push(threat(l.trim(), &capitalize(&why), "Tâche cron", "suspicious", None, "rc", serde_json::json!({ "line": l.trim() })));
                }
            }
        }
        if std::fs::read_to_string("/etc/ld.so.preload").map(|s| !s.trim().is_empty()).unwrap_or(false) {
            threats.push(threat("/etc/ld.so.preload", "Une bibliothèque est injectée dans tous les programmes : technique typique des rootkits", "Système", "suspicious",
                Some("/etc/ld.so.preload".into()), "info", serde_json::Value::Null));
        }
        if which("clamscan").is_some() {
            antivirus = Some("ClamAV est installé".into());
            antivirus_ok = Some(true);
            can_scan = true;
        } else {
            antivirus = Some("Aucun antivirus. Linux en a rarement besoin, mais ClamAV permet d'analyser tes téléchargements.".into());
        }
    }

    threats.sort_by_key(|t| match t.meta["severity"].as_str() { Some("known") => 0, Some("suspicious") => 1, _ => 2 });
    SecurityReport { antivirus, antivirus_ok, can_scan, threats }
}

fn capitalize(s: &str) -> String {
    let mut c = s.chars();
    c.next().map(|f| f.to_uppercase().collect::<String>() + c.as_str()).unwrap_or_default()
}

#[tauri::command]
pub async fn scan_security(app: AppHandle) -> SecurityReport {
    tauri::async_runtime::spawn_blocking(move || scan(&app)).await.unwrap()
}

#[tauri::command]
pub async fn remove_threats(items: Vec<Item>) -> (usize, Vec<String>) {
    tauri::async_runtime::spawn_blocking(move || {
        let mut ok = 0;
        let mut errs = vec![];
        for t in items {
            let kind = t.meta["kind"].as_str().unwrap_or("file").to_string();
            let res: Result<(), String> = match kind.as_str() {
                "startup" => {
                    let id = t.meta["extra"]["id"].as_str().unwrap_or("").to_string();
                    crate::startup::list().into_iter().find(|s| s.id == id).ok_or("introuvable".to_string()).and_then(|s| crate::startup::remove(&s))
                }
                "task" => {
                    let name = t.meta["extra"]["task"].as_str().unwrap_or("").to_string();
                    let (c, o) = admin(&format!("schtasks /delete /tn \"{name}\" /f"));
                    if c == 0 { Ok(()) } else { Err(o) }
                }
                "file" => {
                    let r = trash_many(&t.paths.iter().map(|p| (PathBuf::from(p), Some(0))).collect::<Vec<_>>());
                    if r.errors.is_empty() { Ok(()) } else { Err(r.errors.join(", ")) }
                }
                _ => Err(format!("{} : à corriger à la main (ouvre le fichier pour vérifier)", t.name)),
            };
            match res { Ok(_) => ok += 1, Err(e) => errs.push(e) }
        }
        (ok, errs)
    }).await.unwrap_or((0, vec!["erreur interne".into()]))
}

#[tauri::command]
pub async fn antivirus_scan() -> Result<String, String> {
    tauri::async_runtime::spawn_blocking(|| {
        let (c, o) = if cfg!(windows) {
            admin("\"%ProgramFiles%\\Windows Defender\\MpCmdRun.exe\" -Scan -ScanType 1")
        } else if cfg!(target_os = "linux") {
            run("clamscan", &["-r", "-i", "--no-summary", &hp("Downloads").to_string_lossy()])
        } else {
            (0, "XProtect analyse les fichiers automatiquement à chaque ouverture.".into())
        };
        // clamscan returns 1 when it finds something
        if c == 0 { Ok(if o.trim().is_empty() { "Analyse terminée : rien trouvé.".into() } else { o }) }
        else if c == 1 && cfg!(target_os = "linux") { Ok(format!("Fichiers infectés trouvés :\n{o}")) }
        else { Err(o) }
    }).await.map_err(|e| e.to_string())?
}
