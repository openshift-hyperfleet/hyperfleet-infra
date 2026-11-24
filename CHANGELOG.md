# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).
This repository does not follow traditional semantic versioning — Terraform modules are versioned
via git tags, Helm charts are versioned in their component repositories, and infrastructure changes
are deployed directly from `main`. See [CONTRIBUTING.md](CONTRIBUTING.md#release-process) for details.

## [Unreleased]

### Changed

- **BREAKING:** the `hyperfleet-gateway` chart now renders Envoy Gateway and Gateway API resources (`Gateway`, `EnvoyProxy`, `HTTPRoute`, policies) instead of a hand-written Envoy Deployment, ConfigMap and Services (HYPERFLEET-1910, ADR-0036). `make install-envoy-gateway` (pinned, patched upstream manifest plus the shared `hyperfleet` GatewayClass) is a new prerequisite of `install-hyperfleet` and `install-gateway`. In-place upgrades are not supported: redeploy the environment.
- The gateway chart derives the authentication mode from `authorino.enabled` and `authorino.policy.wristband.enabled` instead of `authorino.mode`; the wristband hook image is `authorino.wristbandHookImage`; the identity header list is extended with `headers.stripOverride`; only `GET`, `HEAD`, `PUT` and `DELETE` are retried.
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
