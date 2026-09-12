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

CONFIG_FILE="$(mktemp -t kind-nfs-XXXXXX.yaml)"
trap 'rm -f "${CONFIG_FILE}"' EXIT

cat > "${CONFIG_FILE}" <<'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  extraPortMappings:
  - containerPort: 30090
    hostPort: 9000
    protocol: TCP
  - containerPort: 30091
    hostPort: 9001
    protocol: TCP
- role: worker
  kubeadmConfigPatches:
  - |
    kind: JoinConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "topology.kubernetes.io/zone=AZ-A"
- role: worker
  kubeadmConfigPatches:
  - |
    kind: JoinConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "topology.kubernetes.io/zone=AZ-B"
- role: worker
  kubeadmConfigPatches:
  - |
    kind: JoinConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "topology.kubernetes.io/zone=AZ-C"
EOF

args=(
  --config "${CONFIG_FILE}"
  --image "kindest/node:${K8S_VERSION}"
)

if [ -n "$CLUSTER_NAME" ]; then
  args+=(--name "$CLUSTER_NAME")
fi

kind create cluster "${args[@]}"


helm repo add nfs-ganesha-server-and-external-provisioner https://kubernetes-sigs.github.io/nfs-ganesha-server-and-external-provisioner/
helm install my-release nfs-ganesha-server-and-external-provisioner/nfs-server-provisioner
