ARG BASE_IMAGE=registry.access.redhat.com/ubi9-micro:latest@sha256:dbd325b96bcd432dd42816d31412bdf1dc0fb973b79ed310344bc23c76c068db

FROM registry.access.redhat.com/ubi9/go-toolset:1.26@sha256:0e3894cea4fc077084245e8aa2befc8a7d91a4f60fbf850f0b5b555cbe62ee26 AS build
WORKDIR /opt/app-root/src
COPY --chown=1001:0 go.mod go.sum ./
RUN go mod download
COPY --chown=1001:0 . .
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags "-s -w" -o /tmp/func .

# ubi9-micro doesn't include CA certificates; copy from builder for TLS to the
# OCI API endpoints. The binary is static (CGO_ENABLED=0) and fdk-go embeds the
# OCI Functions invocation protocol directly, so no Go toolchain is needed at
# runtime.
FROM ${BASE_IMAGE}
WORKDIR /function
COPY --from=build /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem
COPY --from=build /tmp/func /function/func
USER 65532:65532
ENTRYPOINT ["./func"]
