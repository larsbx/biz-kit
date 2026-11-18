//! Explicit direct/relay experimental Iroh framing. No governance authority.
use anyhow::{Context, Result, ensure};
use base64::{Engine, engine::general_purpose::STANDARD};
use iroh::{
    Endpoint, EndpointAddr, EndpointId, RelayMode, RelayUrl, SecretKey,
    endpoint::{Connection, QuicTransportConfig, presets},
};
use iroh_relay::{RelayMap, tls::CaTlsConfig};
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::{
    io::Write,
    net::SocketAddr,
    path::{Path, PathBuf},
    sync::Arc,
    time::Duration,
};
use tokio::io::{
    AsyncBufRead, AsyncBufReadExt, AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, BufReader,
};

const ALPN: &[u8] = b"bizkit/halaqa-experiment/0";
const MAX_REQUEST: usize = 24_000;
const MAX_RESPONSE: usize = 12_000;
const MAX_LINE: usize = 32_000;
const DEADLINE: Duration = Duration::from_secs(5);

#[derive(Debug, Deserialize, Serialize)]
#[serde(tag = "op", deny_unknown_fields)]
enum Request {
    #[serde(rename = "status")]
    Status {
        challenge: String,
        recipient: String,
        sender: String,
        message_id: String,
        candidate_sha256: String,
    },
    #[serde(rename = "deliver")]
    Deliver { challenge: String, wire: String },
}
impl Request {
    fn challenge(&self) -> &str {
        match self {
            Self::Status { challenge, .. } | Self::Deliver { challenge, .. } => challenge,
        }
    }
    fn validate(&self) -> Result<()> {
        ensure!(hex32(self.challenge()), "challenge encoding");
        match self {
            Self::Status {
                recipient,
                sender,
                message_id,
                candidate_sha256,
                ..
            } => {
                ensure!(
                    [recipient, sender, message_id].iter().all(|s| token(s)),
                    "status identifiers"
                );
                ensure!(hex32(candidate_sha256), "status hash");
            }
            Self::Deliver { wire, .. } => {
                canonical(wire, 12_288)?;
            }
        }
        Ok(())
    }
}
#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Response {
    challenge: String,
    reply: String,
}
#[derive(Deserialize)]
#[serde(tag = "op", deny_unknown_fields)]
enum HostReply {
    #[serde(rename = "respond")]
    Respond {
        request_id: u64,
        challenge: String,
        reply: String,
    },
    #[serde(rename = "drop")]
    Drop { request_id: u64 },
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ServerConfig {
    key_file: PathBuf,
    bind: SocketAddr,
    allowed_endpoint: EndpointId,
    sender: String,
    recipient: String,
    #[serde(default)]
    relay: Option<RelaySettings>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ClientConfig {
    key_file: PathBuf,
    bind: SocketAddr,
    target: EndpointAddr,
    request: Request,
    #[serde(default)]
    relay: Option<RelaySettings>,
}
#[derive(Clone, Deserialize)]
#[serde(deny_unknown_fields)]
struct RelaySettings {
    url: RelayUrl,
    ca_file: PathBuf,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RelayServerConfig {
    cert_file: PathBuf,
    key_file: PathBuf,
    allowed_endpoints: Vec<EndpointId>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct IdentityConfig {
    key_file: PathBuf,
}

fn token(s: &str) -> bool {
    let b = s.as_bytes();
    !b.is_empty()
        && b.len() <= 128
        && b[0].is_ascii_alphanumeric()
        && b.iter()
            .all(|c| c.is_ascii_alphanumeric() || b"._:-".contains(c))
}
fn hex32(s: &str) -> bool {
    s.len() == 64
        && s.bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}
fn canonical(s: &str, limit: usize) -> Result<Vec<u8>> {
    ensure!(s.len() <= limit.div_ceil(3) * 4, "encoded limit");
    let raw = STANDARD.decode(s)?;
    ensure!(
        !raw.is_empty() && raw.len() <= limit && STANDARD.encode(&raw) == s,
        "body encoding/limit"
    );
    Ok(raw)
}
fn key(path: &Path) -> Result<SecretKey> {
    let meta = std::fs::metadata(path)?;
    ensure!(
        meta.is_file() && meta.len() == 32,
        "32-byte key file required"
    );
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        ensure!(
            meta.permissions().mode() & 0o077 == 0,
            "private key permissions"
        );
    }
    let bytes: [u8; 32] = std::fs::read(path)?
        .try_into()
        .map_err(|_| anyhow::anyhow!("key length"))?;
    Ok(SecretKey::from_bytes(&bytes))
}
fn output(value: serde_json::Value) -> Result<()> {
    let mut out = std::io::stdout().lock();
    serde_json::to_writer(&mut out, &value)?;
    writeln!(out)?;
    out.flush()?;
    Ok(())
}
async fn line<R: AsyncBufRead + Unpin>(input: &mut R) -> Result<Vec<u8>> {
    let mut result = Vec::new();
    loop {
        let bytes = input.fill_buf().await?;
        ensure!(!bytes.is_empty(), "host EOF");
        let newline = bytes.iter().position(|&b| b == b'\n');
        let used = newline.map_or(bytes.len(), |n| n + 1);
        ensure!(result.len() + used <= MAX_LINE, "IPC line limit");
        result.extend_from_slice(&bytes[..used]);
        input.consume(used);
        if newline.is_some() {
            return Ok(result);
        }
    }
}
async fn read_frame<R: AsyncRead + Unpin>(input: &mut R, limit: usize) -> Result<Vec<u8>> {
    let mut header = [0; 4];
    input.read_exact(&mut header).await?;
    let n = u32::from_be_bytes(header) as usize;
    ensure!(n > 0 && n <= limit, "frame length");
    let mut body = vec![0; n];
    input.read_exact(&mut body).await?;
    let mut tail = [0; 1];
    ensure!(input.read(&mut tail).await? == 0, "trailing frame bytes");
    Ok(body)
}
async fn write_frame<W: AsyncWrite + Unpin>(out: &mut W, bytes: &[u8], limit: usize) -> Result<()> {
    ensure!(
        !bytes.is_empty() && bytes.len() <= limit,
        "output frame length"
    );
    out.write_all(&(bytes.len() as u32).to_be_bytes()).await?;
    out.write_all(bytes).await?;
    Ok(())
}
fn response_bytes(response: Response, expected: &str) -> Result<Vec<u8>> {
    ensure!(
        response.challenge == expected && hex32(&response.challenge),
        "stale or unrelated response"
    );
    canonical(&response.reply, 8_192)
}
fn validate_relay(relay: &RelaySettings) -> Result<()> {
    let url = &relay.url;
    ensure!(
        url.scheme() == "https"
            && url.username().is_empty()
            && url.password().is_none()
            && url.query().is_none()
            && url.fragment().is_none()
            && url.path() == "/"
            && url.port_or_known_default().is_some_and(|p| p > 0)
            && url.host_str().is_some_and(|h| h
                .trim_matches(['[', ']'])
                .parse::<std::net::IpAddr>()
                .is_ok()),
        "explicit HTTPS relay IP/root path required"
    );
    Ok(())
}
async fn endpoint(
    path: &Path,
    bind: SocketAddr,
    relay: Option<&RelaySettings>,
) -> Result<Endpoint> {
    ensure!(bind.ip().is_loopback(), "experiment requires loopback bind");
    let transport = QuicTransportConfig::builder()
        .max_concurrent_bidi_streams(1u32.into())
        .max_concurrent_uni_streams(0u32.into())
        .max_idle_timeout(Some(Duration::from_secs(10).try_into()?))
        .build();
    let mut builder = Endpoint::builder(presets::Minimal)
        .clear_ip_transports()
        .secret_key(key(path)?)
        .transport_config(transport)
        .alpns(vec![ALPN.to_vec()]);
    if let Some(relay) = relay {
        validate_relay(relay)?;
        let root = rustls::pki_types::CertificateDer::from(std::fs::read(&relay.ca_file)?);
        builder = builder
            .relay_mode(RelayMode::Custom(RelayMap::from_iter([relay.url.clone()])))
            .ca_tls_config(CaTlsConfig::custom_roots([root]));
    } else {
        builder = builder.relay_mode(RelayMode::Disabled).bind_addr(bind)?;
    }
    let endpoint = builder.bind().await?;
    if relay.is_some() {
        ensure!(
            endpoint.bound_sockets().is_empty(),
            "relay-only profile bound a direct IP socket"
        );
        tokio::time::timeout(DEADLINE, endpoint.online()).await?;
    }
    Ok(endpoint)
}
async fn path_evidence(
    connection: &Connection,
    relay: Option<&RelaySettings>,
    ip_sockets: usize,
) -> Result<serde_json::Value> {
    tokio::time::timeout(Duration::from_secs(2),async {
        loop {
            let paths=connection.paths();
            let rows: Vec<_>=paths.iter().map(|p| {
                let s=p.stats();
                json!({"kind":if p.is_relay(){"relay"}else{"direct"},"selected":p.is_selected(),
                    "address":p.remote_addr().to_string(),"tx_bytes":s.udp_tx.bytes,"rx_bytes":s.udp_rx.bytes,
                    "stream_rx":s.frame_rx.stream})
            }).collect();
            let correct=if let Some(r)=relay {
                ip_sockets==0 && paths.iter().all(|p| p.is_relay() && p.remote_addr().to_string()==format!("relay:{}",r.url))
            } else { paths.iter().all(|p| p.is_ip()) };
            if !rows.is_empty() && correct && rows.iter().any(|r| r["selected"]==true && r["stream_rx"].as_u64().is_some_and(|n|n>0)) {
                ensure!(rows.len()<=4,"path evidence limit");
                return Ok::<_,anyhow::Error>(json!({"mode":if relay.is_some(){"relay_only"}else{"direct"},"ip_bound_sockets":ip_sockets,"paths":rows}));
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    }).await?
}
#[derive(Debug)]
struct RelayAccess(Vec<EndpointId>);
impl iroh_relay::server::AccessControl for RelayAccess {
    async fn on_connect(
        &self,
        request: &iroh_relay::server::ClientRequest,
    ) -> iroh_relay::server::Access {
        if self.0.contains(&request.endpoint_id()) {
            iroh_relay::server::Access::Allow
        } else {
            iroh_relay::server::Access::Deny {
                reason: Some("unconfigured fixture endpoint".into()),
            }
        }
    }
}
async fn relay_server<R: AsyncBufRead + Unpin>(
    config: RelayServerConfig,
    input: &mut R,
) -> Result<()> {
    use iroh_relay::server::{CertConfig, RelayConfig, Server, ServerConfig, TlsConfig};
    ensure!(
        !config.allowed_endpoints.is_empty() && config.allowed_endpoints.len() <= 4,
        "relay endpoint limit"
    );
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        ensure!(
            std::fs::metadata(&config.key_file)?.permissions().mode() & 0o077 == 0,
            "private TLS key permissions"
        );
    }
    let cert = rustls::pki_types::CertificateDer::from(std::fs::read(&config.cert_file)?);
    let key = rustls::pki_types::PrivatePkcs8KeyDer::from(std::fs::read(&config.key_file)?);
    let tls = rustls::ServerConfig::builder_with_provider(Arc::new(
        rustls::crypto::ring::default_provider(),
    ))
    .with_protocol_versions(&[&rustls::version::TLS13])?
    .with_no_client_auth()
    .with_single_cert(vec![cert], key.into())?;
    let mut relay = RelayConfig::new("127.0.0.1:0".parse::<SocketAddr>()?);
    relay.tls = Some(TlsConfig::new(
        "127.0.0.1:0".parse::<SocketAddr>()?,
        CertConfig::Manual { server_config: tls },
    ));
    relay.access = Arc::new(RelayAccess(config.allowed_endpoints));
    let mut cfg = ServerConfig::default();
    cfg.relay = Some(relay);
    let server = Server::spawn(cfg).await?;
    output(
        json!({"event":"relay_ready","url":format!("https://{}/",server.https_addr().context("TLS relay address")?),"tls":true}),
    )?;
    #[derive(Deserialize)]
    #[serde(deny_unknown_fields)]
    struct Stop {
        op: String,
    }
    let stop: Stop = serde_json::from_slice(&line(input).await?)?;
    ensure!(stop.op == "stop", "local relay stop required");
    server.shutdown().await?;
    Ok(())
}
async fn client(config: ClientConfig) -> Result<()> {
    config.request.validate()?;
    if let Some(relay) = config.relay.as_ref() {
        validate_relay(relay)?;
        ensure!(
            config.target.addrs.len() == 1 && config.target.relay_urls().next() == Some(&relay.url),
            "target must use exactly the configured relay"
        );
    } else {
        ensure!(
            !config.target.addrs.is_empty()
                && config.target.addrs.len() <= 4
                && config.target.addrs.iter().all(|a| a.is_ip())
                && config.target.ip_addrs().all(|a| a.ip().is_loopback()),
            "only explicit loopback IP targets"
        );
    }
    let endpoint = endpoint(&config.key_file, config.bind, config.relay.as_ref()).await?;
    let result=tokio::time::timeout(Duration::from_secs(10),async {
        let expected=config.target.id;
        let connection=endpoint.connect(config.target,ALPN).await?;
        ensure!(connection.remote_id()==expected,"remote endpoint mismatch");
        let (mut send,mut recv)=connection.open_bi().await?;
        write_frame(&mut send,&serde_json::to_vec(&config.request)?,MAX_REQUEST).await?; send.finish()?;
        let bytes=read_frame(&mut recv,MAX_RESPONSE).await?;
        let reply=response_bytes(serde_json::from_slice(&bytes)?,config.request.challenge())?;
        let evidence=path_evidence(&connection,config.relay.as_ref(),endpoint.bound_sockets().len()).await?;
        output(json!({"event":"reply","peer":connection.remote_id().to_string(),"challenge":config.request.challenge(),"reply":STANDARD.encode(reply),"path":evidence}))?;
        connection.close(0u32.into(),b"complete");
        Ok::<_,anyhow::Error>(())
    }).await;
    endpoint.close().await;
    result??;
    Ok(())
}
async fn server<R: AsyncBufRead + Unpin>(config: ServerConfig, input: &mut R) -> Result<()> {
    ensure!(
        token(&config.sender) && token(&config.recipient),
        "configured fixture actor identifiers"
    );
    let endpoint = endpoint(&config.key_file, config.bind, config.relay.as_ref()).await?;
    let address = if let Some(relay) = config.relay.as_ref() {
        EndpointAddr::new(endpoint.id()).with_relay_url(relay.url.clone())
    } else {
        let bind = endpoint
            .bound_sockets()
            .into_iter()
            .find(|a| a.is_ipv4() == config.bind.is_ipv4())
            .context("bound socket")?;
        EndpointAddr::new(endpoint.id()).with_ip_addr(bind)
    };
    output(
        json!({"event":"ready","address":address,"endpoint":endpoint.id().to_string(),"application_http":false,
        "relay":config.relay.is_some(),"ip_bound_sockets":endpoint.bound_sockets().len()}),
    )?;
    let mut request_id = 0_u64;
    while let Some(incoming) = endpoint.accept().await {
        let Ok(Ok(connection)) = tokio::time::timeout(DEADLINE, incoming).await else {
            continue;
        };
        if connection.remote_id() != config.allowed_endpoint {
            connection.close(1u32.into(), b"unconfigured endpoint");
            continue;
        }
        let mut host_pending = false;
        let result=tokio::time::timeout(Duration::from_secs(10),async {
            let (mut send,mut recv)=connection.accept_bi().await?;
            let raw=read_frame(&mut recv,MAX_REQUEST).await?;
            let request: Request=serde_json::from_slice(&raw)?; request.validate()?;
            if let Request::Status { sender, recipient, .. }=&request {
                ensure!(sender==&config.sender && recipient==&config.recipient,"status outside local TEST binding");
            }
            request_id=request_id.checked_add(1).context("request counter exhausted")?;
            host_pending = true;
            let evidence=path_evidence(&connection,config.relay.as_ref(),endpoint.bound_sockets().len()).await?;
            output(json!({"event":"request","request_id":request_id,"peer":connection.remote_id().to_string(),"request":request,"path":evidence}))?;
            let command: HostReply=serde_json::from_slice(&tokio::time::timeout(DEADLINE,line(input)).await??)?;
            match command {
                HostReply::Drop { request_id: id } => { ensure!(id==request_id,"host response ID"); host_pending=false; connection.close(3u32.into(),b"test lost reply"); }
                HostReply::Respond { request_id: id, challenge, reply } => {
                    ensure!(id==request_id && challenge==request.challenge(),"host response binding");
                    host_pending = false;
                    canonical(&reply,8_192)?;
                    write_frame(&mut send,&serde_json::to_vec(&Response{challenge,reply})?,MAX_RESPONSE).await?; send.finish()?;
                    // Do not drop the connection before the client consumes the reply.
                    tokio::time::timeout(DEADLINE,connection.closed()).await?;
                }
            }
            Ok::<_,anyhow::Error>(())
        }).await;
        if !matches!(result, Ok(Ok(()))) {
            connection.close(2u32.into(), b"experimental request refused");
            // A late host reply must never become the next request's result.
            if host_pending {
                // Tokio stdin can have an uncancellable blocking read. Exit
                // this owned fixture rather than wait for it during shutdown.
                eprintln!("host IPC lost synchronization; restart required");
                std::process::exit(1);
            }
        }
    }
    endpoint.close().await;
    Ok(())
}
#[tokio::main(flavor = "multi_thread", worker_threads = 2)]
async fn main() -> Result<()> {
    let args: Vec<_> = std::env::args().skip(1).collect();
    ensure!(args.len() == 1, "use identity, client or server");
    let mut input = BufReader::new(tokio::io::stdin());
    let bytes = tokio::time::timeout(DEADLINE, line(&mut input)).await??;
    match args[0].as_str() {
        "identity" => {
            let c: IdentityConfig = serde_json::from_slice(&bytes)?;
            output(json!({"endpoint":key(&c.key_file)?.public().to_string()}))?;
        }
        "client" => client(serde_json::from_slice(&bytes)?).await?,
        "server" => server(serde_json::from_slice(&bytes)?, &mut input).await?,
        "relay-server" => relay_server(serde_json::from_slice(&bytes)?, &mut input).await?,
        _ => anyhow::bail!("unknown experimental mode"),
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn relay_profile_requires_explicit_https_ip_and_no_url_credentials() {
        for url in [
            "http://127.0.0.1:4443/",
            "https://localhost:4443/",
            "https://127.0.0.1:4443/other",
            "https://user:pass@127.0.0.1:4443/",
            "https://127.0.0.1:0/",
        ] {
            let r = RelaySettings {
                url: url.parse().unwrap(),
                ca_file: PathBuf::from("unused"),
            };
            assert!(validate_relay(&r).is_err());
        }
        for url in ["https://127.0.0.1:4443/", "https://[::1]:4443/"] {
            let r = RelaySettings {
                url: url.parse().unwrap(),
                ca_file: PathBuf::from("unused"),
            };
            assert!(validate_relay(&r).is_ok());
        }
    }
    #[tokio::test]
    async fn framing_refuses_oversize_truncation_and_trailing_bytes() {
        for raw in [
            vec![0, 0, 0, 0],
            vec![255, 255, 255, 255],
            vec![0, 0, 0, 2, b'x'],
            vec![0, 0, 0, 1, b'x', b'y'],
        ] {
            assert!(read_frame(&mut raw.as_slice(), 8).await.is_err());
        }
        assert_eq!(
            read_frame(&mut [0, 0, 0, 1, b'x'].as_slice(), 8)
                .await
                .unwrap(),
            b"x"
        );
    }
    #[test]
    fn stale_response_challenge_is_refused() {
        let r = Response {
            challenge: "00".repeat(32),
            reply: STANDARD.encode(b"{}"),
        };
        assert!(response_bytes(r, &"01".repeat(32)).is_err());
    }
    #[test]
    fn duplicate_unknown_and_unreviewed_fields_are_refused() {
        for raw in [
            r#"{"op":"status","challenge":"x","challenge":"y"}"#,
            r#"{"op":"delete"}"#,
            r#"{"op":"deliver","challenge":"x","wire":"eA==","authority":true}"#,
        ] {
            assert!(serde_json::from_str::<Request>(raw).is_err());
        }
        assert!(
            serde_json::from_str::<Response>(r#"{"challenge":"x","challenge":"y","reply":"eA=="}"#)
                .is_err()
        );
    }
    #[test]
    fn wire_limits_and_noncanonical_encoding_are_refused() {
        assert!(canonical("eB==", 12_288).is_err());
        assert!(canonical(&STANDARD.encode(vec![0; 12_289]), 12_288).is_err());
        assert!(
            Request::Deliver {
                challenge: "00".repeat(32),
                wire: STANDARD.encode(b"{}")
            }
            .validate()
            .is_ok()
        );
    }
    #[tokio::test]
    async fn ipc_line_has_a_fixed_bound() {
        let bytes = vec![b'x'; MAX_LINE + 1];
        let mut input = BufReader::new(bytes.as_slice());
        assert!(line(&mut input).await.is_err());
    }
}
