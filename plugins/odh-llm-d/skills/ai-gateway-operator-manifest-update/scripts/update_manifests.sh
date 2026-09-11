#!/usr/bin/env bash
set -euo pipefail

REPO=""
UPSTREAM_REPO="https://github.com/opendatahub-io/llm-d-batch-gateway-operator.git"
UPSTREAM_REF="refs/heads/main"

usage() {
    echo "Usage: $0 [--repo PATH]" >&2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo)
            [[ $# -ge 2 ]] || { usage; exit 2; }
            REPO="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage
            exit 2
            ;;
    esac
done

if [[ -z "$REPO" ]]; then
    REPO="$(git rev-parse --show-toplevel 2>/dev/null)" || {
        echo "ERROR: run from a Git checkout or pass --repo PATH" >&2
        exit 1
    }
fi

SCRIPT="$REPO/hack/scripts/get-manifests.sh"
[[ -d "$REPO/.git" ]] || { echo "ERROR: not a Git checkout: $REPO" >&2; exit 1; }
[[ -f "$SCRIPT" ]] || { echo "ERROR: missing $SCRIPT" >&2; exit 1; }

current_sha="$(
    sed -nE 's/^[[:space:]]*\[batchgateway\]="[^"]*\|config\|([0-9a-f]{40})(\|[0-9a-f]{40})?".*/\1/p' "$SCRIPT"
)"
[[ "$current_sha" =~ ^[0-9a-f]{40}$ ]] || {
    echo "ERROR: could not read the batchgateway SHA from $SCRIPT" >&2
    exit 1
}

latest_sha="$(git ls-remote "$UPSTREAM_REPO" "$UPSTREAM_REF" | awk 'NR == 1 { print $1 }')"
[[ "$latest_sha" =~ ^[0-9a-f]{40}$ ]] || {
    echo "ERROR: could not resolve $UPSTREAM_REPO $UPSTREAM_REF" >&2
    exit 1
}

if [[ "$current_sha" == "$latest_sha" ]]; then
    printf 'UP-TO-DATE\t%s\n' "$current_sha"
    exit 0
fi

compare_dir="$(mktemp -d -t ai-gateway-operator-compare.XXXXXXXXXX)"
trap 'rm -rf "$compare_dir"' EXIT
git -C "$compare_dir" init -q
git -C "$compare_dir" remote add origin "$UPSTREAM_REPO"
if ! git -C "$compare_dir" fetch --quiet origin "$current_sha" "$latest_sha"; then
    echo "ERROR: could not fetch the local and upstream commits for ancestry check" >&2
    exit 1
fi
if git -C "$compare_dir" merge-base --is-ancestor "$current_sha" "$latest_sha"; then
    :
else
    status=$?
    if [[ "$status" == 1 ]]; then
        printf 'NOT-NEWER\t%s\t%s\n' "$current_sha" "$latest_sha"
        exit 0
    fi
    echo "ERROR: could not determine commit ancestry" >&2
    exit "$status"
fi

if [[ -n "$(git -C "$REPO" status --porcelain)" ]]; then
    echo "ERROR: checkout has local changes; refusing to update: $REPO" >&2
    git -C "$REPO" status --short >&2
    exit 1
fi

sed -i -E "s/(^[[:space:]]*\[batchgateway\]=\"[^|]*\|config\|)[0-9a-f]{40}/\1$latest_sha/" "$SCRIPT"
make -C "$REPO" get-manifests

printf 'UPDATED\t%s\t%s\n' "$current_sha" "$latest_sha"
