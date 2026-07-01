#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-hcm-hyperfleet}"
TTL_DAYS="${TTL_DAYS:-5}"
DRY_RUN="${DRY_RUN:-true}"

if ! [[ "${TTL_DAYS}" =~ ^[0-9]+$ ]]; then
    echo "ERROR: TTL_DAYS must be a non-negative integer" >&2
    exit 1
fi

DRY_RUN="$(printf '%s' "${DRY_RUN}" | tr '[:upper:]' '[:lower:]')"
if [[ "${DRY_RUN}" != "true" && "${DRY_RUN}" != "false" ]]; then
    echo "ERROR: DRY_RUN must be true or false" >&2
    exit 1
fi

TTL_DATE=$(date -u -v+"${TTL_DAYS}"d +%Y-%m-%d 2>/dev/null || date -u -d "+${TTL_DAYS} days" +%Y-%m-%d)

echo "=== Add TTL Labels to GKE Clusters ==="
echo "Project:  ${PROJECT_ID}"
echo "TTL date: ${TTL_DATE} (${TTL_DAYS} days from now)"
echo "Dry run:  ${DRY_RUN}"
echo ""

clusters=$(gcloud container clusters list \
    --project="${PROJECT_ID}" \
    --format="csv[no-heading](name,zone,resourceLabels.environment,resourceLabels.ttl)")

if [ -z "${clusters}" ]; then
    echo "No clusters found in project ${PROJECT_ID}"
    exit 0
fi

updated=0
skipped=0

while IFS=',' read -r name zone env ttl; do
    if [ "${env}" = "cicd" ]; then
        echo "SKIP  ${name} (environment=cicd)"
        skipped=$((skipped + 1))
        continue
    fi

    if [[ "${name}" == hyperfleet-dev-ci-infra-* ]]; then
        echo "SKIP  ${name} (ephemeral CI cluster)"
        skipped=$((skipped + 1))
        continue
    fi

    if [ -n "${ttl}" ]; then
        echo "SKIP  ${name} (already has ttl=${ttl})"
        skipped=$((skipped + 1))
        continue
    fi

    if [ "${DRY_RUN}" = "true" ]; then
        echo "WOULD UPDATE  ${name} (zone=${zone}) → ttl=${TTL_DATE}"
    else
        echo "UPDATE  ${name} (zone=${zone}) → ttl=${TTL_DATE}"
        gcloud container clusters update "${name}" \
            --project="${PROJECT_ID}" \
            --zone="${zone}" \
            --update-labels="ttl=${TTL_DATE}" \
            --quiet
    fi
    updated=$((updated + 1))
done <<< "${clusters}"

echo ""
echo "Summary: ${updated} updated, ${skipped} skipped"
if [ "${DRY_RUN}" = "true" ]; then
    echo "Run with DRY_RUN=false to apply changes"
fi
