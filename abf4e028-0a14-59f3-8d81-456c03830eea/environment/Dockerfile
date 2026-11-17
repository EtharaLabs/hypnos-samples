# syntax=docker/dockerfile:1.19@sha256:b6afd42430b15f2d2a4c5a02b919e98a525b785b1aaff16747d2f623364e39b6
FROM --platform=$BUILDPLATFORM rust:1.97.1@sha256:b1b3c9c0d921d7fa0a6d1f9ec7e4eab87f8c8ec97644c3d791450f131dec813f AS source
ARG SWC_COMMIT=75848acc40ea51b8409ac57b97f2d7fbbc2a3bdd
ARG SWC_ARCHIVE_SHA256=2e3689758bea9ecd757a0366ce92a8619870bbb50063c681a5b00fd411db0dcb
ARG SWC_TOOLCHAIN=nightly-2026-04-10
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN curl -fsSL -o /tmp/swc.tar.gz "https://codeload.github.com/swc-project/swc/tar.gz/${SWC_COMMIT}" \
 && echo "${SWC_ARCHIVE_SHA256}  /tmp/swc.tar.gz" | sha256sum -c - \
 && mkdir -p /src \
 && tar -xzf /tmp/swc.tar.gz -C /src --strip-components=1 \
 && rm -f /tmp/swc.tar.gz
# Every crate the workspace's Cargo.lock names, for every platform, fetched against its checksums.
RUN rustup toolchain install "${SWC_TOOLCHAIN}" --profile minimal \
 && mkdir -p /cargo-home \
 && cd /src \
 && CARGO_HOME=/cargo-home cargo fetch --locked

# mocha and expect for the repository's exec tests, from a lock file with integrity hashes.
FROM --platform=$BUILDPLATFORM rust:1.97.1@sha256:b1b3c9c0d921d7fa0a6d1f9ec7e4eab87f8c8ec97644c3d791450f131dec813f AS exectools
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN rm -f /etc/apt/sources.list.d/* \
 && echo "deb [check-valid-until=no] http://snapshot.debian.org/archive/debian/20261020T000000Z trixie main" > /etc/apt/sources.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends nodejs=20.19.2+dfsg-1+deb13u2 npm=9.2.0~ds1-3 \
 && rm -rf /var/lib/apt/lists/*
COPY exec-tools/package.json exec-tools/package-lock.json /opt/swc-exec-tools/
RUN cd /opt/swc-exec-tools \
 && npm ci --ignore-scripts --no-audit --no-fund \
 && rm -rf /root/.npm

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

FROM rust:1.97.1@sha256:b1b3c9c0d921d7fa0a6d1f9ec7e4eab87f8c8ec97644c3d791450f131dec813f AS runtime
ARG SWC_TOOLCHAIN=nightly-2026-04-10
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN rm -f /etc/apt/sources.list.d/* \
 && echo "deb [check-valid-until=no] http://snapshot.debian.org/archive/debian/20261020T000000Z trixie main" > /etc/apt/sources.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends tmux=3.5a-3 nodejs=20.19.2+dfsg-1+deb13u2 \
 && rm -rf /var/lib/apt/lists/*
COPY --from=exectools /opt/swc-exec-tools /opt/swc-exec-tools
ENV NODE_PATH=/opt/swc-exec-tools/node_modules \
    PATH=/opt/swc-exec-tools/node_modules/.bin:$PATH
# Make the toolchain rust-toolchain pins the default, so cargo uses it everywhere.
RUN rustup toolchain install "${SWC_TOOLCHAIN}" --profile minimal --component rustfmt \
 && rustup default "${SWC_TOOLCHAIN}" \
 && rm -rf /usr/local/rustup/downloads /usr/local/rustup/tmp
RUN groupadd --gid 20001 dev \
 && useradd --uid 20001 --gid 20001 --create-home --home-dir /home/dev --shell /bin/bash dev
COPY --from=source --chown=20001:20001 /cargo-home/registry /usr/local/cargo/registry
RUN chown 20001:20001 /usr/local/cargo
COPY --from=source --chown=20001:20001 /src /app
ENV CARGO_NET_OFFLINE=true
WORKDIR /app
LABEL org.opencontainers.image.source="https://github.com/swc-project/swc" \
      org.opencontainers.image.revision="75848acc40ea51b8409ac57b97f2d7fbbc2a3bdd" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.base.name="docker.io/library/rust:1.97.1" \
      org.opencontainers.image.base.digest="sha256:b1b3c9c0d921d7fa0a6d1f9ec7e4eab87f8c8ec97644c3d791450f131dec813f"
# Restore the image PATH and NODE_PATH in login shells (Debian's /etc/profile resets them).
USER root
RUN printf 'export PATH="%s"\nexport NODE_PATH="%s"\n' "$PATH" "$NODE_PATH" > /etc/profile.d/00-image-path.sh \
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
