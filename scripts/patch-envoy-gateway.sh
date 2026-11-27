#!/usr/bin/env bash
# Patch Envoy Gateway's upstream install.yaml (stdin) for HyperFleet (stdout).
#
# The upstream manifest is built for the default mode, where every Gateway's Envoy
# runs in the controller's namespace. HyperFleet runs each Envoy in the Gateway's own
# namespace (next to Authorino and the API) and needs Lua EnvoyExtensionPolicies, so
# three things change:
#
#   1. controller config: provider.kubernetes.deploy.type: GatewayNamespace
#   2. controller config: extensionApis.enableLua: true
#   3. the topology-injector webhook loses its namespaceSelector, which upstream
#      pins to the controller's namespace; the proxy pods are now in other namespaces
#
# The cluster-wide RBAC that mode also needs is not part of the manifest: it is
# applied from manifests/envoy-gateway-rbac.yaml.
#
# Every edit must match exactly once. If upstream changes the text, this fails
# instead of silently shipping an unpatched controller; the exit status is the
# signal, so callers must not use the output when it is non-zero.
set -euo pipefail

awk '
{ line[NR] = $0 }
END {
    for (i = 1; i <= NR; i++) {
        l = line[i]
        if (l == "    extensionApis: {}") {
            print "    extensionApis:"
            print "      enableLua: true"
            lua++
            continue
        }
        if (l == "      kubernetes:" && line[i - 1] == "    provider:") {
            print l
            print "        deploy:"
            print "          type: GatewayNamespace"
            mode++
            continue
        }
        if (l == "    namespaceSelector:" \
            && line[i + 1] == "      matchExpressions:" \
            && line[i + 2] == "        - key: kubernetes.io/metadata.name" \
            && line[i + 3] == "          operator: In" \
            && line[i + 4] == "          values:" \
            && line[i + 5] == "            - envoy-gateway-system") {
            i += 5
            selector++
            continue
        }
        print l
    }
    if (lua != 1 || mode != 1 || selector != 1) {
        printf "ERROR: Envoy Gateway manifest patches matched lua=%d mode=%d selector=%d times, expected 1 each; the upstream manifest changed\n", lua, mode, selector > "/dev/stderr"
        exit 1
    }
}'
