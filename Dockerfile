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
RUN useradd --uid 10001 --user-group --create-home aviation
WORKDIR /app
COPY --from=build --chown=aviation:aviation /output/ ./
USER 10001:10001
ENV APP_ROLE=serve PORT=8080
EXPOSE 8080
ENTRYPOINT ["/app/aviation-mcp"]
CMD ["serve", "--env", "production", "--hostname", "0.0.0.0", "--port", "8080"]
