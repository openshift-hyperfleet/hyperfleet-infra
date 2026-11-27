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
- `make rotate-wristband-key` rotates the API gateway's key (release `hyperfleet-gateway`) and is scoped to that one release: the AuthConfig, the Authorino instance, the sweep label and the helmfile redeploy no longer target every `component=gateway` release, so a second gateway in the namespace is never re-synced with the API gateway's signing keys (the Desire Store's keys come from its operator, not this chart).
- The gateway chart assumes nothing about its callers either: `authorino.policy.machineIdentity.audience`, `authorino.policy.wristband.audience` and `authorino.policy.identityProviders` are required with no defaults, and `machineIdentity.allowedServiceAccounts` no longer defaults to the kind environment's Sentinels and adapters (Helmfile derives the real list; an empty list is valid and denies every machine caller). The renders are unchanged.
- The gateway chart has no default upstream: `upstream.host`, `upstream.port` and `upstream.podSelector` are all required, so a release declares the backend it fronts in full (`ci/lint-values.yaml` supplies them for `helm lint`). The Helmfile follows the adapter pattern: each environment lists its gateways in `helmfile/environments/<env>/gateway-configs.yaml.gotmpl`, the API gateway's values moved from `base-gateway.yaml.gotmpl` to `values/api-gateway.yaml.gotmpl`, and `base-gateway.yaml.gotmpl` keeps only what every gateway shares. The renders are unchanged.
- The gateway chart labels the AuthConfig it renders `hyperfleet.io/gateway: general` and its Authorino selects exactly that (`authorino.authConfigLabelSelectors`, now required and validated: only `key`, `!key`, `key=value` and `key!=value` terms, because Authorino treats a selector it cannot parse as matching everything), so a second Authorino in the namespace, with its own shard label, never loads the same AuthConfig.
- The gateway chart renders the NetworkPolicy that admits its own Envoy pods to its upstream (`upstream.podSelector`, `upstream.port`), so a second gateway gets one automatically; `helm/network-policies` no longer names the gateway and `gatewayName` is removed.
- The wristband lifetime is a value again: `authorino.policy.wristband.tokenDuration` (seconds, default 300, minimum 1) replaces the duration the Envoy Gateway rework had hardcoded in the AuthConfig.
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
