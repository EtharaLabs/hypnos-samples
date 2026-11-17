# syntax=docker/dockerfile:1.19@sha256:b6afd42430b15f2d2a4c5a02b919e98a525b785b1aaff16747d2f623364e39b6
FROM --platform=$BUILDPLATFORM rust:1.97.1@sha256:b1b3c9c0d921d7fa0a6d1f9ec7e4eab87f8c8ec97644c3d791450f131dec813f AS source
ARG OXC_COMMIT=d76d89996f56df949c2b2ea8c4dc274aa8bd4356
ARG OXC_ARCHIVE_SHA256=f83ba98cb43df343fa6f9b7f74d44f34d1bafec618db731f8d6299dfc208eb76
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
COPY grading/upstream-test.diff /tmp/upstream-test.diff
RUN curl -fsSL -o /tmp/oxc.tar.gz "https://codeload.github.com/oxc-project/oxc/tar.gz/${OXC_COMMIT}" \
 && echo "${OXC_ARCHIVE_SHA256}  /tmp/oxc.tar.gz" | sha256sum -c - \
 && mkdir -p /src \
 && tar -xzf /tmp/oxc.tar.gz -C /src --strip-components=1 \
 && cd /src \
 && { git apply --whitespace=nowarn /tmp/upstream-test.diff || patch -p1 --fuzz=0 </tmp/upstream-test.diff; } \
 && rm -f /tmp/oxc.tar.gz /tmp/upstream-test.diff
RUN mkdir -p /cargo-home \
 && cd /src \
 && CARGO_HOME=/cargo-home cargo fetch --locked

FROM rust:1.97.1@sha256:b1b3c9c0d921d7fa0a6d1f9ec7e4eab87f8c8ec97644c3d791450f131dec813f AS runtime
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN rm -f /etc/apt/sources.list.d/* \
 && echo "deb [check-valid-until=no] http://snapshot.debian.org/archive/debian/20261020T000000Z trixie main" > /etc/apt/sources.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends python3-venv=3.13.5-1 python3.13-venv=3.13.5-2+deb13u5 \
 && rm -rf /var/lib/apt/lists/*
COPY rewardkit.lock /tmp/rewardkit.lock
RUN python3 -m venv /opt/rewardkit \
 && /opt/rewardkit/bin/pip install --no-cache-dir --require-hashes -r /tmp/rewardkit.lock \
 && rm -f /tmp/rewardkit.lock
RUN groupadd --gid 20002 verifier \
 && useradd --uid 20002 --gid 20002 --create-home --home-dir /home/verifier --shell /bin/bash verifier \
 && groupadd --gid 20003 tester \
 && useradd --uid 20003 --gid 20003 --no-create-home --home-dir /tmp/tester-home --shell /bin/bash tester
COPY --from=source --chown=20003:20003 /cargo-home/registry /usr/local/cargo/registry
RUN chown 20003:20003 /usr/local/cargo
COPY --from=source /src /opt/base-src
COPY grading/ /grading/
RUN chmod 0700 /grading/private
COPY test.sh test_output.py judge.toml reward.toml /tests/
WORKDIR /tests
LABEL org.opencontainers.image.source="https://github.com/oxc-project/oxc" \
      org.opencontainers.image.revision="d76d89996f56df949c2b2ea8c4dc274aa8bd4356" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.base.name="docker.io/library/rust:1.97.1" \
      org.opencontainers.image.base.digest="sha256:b1b3c9c0d921d7fa0a6d1f9ec7e4eab87f8c8ec97644c3d791450f131dec813f"
USER root
CMD ["/bin/bash", "/tests/test.sh"]
