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
  --config "${SCRIPT_DIR}/cluster-s3.yaml"
  --image "kindest/node:${K8S_VERSION}"
)

if [ -n "$CLUSTER_NAME" ]; then
  args+=(--name "$CLUSTER_NAME")
fi

kind create cluster "${args[@]}"



helm repo add rustfs https://charts.rustfs.com
helm repo update

helm install rustfs rustfs/rustfs \
  --namespace rustfs \
  --create-namespace \
  --set mode.standalone.enabled=true \
  --set mode.distributed.enabled=false \
  --set secret.rustfs.access_key=myadminuser \
  --set secret.rustfs.secret_key=myadminpassword \
  --set storageclass.name=standard \
  --set storageclass.dataStorageSize=10Gi \
  --set service.type=NodePort \
  --set service.endpoint.nodePort=30090 \
  --set service.console.nodePort=30091 \
  --set service.s3=null

kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=rustfs  --timeout=2m -n rustfs 

export AWS_ACCESS_KEY_ID=myadminuser
export AWS_SECRET_ACCESS_KEY=myadminpassword
export AWS_DEFAULT_REGION=us-east-1

aws --endpoint-url http://localhost:9000 s3 mb s3://my-kind-bucket


aws --endpoint-url http://localhost:9000 s3 ls