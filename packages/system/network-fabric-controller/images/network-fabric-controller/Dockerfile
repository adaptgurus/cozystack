FROM golang:1.26-alpine AS builder

ARG TARGETOS
ARG TARGETARCH

WORKDIR /workspace
COPY go.mod go.sum ./
RUN GOOS=$TARGETOS GOARCH=$TARGETARCH go mod download
COPY api api/
COPY pkg pkg/
COPY cmd cmd/
COPY internal internal/
RUN GOOS=$TARGETOS GOARCH=$TARGETARCH CGO_ENABLED=0 go build -trimpath -ldflags="-s -w -extldflags=-static" -o /network-fabric-controller ./cmd/network-fabric-controller

FROM ghcr.io/siderolabs/talosctl:v1.13.6 AS talosctl

FROM scratch
COPY --from=builder /network-fabric-controller /network-fabric-controller
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=talosctl /talosctl /usr/local/bin/talosctl
USER 65532:65532
ENTRYPOINT ["/network-fabric-controller"]
