# kind-scripts


https://kind.sigs.k8s.io/

## Installing Kind

https://kind.sigs.k8s.io/docs/user/quick-start/

## 1 master and 3 worker with AZ labels

```shell
cd 3node
./create-cluster.sh

or

./create-cluster.sh v1.37.0 cluster
```

## S3 Enabled 3 Workers- RustFS

```shell
cd s3
./create-cluster.sh

or

./create-cluster.sh v1.37.0 s3-cluster
```

WEB UI on

```shell
http://localhost:9001
user : myadminuser
password: myadminpassword
```

CLI Access with AWS CLI

```shell
export AWS_ACCESS_KEY_ID=myadminuser
export AWS_SECRET_ACCESS_KEY=myadminpassword
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