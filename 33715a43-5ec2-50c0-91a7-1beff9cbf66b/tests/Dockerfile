# syntax=docker/dockerfile:1.19@sha256:b6afd42430b15f2d2a4c5a02b919e98a525b785b1aaff16747d2f623364e39b6
FROM --platform=$BUILDPLATFORM rust:1.98.1@sha256:a8a5f0a1e5fe7dfe1d352591e4a1c7dd2c08fd70475cae872cf3458ba0df0546 AS source
ARG BIOME_COMMIT=97cfc6e40a31c8f46fa32930224230b904618263
ARG BIOME_ARCHIVE_SHA256=20fbc0c7b814428ceeac8389adbfeb3e1aab3ceafa80930c2c3d16905c955dcd
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
COPY grading/upstream-test.diff /tmp/upstream-test.diff
RUN curl -fsSL -o /tmp/biome.tar.gz "https://codeload.github.com/biomejs/biome/tar.gz/${BIOME_COMMIT}" \
 && echo "${BIOME_ARCHIVE_SHA256}  /tmp/biome.tar.gz" | sha256sum -c - \
 && mkdir -p /src \
 && tar -xzf /tmp/biome.tar.gz -C /src --strip-components=1 \
 && cd /src \
 && patch -p1 --fuzz=0 </tmp/upstream-test.diff \
 && rm -f /tmp/biome.tar.gz /tmp/upstream-test.diff
RUN rustup target add wasm32-unknown-unknown \
 && mkdir -p /cargo-home \
 && cd /src \
 && CARGO_HOME=/cargo-home cargo fetch --locked

FROM rust:1.98.1@sha256:a8a5f0a1e5fe7dfe1d352591e4a1c7dd2c08fd70475cae872cf3458ba0df0546 AS runtime
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN rm -f /etc/apt/sources.list.d/* \
 && echo "deb [check-valid-until=no] http://snapshot.debian.org/archive/debian/20261020T000000Z trixie main" > /etc/apt/sources.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends python3-venv=3.13.5-1 python3.13-venv=3.13.5-2+deb13u5 \
 && rm -rf /var/lib/apt/lists/*
RUN rustup component add rustfmt clippy \
 && rustup target add wasm32-unknown-unknown
COPY rewardkit.lock /tmp/rewardkit.lock
RUN python3 -m venv /opt/rewardkit \
 && /opt/rewardkit/bin/pip install --no-cache-dir --require-hashes -r /tmp/rewardkit.lock \
 && rm -f /tmp/rewardkit.lock
RUN groupadd --gid 20002 verifier \
 && useradd --uid 20002 --gid 20002 --create-home --home-dir /home/verifier --shell /bin/bash verifier \
 && groupadd --gid 20003 tester \
 && useradd --uid 20003 --gid 20003 --no-create-home --home-dir /home/tester --shell /bin/bash tester
COPY --from=source --chown=20003:20003 /cargo-home/registry /usr/local/cargo/registry
COPY --from=source --chown=20003:20003 /cargo-home/git /usr/local/cargo/git
RUN chown 20003:20003 /usr/local/cargo
COPY --from=source /src /opt/base-src
COPY grading/ /grading/
RUN chmod 0700 /grading/private
COPY test.sh test_output.py judge.toml reward.toml /tests/
WORKDIR /tests
LABEL org.opencontainers.image.source="https://github.com/biomejs/biome" \
      org.opencontainers.image.revision="97cfc6e40a31c8f46fa32930224230b904618263" \
      org.opencontainers.image.licenses="MIT OR Apache-2.0" \
      org.opencontainers.image.base.name="docker.io/library/rust:1.98.1" \
      org.opencontainers.image.base.digest="sha256:a8a5f0a1e5fe7dfe1d352591e4a1c7dd2c08fd70475cae872cf3458ba0df0546"
USER root
CMD ["/bin/bash", "/tests/test.sh"]
