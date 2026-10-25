//! Opaque, bounded iroh-gossip sidecar. Marketplace authority stays in the host.
use anyhow::{Context, Result, ensure};
use base64::{Engine, engine::general_purpose::STANDARD};
use iroh::{
    Endpoint, EndpointAddr, EndpointId, RelayMode, SecretKey, address_lookup::memory::MemoryLookup,
    endpoint::presets,
};
use iroh_gossip::{
    Gossip, TopicId,
    api::{Event, JoinOptions},
};
use n0_future::StreamExt;
use serde::Deserialize;
use serde_json::json;
use std::{
    collections::HashSet, io::Write, net::SocketAddr, path::PathBuf, sync::Arc, time::Duration,
};
use tokio::io::{AsyncBufRead, AsyncBufReadExt, BufReader};

const MAX_WIRE: usize = 65_536;
const MAX_LINE: usize = 90_000;
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Config {
    key_file: PathBuf,
    topic: String,
    bind: SocketAddr,
    peers: Vec<EndpointAddr>,
    allowed_endpoints: Vec<EndpointId>,
}
#[derive(Deserialize)]
#[serde(tag = "op", deny_unknown_fields)]
enum Command {
    #[serde(rename = "broadcast")]
    Broadcast { id: String, body: String },
    #[serde(rename = "stop")]
    Stop,
}
fn output(value: serde_json::Value) -> Result<()> {
    let stdout = std::io::stdout();
    let mut out = stdout.lock();
    serde_json::to_writer(&mut out, &value)?;
    writeln!(out)?;
    out.flush()?;
    Ok(())
}
async fn line<R: AsyncBufRead + Unpin>(input: &mut R) -> Result<Option<Vec<u8>>> {
    let mut result = Vec::new();
    loop {
        let bytes = input.fill_buf().await?;
        if bytes.is_empty() {
            ensure!(result.is_empty(), "unterminated command");
            return Ok(None);
        }
        let newline = bytes.iter().position(|&b| b == b'\n');
        let used = newline.map_or(bytes.len(), |n| n + 1);
        ensure!(result.len() + used <= MAX_LINE, "command limit");
        result.extend_from_slice(&bytes[..used]);
        input.consume(used);
        if newline.is_some() {
            return Ok(Some(result));
        }
    }
}

