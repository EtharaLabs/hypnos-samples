# syntax=docker/dockerfile:1.19@sha256:b6afd42430b15f2d2a4c5a02b919e98a525b785b1aaff16747d2f623364e39b6
FROM --platform=$BUILDPLATFORM rust:1.97.1@sha256:b1b3c9c0d921d7fa0a6d1f9ec7e4eab87f8c8ec97644c3d791450f131dec813f AS source
ARG SWC_COMMIT=75848acc40ea51b8409ac57b97f2d7fbbc2a3bdd
ARG SWC_ARCHIVE_SHA256=2e3689758bea9ecd757a0366ce92a8619870bbb50063c681a5b00fd411db0dcb
ARG SWC_TOOLCHAIN=nightly-2026-04-10
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
COPY grading/hidden-test.diff /tmp/hidden-test.diff
RUN curl -fsSL -o /tmp/swc.tar.gz "https://codeload.github.com/swc-project/swc/tar.gz/${SWC_COMMIT}" \
 && echo "${SWC_ARCHIVE_SHA256}  /tmp/swc.tar.gz" | sha256sum -c - \
 && mkdir -p /src \
 && tar -xzf /tmp/swc.tar.gz -C /src --strip-components=1 \
 && cd /src \
 && { git apply --whitespace=nowarn /tmp/hidden-test.diff || patch -p1 --fuzz=0 </tmp/hidden-test.diff; } \
 && rm -f /tmp/swc.tar.gz /tmp/hidden-test.diff
RUN rustup toolchain install "${SWC_TOOLCHAIN}" --profile minimal \
 && mkdir -p /cargo-home \
 && cd /src \
 && CARGO_HOME=/cargo-home cargo fetch --locked

# mocha and expect for the repository's cargo exec tests, from a lock file with integrity hashes.
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

FROM rust:1.97.1@sha256:b1b3c9c0d921d7fa0a6d1f9ec7e4eab87f8c8ec97644c3d791450f131dec813f AS runtime
ARG SWC_TOOLCHAIN=nightly-2026-04-10
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN rm -f /etc/apt/sources.list.d/* \
 && echo "deb [check-valid-until=no] http://snapshot.debian.org/archive/debian/20261020T000000Z trixie main" > /etc/apt/sources.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends python3-venv=3.13.5-1 python3.13-venv=3.13.5-2+deb13u5 nodejs=20.19.2+dfsg-1+deb13u2 \
 && rm -rf /var/lib/apt/lists/*
COPY --from=exectools /opt/swc-exec-tools /opt/swc-exec-tools
RUN rustup toolchain install "${SWC_TOOLCHAIN}" --profile minimal \
 && rustup default "${SWC_TOOLCHAIN}" \
 && rm -rf /usr/local/rustup/downloads /usr/local/rustup/tmp
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
LABEL org.opencontainers.image.source="https://github.com/swc-project/swc" \
      org.opencontainers.image.revision="75848acc40ea51b8409ac57b97f2d7fbbc2a3bdd" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.base.name="docker.io/library/rust:1.97.1" \
      org.opencontainers.image.base.digest="sha256:b1b3c9c0d921d7fa0a6d1f9ec7e4eab87f8c8ec97644c3d791450f131dec813f"
USER root
CMD ["/bin/bash", "/tests/test.sh"]
