#!/usr/bin/env bash
# End-to-end test: create a real kind cluster with one of the scripts, check
# that it works, then delete it.
#
# Needs Docker plus the tools the script uses. The cluster is called
# e2e-<script>, and the script switches your current kubectl context to it.
# The nfs, s3 and s3-with-ssl clusters all bind host ports 9000/9001, so run
# them one at a time.
#
# Usage: tests/e2e.sh <3node|nfs|s3|s3-with-ssl> [k8s-version]
# Set KEEP_CLUSTER=1 to leave the cluster running afterwards.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAME="${1:-}"
K8S_VERSION="${2:-}"

case "$NAME" in
  3node | nfs | s3 | s3-with-ssl) ;;
  *) echo "Usage: $0 <3node|nfs|s3|s3-with-ssl> [k8s-version]" >&2; exit 2 ;;
esac

CLUSTER="e2e-${NAME}"
CONTEXT="kind-${CLUSTER}"

if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  echo "Cluster ${CLUSTER} already exists; delete it first with: kind delete cluster --name ${CLUSTER}" >&2
  exit 1
fi

cleanup() {
  local status=$?
  if [ "$status" -ne 0 ]; then
    echo "--- test failed, cluster state:" >&2
    kubectl --context "$CONTEXT" get nodes,pods,pvc -A -o wide >&2 || true
  fi
  if [ "${KEEP_CLUSTER:-}" = "1" ]; then
    echo "Leaving cluster ${CLUSTER} running (KEEP_CLUSTER=1)"
  else
    kind delete cluster --name "$CLUSTER" || true
  fi
  exit "$status"
}
trap cleanup EXIT

step() { echo; echo "==> $*"; }

step "Running ${NAME}/create-cluster.sh"
"$ROOT/$NAME/create-cluster.sh" "${K8S_VERSION:-$(sed -n 's/^DEFAULT_K8S_VERSION="\(.*\)"$/\1/p' "$ROOT/$NAME/create-cluster.sh")}" "$CLUSTER"

k() { kubectl --context "$CONTEXT" "$@"; }

step "Checking nodes"
k wait --for=condition=Ready nodes --all --timeout=180s
node_count="$(k get nodes -o name | wc -l | tr -d ' ')"
[ "$node_count" -eq 4 ] || { echo "expected 4 nodes, got ${node_count}" >&2; exit 1; }
for zone in AZ-A AZ-B AZ-C; do
  count="$(k get nodes -l "topology.kubernetes.io/zone=${zone}" -o name | wc -l | tr -d ' ')"
  [ "$count" -eq 1 ] || { echo "expected 1 node in ${zone}, got ${count}" >&2; exit 1; }
done
echo "4 nodes ready, one worker in each of AZ-A, AZ-B, AZ-C"

s3_round_trip() {
  local endpoint="$1"; shift
  export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION=us-east-1
  AWS_ACCESS_KEY_ID="$(k get secret rustfs-admin-credentials -n rustfs -o jsonpath='{.data.access-key}' | base64 --decode)"
  AWS_SECRET_ACCESS_KEY="$(k get secret rustfs-admin-credentials -n rustfs -o jsonpath='{.data.secret-key}' | base64 --decode)"

  local s3=(aws "$@" --endpoint-url "$endpoint" s3)
  "${s3[@]}" ls | grep -q "my-kind-bucket" || { echo "bucket my-kind-bucket not found" >&2; exit 1; }

  local tmp; tmp="$(mktemp -d)"
  echo "hello from e2e $(date +%s)" > "$tmp/in.txt"
  "${s3[@]}" cp "$tmp/in.txt" s3://my-kind-bucket/e2e.txt
  "${s3[@]}" cp s3://my-kind-bucket/e2e.txt "$tmp/out.txt"
  if ! cmp -s "$tmp/in.txt" "$tmp/out.txt"; then
    echo "object read back from S3 does not match what was written" >&2
    rm -rf "$tmp"
    exit 1
  fi
  rm -rf "$tmp"
  echo "bucket exists and an object round-trips through ${endpoint}"
}

case "$NAME" in
  3node) ;;

  nfs)
    step "Checking an NFS volume can be provisioned and written to"
    k apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: e2e-nfs
spec:
  storageClassName: nfs
  accessModes: [ReadWriteMany]
  resources:
    requests:
      storage: 10Mi
---
apiVersion: v1
kind: Pod
metadata:
  name: e2e-nfs-writer
spec:
  restartPolicy: Never
  containers:
  - name: writer
    image: busybox:1.36
    command: [sh, -c, "echo ok > /data/e2e.txt && cat /data/e2e.txt"]
    volumeMounts:
    - name: data
      mountPath: /data
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: e2e-nfs
EOF
    k wait --for=jsonpath='{.status.phase}'=Bound pvc/e2e-nfs --timeout=300s
    k wait --for=jsonpath='{.status.phase}'=Succeeded pod/e2e-nfs-writer --timeout=300s
    [ "$(k logs e2e-nfs-writer)" = "ok" ] || { echo "unexpected output from NFS writer pod" >&2; exit 1; }
    echo "PVC bound and pod wrote to the NFS volume"
    ;;

  s3)
    step "Checking S3 over HTTP"
    s3_round_trip http://localhost:9000
    ;;

  s3-with-ssl)
    step "Checking S3 over HTTPS"
    s3_round_trip https://localhost:9000 --no-verify-ssl
    ;;
esac

echo
echo "PASS: ${NAME}"
