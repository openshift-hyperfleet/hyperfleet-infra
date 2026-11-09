# Envoy Gateway ingress POC — HYPERFLEET-1681

Proves the decided entry path on OCI: Gateway API with Envoy Gateway, TLS
terminated at the Gateway's 443 listener, and the gateway hostname's
certificate issued by cert-manager HTTP-01 through the Gateway's port-80
listener. The HYPERFLEET-1909 layer (steps 4-5) adds the auth mechanisms
[ADR-0036](https://github.com/openshift-hyperfleet/architecture/blob/main/hyperfleet/adrs/0036-management-cluster-ingress-tls-termination.md) prescribes: listener-scoped SecurityPolicy, early header stripping,
and port-80 confinement. This branch is a POC — nothing here merges into the
charts. The chart-rework follow-up turns the proven shape into
`helm/hyperfleet-gateway`.

## Cluster

Runs on the `context-dns-testing-c2qvrucliyq` OKE cluster (us-sanjose-1);
the management cluster's API endpoint is office-network-only, and this
cluster is empty, so the prerequisites below install everything needed. The
OCI CLI session must be authenticated (`oci session authenticate`).

## Prerequisites

- `kubectl` on the dns-testing context, `helm` installed.
- cert-manager (the repo's pinned target):

  ```bash
  make install-cert-manager
  ```

- ExternalDNS (instance principals, the `oci.hypershell.app` zone):

  ```bash
  helm upgrade --install external-dns helm/external-dns \
    --namespace hyperfleet-oci-test --create-namespace \
    --set oci.compartmentId=ocid1.compartment.oc1..aaaaaaaayxy5royzq3wztxzqezo7ixxg2dyzl2rko4gsifkash24ag2a5iuq \
    --set domainFilter=oci.hypershell.app \
    --set txtOwnerId=dns-testing \
    --wait --timeout 5m
  ```

- **Network rules:** in NSG mode the CCM creates only the load balancer's
  *frontend* ingress rule. The load balancer → worker path is default-denied
  on this cluster: the worker subnet's security list allows only
  intra-subnet, control-plane, and SSH traffic, and the LB subnet's security
  list is empty. Two rules are needed:

  - Worker subnet security list, ingress: TCP 30000-32767 from `10.0.20.0/24`
    (the LB subnet) — node ports and health check node ports.
  - LB subnet security list, egress: TCP 30000-32767 to `10.0.10.0/24` (the
    worker subnet).

  Without them the backend health checks report CONNECT_FAILED and port 80
  resets for every client, including the ACME validator.

## Steps

The prerequisites above run from the repo root; the steps and teardown below reference manifests by bare filename, so run them from this directory:

```bash
cd poc/envoy-gateway-ingress
```

### 1. Install Envoy Gateway (pinned v1.9.3) and the GatewayClass

The helm chart installs the controller and the Gateway API CRDs but **not**
the GatewayClass — without it the Gateway sits in "Waiting for controller":

```bash
helm install eg oci://docker.io/envoyproxy/gateway-helm \
  --version v1.9.3 -n envoy-gateway-system --create-namespace --wait
kubectl apply -f gatewayclass.yaml
```

### 2. Enable cert-manager's Gateway API support

cert-manager 1.15+ ships the `gatewayHTTPRoute` HTTP-01 solver, opt-in via the
controller config file. The repo installs cert-manager from the pinned
manifest, so enable it with a ConfigMap (a `ControllerConfiguration` object —
bare values crash the controller) plus a JSON patch that appends `--config`
without touching the deployment's customized args:

```bash
kubectl apply -f cert-manager-gatewayapi.yaml
kubectl patch deployment cert-manager -n cert-manager \
  --type=json --patch-file cert-manager-gatewayapi-patch.yaml
kubectl rollout restart deployment/cert-manager -n cert-manager
```

### 3. Apply the POC manifests

The manifests target `hyperfleet-oci-test`:

```bash
kubectl apply -f gateway.yaml -f issuer.yaml -f certificate.yaml -f httproute.yaml
```

Note: Envoy Gateway's default deployment mode places the generated Envoy
pods and the LoadBalancer Service in `envoy-gateway-system`, named
`envoy-<namespace>-<gateway>-<hash>` — not in the Gateway's namespace.

### 4. Add the auth verification layer (HYPERFLEET-1909)

The Authorino operator is the repo's pinned install. The
POC Authorino instance disables TLS on its listeners — internal-hop TLS is
chart-owned hardening, not part of what this verifies:

```bash
make install-authorino-operator
kubectl apply -f authorino-poc.yaml
kubectl -n hyperfleet-oci-test wait --for=condition=Ready authorino/hyperfleet-poc --timeout=180s
kubectl apply -f authconfig-poc.yaml -f echo-backend.yaml -f securitypolicy.yaml -f clienttrafficpolicy.yaml
```

### 5. Verify the auth mechanisms (HYPERFLEET-1909)

```bash
# Fail-closed: the SecurityPolicy targets the https listener, so a route with
# no route-level policy is still authenticated — an unauthenticated request
# never reaches the backend
curl -sk -o /dev/null -w '%{http_code}\n' https://api.oci.hypershell.app/headers
# expect: 401 or 403

# Stripping before authorization: client-supplied identity headers never
# arrive; Authorino's injected identity does
TOKEN=$(kubectl create token poc-verifier -n hyperfleet-oci-test --audience=hyperfleet-poc)
curl -sk https://api.oci.hypershell.app/headers \
  -H "Authorization: ServiceAccount $TOKEN" \
  -H "x-hyperfleet-identity: forged@example.com" \
  -H "x-hyperfleet-system: forged"
# expect: X-Hyperfleet-Identity: system:serviceaccount:hyperfleet-oci-test:poc-verifier
#         X-Hyperfleet-System: true — no trace of the forged values

# Renewal under confinement: the solver HTTPRoute must still attach to the
# port-80 listener (allowedRoutes from Same) and the certificate reissue
kubectl -n hyperfleet-oci-test delete secret api-oci-hypershell-app-tls
kubectl -n hyperfleet-oci-test get httproute    # cm-acme-http-solver-* appears during the challenge
kubectl -n hyperfleet-oci-test get certificate api-oci-hypershell-app -w
# expect: back to Ready with a fresh staging certificate

# Port-80 confinement: nothing but the solver answers
curl -s -o /dev/null -w '%{http_code}\n' http://api.oci.hypershell.app/
# expect: 404
```

**Results (11/9):** all four mechanisms hold.

- **Fail-closed:** 401 unauthenticated — the listener-scoped SecurityPolicy
  authenticates a route with no route-level policy
- **Stripping:** forged `x-hyperfleet-*` values never reached the backend;
  Authorino's injected identity did
- **Renewal:** re-issued in ~5 s with the ACME challenge served through the
  confined port-80 listener; the solver HTTPRoute is ephemeral — witness it
  via the Certificate's events, not polling
- **Port 80:** 404 outside the solver

Notes for the rework:

- The POC AuthConfig has no wristband, so the ServiceAccount credential is
  forwarded upstream — the chart's full config replaces it
- Envoy Gateway's `HTTPHeaderFilter` is flat (`set`/`add`/`remove`, not the
  Gateway API `request:` wrapper)
- The Authorino operator appends `-authorino-authorization` to the CR name —
  name the CR without an `-authorino` suffix to get the chart's service names

## Verification

```bash
# Service is a LoadBalancer on 80/443 with the infrastructure annotations
kubectl -n envoy-gateway-system get svc -l gateway.envoyproxy.io/owning-gateway-name=hyperfleet-poc

# DNS publishes (ExternalDNS logs), then resolves publicly
kubectl -n hyperfleet-oci-test logs deploy/external-dns --tail=20 | grep api.oci
dig +short api.oci.hypershell.app          # expect: the LB IP

# Issuance: Certificate goes Ready; the temporary solver HTTPRoute
# (cm-acme-http-solver-*) appears on the port-80 listener during the challenge
kubectl -n hyperfleet-oci-test get certificate api-oci-hypershell-app -w

# Serving: the staging certificate terminates TLS on 443
curl -kv https://api.oci.hypershell.app/
# expect: subject CN=api.oci.hypershell.app,
#         issuer "(STAGING) ... Let's Encrypt", HTTP/2 — with the auth layer
#         applied, an Envoy 401/403 (unauthenticated)
```

## Caveats

- The route targets the echo backend (httpbin), not the real API Service:
  on the management cluster [ADR-0020](https://github.com/openshift-hyperfleet/architecture/blob/main/hyperfleet/adrs/0020-envoy-authorino-api-gateway.md)'s NetworkPolicy confines the API to the
  chart's Envoy pods, so the real Service returns 503 until the rework widens
  the selector. The echo backend keeps the header checks observable either way.
- The staging certificate is untrusted by design; production switch happens
  last (prod allows five duplicate certificates per week).
- `.app` is HSTS-preloaded, so browsers refuse plain `http://` — verify port
  80 with curl.
- OKE enforces image short-name resolution: use fully-qualified images
  (`docker.io/...`) for any ad-hoc debug pods.

## Teardown

```bash
kubectl delete -f securitypolicy.yaml -f clienttrafficpolicy.yaml -f echo-backend.yaml -f authconfig-poc.yaml -f authorino-poc.yaml
kubectl delete -f httproute.yaml -f certificate.yaml -f issuer.yaml -f gateway.yaml -f gatewayclass.yaml
helm uninstall eg -n envoy-gateway-system
make uninstall-authorino-operator
kubectl delete -f cert-manager-gatewayapi.yaml
kubectl patch deployment cert-manager -n cert-manager --type=json \
  -p='[{"op":"remove","path":"/spec/template/spec/containers/0/volumeMounts"},{"op":"remove","path":"/spec/template/spec/volumes"}]'
kubectl rollout restart deployment/cert-manager -n cert-manager
# Optional: remove the two network rules and ExternalDNS — both are generic
# cluster prerequisites worth keeping.
```
