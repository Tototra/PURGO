//! Live CPU / RAM / disk / battery / processes (sysinfo + per-OS battery readers).

use crate::util::*;
use serde::Serialize;
use std::sync::Mutex;
use sysinfo::{Disks, ProcessesToUpdate, System};

static SYS: Mutex<Option<System>> = Mutex::new(None);

#[derive(Serialize, Clone)]
pub struct Battery {
    pub percent: u32,
    pub charging: bool,
    pub plugged: bool,
    pub cycles: Option<u32>,
    pub health: Option<f64>,
}

#[derive(Serialize)]
pub struct Stats {
    pub cpu: f32,
    pub cores: usize,
    pub mem_total: u64,
    pub mem_used: u64,
    pub swap_total: u64,
    pub swap_used: u64,
    pub disk_free: u64,
    pub disk_total: u64,
    pub disk_name: String,
    pub uptime: u64,
    pub os: String,
    pub battery: Option<Battery>,
}

#[derive(Serialize)]
pub struct Proc {
    pub pid: u32,
    pub name: String,
    pub cpu: f32,
    pub mem: u64,
}

/// (free, total) of the disk that holds the home folder.
pub fn home_disk() -> (u64, u64) {
    let disks = Disks::new_with_refreshed_list();
    let h = home();
    let mut best: Option<(&sysinfo::Disk, usize)> = None;
    for d in disks.list() {
        let mp = d.mount_point();
        if h.starts_with(mp) {
            let len = mp.as_os_str().len();
            if best.map(|(_, l)| len > l).unwrap_or(true) {
                best = Some((d, len));
            }
        }
    }
    best.map(|(d, _)| (d.available_space(), d.total_space())).unwrap_or((0, 0))
}

fn battery() -> Option<Battery> {
    #[cfg(target_os = "linux")]
    {
        let dir = children(&std::path::PathBuf::from("/sys/class/power_supply"))
            .into_iter().find(|p| file_name(p).starts_with("BAT"))?;
        let read = |f: &str| std::fs::read_to_string(dir.join(f)).ok().map(|s| s.trim().to_string());
        let num = |f: &str| read(f).and_then(|s| s.parse::<f64>().ok());
        let status = read("status").unwrap_or_default();
        let full = num("energy_full").or_else(|| num("charge_full"));
        let design = num("energy_full_design").or_else(|| num("charge_full_design"));
        let ac = children(&std::path::PathBuf::from("/sys/class/power_supply")).into_iter()
            .filter(|p| !file_name(p).starts_with("BAT"))
            .any(|p| std::fs::read_to_string(p.join("online")).map(|s| s.trim() == "1").unwrap_or(false));
        return Some(Battery {
            percent: num("capacity").unwrap_or(0.0) as u32,
            charging: status == "Charging",
            plugged: ac || status == "Charging" || status == "Full",
            cycles: num("cycle_count").map(|c| c as u32).filter(|c| *c > 0),
            health: match (full, design) { (Some(f), Some(d)) if d > 0.0 => Some((f / d).min(1.0)), _ => None },
        });
    }
    #[cfg(target_os = "macos")]
    {
        let out = run("/usr/sbin/ioreg", &["-rn", "AppleSmartBattery"]).1;
        if !out.contains("CycleCount") {
            return None;
        }
        let num = |k: &str| -> Option<f64> {
            let re = regex::Regex::new(&format!("\"{k}\" = (\\d+)")).ok()?;
            re.captures(&out).and_then(|c| c[1].parse().ok())
        };
        let yes = |k: &str| out.contains(&format!("\"{k}\" = Yes"));
        let cur = num("CurrentCapacity").unwrap_or(0.0);
        let max = num("MaxCapacity").unwrap_or(100.0);
        let percent = if max == 100.0 { cur } else if max > 0.0 { cur * 100.0 / max } else { 0.0 };
        let raw = num("AppleRawMaxCapacity").or_else(|| num("NominalChargeCapacity"));
        let design = num("DesignCapacity");
        return Some(Battery {
            percent: percent as u32,
            charging: yes("IsCharging"),
            plugged: yes("ExternalConnected"),
            cycles: num("CycleCount").map(|c| c as u32),
            health: match (raw, design) { (Some(r), Some(d)) if d > 0.0 => Some((r / d).min(1.0)), _ => None },
        });
    }
    #[cfg(windows)]
    {
        let (c, o) = sh("$b = Get-CimInstance Win32_Battery | Select-Object -First 1 EstimatedChargeRemaining,BatteryStatus; \
            $f = (Get-CimInstance -Namespace root\\wmi -ClassName BatteryFullChargedCapacity -ErrorAction SilentlyContinue | Select-Object -First 1).FullChargedCapacity; \
            $d = (Get-CimInstance -Namespace root\\wmi -ClassName BatteryStaticData -ErrorAction SilentlyContinue | Select-Object -First 1).DesignedCapacity; \
            $cy = (Get-CimInstance -Namespace root\\wmi -ClassName BatteryCycleCount -ErrorAction SilentlyContinue | Select-Object -First 1).CycleCount; \
            if ($b) { @{p=$b.EstimatedChargeRemaining; s=$b.BatteryStatus; f=$f; d=$d; c=$cy} | ConvertTo-Json -Compress }");
        if c != 0 || o.trim().is_empty() {
            return None;
        }
        let j: serde_json::Value = serde_json::from_str(o.trim()).ok()?;
        let s = j["s"].as_u64().unwrap_or(0);
        let f = j["f"].as_f64();
        let d = j["d"].as_f64();
        return Some(Battery {
            percent: j["p"].as_u64().unwrap_or(0) as u32,
            charging: matches!(s, 6 | 7 | 8 | 9),
            plugged: s == 2 || matches!(s, 6 | 7 | 8 | 9),
            cycles: j["c"].as_u64().map(|c| c as u32).filter(|c| *c > 0),
            health: match (f, d) { (Some(f), Some(d)) if d > 0.0 => Some((f / d).min(1.0)), _ => None },
        });
    }
    #[allow(unreachable_code)]
    None
}

