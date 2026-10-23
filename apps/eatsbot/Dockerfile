# Find eligible builder and runner images on Docker Hub. We use Ubuntu/Debian
# instead of Alpine to avoid DNS resolution issues in production.
#
# https://hub.docker.com/r/hexpm/elixir/tags?page=1&name=ubuntu
# https://hub.docker.com/_/ubuntu?tab=tags
#
# This file is based on these images:
#
#   - https://hub.docker.com/r/hexpm/elixir/tags - for the build image
#   - https://hub.docker.com/_/debian?tab=tags&page=1&name=bookworm-20260610-slim - for the release image
#   - https://pkgs.org/ - resource for finding needed packages
#   - Ex: hexpm/elixir:1.19.0-erlang-27.3.4-debian-bookworm-20260610-slim
#
ARG ELIXIR_VERSION=1.19.0
ARG OTP_VERSION=27.3.4
ARG DEBIAN_VERSION=bookworm-20260610-slim

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

FROM ${BUILDER_IMAGE} as builder

# install build dependencies
RUN apt-get update -y && apt-get install -y build-essential git \
    && apt-get clean && rm -f /var/lib/apt/lists/*_*

# prepare build dir
WORKDIR /app

# install hex + rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# set build ENV
ENV MIX_ENV="prod"

# install mix dependencies
# Built from the biz-kit root (`docker build -f apps/eatsbot/Dockerfile .`):
# eatsbot is an umbrella app, so only it, its sibling apps, the shared lock and
# config, and its vendored dependency are copied. Mix commands run in
# apps/eatsbot so they compile eatsbot alone, not the whole umbrella.
COPY mix.lock ./
COPY config config
COPY vendor/telegex vendor/telegex
COPY apps/eatsbot_core apps/eatsbot_core
COPY apps/eatsbot_extension_kafka apps/eatsbot_extension_kafka
COPY apps/eatsbot_extension_prometheus apps/eatsbot_extension_prometheus
COPY apps/eatsbot_extension_telegram_bot apps/eatsbot_extension_telegram_bot
COPY apps/eatsbot/mix.exs apps/eatsbot/
COPY apps/eatsbot/config apps/eatsbot/config
WORKDIR /app/apps/eatsbot
RUN mix deps.get --only $MIX_ENV --check-locked

COPY apps/eatsbot/priv priv
COPY apps/eatsbot/lib lib
COPY apps/eatsbot/assets assets

# compile assets
RUN mix deps.compile
RUN mix assets.deploy

RUN mix compile --warnings-as-errors
RUN mix localize.download_locales

COPY apps/eatsbot/rel rel
RUN mix release

# start a new build stage so that the final image will only contain
# the compiled release and other runtime necessities
FROM ${RUNNER_IMAGE}

RUN apt-get update -y && \
  apt-get install -y libstdc++6 openssl libncurses5 locales ca-certificates \
  && apt-get clean && rm -f /var/lib/apt/lists/*_*

# Set the locale
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG en_US.UTF-8
ENV LANGUAGE en_US:en
ENV LC_ALL en_US.UTF-8

WORKDIR "/app"
RUN chown nobody /app

# set runner ENV
ENV MIX_ENV="prod"

# Only copy the final release from the build stage
COPY --from=builder --chown=nobody:root /app/_build/${MIX_ENV}/rel/eatsbot ./

USER nobody

# If using an environment that doesn't automatically reap zombie processes, it is
# advised to add an init process such as tini via `apt-get install`
# above and adding an entrypoint. See https://github.com/krallin/tini for details
# ENTRYPOINT ["/tini", "--"]

CMD ["/app/bin/server"]
