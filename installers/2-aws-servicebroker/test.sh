#!/bin/bash

set -eu
set -o pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

echo "Test aws-servicebroker"

svcat describe broker aws-servicebroker

echo "Wait for at least one service broker class"
end=$((SECONDS+300))
while :
do
  if (( $(svcat get classes --scope cluster -o json | jq -r '. | length') >= 1 )); then
    echo "success"
    break;
  fi
  if (( ${SECONDS} >= end )); then
    echo "Timeout: Wait for at least one service broker class"
    exit 1
  fi
  echo -n "."
  sleep 5
done

echo "Test aws-servicebroker rds class (will take a while)"
NAMESPACE=aws-sb-ci-test

if ! kubectl get ns ${NAMESPACE} > /dev/null 2>&1 ; then
    echo "Creating the namespace for aws-servicebroker tests"
    kubectl create namespace ${NAMESPACE}
fi

echo "Cleanup in case there was an error the last time the test ran"
kubectl -n ${NAMESPACE} delete servicebinding --all=true || true
kubectl -n ${NAMESPACE} delete serviceinstance --all=true --wait=false  || true

INSTANCE_NAME="aws-sb-ci-test-${RANDOM}-db"

kubectl apply -n "${NAMESPACE}" -f <(cat <<EOF
apiVersion: servicecatalog.k8s.io/v1beta1
kind: ServiceInstance
metadata:
  name: "${INSTANCE_NAME}"
spec:
  clusterServiceClassExternalName: rdspostgresql
  clusterServicePlanExternalName: dev
EOF
)

echo "Wait for rds serviceinstance to be ready"
kubectl -n "${NAMESPACE}" wait --for=condition=Ready --timeout=30m "ServiceInstance/${INSTANCE_NAME}"

kubectl apply -n "${NAMESPACE}" -f <(cat <<EOF
apiVersion: servicecatalog.k8s.io/v1beta1
kind: ServiceBinding
metadata:
  name: ${INSTANCE_NAME}-binding
spec:
  instanceRef:
    name: ${INSTANCE_NAME}
EOF
)

BINDING_JSON="$(kubectl -n ${NAMESPACE} get secret ${INSTANCE_NAME}-binding -o json)"
POSTGRES_DB_NAME="$(echo ${BINDING_JSON} | jq -r '.data.DB_NAME' | base64 -d)"
POSTGRES_ENDPOINT_ADDRESS="$(echo ${BINDING_JSON} | jq -r '.data.ENDPOINT_ADDRESS' | base64 -d)"
POSTGRES_MASTER_PASSWORD="$(echo ${BINDING_JSON} | jq -r '.data.MASTER_PASSWORD' | base64 -d)"
POSTGRES_MASTER_USERNAME="$(echo ${BINDING_JSON} | jq -r '.data.MASTER_USERNAME' | base64 -d)"
POSTGRES_PORT="$(echo ${BINDING_JSON} | jq -r '.data.PORT' | base64 -d)"

kubectl run --namespace ${NAMESPACE} psql --rm --tty -i --restart='Never' \
  --env PGHOST=$POSTGRES_ENDPOINT_ADDRESS \
  --env PGDATABASE=$POSTGRES_DB_NAME \
  --env PGUSER=$POSTGRES_MASTER_USERNAME \
  --env PGPASSWORD=$POSTGRES_MASTER_PASSWORD \
  --env PGPORT=$POSTGRES_PORT \
  --image postgres -- pg_isready

# cleanup
kubectl -n ${NAMESPACE} delete servicebinding "${INSTANCE_NAME}-binding"
kubectl -n ${NAMESPACE} delete --wait=false serviceinstance "${INSTANCE_NAME}"
