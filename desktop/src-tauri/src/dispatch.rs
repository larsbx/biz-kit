//! The Dispatch panel's connection: sign-in, and calls to dispatch's `/v1` API.
//!
//! Sign-in is OAuth 2.0 for Native Apps (RFC 8252) with PKCE (RFC 7636), as
//! biz-kit's `/auth` brokers it for every native client: the system browser
//! signs in, `/auth` redirects to a loopback listener here with a one-time
//! code, and the code and verifier are exchanged for a session that lasts until
//! sign-out. The app never sees the provider or a password.
//!
//! The session is the one credential, so it stays in this process and in a
//! 0600 file beside `config.json`. The webview never holds it: it asks for a
//! `/v1` path and gets the response, and nothing outside `/v1/` can be named.

use crate::settings::{self, Dispatch};
use rand::RngCore;
use serde::Serialize;
use sha2::{Digest, Sha256};
use std::path::PathBuf;
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;

/// The loopback redirect. `/auth` matches redirect URIs exactly, so the port
/// is fixed and the URI must be on its allowlist (`BIZKIT_NATIVE_REDIRECT_URIS`).
pub const REDIRECT_URI: &str = "http://127.0.0.1:47811/callback";
const LISTEN: &str = "127.0.0.1:47811";
/// Long enough to type a password; a sign-in request lives ten minutes server-side.
const SIGN_IN_TIMEOUT: Duration = Duration::from_secs(300);
/// How long an accepted connection has to send its request line.
const REQUEST_READ_TIMEOUT: Duration = Duration::from_secs(5);

/// Cancels the sign-in in progress, so starting another frees the port
/// instead of failing to bind it.
static PENDING: std::sync::Mutex<Option<tokio::sync::oneshot::Sender<()>>> =
    std::sync::Mutex::new(None);

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Status {
    /// None when `config.json` has no `dispatch` section.
    pub api: Option<String>,
    pub signed_in: bool,
}

#[derive(Debug, Clone, Serialize)]
pub struct Reply {
    pub status: u16,
    /// The JSON body, or null when there was none.
    pub body: serde_json::Value,
}

fn config() -> Result<Dispatch, String> {
    settings::load()?.dispatch.ok_or_else(|| {
        format!("no \"dispatch\" section in {}", settings::path().display())
    })
}

fn session_path() -> PathBuf {
    settings::path().with_file_name("dispatch-session")
}

fn session() -> Option<String> {
    std::fs::read_to_string(session_path())
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

fn save_session(token: &str) -> Result<(), String> {
    let path = session_path();
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    }
    write_private(&path, token).map_err(|e| format!("{}: {e}", path.display()))
}

#[cfg(unix)]
fn write_private(path: &std::path::Path, contents: &str) -> std::io::Result<()> {
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;
    let mut f = std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(path)?;
    f.write_all(contents.as_bytes())
}

#[cfg(not(unix))]
fn write_private(path: &std::path::Path, contents: &str) -> std::io::Result<()> {
    std::fs::write(path, contents)
}

fn client() -> Result<reqwest::Client, String> {
    reqwest::Client::builder()
        .timeout(Duration::from_secs(30))
        // A redirect from an API call is never wanted, and following one would
        // carry the bearer somewhere it was not sent.
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .map_err(|e| e.to_string())
}

fn random_url_safe(bytes: usize) -> String {
    let mut buf = vec![0u8; bytes];
    rand::thread_rng().fill_bytes(&mut buf);
    base64url(&buf)
}

/// Unpadded base64url (RFC 4648 §5), as PKCE requires.
fn base64url(bytes: &[u8]) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let n = chunk.iter().enumerate().fold(0u32, |n, (i, b)| n | (*b as u32) << (16 - 8 * i));
        for i in 0..=chunk.len() {
            out.push(ALPHABET[(n >> (18 - 6 * i) & 63) as usize] as char);
        }
    }
    out
}

fn challenge(verifier: &str) -> String {
    base64url(&Sha256::digest(verifier.as_bytes()))
}

fn encode(s: &str) -> String {
    s.bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => (b as char).to_string(),
            _ => format!("%{b:02X}"),
        })
        .collect()
}

fn decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'%' if i + 2 < bytes.len() => {
                let hex = std::str::from_utf8(&bytes[i + 1..i + 3]).ok();
                match hex.and_then(|h| u8::from_str_radix(h, 16).ok()) {
                    Some(b) => {
                        out.push(b);
                        i += 3;
                        continue;
                    }
                    None => out.push(b'%'),
                }
            }
            b'+' => out.push(b' '),
            b => out.push(b),
        }
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// The query of the request line `GET /callback?… HTTP/1.1`, as pairs.
fn callback_query(request: &str) -> Option<Vec<(String, String)>> {
    let target = request.lines().next()?.split_whitespace().nth(1)?;
    let (path, query) = target.split_once('?').unwrap_or((target, ""));
    if path != "/callback" {
        return None;
    }
    Some(
        query
            .split('&')
            .filter(|p| !p.is_empty())
            .map(|p| {
                let (k, v) = p.split_once('=').unwrap_or((p, ""));
                (decode(k), decode(v))
            })
            .collect(),
    )
}

