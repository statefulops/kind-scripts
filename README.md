# kind-scripts


https://kind.sigs.k8s.io/

## Installing Kind

https://kind.sigs.k8s.io/docs/user/quick-start/

## A note on `curl | bash`

Each script below can be run with a single curl piped straight into `bash`. Piping an unread script into your shell is convenient but means you're trusting the remote content sight unseen. For safety, prefer downloading the script, reading it, then running it:

```shell
curl -fsSL https://raw.githubusercontent.com/statefulops/kind-scripts/main/3node/create-cluster.sh -o create-cluster.sh
less create-cluster.sh
chmod +x create-cluster.sh
./create-cluster.sh
```

## 1 master and 3 worker with AZ labels

```shell
cd 3node
./create-cluster.sh

or

./create-cluster.sh v1.37.0 cluster
```

Or run it directly with a single curl (script is self-contained, no other files needed):

```shell
curl -fsSL https://raw.githubusercontent.com/statefulops/kind-scripts/main/3node/create-cluster.sh | bash

or with args (note the -s --)

curl -fsSL https://raw.githubusercontent.com/statefulops/kind-scripts/main/3node/create-cluster.sh | bash -s -- v1.37.0 cluster
```

## S3 Enabled 3 Workers- RustFS

```shell
cd s3
./create-cluster.sh

or

./create-cluster.sh v1.37.0 s3-cluster
```

Or run it directly with a single curl (script is self-contained, no other files needed):

```shell
curl -fsSL https://raw.githubusercontent.com/statefulops/kind-scripts/main/s3/create-cluster.sh | bash

or with args (note the -s --)

curl -fsSL https://raw.githubusercontent.com/statefulops/kind-scripts/main/s3/create-cluster.sh | bash -s -- v1.37.0 s3-cluster
```

WEB UI on

```shell
http://localhost:9001
user : myadminuser
password: (randomly generated per run, see below)
```

The password is generated fresh on each run and stored in a Kubernetes secret named
`rustfs-admin-credentials` in the `rustfs` namespace. Retrieve it with:

```shell
kubectl get secret rustfs-admin-credentials -n rustfs -o jsonpath='{.data.secret-key}' | base64 -d
```

CLI Access with AWS CLI

```shell
export AWS_ACCESS_KEY_ID=myadminuser
export AWS_SECRET_ACCESS_KEY=$(kubectl get secret rustfs-admin-credentials -n rustfs -o jsonpath='{.data.secret-key}' | base64 -d)
export AWS_DEFAULT_REGION=us-east-1

aws --endpoint-url http://localhost:9000 s3 mb s3://my-kind-bucket

aws --endpoint-url http://localhost:9000 s3 ls
```


## NFS Enabled 3 Workers

```shell
cd nfs
./create-cluster.sh

or

./create-cluster.sh v1.37.0 s3-cluster
```

Or run it directly with a single curl (script is self-contained, no other files needed):

```shell
curl -fsSL https://raw.githubusercontent.com/statefulops/kind-scripts/main/nfs/create-cluster.sh | bash

or with args (note the -s --)

curl -fsSL https://raw.githubusercontent.com/statefulops/kind-scripts/main/nfs/create-cluster.sh | bash -s -- v1.37.0 nfs-cluster
```

For more info : https://github.com/kubernetes-sigs/nfs-ganesha-server-and-external-provisioner/blob/master/charts/nfs-server-provisioner/README.md
## Testing

Unit tests replace kind, helm, kubectl, aws and openssl with stub commands, so they need nothing installed and run in a few seconds:

```shell
tests/unit.sh
```

End-to-end tests create a real cluster with one script, check it works (nodes and zone labels, an S3 round trip, an NFS volume), then delete it. They need Docker and the script's tools. The cluster is named `e2e-<script>`. Run them one at a time, because the nfs and s3 clusters use the same host ports:

```shell
tests/e2e.sh 3node
tests/e2e.sh s3
KEEP_CLUSTER=1 tests/e2e.sh nfs   # leave the cluster running afterwards
```

GitHub Actions ([.github/workflows/test.yml](.github/workflows/test.yml)) runs ShellCheck, runs the unit tests on Ubuntu and macOS, and runs the end-to-end test for every script on Ubuntu.
