#!/bin/bash

set -eu
set -o pipefail

: "${AWS_ACCESS_KEY_ID:?Need to set AWS_ACCESS_KEY_ID}"
: "${AWS_SECRET_ACCESS_KEY:?Need to set AWS_SECRET_ACCESS_KEY}"
: "${ENV_NAME:?Need to set ENV_NAME}"

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

export PATH_TO_OPS=${SCRIPT_DIR}/../../ops

# Put our AWS creds into a credentials file
mkdir -p $HOME/.aws
cat <<EOF > $HOME/.aws/credentials
[default]
aws_access_key_id = ${AWS_ACCESS_KEY_ID}
aws_secret_access_key = ${AWS_SECRET_ACCESS_KEY}
EOF
unset AWS_ACCESS_KEY_ID
unset AWS_SECRET_ACCESS_KEY

# Secrets should have been set above, so now its ok to use set -x
set -x

pushd ${PATH_TO_OPS}/terraform/env/${ENV_NAME}-cld
  terraform init
  if [[ -v SKIP_TERRAFORM_PLAN ]]; then
    # YOLO
    terraform apply -auto-approve
  else
    if [ "$TERRAFORM_ACTION" != "plan" ] && \
        [ "$TERRAFORM_ACTION" != "apply" ]; then
      echo 'must set $TERRAFORM_ACTION to "plan" or "apply"' >&2
      exit 1
    fi

    TFPLANS_BUCKET_DIR="${SCRIPT_DIR}/../../tfplan"
    TFPLAN="${TFPLANS_BUCKET_DIR}/terraform.tfplan"

    if [ "${TERRAFORM_ACTION}" = "plan" ]; then
      terraform plan \
        -out=${TFPLAN}

      set +e
      terraform show ${TFPLAN} \
        | grep -v "This plan does nothing." \
        > ${TFPLANS_BUCKET_DIR}/message.txt
      set -e
      exit 0
    else
      echo "Applying terraform plan:"
      terraform show ${TFPLAN}
      terraform apply ${TFPLAN}
    fi
  fi
popd

