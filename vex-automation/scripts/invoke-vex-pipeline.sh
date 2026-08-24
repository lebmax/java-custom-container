#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  invoke-vex-pipeline.sh [options]

Options:
  --sbom <path>          CycloneDX SBOM path. Default: ./sbom.cdx.json
  --decisions <path>     VEX triage decisions. Default: ./vex-automation/decisions.example.json
  --output-dir <path>    Output directory. Default: ./vex-automation/out
  --trivy-image <image>  Trivy container image. Default: aquasec/trivy:latest
  --product-id <id>      Override product id in generated OpenVEX.
  --skip-scan-with-vex   Do not run the validation scan with --vex.
  -h, --help             Show this help.
EOF
}

SBOM_PATH="./sbom.cdx.json"
DECISION_PATH="./vex-automation/decisions.example.json"
OUTPUT_DIR="./vex-automation/out"
TRIVY_IMAGE="aquasec/trivy:latest"
PRODUCT_ID=""
SKIP_SCAN_WITH_VEX="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sbom)
      SBOM_PATH="${2:-}"
      shift 2
      ;;
    --decisions)
      DECISION_PATH="${2:-}"
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="${2:-}"
      shift 2
      ;;
    --trivy-image)
      TRIVY_IMAGE="${2:-}"
      shift 2
      ;;
    --product-id)
      PRODUCT_ID="${2:-}"
      shift 2
      ;;
    --skip-scan-with-vex)
      SKIP_SCAN_WITH_VEX="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if ! command -v docker >/dev/null 2>&1; then
  echo "docker is required." >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required for path normalization and JSON processing." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GENERATOR="$SCRIPT_DIR/invoke-openvex-from-trivy.sh"

absolute_path() {
  python3 - "$1" <<'PY'
import os
import sys
print(os.path.abspath(sys.argv[1]))
PY
}

relative_path() {
  python3 - "$REPO_ROOT" "$1" <<'PY'
import os
import sys
print(os.path.relpath(os.path.abspath(sys.argv[2]), os.path.abspath(sys.argv[1])).replace(os.sep, "/"))
PY
}

docker_mount_path() {
  local path="$1"
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -m "$path"
  else
    printf '%s\n' "$path"
  fi
}

SBOM_ABS="$(absolute_path "$SBOM_PATH")"
DECISION_ABS="$(absolute_path "$DECISION_PATH")"
OUTPUT_ABS="$(absolute_path "$OUTPUT_DIR")"
mkdir -p "$OUTPUT_ABS"

TRIVY_SCAN_ABS="$OUTPUT_ABS/trivy-sbom-scan.json"
OPENVEX_ABS="$OUTPUT_ABS/petclinic.openvex.json"
TRIVY_SCAN_WITH_VEX_ABS="$OUTPUT_ABS/trivy-sbom-scan-with-vex.json"

SBOM_DOCKER_PATH="/work/$(relative_path "$SBOM_ABS")"
TRIVY_SCAN_DOCKER_PATH="/work/$(relative_path "$TRIVY_SCAN_ABS")"
OPENVEX_DOCKER_PATH="/work/$(relative_path "$OPENVEX_ABS")"
TRIVY_SCAN_WITH_VEX_DOCKER_PATH="/work/$(relative_path "$TRIVY_SCAN_WITH_VEX_ABS")"
DOCKER_REPO_ROOT="$(docker_mount_path "$REPO_ROOT")"

echo "Scanning SBOM with Trivy..."
docker run --rm \
  -v "$DOCKER_REPO_ROOT:/work" \
  "$TRIVY_IMAGE" sbom \
  --quiet \
  --format json \
  --output "$TRIVY_SCAN_DOCKER_PATH" \
  "$SBOM_DOCKER_PATH"

echo "Generating OpenVEX..."
GENERATOR_ARGS=(
  --trivy-json "$TRIVY_SCAN_ABS"
  --sbom "$SBOM_ABS"
  --decisions "$DECISION_ABS"
  --output "$OPENVEX_ABS"
)

if [[ -n "$PRODUCT_ID" ]]; then
  GENERATOR_ARGS+=(--product-id "$PRODUCT_ID")
fi

"$GENERATOR" "${GENERATOR_ARGS[@]}"

if [[ "$SKIP_SCAN_WITH_VEX" != "true" ]]; then
  echo "Re-scanning SBOM with generated VEX..."
  docker run --rm \
    -v "$DOCKER_REPO_ROOT:/work" \
    "$TRIVY_IMAGE" sbom \
    --quiet \
    --format json \
    --vex "$OPENVEX_DOCKER_PATH" \
    --output "$TRIVY_SCAN_WITH_VEX_DOCKER_PATH" \
    "$SBOM_DOCKER_PATH"
fi

cat <<EOF
SBOM: $SBOM_ABS
Trivy scan: $TRIVY_SCAN_ABS
OpenVEX: $OPENVEX_ABS
Trivy scan with VEX: $TRIVY_SCAN_WITH_VEX_ABS
EOF
