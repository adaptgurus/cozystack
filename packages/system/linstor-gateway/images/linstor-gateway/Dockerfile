# LINSTOR Gateway upstream: https://github.com/LINBIT/linstor-gateway (Apache-2.0)
# The published upstream Linux binary is checksum-verified at build time so the
# runtime image does not download executable content.
FROM alpine:3.22.1 AS fetch
ARG LINSTOR_GATEWAY_VERSION=2.3.0
ARG LINSTOR_GATEWAY_SHA256=a5cd30cc79941d8cbf742b1539a57eefa33d5a001f3b26ef671ff027f2c8e4ef
RUN apk add --no-cache ca-certificates curl && \
    curl -fsSL "https://github.com/LINBIT/linstor-gateway/releases/download/v${LINSTOR_GATEWAY_VERSION}/linstor-gateway-linux-amd64" -o /tmp/linstor-gateway && \
    echo "${LINSTOR_GATEWAY_SHA256}  /tmp/linstor-gateway" | sha256sum -c - && \
    chmod 0755 /tmp/linstor-gateway

# Upstream v2.3.0 is linked against glibc, so use a glibc runtime rather than
# musl-based Alpine. Running the binary in Alpine fails before main() with the
# dynamic-loader style error "no such file or directory".
FROM debian:bookworm-slim
RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates && \
    rm -rf /var/lib/apt/lists/*
COPY --from=fetch /tmp/linstor-gateway /usr/local/bin/linstor-gateway
USER 65532:65532
EXPOSE 8337
ENTRYPOINT ["/usr/local/bin/linstor-gateway"]
CMD ["server", "--addr=:8337"]
