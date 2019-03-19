#!/bin/bash

set -eu
set -o pipefail

: "${ALERTMANAGER_SLACK_API_URL:?Need to set ALERTMANAGER_SLACK_API_URL}"
: "${AWS_ACCESS_KEY_ID:?Need to set AWS_ACCESS_KEY_ID}"
: "${AWS_SECRET_ACCESS_KEY:?Need to set AWS_SECRET_ACCESS_KEY}"
: "${ENV_NAME:?Need to set ENV_NAME}"
: "${JUMPBOX_SSH_KEY:?Need to set JUMPBOX_SSH_KEY}"
: "${JUMPBOX_SSH_PORT:?Need to set JUMPBOX_SSH_PORT}"
: "${LETSENCRYPT_EMAIL:?Need to set LETSENCRYPT_EMAIL}"
: "${SSO_GOOGLE_CLIENT_SECRET:?Need to set SSO_GOOGLE_CLIENT_SECRET}"

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

export PATH_TO_OPS=${SCRIPT_DIR}/../../ops
export JUMPBOX=bosh-jumpbox.${ENV_NAME}.cld.gov.au
export PATH_TO_KEY=${PWD}/secret-jumpbox.pem

# Add DTA CA as cert authority for jumpboxes
SSHCA_CA_PUB="$(cat ${PATH_TO_OPS}/terraform/sshca-ca.pub)"
mkdir -p $HOME/.ssh
cat <<EOF >> $HOME/.ssh/known_hosts
@cert-authority *.cld.gov.au ${SSHCA_CA_PUB}
EOF

# Create the private key for the jumpbox
echo "${JUMPBOX_SSH_KEY}">${PATH_TO_KEY}
chmod 600 ${PATH_TO_KEY}

export SSH="ssh -oBatchMode=yes -i ${PATH_TO_KEY} -p ${JUMPBOX_SSH_PORT} ec2-user@${JUMPBOX}"

# Put our AWS creds into a credentials file
mkdir -p $HOME/.aws
cat <<EOF > $HOME/.aws/credentials
[default]
aws_access_key_id = ${AWS_ACCESS_KEY_ID}
aws_secret_access_key = ${AWS_SECRET_ACCESS_KEY}
EOF
unset AWS_ACCESS_KEY_ID
unset AWS_SECRET_ACCESS_KEY

for installer in ${SCRIPT_DIR}/../installers/*/deploy.sh; do
  echo "Running installer ${installer}"
  ALERTMANAGER_SLACK_API_URL="${ALERTMANAGER_SLACK_API_URL}" \
  ENV_NAME="${ENV_NAME}" \
  HELM_HOST=":44134" \
  LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL}" \
  SSH="${SSH}" \
  SSO_GOOGLE_CLIENT_SECRET="${SSO_GOOGLE_CLIENT_SECRET}" \
  ${installer}
done

echo "Killing tiller"
pkill tiller
