FROM golang:1.26-alpine@sha256:0178a641fbb4858c5f1b48e34bdaabe0350a330a1b1149aabd498d0699ff5fb2 AS builder

ARG TARGETOS
ARG TARGETARCH
WORKDIR /workspace
COPY go.mod go.sum ./
RUN GOOS=$TARGETOS GOARCH=$TARGETARCH go mod download
COPY pkg pkg/
COPY cmd cmd/
RUN GOOS=$TARGETOS GOARCH=$TARGETARCH CGO_ENABLED=0 go build -ldflags="-extldflags=-static" -o /vm-network-admission cmd/vm-network-admission/main.go

FROM scratch
COPY --from=builder /vm-network-admission /vm-network-admission
USER 65532:65532
ENTRYPOINT ["/vm-network-admission"]
