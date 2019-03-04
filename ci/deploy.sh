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
      echo "todo terraform apply"
      exit 1
      terraform apply ${TFPLAN}
    fi
  fi
popd

# jumpbox should be available in dns
nslookup bosh-jumpbox.${ENV_NAME}.cld.gov.au

# Tell the jumpbox to refresh its host cert now
ssh \
  -o UserKnownHostsFile=/dev/null \
  -o StrictHostKeyChecking=no \
  -o BatchMode=yes \
  -i ${PATH_TO_KEY} \
  -p ${JUMPBOX_SSH_PORT} \
  ec2-user@bosh-jumpbox.${ENV_NAME}.cld.gov.au \
  sudo /etc/ssh/refreshHostCert.sh

# jumpbox should now have a valid host cert
ssh \
  -o BatchMode=yes \
  -i ${PATH_TO_KEY} \
  -p ${JUMPBOX_SSH_PORT} \
  ec2-user@bosh-jumpbox.${ENV_NAME}.cld.gov.au \
  echo ok

# Run the platform installer
pushd ${PATH_TO_OPS}/terraform/modules/platform/installer
  ansible-playbook --private-key=${PATH_TO_KEY} -i ${JUMPBOX}:${JUMPBOX_SSH_PORT}, playbook.yml \
      --ssh-common-args="-oBatchMode=yes"
popd

# Add profile to assume role in the child aws account
export AWS_ACCOUNT_ID="$(${SSH} aws sts get-caller-identity --output json  | jq -r .Account)"
cat <<EOF >> $HOME/.aws/credentials
[${ENV_NAME}-cld]
role_arn = arn:aws:iam::${AWS_ACCOUNT_ID}:role/Terraform
source_profile = default
EOF

aws eks update-kubeconfig \
  --profile ${ENV_NAME}-cld \
  --name eks \
  --role-arn arn:aws:iam::${AWS_ACCOUNT_ID}:role/Terraform

# kubectl should now be able to connect to our cluster
kubectl get svc

# Enable worker nodes to join your cluster.
# Also allow jumpbox.
EKS_WORKER_INSTANCE_ROLE_ARN="$(${SSH} sdget eks.cld.internal worker-iam-role-arn)"
kubectl apply -f <(cat <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: aws-auth
  namespace: kube-system
data:
  mapRoles: |
    - rolearn: ${EKS_WORKER_INSTANCE_ROLE_ARN}
      username: system:node:{{EC2PrivateDNSName}}
      groups:
        - system:bootstrappers
        - system:nodes
    - rolearn: "arn:aws:iam::${AWS_ACCOUNT_ID}:role/bosh_jumpbox"
      username: jumpbox
      groups:
        - system:masters
EOF
)

# Wait for nodes to join the cluster
end=$((SECONDS+600))
while [ $SECONDS -lt $end ]; do
  if [[ ! $(kubectl get nodes -o json | jq -r '.items | length') ]]; then
    echo "Still waiting for nodes"
    sleep 30
  else
    break
  fi
done

# Nodes should have joined the cluster
if [[ ! $(kubectl get nodes -o json | jq -r '.items | length') ]]; then
  echo "Timeout: wait for nodes to join cluster"
  exit 1
fi

# ${SSH} eks/bin/deploy.sh
# exit 0

echo "Starting tiller in the background. It is then killed at the end."
pkill tiller || true
export HELM_HOST=:44134
tiller --storage=secret --listen "$HELM_HOST" >/dev/null 2>&1 &

helm init --client-only

# Update your local Helm chart repository cache
helm repo update

for installer in ${SCRIPT_DIR}/../installers/*/deploy.sh; do
  ALERTMANAGER_SLACK_API_URL="${ALERTMANAGER_SLACK_API_URL}" \
  ENV_NAME="${ENV_NAME}" \
  HELM_HOST=":44134" \
  LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL}" \
  SSH="${SSH}" \
  SSO_GOOGLE_CLIENT_SECRET="${SSO_GOOGLE_CLIENT_SECRET}" \
  $installer
done

# $SCRIPT_DIR/../installers/contour/deploy.sh

# ENV_NAME="${ENV_NAME}" \
# HELM_HOST=":44134" \
# LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL}" \
# $SCRIPT_DIR/../installers/cert-manager/deploy.sh

# ENV_NAME="${ENV_NAME}" \
# SSO_GOOGLE_CLIENT_SECRET="${SSO_GOOGLE_CLIENT_SECRET}" \
# HELM_HOST=":44134" \
# $SCRIPT_DIR/../installers/sso/deploy.sh

# ALERTMANAGER_SLACK_API_URL="${ALERTMANAGER_SLACK_API_URL}" \
# ENV_NAME="${ENV_NAME}" \
# HELM_HOST=":44134" \
# $SCRIPT_DIR/../installers/prometheus-operator/deploy.sh

echo "Killing tiller"
pkill tiller
