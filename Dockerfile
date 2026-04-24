# Image that bundles all tools needed to run both Okteto integration test
# scripts: the platform health checks (run.sh) and the Okteto CLI end-to-end
# tests (okteto-e2e.sh).
#
# Build:
#   docker buildx build \
#     --platform linux/amd64,linux/arm64 \
#     -t ghcr.io/YOUR_USERNAME/okteto-integration-tests:latest \
#     --push \
#     .
#
# Tools installed:
#   kubectl            – query the Kubernetes API
#   okteto CLI         – run Okteto platform operations
#   curl / nc          – HTTP and TCP health checks
#   grpc_health_probe  – BuildKit gRPC probe (with TCP fallback)
#   nslookup           – DNS smoke test
#   jq                 – parse JSON from API responses

ARG KUBECTL_VERSION=v1.30.3
ARG GRPC_HEALTH_PROBE_VERSION=v0.4.28
# Okteto CLI version — keep in sync with your platform version
ARG OKTETO_CLI_VERSION=3.3.0

FROM alpine:3.20

ARG KUBECTL_VERSION
ARG GRPC_HEALTH_PROBE_VERSION
ARG OKTETO_CLI_VERSION
ARG TARGETARCH

RUN apk add --no-cache \
      bash \
      curl \
      netcat-openbsd \
      bind-tools \
      ca-certificates \
      openssl \
      jq \
      git \
    && update-ca-certificates

# Install kubectl
RUN curl -fsSL \
      "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl" \
      -o /usr/local/bin/kubectl \
    && chmod +x /usr/local/bin/kubectl \
    && kubectl version --client

# Install Okteto CLI
RUN curl -fsSL \
      "https://github.com/okteto/okteto/releases/download/${OKTETO_CLI_VERSION}/okteto-Linux-${TARGETARCH}" \
      -o /usr/local/bin/okteto \
    && chmod +x /usr/local/bin/okteto \
    && okteto version

# Install grpc_health_probe (best-effort; TCP fallback used if unavailable)
RUN curl -fsSL \
      "https://github.com/grpc-ecosystem/grpc-health-probe/releases/download/${GRPC_HEALTH_PROBE_VERSION}/grpc_health_probe-linux-${TARGETARCH}" \
      -o /usr/local/bin/grpc_health_probe \
    && chmod +x /usr/local/bin/grpc_health_probe \
    || echo "WARNING: grpc_health_probe not installed; TCP fallback will be used"

COPY run-integration-tests.sh        /usr/local/bin/run-integration-tests.sh
COPY run-okteto-e2e.sh                   /usr/local/bin/run-okteto-e2e.sh
COPY entrypoint.sh                   /usr/local/bin/entrypoint.sh

RUN chmod +x \
      /usr/local/bin/run-integration-tests.sh \
      /usr/local/bin/run-okteto-e2e.sh \
      /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
