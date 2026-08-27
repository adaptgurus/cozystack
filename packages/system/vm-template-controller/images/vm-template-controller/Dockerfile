FROM golang:1.26.5-alpine AS builder

ARG TARGETOS
ARG TARGETARCH

WORKDIR /workspace
COPY go.mod go.sum ./
RUN GOOS=$TARGETOS GOARCH=$TARGETARCH go mod download
COPY api api/
COPY pkg pkg/
COPY cmd cmd/
COPY internal internal/
RUN GOOS=$TARGETOS GOARCH=$TARGETARCH CGO_ENABLED=0 go build -mod=readonly -buildvcs=false -trimpath -ldflags="-s -w -extldflags=-static" -o /vm-template-controller ./cmd/vm-template-controller

FROM scratch
COPY --from=builder /vm-template-controller /vm-template-controller
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
USER 65532:65532
ENTRYPOINT ["/vm-template-controller"]
