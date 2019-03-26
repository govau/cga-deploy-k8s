#!/bin/bash

set -eu
set -o pipefail

: "${AWS_ACCESS_KEY_ID:?Need to set AWS_ACCESS_KEY_ID}"
: "${AWS_SECRET_ACCESS_KEY:?Need to set AWS_SECRET_ACCESS_KEY}"
: "${ENV_NAME:?Need to set ENV_NAME}"

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
PATH_TO_OPS=${SCRIPT_DIR}/../../ops

pushd ${PATH_TO_OPS}/terraform/env/${ENV_NAME}-cld

  terraform init

  export TF_VAR_eks_worker_ami="not-used"

  # Put our AWS creds into a credentials file
  # Add profile to assume role in the child aws account
  export AWS_ACCOUNT_ID="$(terraform output aws_account_id)"
  mkdir -p $HOME/.aws
  cat <<EOF >> $HOME/.aws/credentials
[default]
aws_access_key_id = ${AWS_ACCESS_KEY_ID}
aws_secret_access_key = ${AWS_SECRET_ACCESS_KEY}
[${ENV_NAME}-cld]
role_arn = arn:aws:iam::${AWS_ACCOUNT_ID}:role/Terraform
source_profile = default
EOF
  unset AWS_ACCESS_KEY_ID
  unset AWS_SECRET_ACCESS_KEY

  # Terraform is set to not delete etcd backup bucket, so delete it here
  if [[ $(terraform state list | grep "aws_s3_bucket.catalog_etcd_operator") != "" ]]; then
    ETCD_BACKUP_BUCKET="$(terraform output k8s_catalog_etcd_operator_bucket_id)"
    echo "Deleting ETCD_BACKUP_BUCKET ${ETCD_BACKUP_BUCKET}"
    aws --profile "${ENV_NAME}-cld" s3 \
      rb --force "s3://${ETCD_BACKUP_BUCKET}"
  fi

  # Destroy as much as we can automatically recreate.
  # We use a blacklist of resources we want to exclude.
  # All resources in terraform state not in the black list
  # are passed to 'terraform destroy' using -resource.
  resources="$(terraform state list)"
  blacklisted_resources=( \
    "aws_route53_zone.cld_subdomain" \
    "aws_route53_zone.int_cld_subdomain" \
    "aws_vpc_peering_connection.to_mgmt" \
    "aws_vpc.platform" \
    )
  terraform_cmd="terraform destroy -auto-approve -input=false"
  for resource in $resources; do
    BLACKLISTED=0
    for blackedlisted_resource in ${blacklisted_resources[@]}; do
      if [[ $resource == *"${blackedlisted_resource}"* ]]; then
        BLACKLISTED=1
        break
      fi
    done
    if [[ $BLACKLISTED == 0 ]]; then
      terraform_cmd="$terraform_cmd -target $resource"
    else
      echo "Will not destroy blacklisted resource: $resource"
    fi
  done

  pwd
  echo "Will 'terraform destroy' ${ENV_NAME}-cld in 60 seconds..."
  sleep 60

  $terraform_cmd
popd