static BAT: Mutex<(u64, Option<Battery>)> = Mutex::new((0, None));

#[tauri::command]
pub async fn system_stats() -> Stats {
    tauri::async_runtime::spawn_blocking(|| {
        let mut g = SYS.lock().unwrap_or_else(|e| e.into_inner());
        let sys = g.get_or_insert_with(System::new);
        sys.refresh_cpu_usage();
        sys.refresh_memory();
        let (free, total) = home_disk();
        let bat = {
            let mut b = BAT.lock().unwrap_or_else(|e| e.into_inner());
            if now() - b.0 > 30 {
                *b = (now(), battery());
            }
            b.1.clone()
        };
        Stats {
            cpu: sys.global_cpu_usage(),
            cores: sys.cpus().len(),
            mem_total: sys.total_memory(),
            mem_used: sys.used_memory(),
            swap_total: sys.total_swap(),
            swap_used: sys.used_swap(),
            disk_free: free,
            disk_total: total,
            disk_name: if cfg!(windows) { "C:".into() } else if cfg!(target_os = "macos") { "Macintosh HD".into() } else { "/".into() },
            uptime: System::uptime(),
            os: format!("{} {}", System::name().unwrap_or_default(), System::os_version().unwrap_or_default()),
            battery: bat,
        }
    })
    .await
    .unwrap()
}

#[tauri::command]
pub async fn processes(by_memory: bool) -> Vec<Proc> {
    tauri::async_runtime::spawn_blocking(move || {
        let mut g = SYS.lock().unwrap_or_else(|e| e.into_inner());
        let sys = g.get_or_insert_with(System::new);
        sys.refresh_processes(ProcessesToUpdate::All, true);
        let n = sys.cpus().len().max(1) as f32;
        // group helper processes by name (Chrome, Electron apps…)
        let mut map: std::collections::HashMap<String, Proc> = std::collections::HashMap::new();
        for (pid, p) in sys.processes() {
            let name = p.name().to_string_lossy().trim_end_matches(".exe").to_string();
            let e = map.entry(name.clone()).or_insert(Proc { pid: pid.as_u32(), name, cpu: 0.0, mem: 0 });
            e.cpu += p.cpu_usage() / n;
            e.mem += p.memory();
        }
        let mut v: Vec<Proc> = map.into_values().collect();
        if by_memory {
            v.sort_by(|a, b| b.mem.cmp(&a.mem));
        } else {
            v.sort_by(|a, b| b.cpu.partial_cmp(&a.cpu).unwrap_or(std::cmp::Ordering::Equal));
        }
        v.truncate(14);
        v
    })
    .await
    .unwrap_or_default()
}

#[tauri::command]
pub fn kill_process(name: String) -> usize {
    crate::privacy::quit_app(vec![name])
}

#[tauri::command]
pub async fn free_ram() -> Result<String, String> {
    tauri::async_runtime::spawn_blocking(|| {
        let (c, o) = if cfg!(target_os = "macos") {
            admin("/usr/sbin/purge")
        } else if cfg!(target_os = "linux") {
            admin("sync; echo 3 > /proc/sys/vm/drop_caches")
        } else {
            return Err("Windows gère sa mémoire tout seul : ferme plutôt les apps gourmandes listées ci-dessous.".to_string());
        };
        if c == 0 { Ok("Mémoire libérée".into()) } else { Err(o) }
    })
    .await
    .map_err(|e| e.to_string())?
}
