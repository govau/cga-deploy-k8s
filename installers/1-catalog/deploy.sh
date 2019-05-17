#!/bin/bash

set -eu
set -o pipefail

: "${ENV_NAME:?Need to set ENV_NAME}"
: "${HELM_HOST:?Need to set HELM_HOST}"
: "${JUMPBOX:?Need to set JUMPBOX}"

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

ETCD_AWS_SECRET_NAME=catalog-etcd-operator-aws
ETCD_BACKUP_BUCKET="$(ssh ${JUMPBOX} sdget catalog.k8s.cld.internal etcd-backup-bucket)"

SERVICE_CATALOG_VERSION="$(cat "${SCRIPT_DIR}/../../../service-catalog/tag")"

helm dependency update charts/stable/etcd-operator

if ! kubectl get namespace catalog > /dev/null 2>&1 ; then
    echo "Creating catalog namespace"
    kubectl create namespace catalog
fi

echo "Creating aws-secrets for etcd-operator backups if necessary"
if [[ ! $(kubectl -n catalog get secret "${ETCD_AWS_SECRET_NAME}" 2>/dev/null) ]]; then
  IAM_USER="catalog-etcd-operator" # todo could read this from the env instead of hardcoded?
  export AWS_PROFILE="${ENV_NAME}-cld"
  key_count=$(aws iam list-access-keys --user-name "${IAM_USER}" | jq '.AccessKeyMetadata | length')
  if [[ $key_count > 1 ]]; then
      oldest_key_id=$(aws iam list-access-keys --user-name "${IAM_USER}" | jq -r '.AccessKeyMetadata |= sort_by(.CreateDate) | .AccessKeyMetadata | first | .AccessKeyId')
      aws iam delete-access-key --user-name "${IAM_USER}" --access-key-id "${oldest_key_id}"
  fi

  output="$(aws iam create-access-key --user-name "${IAM_USER}")"
  aws_access_key_id="$(echo $output | jq -r .AccessKey.AccessKeyId)"
  aws_secret_access_key="$(echo $output | jq -r .AccessKey.SecretAccessKey)"

  cat << EOF > credentials
[default]
aws_access_key_id = ${aws_access_key_id}
aws_secret_access_key = ${aws_secret_access_key}
region = ap-southeast-2
EOF

  kubectl -n catalog create secret generic "${ETCD_AWS_SECRET_NAME}" \
        --from-file credentials --dry-run -o yaml | kubectl apply -f -

  rm credentials
  unset AWS_PROFILE
fi

cat << EOF > etcd-values.yml
deployments:
  # restore only needs to be deployed when
  # a restore is needed
  restoreOperator: false
customResources:
  createBackupCRD: true

  # The chart cluster does not seem to support podAntiAffinity, so we
  # we will create our own below
  createEtcdClusterCRD: false

backupOperator:
  image:
    tag: v0.9.4 # required for periodic backups
  spec:
    etcdEndpoints:
    - http://etcd-cluster-client:2379
    storageType: S3
    backupPolicy:
      # 0 > enable periodic backup
      backupIntervalInSecond: 125
      maxBackups: 4
    s3:
      # The format of "path" must be: "<s3-bucket-name>/<path-to-backup-file>"
      # e.g: "mybucket/etcd.backup"
      # s3Bucket: "${ETCD_BACKUP_BUCKET}"
      path: "${ETCD_BACKUP_BUCKET}/etcd.backup"
      awsSecret: "${ETCD_AWS_SECRET_NAME}"
etcdOperator:
  image:
    tag: v0.9.4 # required for periodic backups
  resources:
    # Increased to avoid CPUThrottlingHigh alert
    cpu: 200m
restoreOperator:
  image:
    tag: v0.9.4 # required for periodic backups
EOF

echo "Deploying etcd-operator (needed by Service Catalog)"
helm upgrade --install --wait --force \
    --namespace catalog \
    -f etcd-values.yml \
    catalog-etcd-operator charts/stable/etcd-operator

echo "Waiting for etcd-operator to start"
kubectl rollout status --namespace=catalog --timeout=2m \
        --watch deployment/catalog-etcd-operator-etcd-operator-etcd-operator

kubectl -n catalog apply -f <(cat <<EOF
apiVersion: etcd.database.coreos.com/v1beta2
kind: EtcdCluster
metadata:
  name: etcd-cluster
spec:
  size: 3
  pod:
    affinity:
      podAntiAffinity:
        preferredDuringSchedulingIgnoredDuringExecution:
        - weight: 100
          podAffinityTerm:
            labelSelector:
              matchExpressions:
              - key: etcd_cluster
                operator: In
                values:
                - etcd-cluster
            topologyKey: failure-domain.beta.kubernetes.io/zone
        requiredDuringSchedulingIgnoredDuringExecution:
        - labelSelector:
          matchExpressions:
          - key: etcd_cluster
            operator: In
            values:
            - etcd-cluster
          topologyKey: kubernetes.io/hostname
EOF
)

kubectl -n catalog wait --for=condition=Available --timeout=2m "EtcdCluster/etcd-cluster"

# Add a poddisruptionbudget on the etcd cluster pods to
# maintain quorum
kubectl -n catalog apply -f <(cat <<EOF
apiVersion: policy/v1beta1
kind: PodDisruptionBudget
metadata:
  name: etcd-cluster
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app: etcd
      etcd_cluster: etcd-cluster
EOF
)

echo "Deploying Service Catalog (needed by AWS servicebroker)"
helm repo add svc-cat https://svc-catalog-charts.storage.googleapis.com
helm upgrade --install --wait \
    --namespace catalog \
    --version "${SERVICE_CATALOG_VERSION}" \
    -f ${SCRIPT_DIR}/catalog-values.yml \
    catalog svc-cat/catalog

echo "Waiting for all catalog deployments to start"
DEPLOYMENTS="$(kubectl -n catalog get deployments -o json | jq -r .items[].metadata.name)"
for DEPLOYMENT in $DEPLOYMENTS; do
    kubectl rollout status --namespace=catalog --timeout=2m \
        --watch deployment/${DEPLOYMENT}
done
