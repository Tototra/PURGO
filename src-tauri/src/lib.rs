#![allow(dead_code)]

mod apps;
mod dev;
mod files;
mod junk;
mod maintenance;
mod monitor;
mod packages;
mod privacy;
mod python;
mod security;
mod settings;
mod startup;
mod storage;
mod util;

use tauri::menu::{Menu, MenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Manager, WindowEvent};
use tauri_plugin_autostart::ManagerExt;
use tauri_plugin_dialog::DialogExt;
use tauri_plugin_opener::OpenerExt;

fn show(app: &AppHandle) {
    if let Some(w) = app.get_webview_window("main") {
        let _ = w.show();
        let _ = w.unminimize();
        let _ = w.set_focus();
    }
}

#[tauri::command]
fn autostart_get(app: AppHandle) -> bool {
    app.autolaunch().is_enabled().unwrap_or(false)
}

#[tauri::command]
fn autostart_set(app: AppHandle, on: bool) -> Result<bool, String> {
    let m = app.autolaunch();
    if on { m.enable() } else { m.disable() }.map_err(|e| e.to_string())?;
    Ok(m.is_enabled().unwrap_or(false))
}

#[tauri::command]
async fn pick_folder(app: AppHandle, start: Option<String>) -> Option<String> {
    let mut d = app.dialog().file();
    if let Some(s) = start {
        d = d.set_directory(s);
    }
    d.blocking_pick_folder().and_then(|p| p.into_path().ok()).map(|p| p.to_string_lossy().to_string())
}

#[tauri::command]
fn reveal(path: String) -> Result<(), String> {
    tauri_plugin_opener::reveal_item_in_dir(&path).map_err(|e| e.to_string())
}

#[tauri::command]
fn open_url(app: AppHandle, url: String) -> Result<(), String> {
    app.opener().open_url(url, None::<&str>).map_err(|e| e.to_string())
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_notification::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_autostart::init(tauri_plugin_autostart::MacosLauncher::LaunchAgent, Some(vec!["--hidden"])))
        .setup(|app| {
            let open = MenuItem::with_id(app, "open", "Ouvrir Purgo", true, None::<&str>)?;
            let ram = MenuItem::with_id(app, "ram", "Libérer la mémoire", !cfg!(windows), None::<&str>)?;
            let quit = MenuItem::with_id(app, "quit", "Quitter Purgo", true, None::<&str>)?;
            let menu = Menu::with_items(app, &[&open, &ram, &quit])?;
            let mut tray = TrayIconBuilder::with_id("main")
                .tooltip("Purgo")
                .menu(&menu)
                .show_menu_on_left_click(false)
                .on_menu_event(|app, e| match e.id.as_ref() {
                    "open" => show(app),
                    "ram" => {
                        tauri::async_runtime::spawn(async {
                            let _ = monitor::free_ram().await;
                        });
                    }
                    "quit" => app.exit(0),
                    _ => {}
                })
                .on_tray_icon_event(|tray, e| {
                    if let TrayIconEvent::Click { button: MouseButton::Left, button_state: MouseButtonState::Up, .. } = e {
                        show(tray.app_handle());
                    }
                });
            if let Some(icon) = app.default_window_icon() {
                tray = tray.icon(icon.clone());
            }
            tray.build(app)?;

            if std::env::args().any(|a| a == "--hidden") {
                if let Some(w) = app.get_webview_window("main") {
                    let _ = w.hide();
                }
            }
            settings::start_watchdog(app.handle().clone());
            Ok(())
        })
        .on_window_event(|w, e| {
            // closing the window keeps Purgo in the tray so alerts keep working
            if let WindowEvent::CloseRequested { api, .. } = e {
                let _ = w.hide();
                api.prevent_close();
            }
        })
        .invoke_handler(tauri::generate_handler![
            autostart_get, autostart_set, pick_folder, reveal, open_url,
            util::trash_paths, util::trash_info, util::empty_trash, util::platform_info, util::open_terminal, util::open_path,
            settings::get_settings, settings::set_settings,
            junk::scan_junk,
            privacy::scan_privacy, privacy::quit_browser,
            security::scan_security, security::remove_threats, security::antivirus_scan,
            monitor::system_stats, monitor::processes, monitor::kill_process, monitor::free_ram,
            maintenance::maintenance_tasks, maintenance::run_task,
            startup::startup_list, startup::startup_toggle, startup::startup_remove, startup::open_startup_settings,
            apps::apps_list, apps::app_leftovers, apps::app_uninstall, apps::app_orphans,
            packages::packages_status, packages::package_action, packages::brew_installed, packages::open_os_updates,
            files::lens_roots, files::dir_children, files::large_files, files::duplicates,
            python::python_scan, python::python_refresh_env, python::python_uninstall, python::python_save_requirements,
            python::python_trash_envs, python::python_recreate, python::python_remove_interpreter, python::activate_command,
            dev::node_scan, dev::git_scan, dev::git_gc, dev::docker_status, dev::docker_cmd, dev::docker_start, dev::ai_scan, dev::ai_delete,
            storage::cloud_scan, storage::cloud_free, storage::cloud_send,
            storage::organize_plan, storage::organize_apply, storage::organize_can_undo, storage::organize_undo,
            storage::music_scan, storage::music_archive, storage::tips_list, storage::tip_apply,
        ])
        .run(tauri::generate_context!())
        .expect("Purgo n'a pas pu démarrer");
}
