//! Icono de bandeja de neoMemorial Soporte (cliente y consola, sin instalar).

use hbb_common::{allow_err, log, ResultType};

const RUN_KEY: &str = r"Software\Microsoft\Windows\CurrentVersion\Run";

const BROKER_PENDING_URL: &str =
    "https://apps-soporte-broker.kc54fe.easypanel.host/v1/admin/solicitudes";

pub fn enabled() -> bool {
    use hbb_common::config::{is_incoming_only, is_outgoing_only};
    (is_incoming_only() || is_outgoing_only()) && !crate::platform::is_installed()
}

/// Llamado por la ventana principal al arrancar.
pub fn ensure_running() {
    if !enabled() {
        return;
    }
    if !crate::check_process("--tray", true) {
        allow_err!(crate::run_me(vec!["--tray"]));
    }
}

fn autostart_enabled() -> bool {
    use winreg::{enums::HKEY_CURRENT_USER, RegKey};
    RegKey::predef(HKEY_CURRENT_USER)
        .open_subkey(RUN_KEY)
        .and_then(|k| k.get_value::<String, _>(crate::get_app_name()))
        .is_ok()
}

// Al iniciar Windows solo arranca la bandeja. En el cliente, el pedido de
// soporte se envia recien cuando el usuario abre la ventana; en la consola,
// la bandeja abre la ventana cuando llega un pedido.
fn set_autostart(enable: bool) -> ResultType<()> {
    use winreg::{enums::HKEY_CURRENT_USER, RegKey};
    let (key, _) = RegKey::predef(HKEY_CURRENT_USER).create_subkey(RUN_KEY)?;
    let name = crate::get_app_name();
    if enable {
        let exe = std::env::current_exe()?;
        key.set_value(&name, &format!("\"{}\" --tray", exe.display()))?;
    } else if key.get_value::<String, _>(&name).is_ok() {
        key.delete_value(&name)?;
    }
    Ok(())
}

fn pending_ids(token: &str) -> ResultType<std::collections::HashSet<String>> {
    let body = crate::hbbs_http::create_http_client_with_url(BROKER_PENDING_URL)
        .get(BROKER_PENDING_URL)
        .header("Authorization", format!("Bearer {token}"))
        .timeout(std::time::Duration::from_secs(10))
        .send()?
        .error_for_status()?
        .text()?;
    let v: serde_json::Value = serde_json::from_str(&body)?;
    Ok(v["solicitudes"]
        .as_array()
        .map(|a| {
            a.iter()
                .filter_map(|x| match &x["id"] {
                    serde_json::Value::String(s) => Some(s.clone()),
                    serde_json::Value::Number(n) => Some(n.to_string()),
                    _ => None,
                })
                .collect()
        })
        .unwrap_or_default())
}

// Consola: avisa (abriendo la ventana) cuando aparece un equipo que no estaba
// en la consulta anterior. Usa el token de sesion que guardo la ventana.
fn watch_requests(sender: std::sync::mpsc::Sender<()>) {
    let mut known = std::collections::HashSet::new();
    loop {
        let token = hbb_common::config::LocalConfig::get_option_from_file("neo-broker-token");
        if !token.is_empty() {
            match pending_ids(&token) {
                Ok(ids) => {
                    if ids.iter().any(|id| !known.contains(id)) && sender.send(()).is_err() {
                        return;
                    }
                    known = ids;
                }
                Err(err) => log::trace!("neo broker poll failed: {}", err),
            }
        }
        std::thread::sleep(std::time::Duration::from_secs(5));
    }
}

pub fn run() -> ResultType<()> {
    use hbb_common::anyhow::Context;
    use tao::event_loop::{ControlFlow, EventLoopBuilder};
    use tray_icon::{
        menu::{CheckMenuItem, Menu, MenuEvent, MenuItem},
        TrayIcon, TrayIconBuilder, TrayIconEvent as TrayEvent,
    };

    if !crate::platform::windows::try_lock_tray_single_instance() {
        log::info!("Another tray process is already running in this session, exit");
        return Ok(());
    }

    let image = image::load_from_memory(include_bytes!("../res/64x64.png"))
        .context("Failed to open icon")?
        .into_rgba8();
    let (width, height) = image.dimensions();
    let icon = tray_icon::Icon::from_rgba(image.into_raw(), width, height)
        .context("Failed to open icon")?;

    let event_loop = EventLoopBuilder::new().build();
    let open_i = MenuItem::new("Abrir", true, None);
    let autostart_i = CheckMenuItem::new("Iniciar con Windows", true, autostart_enabled(), None);
    let quit_i = MenuItem::new("Salir", true, None);
    let tray_menu = Menu::new();
    tray_menu
        .append_items(&[&open_i, &autostart_i, &quit_i])
        .ok();

    let menu_channel = MenuEvent::receiver();
    let tray_channel = TrayEvent::receiver();
    // Sin argumentos: si la ventana ya existe, el runner solo la muestra.
    let open_func = || {
        allow_err!(crate::run_me::<&str>(vec![]));
    };
    let mut tray: Option<TrayIcon> = None;
    let (request_tx, request_rx) = std::sync::mpsc::channel::<()>();
    if hbb_common::config::is_outgoing_only() {
        std::thread::spawn(move || watch_requests(request_tx));
    }
    let mut last_click = std::time::Instant::now();

    event_loop.run(move |event, _, control_flow| {
        *control_flow = ControlFlow::WaitUntil(
            std::time::Instant::now() + std::time::Duration::from_millis(100),
        );

        if let tao::event::Event::NewEvents(tao::event::StartCause::Init) = event {
            match TrayIconBuilder::new()
                .with_id(crate::get_app_name().to_lowercase())
                .with_menu(Box::new(tray_menu.clone()))
                .with_tooltip(crate::get_app_name())
                .with_icon(icon.clone())
                .with_menu_on_left_click(false)
                .build()
            {
                Ok(t) => tray = Some(t),
                Err(err) => log::error!("Failed to create tray icon: {}", err),
            }
        }

        if let Ok(event) = menu_channel.try_recv() {
            if event.id == open_i.id() {
                open_func();
            } else if event.id == autostart_i.id() {
                let enable = autostart_i.is_checked();
                if let Err(err) = set_autostart(enable) {
                    log::error!("Failed to change autostart: {}", err);
                    autostart_i.set_checked(!enable);
                }
            } else if event.id == quit_i.id() {
                if let Some(t) = tray.as_mut() {
                    t.set_visible(false).ok();
                }
                allow_err!(crate::platform::windows::try_kill_rustdesk_main_window_process());
                *control_flow = ControlFlow::Exit;
            }
        }

        if request_rx.try_recv().is_ok() {
            unsafe {
                winapi::um::winuser::MessageBeep(winapi::um::winuser::MB_ICONASTERISK);
            }
            open_func();
        }

        if let Ok(TrayEvent::Click {
            button,
            button_state,
            ..
        }) = tray_channel.try_recv()
        {
            if button == tray_icon::MouseButton::Left
                && button_state == tray_icon::MouseButtonState::Up
                && last_click.elapsed() >= std::time::Duration::from_secs(1)
            {
                open_func();
                last_click = std::time::Instant::now();
            }
        }
    });
}
