#!/usr/bin/env bash
set -euo pipefail

DEFAULT_K8S_VERSION="v1.35.1"

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  echo "Usage: $0 [k8s-version] [cluster-name]" >&2
  echo "Example: $0 v1.31.0" >&2
  echo "Defaults to ${DEFAULT_K8S_VERSION} if not specified." >&2
  echo "Available versions: https://github.com/kubernetes-sigs/kind/releases (see node image tags)" >&2
  exit 1
fi

K8S_VERSION="${1:-$DEFAULT_K8S_VERSION}"
CLUSTER_NAME="${2:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

args=(
  --config "${SCRIPT_DIR}/cluster-3node.yaml"
  --image "kindest/node:${K8S_VERSION}"
)

if [ -n "$CLUSTER_NAME" ]; then
  args+=(--name "$CLUSTER_NAME")
fi

kind create cluster "${args[@]}"
