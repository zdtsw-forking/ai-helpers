#!/usr/bin/env bash
set -euo pipefail

# Check if a branch exists on a GitHub repository.
# Exit 0 if the branch exists, exit 1 if it does not.

usage() {
    echo "Usage: $0 --repo ORG/REPO --branch BRANCH_NAME" >&2
    exit 2
}

REPO=""
BRANCH=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo)
            REPO="$2"
            shift 2
            ;;
        --branch)
            BRANCH="$2"
            shift 2
            ;;
        *)
            usage
            ;;
    esac
done

if [[ -z "${REPO}" || -z "${BRANCH}" ]]; then
    usage
fi

if gh api "repos/${REPO}/branches/${BRANCH}" --jq '.name' >/dev/null 2>&1; then
    echo "Branch '${BRANCH}' exists on ${REPO}" >&2
    exit 0
else
    echo "Branch '${BRANCH}' does not exist on ${REPO}" >&2
    exit 1
fi
