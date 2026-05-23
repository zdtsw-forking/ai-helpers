---
name: odh-release
description: >-
  Automate per-component ODH release steps on code freeze day: create release
  branch, run Konflux release onboarder GitHub Action, verify Quay images, and
  generate KServe component_metadata snippet. Use when asked to cut an ODH
  release, run release steps, or prepare a component for ODH code freeze.
argument-hint: "<component-name> --version <vX.Y.Z> [--dry-run] [--step N]"
user-invocable: true
allowed-tools: Bash Read WebFetch
compatibility: Requires gh CLI (authenticated to opendatahub-io), yq, jq, skopeo, bash
metadata:
  author: ODH
  version: "1.0"
  tags: release, odh, konflux, llm-d, quay
---

# ODH Release — Per-Component Code Freeze Steps

This skill automates the per-component steps that run on ODH code freeze Friday.
It covers 4 sequential steps for a single component, with interactive checkpoints
before any action that creates external side effects.

## Prerequisites

Before starting, verify the required tools are available:

```bash
gh auth status 2>&1 | head -5
command -v yq >/dev/null && echo "yq: ok" || echo "yq: MISSING"
command -v jq >/dev/null && echo "jq: ok" || echo "jq: MISSING"
command -v skopeo >/dev/null && echo "skopeo: ok" || echo "skopeo: MISSING"
```

If any tool is missing, tell the user what to install and stop:
- `gh`: `dnf install gh` or `brew install gh`, then `gh auth login`
- `yq`: `dnf install yq` or `brew install yq`
- `jq`: `dnf install jq` or `brew install jq`
- `skopeo`: `dnf install skopeo` or `brew install skopeo`

## Step 0: Parse Arguments and Load Config

Parse `$ARGUMENTS` to extract:
- **component name** (required): one of `inference-router`, `kv-cache`, `workload-variant-autoscaler`, `batch-gateway`
- **--version vX.Y.Z** (required): the upstream release version tag
- **--dry-run** (optional): report what would happen without making changes
- **--step N** (optional): resume from step N (1-4), skipping earlier steps

If the component name or version is missing, prompt the user interactively. Show the
list of valid component names from the config.

Validate the version matches the pattern `^v[0-9]+\.[0-9]+\.[0-9]+(-ea[0-9]*)?$`.

Load the component config:

```bash
SKILL_DIR="${CLAUDE_SKILL_DIR:-$(dirname "$0")/..}"
CONFIG="${SKILL_DIR}/references/components.yaml"
COMPONENT="<parsed-component-name>"
VERSION="<parsed-version>"
RELEASE_BRANCH="release-${VERSION}"

ODH_ORG=$(yq ".components.\"${COMPONENT}\".odh.org" "${CONFIG}")
ODH_REPO=$(yq ".components.\"${COMPONENT}\".odh.repo" "${CONFIG}")
ODH_DEFAULT_BRANCH=$(yq ".components.\"${COMPONENT}\".odh.default_branch" "${CONFIG}")
KONFLUX_CENTRAL=$(yq ".components.\"${COMPONENT}\".konflux.central_repo" "${CONFIG}")
ONBOARDER_WORKFLOW=$(yq ".components.\"${COMPONENT}\".konflux.onboarder_workflow" "${CONFIG}")
```

Verify the component exists in the config (the yq output should not be `null`). If
it does not exist, show valid component names and stop.

Print a summary of what will be done:

```
Component:      <component-name>
Version:        <vX.Y.Z>
Release branch: release-<vX.Y.Z>
ODH repo:       <org>/<repo>
Mode:           <normal|dry-run>
Starting step:  <1|N>
```

## Step 1: Create Release Branch

**Goal**: Create branch `release-vX.Y.Z` from ODH main on the component's ODH repo.

First, check if the branch already exists:

```bash
bash "${SKILL_DIR}/scripts/check-release-branch.sh" \
  --repo "${ODH_ORG}/${ODH_REPO}" \
  --branch "${RELEASE_BRANCH}"
```

- If exit code 0: the branch exists. Report `Step 1: SKIPPED — branch already exists` and proceed to step 2.
- If exit code 1: the branch does not exist. Continue below.

**Checkpoint** — Tell the user:

> I will create branch `release-vX.Y.Z` from `main` on `{ODH_ORG}/{ODH_REPO}`.
> This is a visible action on the GitHub repository. Proceed?

Wait for user confirmation. If `--dry-run`, report what would happen and skip.

Create the branch:

```bash
SHA=$(gh api "repos/${ODH_ORG}/${ODH_REPO}/git/ref/heads/${ODH_DEFAULT_BRANCH}" --jq '.object.sha')
gh api "repos/${ODH_ORG}/${ODH_REPO}/git/refs" \
  -f ref="refs/heads/${RELEASE_BRANCH}" \
  -f sha="${SHA}"
```

Verify the branch was created:

```bash
gh api "repos/${ODH_ORG}/${ODH_REPO}/branches/${RELEASE_BRANCH}" --jq '.name'
```

Report `Step 1: DONE — branch release-vX.Y.Z created from main (SHA: <short-sha>)`.

## Step 2: Run Konflux Release Onboarder

**Goal**: Trigger the `odh-konflux-release-onboarder.yml` GitHub Action to generate
a new Konflux pipeline for the release branch.

The onboarder must be run once per Konflux component (some ODH repos produce
multiple images). Read the component list from config:

```bash
KONFLUX_COMPONENTS=$(yq -r ".components.\"${COMPONENT}\".konflux.components[]" "${CONFIG}")
```

For each Konflux component, prepare the workflow inputs:

- **Repository name**: The Konflux component name (e.g., `batch-gateway-apiserver`)
- **Branch to open PR against**: `release-vX.Y.Z`
- **Branch images are built from**: `release-vX.Y.Z`
- **Release type**: `Release`
- **New version**: `vX.Y.Z`

