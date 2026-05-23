#!/usr/bin/env bash
set -euo pipefail

# Verify that container images exist in quay.io with the expected tag.
# Outputs a JSON report with per-image status.
# Exit 0 if all images found, exit 1 if any missing.

usage() {
    echo "Usage: $0 --images img1,img2,... --org QUAY_ORG --tag TAG" >&2
    exit 2
}

IMAGES=""
ORG=""
TAG=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --images)
            IMAGES="$2"
            shift 2
            ;;
        --org)
            ORG="$2"
            shift 2
            ;;
        --tag)
            TAG="$2"
            shift 2
            ;;
        *)
            usage
            ;;
    esac
done

if [[ -z "${IMAGES}" || -z "${ORG}" || -z "${TAG}" ]]; then
    usage
fi

TMPDIR=$(mktemp -d)
trap 'rm -rf "${TMPDIR}"' EXIT

RESULTS_FILE="${TMPDIR}/results.json"
echo '[]' > "${RESULTS_FILE}"

ALL_FOUND=true

IFS=',' read -ra IMAGE_LIST <<< "${IMAGES}"
for IMAGE in "${IMAGE_LIST[@]}"; do
    IMAGE=$(echo "${IMAGE}" | xargs)
    FULL_REF="docker://quay.io/${ORG}/${IMAGE}:${TAG}"

    if INSPECT_OUTPUT=$(skopeo inspect "${FULL_REF}" 2>/dev/null); then
        DIGEST=$(echo "${INSPECT_OUTPUT}" | jq -r '.Digest // "unknown"')
        CREATED=$(echo "${INSPECT_OUTPUT}" | jq -r '.Created // "unknown"')
        ENTRY=$(jq -n \
            --arg image "${IMAGE}" \
            --arg tag "${TAG}" \
            --arg digest "${DIGEST}" \
            --arg created "${CREATED}" \
            --arg status "found" \
            '{image: $image, tag: $tag, digest: $digest, created: $created, status: $status}')
    else
        ALL_FOUND=false
        ENTRY=$(jq -n \
            --arg image "${IMAGE}" \
            --arg tag "${TAG}" \
            --arg status "missing" \
            '{image: $image, tag: $tag, digest: null, created: null, status: $status}')
    fi

    UPDATED=$(jq --argjson entry "${ENTRY}" '. + [$entry]' "${RESULTS_FILE}")
    echo "${UPDATED}" > "${RESULTS_FILE}"
done

REPORT=$(jq -n \
    --arg org "${ORG}" \
    --arg tag "${TAG}" \
    --argjson all_found "${ALL_FOUND}" \
    --slurpfile results "${RESULTS_FILE}" \
    '{org: $org, tag: $tag, all_found: $all_found, images: $results[0]}')

echo "${REPORT}"

if [[ "${ALL_FOUND}" == "true" ]]; then
    exit 0
else
    exit 1
fi
