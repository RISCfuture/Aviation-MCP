FROM swift:6.4-noble AS build
ARG SWIFT_BUILD_JOBS=1
ARG SENTRY_NATIVE_VERSION=0.17.6
# hadolint ignore=DL3008
RUN apt-get update \
    && apt-get install -y --no-install-recommends cmake make libcurl4-openssl-dev zlib1g-dev unzip \
    && rm -rf /var/lib/apt/lists/*
ADD --checksum=sha256:40b4b70cbada5bfae5b73f8267831dd023ec676d9676fb0d890878f31d2b5055 \
    https://github.com/getsentry/sentry-native/releases/download/${SENTRY_NATIVE_VERSION}/sentry-native.zip /tmp/
RUN unzip -q /tmp/sentry-native.zip -d /tmp/sentry-native \
    && cmake -S /tmp/sentry-native -B /tmp/sentry-native/build \
        -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ -DCMAKE_ASM_COMPILER=clang \
        -DSENTRY_BACKEND=inproc \
        -DSENTRY_BUILD_TESTS=OFF -DSENTRY_BUILD_EXAMPLES=OFF -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    && cmake --build /tmp/sentry-native/build --parallel "$SWIFT_BUILD_JOBS" \
    && cmake --install /tmp/sentry-native/build --prefix /usr/local \
    && strip --strip-debug /usr/local/lib/libsentry.so \
    && ldconfig \
    && rm -rf /tmp/sentry-native /tmp/sentry-native.zip
WORKDIR /workspace
COPY Package.swift Package.resolved ./
RUN --mount=type=cache,id=aviation-swift-6.4.1,target=/workspace/.build,sharing=locked \
    swift package resolve --force-resolved-versions
COPY Sources Sources
COPY Tests Tests
RUN --mount=type=cache,id=aviation-swift-6.4.1,target=/workspace/.build,sharing=locked \
    swift build --build-system native -c release --product aviation-mcp --traits Sentry \
        -Xswiftc -g -Xlinker --build-id=sha1 -Xlinker -L/usr/local/lib --jobs "$SWIFT_BUILD_JOBS" \
    && bin_dir="$(swift build --build-system native -c release --show-bin-path)" \
    && mkdir /output /symbols \
    && objcopy --only-keep-debug "$bin_dir/aviation-mcp" /symbols/aviation-mcp.debug \
    && objcopy --strip-debug --add-gnu-debuglink=/symbols/aviation-mcp.debug \
        "$bin_dir/aviation-mcp" /output/aviation-mcp \
    && find -L "$bin_dir" -maxdepth 1 -type d \
        \( -name '*.resources' -o -name '*.bundle' \) -exec cp -R '{}' /output/ ';'

FROM scratch AS symbols
COPY --from=build /symbols/ /

FROM swift:6.4-noble-slim AS runtime
# Use the distribution's patched Python runtime with application packages from terrain/requirements.txt.
# hadolint ignore=DL3008
RUN apt-get update \
    && apt-get install -y --no-install-recommends python3-venv ca-certificates libcurl4t64 \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --uid 10001 --user-group --create-home aviation
COPY terrain/requirements.txt /opt/terrain-requirements.txt
RUN python3 -m venv /opt/terrain \
    && /opt/terrain/bin/pip install --no-cache-dir --only-binary=:all: -r /opt/terrain-requirements.txt
WORKDIR /app
COPY --from=build /output/ ./
COPY --from=build /usr/local/lib/libsentry.so /usr/local/lib/
COPY scripts/run-job.sh /app/run-job
RUN ldconfig
COPY terrain/ /app/terrain/
RUN /opt/terrain/bin/python -m compileall -q /app/terrain
USER 10001:10001
ENV APP_ROLE=serve PORT=8080
ARG SENTRY_RELEASE
ENV SENTRY_RELEASE=$SENTRY_RELEASE
EXPOSE 8080
ENTRYPOINT ["/app/aviation-mcp"]
CMD ["serve", "--env", "production", "--hostname", "0.0.0.0", "--port", "8080"]
