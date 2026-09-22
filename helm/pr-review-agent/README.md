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
   earlier review summaries of the bot.

The pod contains no model or GitHub credentials. The gateway holds them as
OpenShell providers. The sandbox policy (`files/policy.yaml`) and the provider
profiles (`openshell/`) limit writes to the pull request feedback paths of the
reviewed repository.

## Wrapper prompt and skill changes

`review-pr` is an interactive skill. The wrapper prompt overrides its
`AskUserQuestion` flow and its rule that forbids GitHub posts without a typed
user command. Read the wrapper prompt again when the skill changes. Set
`plugins.ref` to a tag to prevent silent changes of the review instructions.

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

### 2. Create the gateway service account and the Secret

The runner logs in to the gateway with an OpenShell gateway service account
(OIDC client credentials). HyperShell returns the client secret one time.

```bash
hsctl list gateways                    # find the gateway ID
hsctl create serviceAccount \
  --gateway-id <gateway-id> \
  --name hyperfleet-pr-review \
  --description 'PR review CronJob on hyperfleet-dev-review (GKE)' \
  --role openshell-user \
  --expires-in 365d \
  --output-file /path/outside/git/pr-review-bundle.json

# With the kubectl context of this cluster:
helm/pr-review-agent/scripts/create-gateway-secret.sh \
  /path/outside/git/pr-review-bundle.json
rm /path/outside/git/pr-review-bundle.json
```

The script creates the `pr-review-gateway` Secret in the `pr-review-agent`
namespace and prints the service account subject. It does not print the client
secret. `secret.example.yaml` shows the Secret format for a manual procedure.

The credential expires after 365 days at most. HyperShell has no rotation in
place: before the expiry, create a new service account, run the script again,
add the new subject to the workspace, and delete the old service account.

### 3. Create the gateway providers

Use a gateway administrator identity. The chart uses the `default` workspace
(value `gateway.workspace`).

```bash
openshell gateway select '<administrator-gateway-name>'
openshell settings set --global --key providers_v2_enabled --value true --yes

openshell provider profile import --workspace default \
  --file helm/pr-review-agent/openshell/hfreview-github-provider.yaml
openshell provider profile import --workspace default \
  --file helm/pr-review-agent/openshell/hfreview-jira-provider.yaml

gcloud auth application-default login
openshell provider create --workspace default \
  --name hyperfleet-vertex --type google-vertex-ai --from-gcloud-adc \
  --config VERTEX_AI_PROJECT_ID=<vertex-project> \
  --config VERTEX_AI_REGION=global

read -r -s -p 'GitHub token: ' GH_TOKEN; printf '\n'; export GH_TOKEN
openshell provider create --workspace default \
  --name hfreview-github --type hfreview-github --credential GH_TOKEN
unset GH_TOKEN

read -r -s -p 'Jira email: ' JIRA_EMAIL; printf '\n'
read -r -s -p 'Jira API token: ' JIRA_API_TOKEN; printf '\n'
export JIRA_BASIC_AUTH="$JIRA_EMAIL:$JIRA_API_TOKEN"
openshell provider create --workspace default \
  --name hfreview-jira --type hfreview-jira --credential JIRA_BASIC_AUTH
unset JIRA_BASIC_AUTH JIRA_EMAIL JIRA_API_TOKEN

# The subject comes from step 2.
openshell workspace member add --workspace default \
  --subject '<service-account-subject>' --role user
```

To run without JIRA validation, skip the Jira commands and install the chart
with `--set providers.jira=""`.

If the workspace already has a Vertex provider, do not create it again. Set
`providers.claude` to its name. `claude.vertex.projectId` must be the Google
Cloud project of that provider.

The `openshell` CLI of the gateway administrator must match the gateway build
as well. For a gateway with a version suffix such as `v0.0.116-rhaiv.6`, run
the CLI from `quay.io/opendatahub/odh-openshell-cli:<tag>` in a container:

```bash
podman run --rm -it -v "$HOME/.config/openshell:/home/1000/.config/openshell" \
  quay.io/opendatahub/odh-openshell-cli:v0.0.116-rhaiv.6 --help
```

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
