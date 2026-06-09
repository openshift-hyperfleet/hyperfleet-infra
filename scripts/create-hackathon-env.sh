#!/usr/bin/env bash
# Creates per-participant namespaces and RBAC for HyperFleet Ignition Day.
#
# Usage: ./scripts/create-hackathon-env.sh alice,bob,charlie
#
# For each participant, creates:
#   - Namespace: hackathon-{name}
#   - ServiceAccount: {name}-sa
#   - Role: hackathon-participant (create/edit/delete common resources)
#   - RoleBinding: {name}-binding

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <comma-separated-participant-names>"
  echo "Example: $0 alice,bob,charlie"
  exit 1
fi

IFS=',' read -ra PARTICIPANTS <<< "$1"

echo "Creating hackathon environments for ${#PARTICIPANTS[@]} participants..."
echo ""

for name in "${PARTICIPANTS[@]}"; do
  # Trim whitespace
  name=$(echo "$name" | tr -d '[:space:]')
  ns="hackathon-${name}"

  echo "── ${name} ──"

  # Create namespace
  if kubectl get namespace "$ns" >/dev/null 2>&1; then
    echo "  Namespace ${ns} already exists"
  else
    kubectl create namespace "$ns"
    echo "  ✓ Namespace ${ns} created"
  fi

  # Create ServiceAccount
  kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${name}-sa
  namespace: ${ns}
  labels:
    app.kubernetes.io/part-of: hyperfleet-hackathon
    hackathon.hyperfleet.io/participant: ${name}
EOF
  echo "  ✓ ServiceAccount ${name}-sa created"

  # Create Role — allows deploying adapters/sentinels and debugging
  kubectl apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: hackathon-participant
  namespace: ${ns}
  labels:
    app.kubernetes.io/part-of: hyperfleet-hackathon
rules:
  # Deploy and manage Helm releases (adapters, sentinels)
  - apiGroups: ["", "apps", "batch"]
    resources: ["configmaps", "secrets", "services", "deployments", "replicasets", "jobs", "pods"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  # View logs and events for debugging
  - apiGroups: [""]
    resources: ["pods/log", "events"]
    verbs: ["get", "list", "watch"]
  # Manage RBAC within own namespace
  - apiGroups: ["rbac.authorization.k8s.io"]
    resources: ["roles", "rolebindings"]
    verbs: ["get", "list", "watch", "create", "update", "patch"]
  # ServiceAccounts for adapter/sentinel pods
  - apiGroups: [""]
    resources: ["serviceaccounts"]
    verbs: ["get", "list", "watch", "create", "update", "patch"]
EOF
  echo "  ✓ Role hackathon-participant created"

  # Create RoleBinding
  kubectl apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${name}-binding
  namespace: ${ns}
  labels:
    app.kubernetes.io/part-of: hyperfleet-hackathon
    hackathon.hyperfleet.io/participant: ${name}
subjects:
  - kind: ServiceAccount
    name: ${name}-sa
    namespace: ${ns}
roleRef:
  kind: Role
  name: hackathon-participant
  apiGroup: rbac.authorization.k8s.io
EOF
  echo "  ✓ RoleBinding ${name}-binding created"
  echo ""
done

echo "Done. ${#PARTICIPANTS[@]} participant namespaces created."
echo ""
echo "Participants can set their context with:"
echo "  kubectl config set-context --current --namespace=hackathon-<name>"
