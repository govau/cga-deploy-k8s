#!/bin/bash

set -eu
set -o pipefail

: "${ENV_NAME:?Need to set ENV_NAME}"
: "${HELM_HOST:?Need to set HELM_HOST}"
: "${JUMPBOX_SSH_PORT:?Need to set JUMPBOX_SSH_PORT}"
: "${PATH_TO_KEY:?Need to set PATH_TO_KEY}"
: "${SSH:?Need to set SSH}"

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

export PATH_TO_OPS=${SCRIPT_DIR}/../../../ops
export JUMPBOX=bosh-jumpbox.${ENV_NAME}.cld.gov.au

# jumpbox should be available in dns
nslookup ${JUMPBOX}

echo "Waiting for jumpbox"
end=$((SECONDS+180))
while :
do
  if [ "$(${SSH} echo ok)" ]; then
    break;
  fi
  if (( ${SECONDS} >= end )); then
    echo "Timeout: waiting for jumpbox"
    exit 1
  fi
  sleep 5
done

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

echo "Check all worker nodes are running the latest desired AMI"

LAUNCH_CONFIGURATION_NAME="$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names eks-worker-nodes --output json | jq -r .AutoScalingGroups[0].LaunchConfigurationName)"
DESIRED_IMAGE_ID="$(aws autoscaling describe-launch-configurations --launch-configuration-names "${LAUNCH_CONFIGURATION_NAME}" --output json | jq -r .LaunchConfigurations[0].ImageId)"
echo "DESIRED_IMAGE_ID ${DESIRED_IMAGE_ID}"
ACTUAL_IMAGE_IDS="$(aws ec2 describe-instances --filters \
    "Name=tag:aws:autoscaling:groupName,Values=eks-worker-nodes" \
    "Name=instance-state-name,Values=pending,running" \
  | jq -r '.Reservations[].Instances[].ImageId')"

WORKER_NEEDS_UPDATING="0"
for ACTUAL_IMAGE_ID in ${ACTUAL_IMAGE_IDS}; do
  if [[ ${ACTUAL_IMAGE_ID} != ${DESIRED_IMAGE_ID} ]]; then
    echo "Found a worker node running the wrong ami: ${ACTUAL_IMAGE_ID}"
    WORKER_NEEDS_UPDATING="1"
    break
  fi
done

if [[ ${WORKER_NEEDS_UPDATING} == "1" ]]; then
  # The auto scaling group termination policy is set to OldestInstance.
  # So the easiest way is to double the number of instances, and then scale back down
  # to the original size.
  echo "Scale up auto scaling group"
  AUTOSCALING_GROUP_JSON="$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names eks-worker-nodes)"
  STARTING_MIN_SIZE="$(echo ${AUTOSCALING_GROUP_JSON} | jq -r '.AutoScalingGroups[0].MinSize')"
  STARTING_MAX_SIZE="$(echo ${AUTOSCALING_GROUP_JSON} | jq -r '.AutoScalingGroups[0].MaxSize')"
  DOUBLE_MIN_SIZE="$((STARTING_MIN_SIZE * 2))"
  DOUBLE_MAX_SIZE="$((STARTING_MAX_SIZE * 2))"
  aws autoscaling update-auto-scaling-group \
    --auto-scaling-group-name eks-worker-nodes \
    --min-size "${DOUBLE_MIN_SIZE}" --max-size "${DOUBLE_MAX_SIZE}"

  echo "Wait for the new nodes to join the cluster"
  end=$((SECONDS+180))
  while :
  do
    if (( "$(kubectl get nodes -o json | jq -r '.items | length')" >= "${DOUBLE_MIN_SIZE}" )); then
      break;
    fi
    if (( ${SECONDS} >= end )); then
      echo "Timeout: Wait for the new nodes to join the cluster"
      exit 1
    fi
    sleep 5
  done

  # todo taint and drain the nodes with the old ami?

  echo "Scale down auto scaling group"
  aws autoscaling update-auto-scaling-group \
    --auto-scaling-group-name eks-worker-nodes \
    --min-size "${STARTING_MIN_SIZE}" --max-size "${STARTING_MAX_SIZE}"

  # TODO - we can remove this confirmation check after we're happy this all works
  echo "Sleep while we wait for excess nodes to be terminated by the ASG"
  sleep 300

  echo "Confirm all worker nodes are now running the desired ami"
  ACTUAL_IMAGE_IDS="$(aws ec2 describe-instances  \
    --filters "Name=tag:aws:autoscaling:groupName,Values=eks-worker-nodes" \
    "Name=instance-state-name,Values=pending,running" \
    | jq -r '.Reservations[].Instances[].ImageId')"
  for ACTUAL_IMAGE_ID in ${ACTUAL_IMAGE_IDS}; do
    if [[ ${ACTUAL_IMAGE_ID} != ${DESIRED_IMAGE_ID} ]]; then
      echo "Found a worker node that is not running the desired ami"
      exit 1
    fi
  done
else
  echo "Worker nodes are all running the desired ami"
fi
