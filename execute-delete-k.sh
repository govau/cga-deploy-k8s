#!/bin/bash

# This script can be useful when debugging - you can modify the files locally
# and run the task in concourse using `fly execute`.
set -euxo pipefail

PIPELINE=k8s

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

echo "Ensuring you are logged in to credhub"
if ! https_proxy=socks5://localhost:8112 credhub find > /dev/null; then
  https_proxy=socks5://localhost:8112 credhub login --sso
fi

aws_access_key_id="$(https_proxy=socks5://localhost:8112 credhub get -j -n /concourse/apps/${PIPELINE}/aws_access_key_id | jq -r .value)"
aws_secret_access_key="$(https_proxy=socks5://localhost:8112 credhub get -j -n /concourse/apps/${PIPELINE}/aws_secret_access_key | jq -r .value)"

https_proxy=socks5://localhost:8112  \
AWS_ACCESS_KEY_ID=${aws_access_key_id} \
AWS_SECRET_ACCESS_KEY="${aws_secret_access_key}" \
fly -t mcld execute \
  --input deploy-src=${SCRIPT_DIR} \
  --input ops=${PATH_TO_OPS} \
  --config ${SCRIPT_DIR}/ci/delete-k.yml