fn open_browser(url: &str) -> Result<(), String> {
    let mut cmd = if cfg!(target_os = "macos") {
        std::process::Command::new("open")
    } else if cfg!(windows) {
        let mut c = std::process::Command::new("cmd");
        c.args(["/C", "start", ""]);
        c
    } else {
        std::process::Command::new("xdg-open")
    };
    cmd.arg(url).spawn().map(|_| ()).map_err(|e| format!("could not open a browser: {e}"))
}

/// Reads until the request line is complete, or gives up after `REQUEST_READ_TIMEOUT`.
///
/// Browsers open speculative connections that never send a request; without
/// the deadline one of those would hold the listener while the real redirect
/// waited in the backlog until sign-in timed out.
async fn read_request(sock: &mut tokio::net::TcpStream) -> Option<String> {
    let read = async {
        let mut buf = Vec::with_capacity(1024);
        let mut chunk = [0u8; 1024];
        while !buf.windows(2).any(|w| w == b"\r\n") && buf.len() < 8192 {
            let n = sock.read(&mut chunk).await.ok()?;
            if n == 0 {
                break;
            }
            buf.extend_from_slice(&chunk[..n]);
        }
        Some(String::from_utf8_lossy(&buf).into_owned())
    };
    tokio::time::timeout(REQUEST_READ_TIMEOUT, read).await.ok().flatten()
}

