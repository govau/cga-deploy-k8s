#!/bin/bash

set -eu
set -o pipefail

: "${ENV_NAME:?Need to set ENV_NAME}"
: "${HELM_HOST:?Need to set HELM_HOST}"
: "${JUMPBOX:?Need to set JUMPBOX}"

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

# jumpbox should be available in dns
nslookup ${JUMPBOX}

echo "Waiting for jumpbox"
end=$((SECONDS+180))
while :
do
  if [ "$(ssh ${JUMPBOX} echo ok)" ]; then
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
  ansible-playbook -i ${JUMPBOX}, playbook.yml
popd

# Add profile to assume role in the child aws account
export AWS_ACCOUNT_ID="$(ssh ${JUMPBOX} aws sts get-caller-identity --output json  | jq -r .Account)"
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

# Enable disk encryption in the default storageclass
# We cant edit the storage class, so we'll recreate it if necessary
if [[ "$(kubectl get storageclass gp2 -o json | jq -r .parameters.encrypted)" != "true" ]]; then
  echo "Enabling storage class encryption"
  kubectl delete storageclass gp2
  kubectl apply -f <(cat <<EOF
  kind: StorageClass
  apiVersion: storage.k8s.io/v1
  metadata:
    name: gp2
    annotations:
      storageclass.kubernetes.io/is-default-class: "true"
  provisioner: kubernetes.io/aws-ebs
  parameters:
    type: gp2
    fsType: ext4
    encrypted: "true"
  reclaimPolicy: Delete
  # TODO use volumeBindingMode: WaitForFirstConsumer?
  volumeBindingMode: Immediate
EOF
  )
else
  echo "Storage class encryption was already enabled"
fi

# Enable worker nodes to join your cluster.
# Also allow jumpbox.
EKS_WORKER_INSTANCE_ROLE_ARN="$(ssh ${JUMPBOX} sdget eks.cld.internal worker-iam-role-arn)"
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

echo "Apply the desired version of amazon-vpc-cni-k8s if necessary"
DESIRED_AMAZON_VPC_CNI_K8S_VERSION="$(cat ${SCRIPT_DIR}/../../../amazon-vpc-cni-k8s/tag)"
CURRENT_AMAZON_VPC_CNI_K8S_VERSION="$(kubectl describe daemonset aws-node --namespace kube-system | grep Image | cut -d "/" -f 2 | cut -d ":" -f 2)"
if [[ ${CURRENT_AMAZON_VPC_CNI_K8S_VERSION} != ${DESIRED_AMAZON_VPC_CNI_K8S_VERSION} ]]; then
  echo "Updating amazon-vpc-cni-k8s from ${DESIRED_AMAZON_VPC_CNI_K8S_VERSION} to ${CURRENT_AMAZON_VPC_CNI_K8S_VERSION}"
  # The release source includes the config.yaml to apply to the cluster
  # see https://github.com/aws/amazon-vpc-cni-k8s
  pushd "${SCRIPT_DIR}/../../../amazon-vpc-cni-k8s"
    mkdir -p output
    tar xfz source.tar.gz --directory output --strip 1

    MAJOR="$(echo ${DESIRED_AMAZON_VPC_CNI_K8S_VERSION} | cut -d "." -f 1)"
    MINOR="$(echo ${DESIRED_AMAZON_VPC_CNI_K8S_VERSION} | cut -d "." -f 2)"
    FILE=output/config/${MAJOR}.${MINOR}/aws-k8s-cni.yaml
    echo "Will apply $FILE:"
    cat $FILE
    kubectl apply -f $FILE
  popd

  echo "Waiting for amazon vpc cni to be rolled out"
  kubectl rollout status --namespace=kube-system --timeout=5m --watch daemonset/aws-node
else
  echo "amazon-vpc-cni-k8s is already the desired version: ${DESIRED_AMAZON_VPC_CNI_K8S_VERSION}"
fi

echo "Ensure all worker nodes are running the desired AMI"
LAUNCH_CONFIGURATION_NAME="$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names eks-worker-nodes --output json | jq -r .AutoScalingGroups[0].LaunchConfigurationName)"
DESIRED_IMAGE_ID="$(aws autoscaling describe-launch-configurations --launch-configuration-names "${LAUNCH_CONFIGURATION_NAME}" --output json | jq -r .LaunchConfigurations[0].ImageId)"
echo "DESIRED_IMAGE_ID ${DESIRED_IMAGE_ID}"
INSTANCE_IDS="$(aws ec2 describe-instances --filters \
    "Name=tag:aws:autoscaling:groupName,Values=eks-worker-nodes" \
    "Name=instance-state-name,Values=pending,running" \
  | jq -r '.Reservations[].Instances[].InstanceId')"

OLD_INSTANCE_IDS=()

for INSTANCE_ID in ${INSTANCE_IDS}; do
  ACTUAL_IMAGE_ID="$(aws ec2 describe-instances --instance-ids "${INSTANCE_ID}" | jq -r .Reservations[].Instances[0].ImageId)"
  if [[ ${ACTUAL_IMAGE_ID} != ${DESIRED_IMAGE_ID} ]]; then
    echo "${INSTANCE_ID} ami is ${ACTUAL_IMAGE_ID}, not running the desired ami ${DESIRED_IMAGE_ID}"
    OLD_INSTANCE_IDS+=("${INSTANCE_ID}")
  fi
done

if [ ${#OLD_INSTANCE_IDS[@]} -gt 0 ]; then
  # Double the number of instances by scaling the asg, drain pods from the old
  # worker nodes, and then delete them.
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

  # todo check cluster dns provider has more than 1 replica?

  # taint the old nodes (prevents pods being scheduled on them)
  for INSTANCE_ID in "${OLD_INSTANCE_IDS[@]}"; do
    PRIVATE_DNS_NAME="$(aws ec2 describe-instances --instance-ids "${INSTANCE_ID}" | jq -r .Reservations[].Instances[0].PrivateDnsName)"
    kubectl taint nodes "${PRIVATE_DNS_NAME}" key=value:NoSchedule --overwrite=true
  done

  # drain running pods from the old nodes
  for INSTANCE_ID in "${OLD_INSTANCE_IDS[@]}"; do
    PRIVATE_DNS_NAME="$(aws ec2 describe-instances --instance-ids "${INSTANCE_ID}" | jq -r .Reservations[].Instances[0].PrivateDnsName)"
    kubectl drain "${PRIVATE_DNS_NAME}" \
      --ignore-daemonsets --delete-local-data \
      --force --timeout=10m
  done

  # Should now be safe to terminate the old nodes
  for INSTANCE_ID in "${OLD_INSTANCE_IDS[@]}"; do
    aws ec2 terminate-instances \
    --instance-ids "${INSTANCE_ID}"
  done

  echo "Scale down auto scaling group"
  aws autoscaling update-auto-scaling-group \
    --auto-scaling-group-name eks-worker-nodes \
    --min-size "${STARTING_MIN_SIZE}" --max-size "${STARTING_MAX_SIZE}"

  # TODO - we can remove this confirmation check after we're happy this all works
  echo "Sleep while we wait for the old nodes to be terminated"
  sleep 120

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