**Checkpoint** — Show the user the exact workflow inputs for each Konflux component:

> I will trigger the Konflux release onboarder on `{KONFLUX_CENTRAL}` with these inputs:
>
> | Input | Value |
> |-------|-------|
> | Repository name | `<konflux-component>` |
> | Branch to open PR against | `release-vX.Y.Z` |
> | Branch images built from | `release-vX.Y.Z` |
> | Release type | `Release` |
> | New version | `vX.Y.Z` |
>
> This will create a Konflux pipeline and trigger image builds. Proceed?

Wait for user confirmation. If `--dry-run`, report what would happen and skip.

For each Konflux component, trigger the workflow:

```bash
gh workflow run "${ONBOARDER_WORKFLOW}" \
  --repo "${KONFLUX_CENTRAL}" \
  -f "repository_name=<konflux-component>" \
  -f "branch=release-${VERSION}" \
  -f "image_branch=release-${VERSION}" \
  -f "release_type=Release" \
  -f "version=${VERSION}"
```

After triggering, wait a few seconds then find the workflow run:

```bash
gh run list \
  --repo "${KONFLUX_CENTRAL}" \
  --workflow "${ONBOARDER_WORKFLOW}" \
  --limit 5 \
  --json databaseId,status,conclusion,createdAt,headBranch
```

Report the run URL and status. If the user wants to wait for completion, use:

```bash
gh run watch <run-id> --repo "${KONFLUX_CENTRAL}"
```

Report `Step 2: DONE — onboarder triggered for N Konflux component(s)`.

**Note**: The workflow inputs may vary. If `gh workflow run` fails with an input
validation error, show the actual workflow inputs by running:

```bash
gh workflow view "${ONBOARDER_WORKFLOW}" --repo "${KONFLUX_CENTRAL}" --yaml | head -40
```

Then adjust the input field names accordingly and retry.

## Step 3: Verify Quay Images

**Goal**: Verify that images have been built in `quay.io/opendatahub` with the
expected release tag.

Read the expected images from config:

```bash
QUAY_ORG=$(yq -r ".components.\"${COMPONENT}\".quay.org" "${CONFIG}")
QUAY_IMAGES=$(yq -r ".components.\"${COMPONENT}\".quay.images[]" "${CONFIG}")
IMAGE_LIST=$(echo "${QUAY_IMAGES}" | paste -sd, -)
```

Run the verification script:

```bash
bash "${SKILL_DIR}/scripts/verify-quay-images.sh" \
  --images "${IMAGE_LIST}" \
  --org "${QUAY_ORG}" \
  --tag "${VERSION}"
```

The script checks each image using `skopeo inspect` and outputs a JSON report.

If all images are found, report `Step 3: DONE — all images verified in quay.io`.

If any images are missing, report which ones are missing and suggest:

> Some images are not yet available. This is expected if the Konflux pipeline is
> still running. You can re-run this step later with:
> `/odh-release <component> --version <version> --step 3`

## Step 4: Generate KServe Component Metadata Snippet

**Goal**: Generate the YAML snippet for KServe's `config/component_metadata.yaml`
that corresponds to this component's release images.

Read KServe config:

```bash
KSERVE_REPO=$(yq -r ".kserve.metadata_repo" "${CONFIG}")
KSERVE_FILE=$(yq -r ".kserve.metadata_file" "${CONFIG}")
KSERVE_BRANCH=$(yq -r ".kserve.metadata_branch" "${CONFIG}")
```

First, fetch the current component_metadata.yaml to understand the existing format.
Use `gh` to download the raw file content directly:

```bash
gh api "repos/${KSERVE_REPO}/contents/${KSERVE_FILE}?ref=${KSERVE_BRANCH}" \
  -H "Accept: application/vnd.github.raw+json"
```

Then generate the snippet for this component using the verified Quay images:

```bash
bash "${SKILL_DIR}/scripts/generate-kserve-snippet.sh" \
  --images "${IMAGE_LIST}" \
  --org "${QUAY_ORG}" \
  --tag "${VERSION}" \
  --component "${COMPONENT}"
```

The script outputs the YAML snippet to stdout. Present it to the user:

> Here is the KServe component_metadata.yaml snippet for `<component>`:
>
> ```yaml
> <snippet output>
> ```
>
> Save this snippet. Once all components are processed, combine the snippets
> into a single PR against `{KSERVE_REPO}` (branch: `{KSERVE_BRANCH}`).

Report `Step 4: DONE — KServe metadata snippet generated`.

## Final: Status Summary

Print a summary table:

```
ODH Release — <component> <version>
════════════════════════════════════════════════════
Step 1: Create release branch     [DONE|SKIPPED|PENDING]
Step 2: Run Konflux onboarder     [DONE|SKIPPED|PENDING]
Step 3: Verify Quay images        [DONE|MISSING|PENDING]
Step 4: KServe metadata snippet   [DONE|PENDING]
════════════════════════════════════════════════════
```

If any steps are pending or have issues, summarize the next actions the user
should take.

## Error Handling

- **gh auth failure**: Tell the user to run `gh auth login` and ensure they have
  access to the `opendatahub-io` GitHub org.
- **Version format invalid**: Show the expected format `vX.Y.Z` or `vX.Y.Z-eaN`.
- **Component not found**: List valid component names from the config.
- **Workflow dispatch failure**: Show the error, suggest checking the workflow
  definition with `gh workflow view`, and provide the workflow URL.
- **Image not found**: Report which images are missing, explain this may be
  a timing issue (pipeline still running), and suggest `--step 3` to retry.
- **Network timeout**: Report the failure and suggest retry with `--step N`.
