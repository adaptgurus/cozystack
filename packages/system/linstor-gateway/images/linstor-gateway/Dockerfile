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

FROM alpine:3.22.1
RUN apk add --no-cache ca-certificates && \
    addgroup -g 65532 -S gateway && \
    adduser -u 65532 -S -D -H -G gateway gateway
COPY --from=fetch /tmp/linstor-gateway /usr/local/bin/linstor-gateway
USER 65532:65532
EXPOSE 8337
ENTRYPOINT ["/usr/local/bin/linstor-gateway"]
CMD ["server", "--addr=:8337"]
