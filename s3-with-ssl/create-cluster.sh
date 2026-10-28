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

CONFIG_FILE="$(mktemp -t kind-s3-XXXXXX.yaml)"
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



RUSTFS_NAMESPACE="rustfs"
RUSTFS_SECRET_NAME="rustfs-admin-credentials"
ADMIN_USER="myadminuser"
ADMIN_PASSWORD="$(openssl rand -base64 24)"

kubectl create namespace "${RUSTFS_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic "${RUSTFS_SECRET_NAME}" \
  --namespace "${RUSTFS_NAMESPACE}" \
  --from-literal=access-key="${ADMIN_USER}" \
  --from-literal=secret-key="${ADMIN_PASSWORD}" \
  --dry-run=client -o yaml | kubectl apply -f -

helm repo add rustfs https://charts.rustfs.com
helm repo update

helm install rustfs rustfs/rustfs \
  --namespace "${RUSTFS_NAMESPACE}" \
  --create-namespace \
  --set mode.standalone.enabled=true \
  --set mode.distributed.enabled=false \
  --set secret.rustfs.access_key="${ADMIN_USER}" \
  --set secret.rustfs.secret_key="${ADMIN_PASSWORD}" \
  --set storageclass.name=standard \
  --set storageclass.dataStorageSize=10Gi \
  --set service.type=NodePort \
  --set service.endpoint.nodePort=30090 \
  --set service.console.nodePort=30091 \
  --set service.s3=null

kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=rustfs  --timeout=2m -n "${RUSTFS_NAMESPACE}"


# Enable TLS on the local rustfs pod so pgBackRest can use it as an S3 repo.
#
# pgBackRest ALWAYS speaks TLS to an S3 endpoint -- there is no plaintext-HTTP
# option -- so a stock rustfs listening on http://:9000 can never be a repo.
# This mints a self-signed cert for the in-cluster service name and turns on
# RUSTFS_TLS_PATH. Pair it with these pgBackRest options in the cluster CR:
#
#   backups.pgbackrest.global:
#     repo2-s3-uri-style: path        # rustfs have no bucket.* vhost DNS
#     repo2-storage-verify-tls: "n"   # cert below is self-signed
#

NS=rustfs
SVC=rustfs-svc

case "$(kubectl config current-context)" in
  *kind*) ;;
  *) echo "ABORT: context '$(kubectl config current-context)' is not a kind cluster" >&2; exit 1 ;;
esac

CLUSTER_IP=$(kubectl get svc "$SVC" -n "$NS" -o jsonpath='{.spec.clusterIP}')
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/san.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = ${SVC}.${NS}.svc.cluster.local
[v3]
subjectAltName = @alt
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
[alt]
DNS.1 = ${SVC}.${NS}.svc.cluster.local
DNS.2 = ${SVC}.${NS}.svc
DNS.3 = ${SVC}.${NS}
DNS.4 = ${SVC}
DNS.5 = localhost
IP.1 = 127.0.0.1
IP.2 = ${CLUSTER_IP}
EOF

# rustfs looks for exactly these filenames in RUSTFS_TLS_PATH.
# Verify with: rustfs tls inspect --path /tls
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$WORK/rustfs_key.pem" -out "$WORK/rustfs_cert.pem" \
  -config "$WORK/san.cnf" 2>/dev/null

kubectl create secret generic rustfs-tls -n "$NS" \
  --from-file=rustfs_cert.pem="$WORK/rustfs_cert.pem" \
  --from-file=rustfs_key.pem="$WORK/rustfs_key.pem" \
  --dry-run=client -o yaml | kubectl apply -f -

# The stock chart probes /health over plain HTTP; flip both probes to HTTPS or
# the pod never goes ready once TLS is on.
kubectl patch deploy rustfs -n "$NS" --type=strategic -p '
spec:
  template:
    spec:
      volumes:
      - name: tls
        secret:
          secretName: rustfs-tls
      containers:
      - name: rustfs
        env:
        - name: RUSTFS_TLS_PATH
          value: /tls
        volumeMounts:
        - name: tls
          mountPath: /tls
          readOnly: true
        livenessProbe:
          httpGet: {path: /health, port: 9000, scheme: HTTPS}
        readinessProbe:
          httpGet: {path: /health, port: 9000, scheme: HTTPS}
'

kubectl rollout status deploy/rustfs -n "$NS" --timeout=180s
echo "rustfs now serving HTTPS on ${SVC}.${NS}.svc.cluster.local:9000"



export AWS_ACCESS_KEY_ID="${ADMIN_USER}"
export AWS_SECRET_ACCESS_KEY="${ADMIN_PASSWORD}"
export AWS_DEFAULT_REGION=us-east-1

aws --no-verify-ssl --endpoint-url https://localhost:9000 s3 mb s3://my-kind-bucket


aws --no-verify-ssl --endpoint-url https://localhost:9000 s3 ls

echo
echo "RustFS admin credentials stored in Kubernetes secret '${RUSTFS_SECRET_NAME}' (namespace: ${RUSTFS_NAMESPACE})"
echo "Retrieve the password later with:"
echo "  kubectl get secret ${RUSTFS_SECRET_NAME} -n ${RUSTFS_NAMESPACE} -o jsonpath='{.data.secret-key}' | base64 -d"
