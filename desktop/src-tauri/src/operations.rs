//! The Operations workspace runs inside the app: the task host's own
//! `/operations` page in a child webview of the main window, laid over the
//! Operations tile and moved with it, as the Crew Deck lays the game over its
//! tile. The page keeps its own cookie session and its own authorization;
//! this module adds no authority and grants the page no IPC (the capability
//! names only the `main` webview, and a remote origin gets none by default).
//!
//! The URL is `operationsUrl` in config.json, or
//! `<dispatch.auth>/operations?provider=<dispatch.provider>` when Dispatch is
//! configured: both are served by the task host, and the page then signs in
//! through the same provider the Dispatch panel uses.
//! Plain HTTP is accepted only for a loopback host; anything else must be
//! HTTPS. Navigation stays on that origin and new windows are refused.

use serde::Serialize;
#[cfg(not(target_os = "linux"))]
use tauri::webview::NewWindowResponse;
#[cfg(not(target_os = "linux"))]
use tauri::{LogicalPosition, LogicalSize, Manager, WebviewBuilder, WebviewUrl};
use tauri::{AppHandle, Url};

#[cfg(not(target_os = "linux"))]
pub const LABEL: &str = "operations";

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Status {
    /// The page the webview opens, if one is configured.
    pub url: Option<String>,
    /// Why there is none, or why the configured one was refused.
    pub problem: Option<String>,
}

fn loopback(url: &Url) -> bool {
    let Some(host) = url.host_str() else { return false };
    let host = host.trim_start_matches('[').trim_end_matches(']');
    host.eq_ignore_ascii_case("localhost")
        || host.parse::<std::net::IpAddr>().is_ok_and(|ip| ip.is_loopback())
}

/// A credential-free http(s) URL; http only on loopback.
fn acceptable(url: &Url) -> bool {
    let scheme_ok = url.scheme() == "https" || (url.scheme() == "http" && loopback(url));
    scheme_ok && url.has_host() && url.username().is_empty() && url.password().is_none()
}

pub fn page_url(raw: &str) -> Result<Url, String> {
    let invalid = "Set operationsUrl to the task host's Operations page, e.g. https://tasks.example.org/operations (plain http only on localhost).";
    let url = Url::parse(raw).map_err(|_| invalid.to_string())?;
    if !acceptable(&url) || url.fragment().is_some() {
        return Err(invalid.into());
    }
    Ok(url)
}

/// Where the page is: the explicit setting wins; otherwise the task host that Dispatch signs in through.
pub fn configured(settings: &crate::settings::Settings) -> Result<Url, String> {
    if let Some(raw) = &settings.operations_url {
        return page_url(raw);
    }
    if let Some(d) = &settings.dispatch {
        // Sign in the way the Dispatch panel does, through the same provider.
        let mut url = page_url(&format!("{}/operations", d.auth.trim_end_matches('/')))?;
        url.query_pairs_mut().append_pair("provider", &d.provider);
        return Ok(url);
    }
    Err("Operations is not configured. Set operationsUrl in config.json.".into())
}

fn same_origin(origin: &Url, target: &Url) -> bool {
    acceptable(target) && origin.origin() == target.origin()
}

#[tauri::command]
pub fn operations_status() -> Status {
    match crate::settings::load().and_then(|s| configured(&s)) {
        Ok(url) => Status { url: Some(url.to_string()), problem: None },
        Err(problem) => Status { url: None, problem: Some(problem) },
    }
}

/// Show the page at a rectangle of the main window, in CSS pixels, creating
/// the webview the first time.
#[tauri::command]
pub async fn operations_place(app: AppHandle, x: f64, y: f64, w: f64, h: f64) -> Result<(), String> {
    if !(x.is_finite() && y.is_finite() && w.is_finite() && h.is_finite()) || w < 1.0 || h < 1.0 {
        return operations_hide(app).await;
    }
    let url = crate::settings::load().and_then(|s| configured(&s))?;
    platform::place(&app, url, x, y, w, h).await
}

