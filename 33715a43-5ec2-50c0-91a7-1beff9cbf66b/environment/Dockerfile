# syntax=docker/dockerfile:1.19@sha256:b6afd42430b15f2d2a4c5a02b919e98a525b785b1aaff16747d2f623364e39b6
FROM --platform=$BUILDPLATFORM rust:1.98.1@sha256:a8a5f0a1e5fe7dfe1d352591e4a1c7dd2c08fd70475cae872cf3458ba0df0546 AS source
ARG BIOME_COMMIT=97cfc6e40a31c8f46fa32930224230b904618263
ARG BIOME_ARCHIVE_SHA256=20fbc0c7b814428ceeac8389adbfeb3e1aab3ceafa80930c2c3d16905c955dcd
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN curl -fsSL -o /tmp/biome.tar.gz "https://codeload.github.com/biomejs/biome/tar.gz/${BIOME_COMMIT}" \
 && echo "${BIOME_ARCHIVE_SHA256}  /tmp/biome.tar.gz" | sha256sum -c - \
 && mkdir -p /src \
 && tar -xzf /tmp/biome.tar.gz -C /src --strip-components=1 \
 && rm -f /tmp/biome.tar.gz
# Fetch every crate Cargo.lock names, with pinned git dependencies; checksums are verified.
RUN rustup target add wasm32-unknown-unknown \
 && mkdir -p /cargo-home \
 && cd /src \
 && CARGO_HOME=/cargo-home cargo fetch --locked

# Preinstall the Codex CLI from checksum-verified release binaries; the environment has no network.
FROM source AS agent-cli
ARG TARGETARCH
ARG CODEX_VERSION=0.169.0
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN arch="${TARGETARCH:-$(uname -m)}" \
 && case "${arch}" in \
      amd64|x86_64) npm_arch=x64; triple=x86_64-unknown-linux-musl; \
        codex_sha512=a34e4dc803820f28123d1a35ca29f3c6f91149d9ac672043f44ee66e99a345a9d27ccf25ca9a96b50804a385df364c21b82476685bbc9a518eb101855d56d5c3 ;; \
      arm64|aarch64) npm_arch=arm64; triple=aarch64-unknown-linux-musl; \
        codex_sha512=359fc36905297109b19aa79eed9f6e0b5af3c371a149ba286b071a4ded4b379624f969629d42867535c98029514fff6881010433d4d6c58cefc4f7e3e46ff116 ;; \
      *) echo "unsupported architecture ${arch}" >&2; exit 1 ;; \
    esac \
 && curl -fsSL -o /tmp/codex.tgz "https://registry.npmjs.org/@openai/codex/-/codex-${CODEX_VERSION}-linux-${npm_arch}.tgz" \
 && echo "${codex_sha512}  /tmp/codex.tgz" | sha512sum -c - \
 && mkdir -p /tmp/codex /opt \
 && tar -xzf /tmp/codex.tgz -C /tmp/codex \
 && mv "/tmp/codex/package/vendor/${triple}" /opt/codex \
 && rm -f /opt/codex/bin/codex-code-mode-host \
 && rm -rf /opt/codex/codex-resources/voice /tmp/codex /tmp/codex.tgz \
 && chmod 0755 /opt/codex/bin/codex /opt/codex/codex-path/rg

FROM rust:1.98.1@sha256:a8a5f0a1e5fe7dfe1d352591e4a1c7dd2c08fd70475cae872cf3458ba0df0546 AS runtime
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN rm -f /etc/apt/sources.list.d/* \
 && echo "deb [check-valid-until=no] http://snapshot.debian.org/archive/debian/20261020T000000Z trixie main" > /etc/apt/sources.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends tmux=3.5a-3 \
 && rm -rf /var/lib/apt/lists/*
# Install the pinned toolchain and the wasm32 target, so rustup never needs the network.
RUN rustup component add rustfmt clippy \
 && rustup target add wasm32-unknown-unknown
RUN groupadd --gid 20001 dev \
 && useradd --uid 20001 --gid 20001 --create-home --home-dir /home/dev --shell /bin/bash dev
COPY --from=source --chown=20001:20001 /cargo-home/registry /usr/local/cargo/registry
COPY --from=source --chown=20001:20001 /cargo-home/git /usr/local/cargo/git
RUN chown 20001:20001 /usr/local/cargo
COPY --from=source --chown=20001:20001 /src /app
ENV CARGO_NET_OFFLINE=true
WORKDIR /app
LABEL org.opencontainers.image.source="https://github.com/biomejs/biome" \
      org.opencontainers.image.revision="97cfc6e40a31c8f46fa32930224230b904618263" \
      org.opencontainers.image.licenses="MIT OR Apache-2.0" \
      org.opencontainers.image.base.name="docker.io/library/rust:1.98.1" \
      org.opencontainers.image.base.digest="sha256:a8a5f0a1e5fe7dfe1d352591e4a1c7dd2c08fd70475cae872cf3458ba0df0546"
# Restore the image PATH in login shells (Debian's /etc/profile resets it).
USER root
RUN printf 'export PATH="%s"\n' "$PATH" > /etc/profile.d/00-image-path.sh \
 && chmod 0644 /etc/profile.d/00-image-path.sh
# Codex CLI on every user's PATH; a managed config turns web search and Code Mode off.
USER root
COPY --from=agent-cli /opt/codex /opt/codex
COPY codex-model-catalog.json /etc/codex/model_catalog.json
RUN ln -sf /opt/codex/bin/codex /usr/local/bin/codex \
 && ln -sf /opt/codex/codex-path/rg /usr/local/bin/rg \
 && mkdir -p /etc/codex \
 && printf 'web_search = "disabled"\nmodel_catalog_json = "/etc/codex/model_catalog.json"\n\n[features]\ncode_mode = false\ncode_mode_only = false\n' >/etc/codex/managed_config.toml \
 && chmod 0644 /etc/codex/managed_config.toml \
 && grep -qx 'web_search = "disabled"' /etc/codex/managed_config.toml \
 && grep -qx 'code_mode = false' /etc/codex/managed_config.toml \
 && grep -qx 'code_mode_only = false' /etc/codex/managed_config.toml \
 && chmod 0644 /etc/codex/model_catalog.json \
 && grep -q '"tool_mode": null' /etc/codex/model_catalog.json \
 && ! grep -q '"tool_mode": "code_mode' /etc/codex/model_catalog.json \
 && test ! -e /opt/codex/bin/codex-code-mode-host
# Harbor runs agent setup as root and the agent as [agent].user (20001).
USER root
CMD ["/bin/bash"]
