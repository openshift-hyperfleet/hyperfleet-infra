# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).
This repository does not follow traditional semantic versioning — Terraform modules are versioned
via git tags, Helm charts are versioned in their component repositories, and infrastructure changes
are deployed directly from `main`. See [CONTRIBUTING.md](CONTRIBUTING.md#release-process) for details.

## [Unreleased]

### Changed

- **BREAKING:** the `hyperfleet-gateway` chart now renders Envoy Gateway and Gateway API resources (`Gateway`, `EnvoyProxy`, `HTTPRoute`, policies) instead of a hand-written Envoy Deployment, ConfigMap and Services (HYPERFLEET-1910, ADR-0036). `make install-envoy-gateway` (pinned, patched upstream manifest plus the shared `hyperfleet` GatewayClass) is a new prerequisite of `install-hyperfleet` and `install-gateway`. In-place upgrades are not supported: redeploy the environment.
- **BREAKING:** the only authentication model is the former `EDGE+API`: Authorino validates the caller at the gateway and issues the wristband the API trusts. `AUTH_MODE` (`NONE`, `EDGE`, `API`) is removed from the Makefile, the env files, the Helmfile, the scripts and the docs, along with `authorino.mode` (earlier `auth.mode`), `authorino.enabled` and `authorino.policy.wristband.enabled` in the gateway chart (Authorino, the SecurityPolicy and the wristband hand-off are always rendered), the Kubernetes OIDC discovery prerequisite that only API mode used, and the `maybe-install-authorino-operator` target (`install-authorino-operator` always runs). A human issuer is required: `OIDC_ISSUER_URL`, or `OIDC_ISSUER_MODE=mock`. The wristband hook image is `authorino.wristbandHookImage` instead of `auth.wristband.lifecycle.image`; `headers.stripOverride` replaces `envoy.stripHeaders` and only adds to a fixed list, so the identity and tenant headers are always stripped; only `GET`, `HEAD`, `PUT` and `DELETE` are retried.
- The gateway chart labels the AuthConfig it renders `hyperfleet.io/gateway: general` and its Authorino selects exactly that (`authorino.authConfigLabelSelectors`, now required and validated: only `key`, `!key`, `key=value` and `key!=value` terms, because Authorino treats a selector it cannot parse as matching everything), so a second Authorino in the namespace, with its own shard label, never loads the same AuthConfig.
- The gateway chart renders the NetworkPolicy that admits its own Envoy pods to its upstream (`upstream.podSelector`, `upstream.port`), so a second gateway gets one automatically; `helm/network-policies` no longer names the gateway and `gatewayName` is removed.
- The gateway chart's `authorino.wristbandHeader` sets the header the wristband leaves in: the default `authorization` keeps `Bearer <wristband>` over the caller's credential, and a custom name such as `x-wristband` carries the raw token and deletes the caller's `Authorization` header after authorization, which a release with `authorino.policy: null` (the Desire Store) can use.
- Wristband signing-key Secrets are labelled `hyperfleet.io/wristband-signing-key=<release>`, and the sweep only deletes the keys of its own release.

### Added

- CONTRIBUTING.md with development setup and common tasks
- CHANGELOG.md following Keep a Changelog format
- CLAUDE.md with AI agent optimization guidelines

## [0.1.0](https://github.com/openshift-hyperfleet/hyperfleet-infra/releases/tag/v0.1.0) - 2026-02-23

### Added

- Initial infrastructure repository for HyperFleet development environments
- Makefile-driven workflow for provisioning and deployment
- Terraform modules for GCP infrastructure (GKE clusters, Pub/Sub, VPC)
- Helm charts for HyperFleet components (API, Sentinels, Adapters)
- Support for two message broker backends: Google Pub/Sub and RabbitMQ
- Automated Helm values generation from Terraform outputs
- Maestro server and agent deployment support
- Multi-environment support via Terraform workspaces
- Development RabbitMQ manifest for non-GCP deployments
- Comprehensive README with quick start guides for both broker types
