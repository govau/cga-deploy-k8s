#!/bin/bash

set -eu
set -o pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

echo "Test etcd cluster"

POD_NAME=etcd-ci-test

# cleanup
kubectl -n catalog delete pod ${POD_NAME} 2>/dev/null || true
kubectl run -it --rm --env ETCDCTL_API=3 --namespace catalog ${POD_NAME} --image quay.io/coreos/etcd --restart=Never -- sh -c "etcdctl --endpoints http://etcd-cluster-client:2379 del ci-foo"

# Start a test pod
kubectl -n catalog run --env ETCDCTL_API=3 --image quay.io/coreos/etcd ${POD_NAME} --restart=Never

echo "Wait for catalog etcd test pod ${POD_NAME} to be created"
end=$((SECONDS+180))
while :
do
  if [[ "$(kubectl -n catalog get pod "${POD_NAME}" -o json | jq -r '.status.phase')" == "Running" ]]; then
    break;
  fi
  if (( ${SECONDS} >= end )); then
    echo "Timeout: Waiting for catalog etcd test pod ${POD_NAME} to be created"
    exit 1
  fi
  sleep 5
done

echo "Write and read from catalog etcd cluster"
kubectl -n catalog exec ${POD_NAME} -- etcdctl --endpoints http://etcd-cluster-client:2379 put ci-foo ci-bar
EXPECTED=$(cat <<END_HEREDOC
ci-foo
ci-bar
END_HEREDOC
)
RESULT="$(kubectl -n catalog exec ${POD_NAME} -- etcdctl --endpoints http://etcd-cluster-client:2379 get ci-foo)"
if [ "${RESULT}" != "${EXPECTED}" ]; then
  echo "Failed to write and read from catalog etcd cluster."
  echo "Expected \"${EXPECTED}\" but got \"${RESULT}\""
  exit 1
fi

# cleanup
kubectl -n catalog exec ${POD_NAME} -- sh -c "etcdctl --endpoints http://etcd-cluster-client:2379 del ci-foo"
kubectl -n catalog delete pod ${POD_NAME}

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

