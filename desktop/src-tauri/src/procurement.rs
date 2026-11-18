//! The coordinator console uses the host's existing HTTPS forms and session.
use tauri::webview::NewWindowResponse;
use tauri::{AppHandle, Manager, Url, WebviewUrl, WebviewWindowBuilder};

const LABEL: &str = "procurement";

pub(super) fn host_url(raw: &str) -> Result<Url, String> {
    let invalid =
        "Set procurementOrigin to an HTTPS origin, such as https://procurement.example.org.";
    let url = Url::parse(raw).map_err(|_| invalid.to_string())?;
    if !credential_free_https(&url)
        || url.path() != "/"
        || url.query().is_some()
        || url.fragment().is_some()
    {
        return Err(invalid.into());
    }
    Ok(url)
}

fn credential_free_https(url: &Url) -> bool {
    url.scheme() == "https"
        && url.has_host()
        && url.username().is_empty()
        && url.password().is_none()
}

fn same_host(origin: &Url, target: &Url) -> bool {
    credential_free_https(target) && origin.origin() == target.origin()
}

#[tauri::command]
pub async fn open_procurement(app: AppHandle) -> Result<(), String> {
    let settings = crate::settings::load()?;
    let raw = settings
        .procurement_origin
        .ok_or("Procurement is not configured. Set procurementOrigin in config.json.")?;
    let origin = host_url(&raw)?;

    if let Some(window) = app.get_webview_window(LABEL) {
        let current = window.url().map_err(|error| error.to_string())?;
        if !same_host(&origin, &current) {
            return Err(
                "Close the existing Procurement window before opening a different server.".into(),
            );
        }
        window.show().map_err(|error| error.to_string())?;
        window.unminimize().map_err(|error| error.to_string())?;
        return window.set_focus().map_err(|error| error.to_string());
    }

    WebviewWindowBuilder::new(&app, LABEL, WebviewUrl::External(origin.clone()))
        .title("Biz-kit Procurement")
        .inner_size(1100.0, 760.0)
        .on_navigation(move |target| same_host(&origin, target))
        .on_new_window(|_, _| NewWindowResponse::Deny)
        .build()
        .map_err(|error| error.to_string())?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn configuration_requires_an_https_origin_without_credentials() {
        assert!(host_url("https://procurement.example.org:8443").is_ok());
        for raw in [
            "http://procurement.example.org",
            "https://user:password@procurement.example.org",
            "https://procurement.example.org/login",
            "https://procurement.example.org/?token=example",
            "https://procurement.example.org/#login",
            "file:///procurement",
        ] {
            assert!(host_url(raw).is_err(), "{raw}");
        }
    }

    #[test]
    fn navigation_stays_on_the_exact_https_origin() {
        let origin = host_url("https://procurement.example.org:8443").unwrap();
        assert!(same_host(
            &origin,
            &Url::parse("https://procurement.example.org:8443/requests/r1").unwrap(),
        ));
        for raw in [
            "https://procurement.example.org/requests",
            "http://procurement.example.org:8443/requests",
            "https://procurement.example.org.evil.test:8443/requests",
            "https://user@procurement.example.org:8443/requests",
            "tauri://localhost/",
            "about:blank",
        ] {
            assert!(!same_host(&origin, &Url::parse(raw).unwrap()), "{raw}");
        }
    }
}