#[tokio::main(flavor = "multi_thread", worker_threads = 2)]
async fn main() -> Result<()> {
    let mut input = BufReader::new(tokio::io::stdin());
    let config: Config =
        serde_json::from_slice(&line(&mut input).await?.context("config required")?)?;
    ensure!(
        config.peers.len() <= 32 && config.allowed_endpoints.len() <= 32,
        "peer limit"
    );
    let topic_bytes: [u8; 32] = hex::decode(&config.topic)?
        .try_into()
        .map_err(|_| anyhow::anyhow!("topic length"))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        ensure!(
            std::fs::metadata(&config.key_file)?.permissions().mode() & 0o077 == 0,
            "key permissions"
        );
    }
    let seed: [u8; 32] = std::fs::read(config.key_file)?
        .try_into()
        .map_err(|_| anyhow::anyhow!("key length"))?;
    let lookup = MemoryLookup::new();
    let allowed_endpoints: Arc<HashSet<_>> =
        Arc::new(config.allowed_endpoints.into_iter().collect());
    ensure!(
        config
            .peers
            .iter()
            .all(|p| allowed_endpoints.contains(&p.id)),
        "bootstrap outside allowed_endpointship"
    );
    let peer_ids: Vec<_> = config.peers.iter().map(|p| p.id).collect();
    for peer in config.peers {
        lookup.add_endpoint_info(peer);
    }
    // This isolated pilot uses explicit addresses: no public relay, DNS lookup,
    // port mapping or service account is silently enabled.
    let endpoint = Endpoint::builder(presets::Minimal)
        .secret_key(SecretKey::from_bytes(&seed))
        .relay_mode(RelayMode::Disabled)
        .address_lookup(lookup)
        .alpns(vec![iroh_gossip::ALPN.to_vec()])
        .bind_addr(config.bind)?
        .bind()
        .await?;
    let gossip = Gossip::builder()
        .max_message_size(MAX_WIRE)
        .spawn(endpoint.clone());
    let mut opts = JoinOptions::with_bootstrap(peer_ids);
    opts.subscription_capacity = 32;
    let (sender, mut receiver) = gossip
        .subscribe_with_opts(TopicId::from_bytes(topic_bytes), opts)
        .await?
        .split();
    output(
        json!({"event":"ready", "address":endpoint.addr(), "endpoint":endpoint.id().to_string()}),
    )?;

    let accept_endpoint = endpoint.clone();
    let accept_gossip = gossip.clone();
    let accepting = tokio::spawn(async move {
        let slots = Arc::new(tokio::sync::Semaphore::new(32));
        while let Some(incoming) = accept_endpoint.accept().await {
            let Ok(permit) = slots.clone().try_acquire_owned() else {
                incoming.refuse();
                continue;
            };
            let allowed = allowed_endpoints.clone();
            let protocol = accept_gossip.clone();
            tokio::spawn(async move {
                let _permit = permit;
                if let Ok(Ok(conn)) = tokio::time::timeout(Duration::from_secs(5), incoming).await {
                    if allowed.contains(&conn.remote_id()) {
                        let _ = protocol.handle_connection(conn).await;
                    } else {
                        conn.close(1u32.into(), b"not a configured endpoint");
                    }
                }
            });
        }
    });

    loop {
        tokio::select! {
            command = line(&mut input) => {
                let Some(command) = command? else { break; };
                match serde_json::from_slice::<Command>(&command)? {
                    Command::Stop => break,
                    Command::Broadcast { id, body } => {
                        ensure!(id.len() <= 2048, "id limit");
                        let wire = STANDARD.decode(body)?;
                        ensure!(wire.len() <= MAX_WIRE, "message limit");
                        tokio::time::timeout(Duration::from_secs(5), sender.broadcast(wire.into())).await??;
                        output(json!({"event":"broadcast_queued", "id":id}))?;
                    }
                }
            }
            event = receiver.next() => {
                match event.context("gossip stream closed")?? {
                    Event::Received(message) => output(json!({"event":"message", "via":message.delivered_from.to_string(), "body":STANDARD.encode(message.content)}))?,
                    Event::NeighborUp(id) => output(json!({"event":"neighbor_up", "endpoint":id.to_string()}))?,
                    Event::NeighborDown(id) => output(json!({"event":"neighbor_down", "endpoint":id.to_string()}))?,
                    Event::Lagged => output(json!({"event":"lagged"}))?,
                }
            }
        }
    }
    accepting.abort();
    gossip.shutdown().await?;
    endpoint.close().await;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn bounded_lines_preserve_separate_commands() {
        let mut reader = BufReader::new(&b"first\nsecond\n"[..]);
        assert_eq!(line(&mut reader).await.unwrap().unwrap(), b"first\n");
        assert_eq!(line(&mut reader).await.unwrap().unwrap(), b"second\n");
        assert!(line(&mut reader).await.unwrap().is_none());
    }
    #[tokio::test]
    async fn oversized_command_is_refused_before_unbounded_allocation() {
        let data = vec![b'x'; MAX_LINE + 1];
        assert!(line(&mut BufReader::new(data.as_slice())).await.is_err());
    }
    #[tokio::test]
    async fn truncated_command_is_refused() {
        assert!(line(&mut BufReader::new(&b"truncated"[..])).await.is_err());
    }
    #[test]
    fn command_rejects_unknown_fields_and_operations() {
        assert!(
            serde_json::from_str::<Command>(
                r#"{"op":"broadcast","id":"x","body":"","command":"reserve"}"#
            )
            .is_err()
        );
        assert!(serde_json::from_str::<Command>(r#"{"op":"execute","body":""}"#).is_err());
    }
}
