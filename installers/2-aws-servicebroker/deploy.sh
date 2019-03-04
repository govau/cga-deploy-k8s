#!/bin/bash

set -eu
set -o pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

AWS_ACCOUNT_ID="$(${SSH} sdget env.cld.internal aws-account-id)"
IAM_USER="$(${SSH} sdget awsbroker.cld.internal iamusername)"
S3_BUCKET="$(${SSH} sdget awsbroker.cld.internal templatebucket)"
TABLE_NAME="$(${SSH} sdget awsbroker.cld.internal tablename)"
VPC_ID="$(${SSH} sdget net.cld.internal vpc-id)"

echo "Deploying AWS servicebroker"

# Add the service broker chart repository
helm repo add aws-sb https://awsservicebroker.s3.amazonaws.com/charts

# Ensure secrets are set for the AWS servicebroker
kubectl apply -f <(cat <<EOF
kind: Namespace
apiVersion: v1
metadata:
  name: aws-sb
  labels:
    name: aws-sb
EOF
)

if ! kubectl --namespace aws-sb get secret installer > /dev/null 2>&1 ; then
    echo "Creating access key"
    export AWS_PROFILE="${ENV_NAME}-cld"
    key_count=$(aws iam list-access-keys --user-name "${IAM_USER}" | jq '.AccessKeyMetadata | length')
    if [[ $key_count > 1 ]]; then
        oldest_key_id=$(aws iam list-access-keys --user-name "${IAM_USER}" | jq -r '.AccessKeyMetadata |= sort_by(.CreateDate) | .AccessKeyMetadata | first | .AccessKeyId')
        aws iam delete-access-key --user-name "${IAM_USER}" --access-key-id "${oldest_key_id}"
    fi
    AWS_KEY="$(aws iam create-access-key --user-name "${IAM_USER}")"

    KEY="$(jq -r .AccessKey.AccessKeyId <(echo "${AWS_KEY}"))"
    SECRET="$(jq -r .AccessKey.SecretAccessKey <(echo "${AWS_KEY}"))"

    kubectl -n aws-sb create secret generic installer \
        --from-literal=AWS_ACCESS_KEY_ID=${KEY} \
        --from-literal=AWS_SECRET_ACCESS_KEY=${SECRET} \
        --dry-run -o yaml | kubectl apply -f -

    unset AWS_PROFILE
fi

BROKER_AWS_ACCESS_KEY_ID="$(kubectl -n aws-sb get secret installer -o yaml | yq -r .data.AWS_ACCESS_KEY_ID | base64 -d)"
BROKER_AWS_SECRET_ACCESS_KEY="$(kubectl -n aws-sb get secret installer -o yaml | yq -r .data.AWS_SECRET_ACCESS_KEY | base64 -d)"

cat << EOF > values.yml
aws:
    region: ap-southeast-2
    bucket: "${S3_BUCKET}"
    s3region: ap-southeast-2
    key: templates/latest
    tablename: "${TABLE_NAME}"
    accesskeyid: "${BROKER_AWS_ACCESS_KEY_ID}"
    secretkey: "${BROKER_AWS_SECRET_ACCESS_KEY}"
    vpcid: "${VPC_ID}"
EOF

helm upgrade --install --wait --recreate-pods \
    --namespace aws-sb \
    -f values.yml \
    --version 1.0.0-beta.4 \
    aws-servicebroker aws-sb/aws-servicebroker

echo "Waiting for aws-sb deployments to start"
DEPLOYMENTS="$(kubectl -n aws-sb get deployments -o json | jq -r .items[].metadata.name)"
for DEPLOYMENT in $DEPLOYMENTS; do
    kubectl rollout status --namespace=aws-sb --timeout=2m \
        --watch deployment/${DEPLOYMENT}
done

echo "TODO Installing aws-servicebroker templates"
# ${SCRIPT_DIR}/install_awsbroker_templates.sh

# svcat should be able to describe the broker
svcat describe broker aws-servicebroker

# todo svcat should be able to describe a clusterserviceclass
# svcat describe class name
