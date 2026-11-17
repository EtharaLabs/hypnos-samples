# syntax=docker/dockerfile:1.19@sha256:b6afd42430b15f2d2a4c5a02b919e98a525b785b1aaff16747d2f623364e39b6
FROM --platform=$BUILDPLATFORM debian:trixie-20261020-slim@sha256:62bd423aeee912639ca8ee681c2b762cb3e25137e0a92b20be455898a9f034ad AS source
ARG K8S_CLIENT_COMMIT=889d3b1581635424c811a345dc9a664e75520a1a
ARG K8S_CLIENT_ARCHIVE_SHA256=ecb2a38d06efdd4a9a4f15f366e66b4012692997dd1003aebd6c19ec61ff660f
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN rm -f /etc/apt/sources.list.d/* \
 && echo "deb [check-valid-until=no] http://snapshot.debian.org/archive/debian/20261020T000000Z trixie main" > /etc/apt/sources.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates=20250419 curl=8.14.1-2+deb13u5 \
      openjdk-21-jdk-headless=21.0.12.1+1-1~deb13u1 maven=3.9.9-1 \
 && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL -o /tmp/src.tar.gz "https://codeload.github.com/fabric8io/kubernetes-client/tar.gz/${K8S_CLIENT_COMMIT}" \
 && echo "${K8S_CLIENT_ARCHIVE_SHA256}  /tmp/src.tar.gz" | sha256sum -c - \
 && mkdir -p /src \
 && tar -xzf /tmp/src.tar.gz -C /src --strip-components=1 \
 && rm -f /tmp/src.tar.gz
# Offline Maven repository for building and testing the graded modules (platform independent).
WORKDIR /src
RUN MODS=kubernetes-model-generator/kubernetes-model-common,generator-annotations,kubernetes-client-api,crd-generator/api-v2,crd-generator/test \
 && mvn -B -q -T 8 -Dmaven.repo.local=/m2 -pl "$MODS" -am install -DskipTests \
 && mvn -B -q -Dmaven.repo.local=/m2 -pl "$MODS" test -Dmaven.test.failure.ignore=true \
      '-Dtest=!GeneratedCRDsOnApiServerTest' -Dsurefire.failIfNoSpecifiedTests=false >/dev/null \
 && mvn -B -q -o -T 8 -Dmaven.repo.local=/m2 -pl "$MODS" -am install -Dmaven.test.skip=true \
 && find /m2 \( -name '*.lastUpdated' -o -name 'resolver-status.properties' \) -delete \
 && find /src -name target -type d -prune -exec rm -rf {} +

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

FROM debian:trixie-20261020-slim@sha256:62bd423aeee912639ca8ee681c2b762cb3e25137e0a92b20be455898a9f034ad AS runtime
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
# The JDK and Maven the build uses, git and patch for the agent, and tmux for the agent's terminal.
RUN rm -f /etc/apt/sources.list.d/* \
 && echo "deb [check-valid-until=no] http://snapshot.debian.org/archive/debian/20261020T000000Z trixie main" > /etc/apt/sources.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      openjdk-21-jdk-headless=21.0.12.1+1-1~deb13u1 maven=3.9.9-1 \
      git=1:2.47.3-0+deb13u1 patch=2.8-2 python3=3.13.5-1 tmux=3.5a-3 \
 && rm -rf /var/lib/apt/lists/*
RUN groupadd --gid 20001 dev \
 && useradd --uid 20001 --gid 20001 --create-home --home-dir /home/dev --shell /bin/bash dev \
 && install -d -o 20001 -g 20001 /home/dev/.m2 \
 && printf '<settings>\n  <offline>true</offline>\n</settings>\n' >/home/dev/.m2/settings.xml \
 && chown 20001:20001 /home/dev/.m2/settings.xml
COPY --from=source --chown=20001:20001 /src /app
COPY --from=source --chown=20001:20001 /m2 /home/dev/.m2/repository
WORKDIR /app
LABEL org.opencontainers.image.source="https://github.com/fabric8io/kubernetes-client" \
      org.opencontainers.image.revision="889d3b1581635424c811a345dc9a664e75520a1a" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.base.name="docker.io/library/debian:trixie-20261020-slim" \
      org.opencontainers.image.base.digest="sha256:62bd423aeee912639ca8ee681c2b762cb3e25137e0a92b20be455898a9f034ad"
# Agent tooling (operator, 2026-11-02). Packages the agent may need, from the pinned snapshot.
USER root
RUN rm -f /etc/apt/sources.list.d/* \
 && echo "deb [check-valid-until=no] http://snapshot.debian.org/archive/debian/20261020T000000Z trixie main" > /etc/apt/sources.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends file=1:5.46-5 unzip=6.0-29+deb13u1 \
 && rm -rf /var/lib/apt/lists/*
# Codex CLI on every user's PATH; a managed config turns web search and Code Mode off.
USER root
COPY --from=agent-cli /opt/codex /opt/codex
# The slim runtime base has no CA bundle; copy the one installed in the source stage.
COPY --from=agent-cli /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
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
