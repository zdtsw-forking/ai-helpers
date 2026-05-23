#!/usr/bin/env bash
set -euo pipefail

# Generate a KServe component_metadata.yaml snippet for a component's images.
# Queries quay.io for actual image digests and outputs YAML to stdout.

usage() {
    echo "Usage: $0 --images img1,img2,... --org QUAY_ORG --tag TAG --component COMPONENT_NAME" >&2
    exit 2
}

IMAGES=""
ORG=""
TAG=""
COMPONENT=""

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
        --component)
            COMPONENT="$2"
            shift 2
            ;;
        *)
            usage
            ;;
    esac
done

if [[ -z "${IMAGES}" || -z "${ORG}" || -z "${TAG}" || -z "${COMPONENT}" ]]; then
    usage
fi

echo "# KServe component_metadata snippet for: ${COMPONENT}"
echo "# Generated at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "# Tag: ${TAG}"
echo "#"
echo "# Merge this into config/component_metadata.yaml in opendatahub-io/kserve"
echo ""

IFS=',' read -ra IMAGE_LIST <<< "${IMAGES}"
for IMAGE in "${IMAGE_LIST[@]}"; do
    IMAGE=$(echo "${IMAGE}" | xargs)
    FULL_REF="docker://quay.io/${ORG}/${IMAGE}:${TAG}"

    if INSPECT_OUTPUT=$(skopeo inspect "${FULL_REF}" 2>/dev/null); then
        DIGEST=$(echo "${INSPECT_OUTPUT}" | jq -r '.Digest // empty')
        if [[ -n "${DIGEST}" ]]; then
            echo "${IMAGE}:"
            echo "  tag: \"${TAG}\""
            echo "  digest: \"${DIGEST}\""
            echo "  image: \"quay.io/${ORG}/${IMAGE}\""
            echo ""
        else
            echo "# WARNING: ${IMAGE} — tag ${TAG} found but digest unavailable" >&2
            echo "${IMAGE}:"
            echo "  tag: \"${TAG}\""
            echo "  digest: \"\"  # FIXME: digest unavailable, inspect manually"
            echo "  image: \"quay.io/${ORG}/${IMAGE}\""
            echo ""
        fi
    else
        echo "# ERROR: ${IMAGE} — tag ${TAG} not found in quay.io/${ORG}" >&2
        echo "# ${IMAGE}: MISSING — run verify-quay-images.sh first"
        echo ""
    fi
done
