# syntax=docker/dockerfile:1.19@sha256:b6afd42430b15f2d2a4c5a02b919e98a525b785b1aaff16747d2f623364e39b6
FROM --platform=$BUILDPLATFORM rust:1.97.1@sha256:b1b3c9c0d921d7fa0a6d1f9ec7e4eab87f8c8ec97644c3d791450f131dec813f AS source
ARG NU_COMMIT=bdf52cd72abef109c2c35268d3ca79e12d89eafe
ARG NU_ARCHIVE_SHA256=8ae8325e702df65bbdbf5d7e548aa41177fd20d70743662bf8ab80e3ae029c7e
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
COPY grading/upstream-test.diff /tmp/upstream-test.diff
RUN curl -fsSL -o /tmp/nu.tar.gz "https://codeload.github.com/nushell/nushell/tar.gz/${NU_COMMIT}" \
 && echo "${NU_ARCHIVE_SHA256}  /tmp/nu.tar.gz" | sha256sum -c - \
 && mkdir -p /src \
 && tar -xzf /tmp/nu.tar.gz -C /src --strip-components=1 \
 && cd /src \
 && { git apply --whitespace=nowarn /tmp/upstream-test.diff || patch -p1 --fuzz=0 </tmp/upstream-test.diff; } \
 && rm -f /tmp/nu.tar.gz /tmp/upstream-test.diff
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
RUN groupadd --gid 10002 verifier \
 && useradd --uid 10002 --gid 10002 --create-home --home-dir /home/verifier --shell /bin/bash verifier \
 && groupadd --gid 10003 tester \
 && useradd --uid 10003 --gid 10003 --no-create-home --home-dir /tmp/tester-home --shell /bin/bash tester
COPY --from=source --chown=10003:10003 /cargo-home/registry /usr/local/cargo/registry
COPY --from=source --chown=10003:10003 /cargo-home/git /usr/local/cargo/git
RUN chown 10003:10003 /usr/local/cargo
COPY --from=source /src /opt/base-src
COPY grading/ /grading/
RUN chmod 0700 /grading/private
COPY test.sh test_output.py judge.toml reward.toml /tests/
WORKDIR /tests
LABEL org.opencontainers.image.source="https://github.com/nushell/nushell" \
      org.opencontainers.image.revision="bdf52cd72abef109c2c35268d3ca79e12d89eafe" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.base.name="docker.io/library/rust:1.97.1" \
      org.opencontainers.image.base.digest="sha256:b1b3c9c0d921d7fa0a6d1f9ec7e4eab87f8c8ec97644c3d791450f131dec813f"
USER 0:0
CMD ["/bin/bash", "/tests/test.sh"]
