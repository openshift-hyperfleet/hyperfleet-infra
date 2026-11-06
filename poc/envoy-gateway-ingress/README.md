# Envoy Gateway ingress POC — HYPERFLEET-1681

Proves the decided entry path on OCI: Gateway API with Envoy Gateway, TLS
terminated at the Gateway's 443 listener, and the gateway hostname's
certificate issued by cert-manager HTTP-01 through the Gateway's port-80
listener. This branch is a POC — nothing here merges into the charts. The
chart-rework follow-up turns the proven shape into `helm/hyperfleet-gateway`.

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

- ExternalDNS with the 1573-verified recipe (instance principals, the
  oci.hypershell.app zone):

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
#         issuer "(STAGING) ... Let's Encrypt", HTTP/2, an Envoy response
#         (500 on this cluster — no backend)

# Port 80 answers (no route on it outside the solver)
curl -v http://api.oci.hypershell.app/     # expect: Envoy 404
```

## Caveats

- The 443 response is a 500 from Envoy: the httproute's backend
  (`hyperfleet-api`) does not exist on this cluster. On the management
  cluster the route exists but ADR-0020's NetworkPolicy confines the API to
  the chart's Envoy pods, so it returns 503 until the rework widens the
  selector. Either way the TLS-termination proof stands on the handshake.
- The staging certificate is untrusted by design; production switch happens
  last (prod allows five duplicate certificates per week).
- `.app` is HSTS-preloaded, so browsers refuse plain `http://` — verify port
  80 with curl.
- OKE enforces image short-name resolution: use fully-qualified images
  (`docker.io/...`) for any ad-hoc debug pods.

## Teardown

```bash
kubectl delete -f httproute.yaml -f certificate.yaml -f issuer.yaml -f gateway.yaml -f gatewayclass.yaml
helm uninstall eg -n envoy-gateway-system
kubectl delete -f cert-manager-gatewayapi.yaml
kubectl patch deployment cert-manager -n cert-manager --type=json \
  -p='[{"op":"remove","path":"/spec/template/spec/containers/0/volumeMounts"},{"op":"remove","path":"/spec/template/spec/volumes"}]'
kubectl rollout restart deployment/cert-manager -n cert-manager
# Optional: remove the two network rules and ExternalDNS — both are generic
# cluster prerequisites worth keeping.
```
