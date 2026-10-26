//! Maintenance tasks for each OS.

use crate::util::*;
use serde::Serialize;

#[derive(Serialize, Clone)]
pub struct Task {
    pub id: &'static str,
    pub name: &'static str,
    pub info: &'static str,
    pub icon: &'static str,
    pub admin: bool,
    #[serde(skip)]
    cmd: String,
}

fn t(id: &'static str, name: &'static str, info: &'static str, icon: &'static str, admin: bool, cmd: impl Into<String>) -> Task {
    Task { id, name, info, icon, admin, cmd: cmd.into() }
}

pub fn tasks() -> Vec<Task> {
    let mut v = vec![];
    if cfg!(windows) {
        v.push(t("dns", "Vider le cache DNS", "Corrige les sites qui ne chargent plus ou pointent vers une ancienne adresse.", "network", false, "ipconfig /flushdns"));
        v.push(t("components", "Nettoyer le magasin de composants (WinSxS)", "Supprime les anciennes versions des mises à jour Windows. Peut libérer plusieurs Go.", "shippingbox", true,
            "Dism.exe /Online /Cleanup-Image /StartComponentCleanup"));
        v.push(t("wu", "Vider le cache de Windows Update", "Supprime les mises à jour déjà installées qui restent téléchargées.", "arrow.down.app", true,
            "net stop wuauserv & rd /s /q %windir%\\SoftwareDistribution\\Download & net start wuauserv"));
        v.push(t("deliveryopt", "Vider le cache d'optimisation de distribution", "Fichiers de mise à jour partagés avec d'autres PC.", "arrow.triangle.2.circlepath", true,
            "powershell -NoProfile -Command Delete-DeliveryOptimizationCache -Force"));
        v.push(t("cleanmgr", "Ouvrir le Nettoyage de disque", "L'outil de Windows pour les fichiers système (Windows.old, journaux de mise à niveau…).", "trash.circle", false, "Start-Process cleanmgr"));
        v.push(t("sfc", "Réparer les fichiers système (SFC)", "Vérifie et répare les fichiers de Windows. Prend 10 à 20 minutes.", "stethoscope", true, "sfc /scannow"));
        v.push(t("trim", "Optimiser les disques", "TRIM sur SSD, défragmentation sur disque dur.", "internaldrive", true, "defrag C: /O"));
        v.push(t("icons", "Reconstruire le cache des icônes", "Répare les icônes vides ou incorrectes.", "square.grid.2x2", false,
            "Stop-Process -Name explorer -Force; Remove-Item \"$env:LOCALAPPDATA\\IconCache.db\" -Force -ErrorAction SilentlyContinue; Remove-Item \"$env:LOCALAPPDATA\\Microsoft\\Windows\\Explorer\\iconcache_*.db\" -Force -ErrorAction SilentlyContinue; Start-Process explorer"));
        v.push(t("explorer", "Relancer l'Explorateur", "Utile quand la barre des tâches ou le bureau se figent.", "arrow.clockwise", false, "Stop-Process -Name explorer -Force; Start-Process explorer"));
    } else if cfg!(target_os = "macos") {
        v.push(t("ram", "Libérer la mémoire vive", "Vide les caches disque gardés en mémoire.", "memorychip", true, "/usr/sbin/purge"));
        v.push(t("dns", "Vider le cache DNS", "Corrige les sites qui ne chargent plus.", "network", true, "dscacheutil -flushcache; killall -HUP mDNSResponder"));
        v.push(t("snapshots", "Supprimer les instantanés Time Machine locaux", "Libère l'espace « purgeable ».", "clock.arrow.circlepath", true, "tmutil thinlocalsnapshots / 999999999999 4"));
        v.push(t("spotlight", "Réindexer Spotlight", "Répare une recherche lente ou incomplète.", "magnifyingglass", true, "mdutil -E /"));
        v.push(t("launchservices", "Reconstruire Launch Services", "Supprime les doublons du menu « Ouvrir avec ».", "square.stack.3d.up", false,
            "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -kill -r -domain local -domain system -domain user"));
        v.push(t("quicklook", "Réinitialiser Quick Look", "Régénère les aperçus.", "eye", false, "qlmanage -r cache; qlmanage -r"));
        v.push(t("verify", "Vérifier le disque", "Contrôle le système de fichiers sans rien modifier.", "stethoscope", false, "diskutil verifyVolume /"));
        v.push(t("ui", "Relancer le Finder et le Dock", "Quand l'interface rame.", "arrow.clockwise", false, "killall Finder; killall Dock"));
    } else {
        v.push(t("ram", "Libérer la mémoire vive", "Vide le cache de pages du noyau.", "memorychip", true, "sync; echo 3 > /proc/sys/vm/drop_caches"));
        v.push(t("dns", "Vider le cache DNS", "Corrige les sites qui ne chargent plus (systemd-resolved).", "network", false, "resolvectl flush-caches"));
        v.push(t("journal", "Réduire les journaux système", "Garde seulement les deux dernières semaines de journald.", "doc.text", true, "journalctl --vacuum-time=2weeks"));
        if which("apt-get").is_some() {
            v.push(t("apt", "Nettoyer APT", "Supprime les paquets devenus inutiles et les .deb téléchargés.", "shippingbox", true, "apt-get autoremove -y && apt-get clean"));
        }
        if which("dnf").is_some() {
            v.push(t("dnf", "Nettoyer DNF", "Supprime les paquets orphelins et le cache.", "shippingbox", true, "dnf autoremove -y && dnf clean all"));
        }
        if which("pacman").is_some() {
            v.push(t("pacman", "Nettoyer pacman", "Vide le cache des paquets et retire les orphelins.", "shippingbox", true,
                "pacman -Sc --noconfirm; orphans=$(pacman -Qdtq); [ -n \"$orphans\" ] && pacman -Rns --noconfirm $orphans; true"));
        }
        if which("flatpak").is_some() {
            v.push(t("flatpak", "Supprimer les runtimes Flatpak inutilisés", "Retire les bibliothèques dont plus aucune app n'a besoin.", "square.stack.3d.up", false, "flatpak uninstall --unused -y"));
        }
        if which("snap").is_some() {
            v.push(t("snap", "Supprimer les anciennes versions Snap", "Snap garde 2 à 3 anciennes versions de chaque app.", "clock.arrow.circlepath", true,
                "snap list --all | awk '/disabled/{print $1, $3}' | while read n r; do snap remove \"$n\" --revision=\"$r\"; done"));
        }
        v.push(t("trim", "Optimiser les SSD (fstrim)", "Signale au SSD les blocs libérés.", "internaldrive", true, "fstrim -av"));
        v.push(t("fonts", "Reconstruire le cache des polices", "Répare les polices manquantes.", "textformat", false, "fc-cache -f"));
        v.push(t("thumbs", "Vider les miniatures", "Régénère les aperçus des fichiers.", "photo", false, "rm -rf \"$HOME/.cache/thumbnails\"/*"));
    }
    v
}

#[tauri::command]
pub fn maintenance_tasks() -> Vec<Task> {
    tasks()
}

#[tauri::command]
pub async fn run_task(id: String) -> Result<String, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let t = tasks().into_iter().find(|t| t.id == id).ok_or("Tâche inconnue")?;
        let (c, o) = if t.admin {
            admin(&t.cmd)
        } else if cfg!(windows) && (t.cmd.starts_with("ipconfig")) {
            run("ipconfig", &["/flushdns"])
        } else {
            sh(&t.cmd)
        };
        let out = o.trim().chars().rev().take(600).collect::<String>().chars().rev().collect::<String>();
        if c == 0 { Ok(out) } else { Err(if out.is_empty() { "Échec ou annulé".into() } else { out }) }
    })
    .await
    .map_err(|e| e.to_string())?
}
