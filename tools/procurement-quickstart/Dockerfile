# Disposable evidence runner, NOT the production application image.
# Package repositories remain mutable; image ID and installed versions are recorded.
FROM node:22.16.0-bookworm-slim AS node
FROM ubuntu:24.04
SHELL ["/bin/bash", "-euo", "pipefail", "-c"]
ENV DEBIAN_FRONTEND=noninteractive
RUN printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d && chmod +x /usr/sbin/policy-rc.d \
 && apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl git build-essential pkg-config libssl-dev libncurses6 \
    libtinfo6 libgmp10 unzip zstd python3 openssl postgresql-16 postgresql-client-16 \
 && rm -rf /var/lib/apt/lists/*
COPY --from=node /usr/local/bin/node /usr/local/bin/node
COPY --from=node /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/npm
RUN ln -s ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm
ENV PATH=/opt/otp/bin:/opt/elixir/bin:/opt/lean/bin:/opt/quint/node_modules/.bin:/opt/cargo/bin:/usr/lib/postgresql/16/bin:${PATH}
ENV RUSTUP_HOME=/opt/rustup CARGO_HOME=/opt/cargo
# Ubuntu 24.04 amd64 OTP build published by Hex's Bob builder.
RUN test "$(dpkg --print-architecture)" = amd64 \
 && mkdir -p /opt/otp /opt/elixir /opt/lean \
 && curl -fL --retry 3 https://builds.hex.pm/builds/otp/amd64/ubuntu-24.04/OTP-27.3.4.tar.gz -o /tmp/otp.tar.gz \
 && tar -xzf /tmp/otp.tar.gz -C /opt/otp \
 && (cd /opt/otp && ./Install -minimal /opt/otp) \
 && curl -fL --retry 3 https://builds.hex.pm/builds/elixir/v1.19.0-otp-27.zip -o /tmp/elixir.zip \
 && unzip -q /tmp/elixir.zip -d /opt/elixir \
 && curl -fL --retry 3 https://github.com/leanprover/lean4/releases/download/v4.19.0/lean-4.19.0-linux.tar.zst -o /tmp/lean.tar.zst \
 && tar --zstd -xf /tmp/lean.tar.zst --strip-components=1 -C /opt/lean \
 && curl -fL --retry 3 https://static.rust-lang.org/rustup/archive/1.28.2/x86_64-unknown-linux-gnu/rustup-init -o /tmp/rustup-init \
 && chmod +x /tmp/rustup-init \
 && /tmp/rustup-init -y --no-modify-path --profile minimal --default-toolchain 1.90.0 \
 && npm install --prefix /opt/quint --no-save @informalsystems/quint@0.33.1 \
 && sha256sum /tmp/otp.tar.gz /tmp/elixir.zip /tmp/lean.tar.zst /tmp/rustup-init > /opt/downloads.sha256 \
 && rm -f /tmp/otp.tar.gz /tmp/elixir.zip /tmp/lean.tar.zst /tmp/rustup-init \
 && chmod -R a+rX /opt/rustup /opt/cargo
RUN useradd --uid 10001 --create-home evidence \
 && mkdir /work /evidence && chown -R evidence:evidence /work /evidence /opt/cargo /opt/rustup /opt/quint
USER evidence
ENV HOME=/home/evidence PYTHONDONTWRITEBYTECODE=1 PROCUREMENT_ENABLED=false GIT_OPTIONAL_LOCKS=0
RUN git config --global safe.directory /source \
 && mix local.hex --force && mix local.rebar --force \
 && elixir --version && lean --version && quint --version && rustc --version
WORKDIR /source
ENTRYPOINT ["python3", "/source/tools/procurement-quickstart/runner.py"]
