# integration-tests/Dockerfile
#
# Lightweight image that bundles the tools needed to run the Okteto
# platform integration tests defined in run.sh.
#
# Build:
#   docker build -t ghcr.io/okteto/integration-tests:<tag> \
#                -f integration-tests/Dockerfile integration-tests/
#
# The image is intentionally based on Alpine to keep it small.
# It installs:
#   • kubectl        – to query the Kubernetes API
#   • curl / nc      – for HTTP and TCP health checks
#   • grpc_health_probe (optional, multi-arch) – for BuildKit gRPC probe
#   • nslookup       – bundled via bind-tools for DNS smoke test

ARG KUBECTL_VERSION=v1.30.3
ARG GRPC_HEALTH_PROBE_VERSION=v0.4.28

FROM alpine:3.20

ARG KUBECTL_VERSION
ARG GRPC_HEALTH_PROBE_VERSION
ARG TARGETARCH

# Install runtime dependencies
RUN apk add --no-cache \
      bash \
      curl \
      netcat-openbsd \
      bind-tools \
      ca-certificates \
      openssl \
    && update-ca-certificates

# Install kubectl
RUN curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl" \
      -o /usr/local/bin/kubectl \
    && chmod +x /usr/local/bin/kubectl \
    && kubectl version --client

# Install grpc_health_probe (best-effort; skipped if download fails)
RUN curl -fsSL \
      "https://github.com/grpc-ecosystem/grpc-health-probe/releases/download/${GRPC_HEALTH_PROBE_VERSION}/grpc_health_probe-linux-${TARGETARCH}" \
      -o /usr/local/bin/grpc_health_probe \
    && chmod +x /usr/local/bin/grpc_health_probe \
    || echo "WARNING: grpc_health_probe could not be installed; TCP fallback will be used"

COPY integration-tests-run.sh /usr/local/bin/run-integration-tests.sh
RUN chmod +x /usr/local/bin/run-integration-tests.sh

ENTRYPOINT ["/usr/local/bin/run-integration-tests.sh"]
