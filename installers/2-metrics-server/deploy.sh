#!/bin/bash

set -eu
set -o pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

echo "Deploying metrics server"
helm upgrade --install --wait \
    --namespace metrics-server \
    metrics-server charts/stable/metrics-server

# A simple smoke-test for metrics-server
echo -n "Waiting for metrics to be available..."
attempt_counter=0
max_attempts=36
while [[ $(kubectl get --raw "/apis/metrics.k8s.io/v1beta1/nodes" | jq '.items | length') == 0 ]]; do
    if [ ${attempt_counter} -eq ${max_attempts} ];then
      echo "Max attempts reached"
      exit 1
    fi
    printf '.'
    attempt_counter=$(($attempt_counter+1))
    sleep 5
done
echo "done"
