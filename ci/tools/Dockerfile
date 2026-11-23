# linux/amd64 only: the archives and provider mirror target Prow.
FROM registry.access.redhat.com/ubi9/ubi:9.8-1791888712@sha256:16e9e43d99e181463513cc84a514859b1abb9460f1c4d9e208da4b4e51cd5cc3

LABEL name="hyperfleet-infra-tools" \
      vendor="Red Hat" \
      summary="Pinned HyperFleet infrastructure CI tools" \
      description="Validation and integration tools with a Terraform provider mirror" \
      org.opencontainers.image.source="https://github.com/openshift-hyperfleet/hyperfleet-infra"

SHELL ["/bin/bash", "-o", "errexit", "-o", "nounset", "-o", "pipefail", "-c"]

RUN dnf install -y git make jq diffutils unzip xz \
    && dnf clean all && rm -rf /var/cache/dnf

ARG TERRAFORM_VERSION=1.17.2
ARG TERRAFORM_SHA256=e6f16b2f0b137ee5729caa8c4e79a3bae4ee261acd198a1fcfa8584a6296605b
ARG KUBECTL_VERSION=v1.37.1
ARG KUBECTL_SHA256=65691ff77eb6fa44c908b77a1082c9f092c3b9733b5cefabec0d1104890e21a8
ARG HELM_VERSION=v3.22.1
ARG HELM_SHA256=896cf63684a42a723d61c980369d6e588330927deb13676ca0d85006dd6da0ea
ARG HELMFILE_VERSION=1.5.2
ARG HELMFILE_SHA256=96e342ff19a45c2e36371f93cf6264f3ef285bbde0fc363e56cb53bdef3df1ff
ARG SHELLCHECK_VERSION=v0.10.0
# ShellCheck publishes no checksum asset; this hash was computed from the archive.
ARG SHELLCHECK_SHA256=6c881ab0698e4e6ea235245f22832860544f17ba386442fe7e9d629f8cbedf87
RUN curl -fsSL -o /tmp/terraform.zip "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip" \
    && echo "${TERRAFORM_SHA256}  /tmp/terraform.zip" | sha256sum -c - \
    && unzip /tmp/terraform.zip terraform -d /usr/local/bin \
    && curl -fsSL -o /usr/local/bin/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
    && echo "${KUBECTL_SHA256}  /usr/local/bin/kubectl" | sha256sum -c - \
    && chmod 755 /usr/local/bin/kubectl \
    && curl -fsSL -o /tmp/helm.tar.gz "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" \
    && echo "${HELM_SHA256}  /tmp/helm.tar.gz" | sha256sum -c - \
    && tar --no-same-owner -xzf /tmp/helm.tar.gz -C /usr/local/bin --strip-components=1 linux-amd64/helm \
    && curl -fsSL -o /tmp/helmfile.tar.gz "https://github.com/helmfile/helmfile/releases/download/v${HELMFILE_VERSION}/helmfile_${HELMFILE_VERSION}_linux_amd64.tar.gz" \
    && echo "${HELMFILE_SHA256}  /tmp/helmfile.tar.gz" | sha256sum -c - \
    && tar --no-same-owner -xzf /tmp/helmfile.tar.gz -C /usr/local/bin helmfile \
    && curl -fsSL -o /tmp/shellcheck.tar.xz "https://github.com/koalaman/shellcheck/releases/download/${SHELLCHECK_VERSION}/shellcheck-${SHELLCHECK_VERSION}.linux.x86_64.tar.xz" \
    && echo "${SHELLCHECK_SHA256}  /tmp/shellcheck.tar.xz" | sha256sum -c - \
    && tar --no-same-owner -xJf /tmp/shellcheck.tar.xz -C /usr/local/bin --strip-components=1 "shellcheck-${SHELLCHECK_VERSION}/shellcheck" \
    && rm -rf /tmp/*

ENV HOME=/tmp/helm-home \
    HELM_CACHE_HOME=/tmp/helm-home/.cache/helm \
    HELM_CONFIG_HOME=/tmp/helm-home/.config/helm \
    HELM_DATA_HOME=/tmp/helm-home/.local/share/helm \
    HELM_PLUGINS=/usr/local/share/helm/plugins \
    USE_GKE_GCLOUD_AUTH_PLUGIN=True

# helm-git has no release archive, so its tag is checked against the commit.
ARG HELM_GIT_VERSION=v1.5.2
ARG HELM_GIT_COMMIT=8f910e377bf743cc07ce963a696b1e7929aebb80
ARG HELM_DIFF_VERSION=3.15.7
ARG HELM_DIFF_SHA256=ff7b1b6f3f4fafeac1d0e2c0c82eafac6fa7601bda52396355bf931ecf3a304a
RUN git -c advice.detachedHead=false clone -q --depth 1 --branch "${HELM_GIT_VERSION}" \
        https://github.com/aslafy-z/helm-git "${HELM_PLUGINS}/helm-git" \
    && test "$(git -C "${HELM_PLUGINS}/helm-git" rev-parse HEAD)" = "${HELM_GIT_COMMIT}" \
    && rm -rf "${HELM_PLUGINS}/helm-git/.git" \
    && curl -fsSL -o /tmp/helm-diff.tgz "https://github.com/databus23/helm-diff/releases/download/v${HELM_DIFF_VERSION}/helm-diff-linux-amd64.tgz" \
    && echo "${HELM_DIFF_SHA256}  /tmp/helm-diff.tgz" | sha256sum -c - \
    && tar --no-same-owner -xzf /tmp/helm-diff.tgz -C "${HELM_PLUGINS}" \
    && rm /tmp/helm-diff.tgz

ARG GCLOUD_VERSION=590.0.0
ARG GCLOUD_SHA256=7ff4eee172a6f8ba916e542aeef1e59ec411c87b45f7e69ea4515e69cc868fce
ARG GKE_AUTH_SHA256=ddcd2d545675ee8052c5af3bacf6e286b00c6fa3ea4581fa0b8f4d0a2b3a5f48
RUN curl -fsSL -o /tmp/google-cloud-cli.rpm "https://packages.cloud.google.com/yum/repos/cloud-sdk-el9-x86_64/Packages/${GCLOUD_SHA256}-google-cloud-cli-${GCLOUD_VERSION}-1.x86_64.rpm" \
    && echo "${GCLOUD_SHA256}  /tmp/google-cloud-cli.rpm" | sha256sum -c - \
    && curl -fsSL -o /tmp/gke-auth.rpm "https://packages.cloud.google.com/yum/repos/cloud-sdk-el9-x86_64/Packages/${GKE_AUTH_SHA256}-google-cloud-cli-gke-gcloud-auth-plugin-${GCLOUD_VERSION}-1.x86_64.rpm" \
    && echo "${GKE_AUTH_SHA256}  /tmp/gke-auth.rpm" | sha256sum -c - \
    && dnf install -y /tmp/google-cloud-cli.rpm /tmp/gke-auth.rpm \
    && dnf clean all && rm -rf /var/cache/dnf /tmp/*.rpm

# The mirror is built with direct registry access, which verifies provider
# checksums and signatures, so terraformrc is copied only after it.
COPY providers.tf /tmp/provider-mirror/providers.tf
RUN cd /tmp/provider-mirror \
    && terraform providers mirror -platform=linux_amd64 /usr/local/share/terraform/providers \
    && rm -rf /tmp/provider-mirror
COPY terraformrc /etc/terraformrc
ENV TF_CLI_CONFIG_FILE=/etc/terraformrc

# Smoke-run the tools as root, then open HOME to the arbitrary UIDs Prow runs as
# and give /go, where ci-operator clones the source, to the image user.
RUN terraform version \
    && kubectl version --client \
    && helm version \
    && helmfile --version \
    && helm plugin list | grep -q '^helm-git' \
    && helm diff version \
    && shellcheck --version \
    && gcloud --version \
    && gke-gcloud-auth-plugin --version \
    && mkdir -p "${HELM_CACHE_HOME}" "${HELM_CONFIG_HOME}" "${HELM_DATA_HOME}" \
    && chmod -R 777 "${HOME}" \
    && mkdir /go && chown 1001:0 /go && chmod 775 /go
USER 1001:0
