#!/bin/bash

set -eu
set -o pipefail

: "${ENV_NAME:?Need to set ENV_NAME}"
: "${HELM_HOST:?Need to set HELM_HOST}"
: "${JUMPBOX_SSH_KEY:?Need to set JUMPBOX_SSH_KEY}"
: "${JUMPBOX_SSH_PORT:?Need to set JUMPBOX_SSH_PORT}"
: "${SSH:?Need to set SSH}"

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

export PATH_TO_OPS=${SCRIPT_DIR}/../../../ops
export JUMPBOX=bosh-jumpbox.${ENV_NAME}.cld.gov.au
export PATH_TO_KEY=${PWD}/secret-jumpbox.pem

# jumpbox should be available in dns
nslookup ${JUMPBOX}

# Tell the jumpbox to refresh its host cert now
ssh \
  -o UserKnownHostsFile=/dev/null \
  -o StrictHostKeyChecking=no \
  -o BatchMode=yes \
  -i ${PATH_TO_KEY} \
  -p ${JUMPBOX_SSH_PORT} \
  ec2-user@${JUMPBOX} \
  sudo /etc/ssh/refreshHostCert.sh

# jumpbox should now have a valid host cert, and the SSH env var
# used in other installers should now work
${SSH} echo ok

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
export AWS_PROFILE="${ENV_NAME}-cld"
aws eks update-kubeconfig \
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

echo "Starting tiller in the background."
pkill tiller || true
tiller --storage=secret --listen "$HELM_HOST" >/dev/null 2>&1 &

helm init --client-only

# Update your local Helm chart repository cache
helm repo update

# Check all worker nodes are running the latest desired AMI
launch_configuration_name="$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names eks-worker-nodes --output json | jq -r .AutoScalingGroups[0].LaunchConfigurationName)"
desired_ami_image_id="$(aws autoscaling describe-launch-configurations --launch-configuration-names "${launch_configuration_name}" --output json | jq -r .LaunchConfigurations[0].ImageId)"
echo "desired_ami_image_id ${desired_ami_image_id}"
actual_ami_image_ids="$(aws ec2 describe-instances --filters \
    "Name=tag:aws:autoscaling:groupName,Values=eks-worker-nodes" \
    "Name=instance-state-name,Values=pending,running" \
  | jq -r '.Reservations[].Instances[].ImageId')"

for actual_ami_image_id in ${actual_ami_image_ids}; do
  echo "checking actual_ami_image_id ${actual_ami_image_id}"
  if [[ ${actual_ami_image_id} != ${desired_ami_image_id} ]]; then
    echo "Found a worker node that is not running the desired ami"
    # todo handle this in the pipeline https://docs.aws.amazon.com/eks/latest/userguide/update-workers.html
    exit 1
  fi
done
