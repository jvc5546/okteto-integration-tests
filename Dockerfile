FROM ubuntu:22.04

ARG KUBECTL_VERSION=v1.29.3
ARG HELM_VERSION=v3.14.3
ARG OKTETO_VERSION=v3.1.0

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    curl \
    git \
    ca-certificates \
    jq \
    unzip \
    wget \
    && rm -rf /var/lib/apt/lists/*

# Install kubectl with checksum verification
RUN curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
        -o /usr/local/bin/kubectl \
    && curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl.sha256" \
        -o /tmp/kubectl.sha256 \
    && echo "$(cat /tmp/kubectl.sha256)  /usr/local/bin/kubectl" | sha256sum -c - \
    && rm /tmp/kubectl.sha256 \
    && chmod +x /usr/local/bin/kubectl

# Install Helm with checksum verification
RUN curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" \
        -o /tmp/helm-linux-amd64.tar.gz \
    && curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz.sha256sum" \
        -o /tmp/helm-linux-amd64.tar.gz.sha256sum \
    && ( cd /tmp && sha256sum -c helm-linux-amd64.tar.gz.sha256sum --ignore-missing ) \
    && tar -xz --strip-components=1 -C /usr/local/bin -f /tmp/helm-linux-amd64.tar.gz linux-amd64/helm \
    && chmod +x /usr/local/bin/helm \
    && rm /tmp/helm-linux-amd64.tar.gz /tmp/helm-linux-amd64.tar.gz.sha256sum

# Install Okteto CLI with checksum verification
RUN curl -fsSL "https://github.com/okteto/okteto/releases/download/${OKTETO_VERSION}/okteto-Linux-x86_64" \
        -o /usr/local/bin/okteto \
    && curl -fsSL "https://github.com/okteto/okteto/releases/download/${OKTETO_VERSION}/okteto-Linux-x86_64.sha256" \
        -o /tmp/okteto.sha256 \
    && echo "$(cat /tmp/okteto.sha256)  /usr/local/bin/okteto" | sha256sum -c - \
    && rm /tmp/okteto.sha256 \
    && chmod +x /usr/local/bin/okteto

WORKDIR /workspace

CMD ["bash"]
