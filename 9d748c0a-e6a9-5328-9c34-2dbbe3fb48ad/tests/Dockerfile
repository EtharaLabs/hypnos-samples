# syntax=docker/dockerfile:1.19@sha256:b6afd42430b15f2d2a4c5a02b919e98a525b785b1aaff16747d2f623364e39b6
FROM --platform=$BUILDPLATFORM debian:trixie-20261020-slim@sha256:62bd423aeee912639ca8ee681c2b762cb3e25137e0a92b20be455898a9f034ad AS source
ARG K8S_CLIENT_COMMIT=889d3b1581635424c811a345dc9a664e75520a1a
ARG K8S_CLIENT_ARCHIVE_SHA256=ecb2a38d06efdd4a9a4f15f366e66b4012692997dd1003aebd6c19ec61ff660f
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN rm -f /etc/apt/sources.list.d/* \
 && echo "deb [check-valid-until=no] http://snapshot.debian.org/archive/debian/20261020T000000Z trixie main" > /etc/apt/sources.list \
 && apt-get -o Acquire::Retries=8 -o Acquire::http::Timeout=60 update \
 && apt-get -o Acquire::Retries=8 install -y --no-install-recommends ca-certificates=20250419 curl=8.14.1-2+deb13u5 patch=2.8-2 \
      openjdk-21-jdk-headless=21.0.12.1+1-1~deb13u1 maven=3.9.9-1 \
 && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL -o /tmp/src.tar.gz "https://codeload.github.com/fabric8io/kubernetes-client/tar.gz/${K8S_CLIENT_COMMIT}" \
 && echo "${K8S_CLIENT_ARCHIVE_SHA256}  /tmp/src.tar.gz" | sha256sum -c - \
 && mkdir -p /src \
 && tar -xzf /tmp/src.tar.gz -C /src --strip-components=1 \
 && rm -f /tmp/src.tar.gz
# Offline Maven repository for grading, without the base commit's own modules (one test jar kept).
WORKDIR /src
RUN MODS=kubernetes-model-generator/kubernetes-model-common,generator-annotations,kubernetes-client-api,crd-generator/api-v2,crd-generator/test \
 && mvn -B -q -T 8 -Dmaven.repo.local=/m2 -pl "$MODS" -am install -DskipTests \
 && mvn -B -q -Dmaven.repo.local=/m2 -pl "$MODS" test -Dmaven.test.failure.ignore=true \
      '-Dtest=!GeneratedCRDsOnApiServerTest' -Dsurefire.failIfNoSpecifiedTests=false >/dev/null 2>&1 \
 && find /m2 \( -name '*.lastUpdated' -o -name 'resolver-status.properties' \) -delete \
 && find /m2/io/fabric8 -path '*/999-SNAPSHOT/*' -type f \
      ! -path '/m2/io/fabric8/kubernetes-client-api/999-SNAPSHOT/kubernetes-client-api-999-SNAPSHOT-tests.jar' \
      ! -path '/m2/io/fabric8/kubernetes-client-api/999-SNAPSHOT/maven-metadata-local.xml' \
      ! -path '/m2/io/fabric8/kubernetes-client-api/999-SNAPSHOT/_remote.repositories' -delete \
 && find /m2/io/fabric8 -mindepth 1 -type d -empty -delete \
 && find /src -name target -type d -prune -exec rm -rf {} +
# The hidden tests: the upstream change's tests and test resources, and the authored guard.
COPY grading/upstream-test.diff /tmp/upstream-test.diff
COPY grading/authored/ /tmp/authored/
RUN patch -p1 --fuzz=0 -s </tmp/upstream-test.diff \
 && cp -r /tmp/authored/. /src/ \
 && rm -rf /tmp/upstream-test.diff /tmp/authored

FROM debian:trixie-20261020-slim@sha256:62bd423aeee912639ca8ee681c2b762cb3e25137e0a92b20be455898a9f034ad AS runtime
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN rm -f /etc/apt/sources.list.d/* \
 && echo "deb [check-valid-until=no] http://snapshot.debian.org/archive/debian/20261020T000000Z trixie main" > /etc/apt/sources.list \
 && apt-get -o Acquire::Retries=8 -o Acquire::http::Timeout=60 update \
 && apt-get -o Acquire::Retries=8 install -y --no-install-recommends \
      openjdk-21-jdk-headless=21.0.12.1+1-1~deb13u1 maven=3.9.9-1 diffutils=1:3.10-4 \
      procps=2:4.0.4-9 python3=3.13.5-1 python3-venv=3.13.5-1 python3.13-venv=3.13.5-2+deb13u5 \
 && rm -rf /var/lib/apt/lists/*
COPY rewardkit.lock /tmp/rewardkit.lock
RUN python3 -m venv /opt/rewardkit \
 && /opt/rewardkit/bin/pip install --no-cache-dir --require-hashes -r /tmp/rewardkit.lock \
 && rm -f /tmp/rewardkit.lock
RUN groupadd --gid 20002 verifier \
 && useradd --uid 20002 --gid 20002 --create-home --home-dir /home/verifier --shell /bin/bash verifier \
 && groupadd --gid 20003 tester \
 && useradd --uid 20003 --gid 20003 --no-create-home --home-dir /tmp/tester-home --shell /bin/bash tester
COPY --from=source /src /opt/base-src
COPY --from=source /m2 /opt/m2
COPY grading/ /grading/
RUN chmod 0700 /grading/private
COPY test.sh test_output.py judge.toml reward.toml /tests/
WORKDIR /tests
LABEL org.opencontainers.image.source="https://github.com/fabric8io/kubernetes-client" \
      org.opencontainers.image.revision="889d3b1581635424c811a345dc9a664e75520a1a" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.base.name="docker.io/library/debian:trixie-20261020-slim" \
      org.opencontainers.image.base.digest="sha256:62bd423aeee912639ca8ee681c2b762cb3e25137e0a92b20be455898a9f034ad"
USER root
CMD ["/bin/bash", "/tests/test.sh"]