/// Waits for the browser to arrive at the loopback redirect and returns the code.
async fn await_code(listener: TcpListener, state: &str) -> Result<String, String> {
    loop {
        let (mut sock, _) = listener.accept().await.map_err(|e| e.to_string())?;
        let Some(request) = read_request(&mut sock).await else {
            continue;
        };

        // Anything else (a favicon, a stray probe) is answered and ignored.
        let Some(query) = callback_query(&request) else {
            let _ = sock.write_all(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n").await;
            continue;
        };
        let get = |k: &str| query.iter().find(|(key, _)| key == k).map(|(_, v)| v.clone());

        let outcome = if get("state").as_deref() != Some(state) {
            Err("sign-in returned with the wrong state; start it again".to_string())
        } else if let Some(error) = get("error") {
            Err(format!("sign-in was refused: {error}"))
        } else {
            get("code").ok_or_else(|| "sign-in returned without a code".to_string())
        };

        let page = if outcome.is_ok() {
            "Signed in to biz-kit. You can close this tab."
        } else {
            "biz-kit sign-in did not complete. Return to the app."
        };
        let reply = format!(
            "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{page}",
            page.len()
        );
        let _ = sock.write_all(reply.as_bytes()).await;
        return outcome;
    }
}

#[tauri::command]
pub fn dispatch_status() -> Result<Status, String> {
    let s = settings::load()?;
    Ok(Status { api: s.dispatch.map(|d| d.api), signed_in: session().is_some() })
}

#[tauri::command]
pub async fn dispatch_sign_in() -> Result<(), String> {
    let cfg = config()?;
    let auth = cfg.auth.trim_end_matches('/');
    // A browser sent to a server that is down shows its own error and never
    // redirects, which would leave the app waiting the full timeout.
    client()?
        .get(auth)
        .timeout(Duration::from_secs(5))
        .send()
        .await
        .map_err(|e| format!("biz-kit sign-in at {auth} is unreachable: {e}"))?;

    let (cancel, cancelled) = tokio::sync::oneshot::channel();
    if let Some(previous) = PENDING.lock().unwrap().replace(cancel) {
        let _ = previous.send(());
    }
    // Bound before the browser opens, so the redirect cannot arrive first. A
    // replaced sign-in releases the port once its task next runs, so retry briefly.
    let mut attempt = 0;
    let listener = loop {
        match TcpListener::bind(LISTEN).await {
            Ok(l) => break l,
            Err(e) if attempt < 20 && e.kind() == std::io::ErrorKind::AddrInUse => {
                attempt += 1;
                tokio::time::sleep(Duration::from_millis(50)).await;
            }
            Err(e) => return Err(format!("cannot listen on {LISTEN} for the sign-in redirect: {e}")),
        }
    };

    let verifier = random_url_safe(32);
    let state = random_url_safe(16);
    let url = format!(
        "{auth}/auth/{}/native/login?redirect_uri={}&code_challenge={}&code_challenge_method=S256&state={}",
        encode(&cfg.provider),
        encode(REDIRECT_URI),
        challenge(&verifier),
        encode(&state)
    );
    open_browser(&url)?;

    let code = tokio::select! {
        outcome = tokio::time::timeout(SIGN_IN_TIMEOUT, await_code(listener, &state)) => {
            outcome.map_err(|_| "sign-in timed out".to_string())?
        }
        _ = cancelled => Err("replaced by a newer sign-in".to_string()),
    }?;

    let resp = client()?
        .post(format!("{auth}/auth/token"))
        .form(&[
            ("grant_type", "authorization_code"),
            ("code", code.as_str()),
            ("code_verifier", verifier.as_str()),
            ("redirect_uri", REDIRECT_URI),
        ])
        .send()
        .await
        .map_err(|e| format!("token exchange failed: {e}"))?;
    if !resp.status().is_success() {
        return Err(format!("token exchange refused ({})", resp.status()));
    }
    let body: serde_json::Value = resp.json().await.map_err(|e| e.to_string())?;
    let token = body["access_token"].as_str().ok_or("token exchange returned no access_token")?;
    save_session(token)
}

#[tauri::command]
pub async fn dispatch_sign_out() -> Result<(), String> {
    if let (Ok(cfg), Some(token)) = (config(), session()) {
        // Best effort: the local copy goes regardless, and an unreachable
        // server must not leave the app signed in.
        let _ = client()?
            .post(format!("{}/auth/logout", cfg.auth.trim_end_matches('/')))
            .bearer_auth(token)
            .send()
            .await;
    }
    match std::fs::remove_file(session_path()) {
        Err(e) if e.kind() != std::io::ErrorKind::NotFound => Err(e.to_string()),
        _ => Ok(()),
    }
}

/// Whether `path` names dispatch's `/v1` API and nothing else.
fn allowed(path: &str) -> bool {
    path.starts_with("/v1/") && !path.contains("..") && !path.contains("://") && !path.contains('#')
}

/// Calls dispatch's `/v1` API as the signed-in person.
#[tauri::command]
pub async fn dispatch_request(
    method: String,
    path: String,
    body: Option<serde_json::Value>,
    role_assignment_id: Option<String>,
    idempotency_key: Option<String>,
) -> Result<Reply, String> {
    if !allowed(&path) {
        return Err(format!("refusing to call {path}: only /v1/ paths"));
    }
    let method = match method.as_str() {
        "GET" => reqwest::Method::GET,
        "POST" => reqwest::Method::POST,
        "PATCH" => reqwest::Method::PATCH,
        other => return Err(format!("refusing method {other}")),
    };
    let cfg = config()?;
    let token = session().ok_or("not signed in")?;

    let mut req = client()?
        .request(method, format!("{}{path}", cfg.api.trim_end_matches('/')))
        .bearer_auth(token)
        .header("accept", "application/json");
    if let Some(id) = role_assignment_id {
        req = req.header("x-role-assignment-id", id);
    }
    if let Some(key) = idempotency_key {
        req = req.header("idempotency-key", key);
    }
    if let Some(body) = body {
        req = req.json(&body);
    }

    let resp = req.send().await.map_err(|e| format!("dispatch unreachable: {e}"))?;
    let status = resp.status().as_u16();
    // An ended session answers 401: forget it so the panel offers sign-in.
    if status == 401 {
        let _ = std::fs::remove_file(session_path());
    }
    let text = resp.text().await.map_err(|e| e.to_string())?;
    let body = if text.trim().is_empty() {
        serde_json::Value::Null
    } else {
        serde_json::from_str(&text).unwrap_or(serde_json::Value::String(text))
    };
    Ok(Reply { status, body })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pkce_challenge_matches_rfc_7636_appendix_b() {
        assert_eq!(
            challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        );
    }

    #[test]
    fn base64url_is_unpadded() {
        assert_eq!(base64url(b"f"), "Zg");
        assert_eq!(base64url(b"fo"), "Zm8");
        assert_eq!(base64url(b"foo"), "Zm9v");
        assert_eq!(base64url(&[0xfb, 0xff]), "-_8");
    }

    #[test]
    fn reads_the_callback_query() {
        let q = callback_query("GET /callback?code=a%2Bb&state=s1 HTTP/1.1\r\nHost: x\r\n\r\n").unwrap();
        assert_eq!(q, [("code".into(), "a+b".into()), ("state".into(), "s1".into())]);
        assert!(callback_query("GET /favicon.ico HTTP/1.1\r\n").is_none());
    }

    #[tokio::test]
    async fn an_idle_connection_does_not_hold_up_the_redirect() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let waiting = tokio::spawn(async move { await_code(listener, "s1").await });

        // A browser preconnect: accepted first, never sends a byte.
        let _idle = tokio::net::TcpStream::connect(addr).await.unwrap();
        let mut real = tokio::net::TcpStream::connect(addr).await.unwrap();
        real.write_all(b"GET /callback?code=c1&state=s1 HTTP/1.1\r\n\r\n").await.unwrap();

        let code = tokio::time::timeout(REQUEST_READ_TIMEOUT * 2, waiting).await;
        assert_eq!(code.expect("redirect was held up").unwrap(), Ok("c1".to_string()));
    }

    #[test]
    fn only_v1_paths_reach_dispatch() {
        assert!(allowed("/v1/operations/loads"));
        assert!(!allowed("/health/dependencies"));
        assert!(!allowed("/v1/../ui/operations"));
        assert!(!allowed("//evil.example/v1/"));
        assert!(!allowed("/v1/x#frag"));
    }
}