/// Hide the page (its tile was closed, covered or emptied). It keeps its session.
#[tauri::command]
pub async fn operations_hide(app: AppHandle) -> Result<(), String> {
    platform::hide(&app).await
}

#[tauri::command]
pub async fn operations_reload(app: AppHandle) -> Result<(), String> {
    platform::reload(&app).await
}

/// macOS and Windows: Tauri places a child webview at its bounds, above the app's.
#[cfg(not(target_os = "linux"))]
mod platform {
    use super::*;

    pub fn install(_window: &tauri::Window) -> Result<(), String> {
        Ok(())
    }

    pub async fn place(app: &AppHandle, url: Url, x: f64, y: f64, w: f64, h: f64) -> Result<(), String> {
        let position = LogicalPosition::new(x, y);
        let size = LogicalSize::new(w, h);
        if let Some(webview) = app.get_webview(LABEL) {
            webview.set_position(position).map_err(|e| e.to_string())?;
            webview.set_size(size).map_err(|e| e.to_string())?;
            return webview.show().map_err(|e| e.to_string());
        }
        let window = app.get_window("main").ok_or("the main window is gone")?;
        let origin = url.clone();
        let builder = WebviewBuilder::new(LABEL, WebviewUrl::External(url))
            .on_navigation(move |target| same_origin(&origin, target))
            .on_new_window(|_, _| NewWindowResponse::Deny);
        window.add_child(builder, position, size).map_err(|e| e.to_string())?;
        Ok(())
    }

    pub async fn hide(app: &AppHandle) -> Result<(), String> {
        match app.get_webview(LABEL) {
            Some(webview) => webview.hide().map_err(|e| e.to_string()),
            None => Ok(()),
        }
    }

    pub async fn reload(app: &AppHandle) -> Result<(), String> {
        match app.get_webview(LABEL) {
            Some(webview) => webview.reload().map_err(|e| e.to_string()),
            None => Ok(()),
        }
    }
}

/// Linux: Tauri packs every child webview into the window's vertical GtkBox,
/// so they stack instead of overlapping. Here the app's webview is moved into
/// a GtkOverlay, and the Operations page is a wry webview in an overlay layer
/// positioned by margins. An overlay child adds nothing to the window's size
/// request, and only its own rectangle takes input; the rest reaches the app.
/// GTK is single-threaded, so every step runs on the main thread.
#[cfg(target_os = "linux")]
mod platform {
    use super::*;
    use gtk::prelude::*;
    use wry::WebViewBuilderExtUnix;
    use std::cell::RefCell;

    struct Page {
        holder: gtk::Box,
        webview: wry::WebView,
    }

    thread_local! {
        static OVERLAY: RefCell<Option<gtk::Overlay>> = const { RefCell::new(None) };
        static PAGE: RefCell<Option<Page>> = const { RefCell::new(None) };
    }

    /// Wrap the window's content (the app's webview) in an overlay. Called once, from setup.
    pub fn install(window: &tauri::Window) -> Result<(), String> {
        let vbox = window.default_vbox().map_err(|e| e.to_string())?;
        let overlay = gtk::Overlay::new();
        for child in vbox.children() {
            vbox.remove(&child);
            overlay.add(&child);
        }
        vbox.pack_start(&overlay, true, true, 0);
        overlay.show_all();
        OVERLAY.with(|o| *o.borrow_mut() = Some(overlay));
        Ok(())
    }

