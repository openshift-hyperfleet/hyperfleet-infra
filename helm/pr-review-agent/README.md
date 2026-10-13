# Pull request review agent

This chart installs a CronJob that reviews the open pull requests of one
HyperFleet repository with the `review-pr` skill of the
[hyperfleet-code-review](https://github.com/openshift-hyperfleet/hyperfleet-claude-plugins/tree/main/hyperfleet-code-review)
plugin. It is a port of the Amber review job of HyperShell. One Helm release
runs for each reviewed repository (`values-<repo>.yaml`); the releases share
the gateway service account, the Secret, and the providers.

## How it works

1. Each run, the runner pod copies the `openshell` CLI from the image that
   matches the gateway build (`openshell.image`) and logs in to an OpenShell
   gateway with an OIDC service account.
2. A discovery sandbox lists the open pull requests. It selects each head
   commit that has no submitted review with the marker
   `<!-- hfreview:v1 repo=... pr=... head=... -->`, and each pull request with
   new follow-up replies in the review threads of the bot.
3. The runner creates one review sandbox for each selected head. The sandbox
   clones three trees:
   - `/sandbox/trusted/<repo>`: the trusted branch of the reviewed repository
   - `/sandbox/pr/<repo>`: the pull request head, as untrusted data
   - `/sandbox/plugins`: the plugin repository at `plugins.ref`
4. `claude -p` runs with a wrapper prompt (in `files/review.sh`) that executes
   steps 1 through 6 of `review-pr/SKILL.md` and replaces its interactive
   parts. Claude posts one `COMMENT` review with inline comments. Claude Code
   calls Vertex AI directly (`claude.vertex.projectId`) with the placeholder
   token that the Vertex provider injects; the sandbox supervisor replaces it
   with the real token at egress. Set `claude.vertex.projectId` to an empty
   value to use a workspace inference route on `inference.local` instead.
5. The shell maintains a status comment, the verdict labels
   `hf-review/approved` and `hf-review/changes-requested`, and hides the
   earlier review summaries of the bot. It appends a footer with the wall
   time and the model cost of the run to the submitted review and to the
   status comment. The cost is the client-side estimate that Claude Code
   reports in its JSON result, summed over retries.

The pod contains no model or GitHub credentials. The gateway holds them as
OpenShell providers. The sandbox policy (`files/policy.yaml`) and the provider
profiles (`openshell/`) limit writes to the pull request feedback paths of the
reviewed repository.

## Wrapper prompt and skill changes

`review-pr` is an interactive skill. The wrapper prompt overrides its
`AskUserQuestion` flow and its rule that forbids GitHub posts without a typed
user command. Read the wrapper prompt again when the skill changes. Set
`plugins.ref` to a tag to prevent silent changes of the review instructions.

## Where it runs

The CronJobs run on the shared GKE CI cluster `hyperfleet-dev-prow`
(`us-central1-a`, Terraform env `dev-prow`, namespace `pr-review-agent`).
Get its credentials with `make get-credentials TF_ENV=dev-prow` or
`gcloud container clusters get-credentials hyperfleet-dev-prow --zone us-central1-a --project hcm-hyperfleet`.
Never run the same releases on two clusters at the same time: the releases
share the gateway workspace, and the stale sandbox cleanup of one cluster
deletes the in-flight sandboxes of the other.

## Requirements

- An OpenShell gateway of a HyperShell instance that the runner pod can reach
  over HTTPS. The gateway does not run in this cluster. This cluster runs only
  the CronJob. The sandboxes, the model credentials, and the GitHub token stay
  on the gateway.
- `hsctl`, logged in to that HyperShell instance, with permission to create a
  service account for the gateway.
- A GitHub bot account that is an active member of the organization of the
  reviewed repository. A fine-grained token needs these permissions on the
  reviewed repository: Organization members: read, Contents: read, Issues:
  read and write, Metadata: read, Pull requests: read and write.
- Both verdict labels exist in the reviewed repository. The runner does not
  create them.
- Optional: a Jira Cloud scoped API token for JIRA validation.

## Setup

### 1. Build the sandbox image

```bash
podman build --platform linux/amd64 \
  --tag <registry>/pr-review-sandbox:<tag> \
  helm/pr-review-agent/sandbox
podman push <registry>/pr-review-sandbox:<tag>
```

The chart default `sandbox.source` is the digest of the last pushed image.
Override it with `PR_REVIEW_SANDBOX_SOURCE` after a new push.
The cluster of the gateway pulls this image, not this cluster.

### 2. Bootstrap the gateway (script)

`scripts/bootstrap-gateway.sh` creates everything on the HyperShell side
except the provider credentials, and is safe to rerun after an instance
rebuild:

```bash
hsctl login --no-browser --url https://api.<instance>.infra.hypershell.app \
  --issuer-url https://keycloak.<instance>.infra.hypershell.app/realms/hypershell
make get-credentials TF_ENV=dev-prow        # KUBECONFIG of the CronJob cluster
make bootstrap-pr-review-gateway PR_REVIEW_CLUSTER=<managed-cluster-name> \
  PR_REVIEW_ADMIN_ENV_FILE=<path-outside-git>/hyperfleet-review-admin.env
```

It creates the gateway when missing (Route enabled) and waits for its
address, a runner service account (`openshell-user`) and the Secret
`pr-review-gateway` in the CronJob namespace, an administrator service
account (`openshell-admin`) whose credentials go to the env file, the
workspace membership of the runner, and the provider profiles from
`openshell/`. Keep the env file outside Git; it is the only copy of the
administrator secret. Service account credentials expire after 365 days at
most; rerun the script before that to replace them.

### 3. Create the providers (script)

`scripts/create-providers.sh` creates or updates the three providers with
the administrator credentials. It prompts for the GitHub token and the Jira
email and API token without echo, and reads the Vertex AI credentials from
the local gcloud Application Default Credentials:

```bash
gcloud auth application-default login
make create-pr-review-providers \
  PR_REVIEW_ADMIN_ENV_FILE=<path-outside-git>/hyperfleet-review-admin.env
```

The GitHub token belongs to the review account (a bot or a user that is a
member of the organization). `--skip-vertex`, `--skip-github`, and
`--skip-jira` limit a run to the providers that changed; the Vertex provider
is recreated on each run so its refresh material is current. To run without
JIRA validation, pass `--skip-jira` and install the chart with
`--set providers.jira=""`.

#### Manual equivalent

The scripts wrap these `hsctl` and `openshell` commands, which also work by
hand: `hsctl create gateway --name <name> --cluster-id <id> --route
'{"enabled": true}'`, `hsctl create serviceAccount --gateway-id <id> --role
openshell-user --output-file <bundle>` followed by
`scripts/create-gateway-secret.sh <bundle>`, and in a container of
`openshell.image` (see `values.yaml`) with the administrator credentials in
the environment: `openshell gateway add`, `gateway login`, `workspace member
add --role user`, `provider profile import --file openshell/<profile>.yaml`,
and `provider create --type {google-vertex-ai,hfreview-github,hfreview-jira}`.
Set `XDG_CONFIG_HOME` and `XDG_STATE_HOME` to a writable directory such as
`/tmp` inside that container, and `OPENSHELL_GATEWAY_INSECURE=true` only
for a gateway whose certificate is not trusted.

### 4. Install

```bash
make install-pr-review-agents            # all repositories in PR_REVIEW_REPOS
make install-pr-review-agent PR_REVIEW_REPO=sentinel   # one repository
```

Each release is named `pr-review-<repo>` and uses `values-<repo>.yaml`, which
sets `repository` and unique sandbox names. `PR_REVIEW_SANDBOX_SOURCE`
overrides the sandbox image for all releases.

### 5. Test one run

```bash
kubectl -n pr-review-agent create job --from=cronjob/pr-review-api manual-1
kubectl -n pr-review-agent logs -f job/manual-1
```

To limit the first run, install with `--set maxReviewsPerRun=1`.

## Add a repository

1. Add `values-<repo>.yaml` with `repository`, a unique `sandbox.namePrefix`,
   and a unique `sandbox.discoveryName`.
2. Add the write block of the repository to
   `openshell/hfreview-github-provider.yaml` and run
   `openshell provider profile update --workspace default --file <file> hfreview-github`.
   The update needs the current `resource_version`: export the profile first
   and copy that line into the file.
3. Create the labels `hf-review/approved` and `hf-review/changes-requested`
   in the repository.
4. Add the repository to `PR_REVIEW_REPOS` in the Makefile and run
   `make install-pr-review-agent PR_REVIEW_REPO=<repo>`.

The label names are in `files/review.sh`, `files/policy.yaml`, and the GitHub
provider profile.

## Items to verify on the first deployment

These items have no test yet:

- The cluster of the gateway must be able to pull the sandbox image.
- A gateway exposed by an OpenShift Route in passthrough mode presents the
  gateway's own `openshell-ca` certificate. Set `gateway.insecure: true` for
  such a gateway (hyp2 on hypc-ibm-02 is one).
- The sandbox proxy of OpenShell 0.1.x drops connections now and then
  (`EOF`). `files/gh-retry.sh` is uploaded as a `gh` wrapper that retries
  transport errors for every call except `POST`; the scripts also wait for
  three successful probes before the first call.
- Direct Vertex AI mode: the name of the token variable that the Vertex
  provider injects depends on the credential type. `files/review.sh` accepts
  the ADC and service-account variants of the builtin profile.
- `files/review.sh` splits `JIRA_BASIC_AUTH` into the jira-cli login and token.
  This works only if the sandbox receives the real credential value and not a
  placeholder that the gateway replaces.
- jira-cli must work with the Atlassian API gateway URL as its server, and
  with only the two `issue` paths that the policy permits.

## Tests

`tests/run-status.sh` runs `review.sh`, `discover.sh`, and `history.sh` in a
container with mock `gh`, `git`, and `claude` commands. It needs podman.

```bash
helm/pr-review-agent/tests/run-status.sh
```

The test checks the clone steps, the wrapper prompt, the status comment, the
verdict labels, retries, and the repair path. It does not contact GitHub, a
gateway, or a model.

## Source

`files/run.sh`, `discover.sh`, `review.sh`, `history.sh`, and
`agent-runtime.sh` come from
`clusters/hysh-ibm-01/apps/{amber-review,_agent-base}` of
`openshift-online/hypershell-gitops`. Port upstream fixes by hand.
