FROM swift:6.4.1-noble AS build
WORKDIR /workspace
COPY Package.swift Package.resolved ./
RUN --mount=type=cache,id=aviation-swift-6.4.1,target=/workspace/.build,sharing=locked \
    swift package resolve --force-resolved-versions
COPY Sources Sources
COPY Tests Tests
RUN --mount=type=cache,id=aviation-swift-6.4.1,target=/workspace/.build,sharing=locked \
    swift build --build-system native -c release --product aviation-mcp --jobs 1 \
    && bin_dir="$(swift build --build-system native -c release --show-bin-path)" \
    && mkdir /output \
    && cp "$bin_dir/aviation-mcp" /output/ \
    && find -L "$bin_dir" -maxdepth 1 -type d \
        \( -name '*.resources' -o -name '*.bundle' \) -exec cp -R '{}' /output/ ';'

FROM swift:6.4.1-noble-slim AS runtime
# Use the distribution's patched Python runtime with pinned application packages.
# hadolint ignore=DL3008
RUN apt-get update \
    && apt-get install -y --no-install-recommends python3-venv ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --uid 10001 --user-group --create-home aviation
COPY terrain/requirements.txt /opt/terrain-requirements.txt
RUN python3 -m venv /opt/terrain \
    && /opt/terrain/bin/pip install --no-cache-dir --only-binary=:all: -r /opt/terrain-requirements.txt
WORKDIR /app
COPY --from=build --chown=aviation:aviation /output/ ./
COPY --chown=aviation:aviation terrain/ /app/terrain/
USER 10001:10001
ENV APP_ROLE=serve PORT=8080
EXPOSE 8080
ENTRYPOINT ["/app/aviation-mcp"]
CMD ["serve", "--env", "production", "--hostname", "0.0.0.0", "--port", "8080"]
