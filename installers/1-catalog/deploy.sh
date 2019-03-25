#!/bin/bash

set -eu
set -o pipefail

: "${ENV_NAME:?Need to set ENV_NAME}"
: "${HELM_HOST:?Need to set HELM_HOST}"
: "${LETSENCRYPT_EMAIL:?Need to set LETSENCRYPT_EMAIL}"

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

helm dependency update charts/stable/etcd-operator

echo "Deploying etcd-operator (needed by Service Catalog)"
helm upgrade --install --wait \
    --namespace catalog \
    -f ${SCRIPT_DIR}/etcd-operator-values.yml \
    catalog-etcd-operator charts/stable/etcd-operator

echo "Waiting for etcd-operator to start"
kubectl rollout status --namespace=catalog --timeout=2m \
        --watch deployment/catalog-etcd-operator-etcd-operator-etcd-operator

echo "Deploying Service Catalog (needed by AWS servicebroker)"
helm repo add svc-cat https://svc-catalog-charts.storage.googleapis.com
helm upgrade --install --wait \
    --namespace catalog \
    -f ${SCRIPT_DIR}/catalog-values.yml \
    catalog svc-cat/catalog

echo "Waiting for all catalog deployments to start"
DEPLOYMENTS="$(kubectl -n catalog get deployments -o json | jq -r .items[].metadata.name)"
for DEPLOYMENT in $DEPLOYMENTS; do
    # todo can exclude etcd-operator
    kubectl rollout status --namespace=catalog --timeout=2m \
        --watch deployment/${DEPLOYMENT}
done

# svcat should be able to get brokers
svcat get brokers

mkdir -p catalog-acceptance-test
pushd catalog-acceptance-test
  git clone https://github.com/kubernetes-incubator/service-catalog
  cd service-catalog
  # todo should we follow the version that's installed?
  git checkout v0.1.42

  # clean up just in case
  kubectl delete ClusterServiceBroker atest-ups-broker >/dev/null 2>&1 || true
  helm delete atest-ups-broker --purge >/dev/null 2>&1 || true

  helm install ./charts/ups-broker --name atest-ups-broker --namespace atest-ups-broker

  echo "Waiting for ups-broker to start"
  kubectl rollout status --namespace=atest-ups-broker --timeout=2m \
        --watch deployment/atest-ups-broker-ups-broker

  # register a broker server with the catalog
  # todo better to test with a namespace-scoped broker instead of cluster?
  kubectl apply -f <(cat <<EOF
apiVersion: servicecatalog.k8s.io/v1beta1
kind: ClusterServiceBroker
metadata:
  name: atest-ups-broker
spec:
  url: http://atest-ups-broker-ups-broker.atest-ups-broker.svc.cluster.local
EOF
)

  # svcat should be able to describe the broker
  svcat describe broker atest-ups-broker

  # svcat should be able to describe a clusterserviceclass
  svcat describe class user-provided-service

  # cleanup
  kubectl delete ClusterServiceBroker atest-ups-broker
  helm delete atest-ups-broker --purge
popd
