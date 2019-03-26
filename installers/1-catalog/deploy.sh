#!/bin/bash

set -eu
set -o pipefail

: "${ENV_NAME:?Need to set ENV_NAME}"
: "${HELM_HOST:?Need to set HELM_HOST}"
: "${SSH:?Need to set SSH}"

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

helm dependency update charts/stable/etcd-operator

echo "Deploying etcd-operator (needed by Service Catalog)"
helm upgrade --install --wait \
    --namespace catalog \
    -f ${SCRIPT_DIR}/etcd-operator-values.yml \
    catalog-etcd-operator charts/stable/etcd-operator

echo "Waiting for etcd-operator to start"
kubectl rollout status --namespace=catalog --timeout=2m \
        --watch deployment/catalog-etcd-operator-etcd-operator-etcd-operator

ETCD_AWS_SECRET_NAME=catalog-etcd-operator-aws
echo "Creating aws-secrets for etcd-operator backups if necessary"
if [[ ! $(kubectl -n catalog get secret "${ETCD_AWS_SECRET_NAME}" 2>/dev/null) ]]; then
  IAM_USER="catalog-etcd-operator" # todo could read this from the env instead of hardcoded?

  output="$(aws --profile "${ENV_NAME}-cld" iam create-access-key --user-name "${IAM_USER}")"
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
fi

echo "Creating EtcdBackup resource"
ETCD_BACKUP_BUCKET="$(${SSH} sdget catalog.k8s.cld.internal etcd-backup-bucket)"

kubectl -n catalog apply -f <(cat <<EOF
apiVersion: "etcd.database.coreos.com/v1beta2"
kind: "EtcdBackup"
metadata:
  name: catalog-etcd-cluster-periodic-backup
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
    path: "${ETCD_BACKUP_BUCKET}/etcd.backup"
    awsSecret: "${ETCD_AWS_SECRET_NAME}"
EOF
)

echo "Waiting for catalog etcd-worker pods to be created"
end=$((SECONDS+180))
while :
do
  if [[ "$(kubectl -n catalog get pods -l app=etcd -l etcd_cluster=etcd-cluster --field-selector=status.phase=Running -o json | jq -r '.items | length')" == "3" ]]; then
    break;
  fi
  if (( ${SECONDS} >= end )); then
    echo "Timeout: Waiting for catalog etcd-worker pods to be created"
    exit 1
  fi
  sleep 5
done

echo "Deploying Service Catalog (needed by AWS servicebroker)"
helm repo add svc-cat https://svc-catalog-charts.storage.googleapis.com
helm upgrade --install --wait \
    --namespace catalog \
    -f ${SCRIPT_DIR}/catalog-values.yml \
    catalog svc-cat/catalog

echo "Waiting for all catalog deployments to start"
DEPLOYMENTS="$(kubectl -n catalog get deployments -o json | jq -r .items[].metadata.name)"
for DEPLOYMENT in $DEPLOYMENTS; do
    # todo can exclude etcd-operator
    kubectl rollout status --namespace=catalog --timeout=2m \
        --watch deployment/${DEPLOYMENT}
done
