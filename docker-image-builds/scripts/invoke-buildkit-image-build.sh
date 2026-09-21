#!/usr/bin/env bash
set -euo pipefail

image_name="spring-petclinic:optimized-dockerfile"
dockerfile="docker-image-builds/Dockerfile"
context="."
cache_ref=""
push=false
load=true

usage() {
  cat <<'USAGE'
Usage:
  invoke-buildkit-image-build.sh [options]

Options:
  --image <name>       Image name and tag. Default: spring-petclinic:optimized-dockerfile
  --dockerfile <path>  Dockerfile path. Default: docker-image-builds/Dockerfile
  --context <path>     Build context. Default: .
  --cache-ref <ref>    Registry cache reference, for example registry.example.ru/petclinic:buildcache
  --push              Push the image and registry cache.
  --no-load           Do not load the image into the local Docker daemon.
  -h, --help          Show this help.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image)
      image_name="$2"
      shift 2
      ;;
    --dockerfile)
      dockerfile="$2"
      shift 2
      ;;
    --context)
      context="$2"
      shift 2
      ;;
    --cache-ref)
      cache_ref="$2"
      shift 2
      ;;
    --push)
      push=true
      load=false
      shift
      ;;
    --no-load)
      load=false
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

cmd=(docker buildx build --file "$dockerfile" --tag "$image_name")

if [[ -n "$cache_ref" ]]; then
  cmd+=(--cache-from "type=registry,ref=$cache_ref")
  cmd+=(--cache-to "type=registry,ref=$cache_ref,mode=max")
fi

if [[ "$push" == true ]]; then
  cmd+=(--push)
elif [[ "$load" == true ]]; then
  cmd+=(--load)
fi

cmd+=("$context")

printf '%q ' "${cmd[@]}"
echo
"${cmd[@]}"