    /// Run `f` on the GTK thread and wait for its result.
    async fn on_main<T: Send + 'static>(
        app: &AppHandle,
        f: impl FnOnce() -> Result<T, String> + Send + 'static,
    ) -> Result<T, String> {
        let (tx, rx) = tokio::sync::oneshot::channel();
        app.run_on_main_thread(move || {
            let _ = tx.send(f());
        })
        .map_err(|e| e.to_string())?;
        rx.await.map_err(|_| "the main thread dropped the request".to_string())?
    }

    fn position(holder: &gtk::Box, x: f64, y: f64, w: f64, h: f64) {
        holder.set_margin_start(x.round() as i32);
        holder.set_margin_top(y.round() as i32);
        holder.set_size_request(w.round() as i32, h.round() as i32);
    }

    pub async fn place(app: &AppHandle, url: Url, x: f64, y: f64, w: f64, h: f64) -> Result<(), String> {
        on_main(app, move || {
            let existing = PAGE.with(|p| p.borrow().as_ref().map(|p| p.holder.clone()));
            if let Some(holder) = existing {
                position(&holder, x, y, w, h);
                holder.show();
                return Ok(());
            }
            let overlay = OVERLAY
                .with(|o| o.borrow().clone())
                .ok_or("the window has no overlay for Operations")?;
            let holder = gtk::Box::new(gtk::Orientation::Vertical, 0);
            holder.set_halign(gtk::Align::Start);
            holder.set_valign(gtk::Align::Start);
            position(&holder, x, y, w, h);
            overlay.add_overlay(&holder);
            let origin = url.clone();
            let webview = wry::WebViewBuilder::new()
                .with_url(url.as_str())
                .with_navigation_handler(move |target| {
                    Url::parse(&target).is_ok_and(|t| same_origin(&origin, &t))
                })
                .with_new_window_req_handler(|_, _| wry::NewWindowResponse::Deny)
                .build_gtk(&holder)
                .map_err(|e| e.to_string())?;
            holder.show_all();
            PAGE.with(|p| *p.borrow_mut() = Some(Page { holder, webview }));
            Ok(())
        })
        .await
    }

    pub async fn hide(app: &AppHandle) -> Result<(), String> {
        on_main(app, || {
            PAGE.with(|p| {
                if let Some(p) = p.borrow().as_ref() {
                    p.holder.hide();
                }
            });
            Ok(())
        })
        .await
    }

    pub async fn reload(app: &AppHandle) -> Result<(), String> {
        on_main(app, || {
            PAGE.with(|p| match p.borrow().as_ref() {
                Some(p) => p.webview.reload().map_err(|e| e.to_string()),
                None => Ok(()),
            })
        })
        .await
    }
}

pub use platform::install;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plain_http_only_on_loopback() {
        assert!(page_url("http://127.0.0.1:4001/operations").is_ok());
        assert!(page_url("http://localhost:4001/operations").is_ok());
        assert!(page_url("http://[::1]:4001/operations").is_ok());
        assert!(page_url("https://tasks.example.org/operations").is_ok());
        assert!(page_url("http://tasks.example.org/operations").is_err());
        assert!(page_url("http://100.67.165.25:4001/operations").is_err());
    }

    #[test]
    fn credentials_fragments_and_other_schemes_are_refused() {
        assert!(page_url("https://user:pw@tasks.example.org/operations").is_err());
        assert!(page_url("https://tasks.example.org/operations#x").is_err());
        assert!(page_url("file:///etc/passwd").is_err());
        assert!(page_url("javascript:alert(1)").is_err());
        assert!(page_url("not a url").is_err());
    }

    #[test]
    fn navigation_stays_on_the_page_origin() {
        let origin = page_url("http://127.0.0.1:4001/operations").unwrap();
        assert!(same_origin(&origin, &Url::parse("http://127.0.0.1:4001/auth/admin/login").unwrap()));
        assert!(!same_origin(&origin, &Url::parse("http://127.0.0.1:4000/").unwrap()));
        assert!(!same_origin(&origin, &Url::parse("https://evil.example/").unwrap()));
    }

    #[test]
    fn defaults_to_the_dispatch_task_host() {
        let mut s = crate::settings::Settings::default();
        assert!(configured(&s).is_err());
        s.dispatch = Some(crate::settings::Dispatch {
            api: "http://localhost:4000".into(),
            auth: "http://127.0.0.1:4001/".into(),
            provider: "dispatcher".into(),
        });
        assert_eq!(configured(&s).unwrap().as_str(), "http://127.0.0.1:4001/operations?provider=dispatcher");
        s.operations_url = Some("https://tasks.example.org/operations".into());
        assert_eq!(configured(&s).unwrap().as_str(), "https://tasks.example.org/operations");
    }
}
