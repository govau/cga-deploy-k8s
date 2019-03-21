#!/bin/bash

set -eu
set -o pipefail

ISTIO_VERSION="1.1.0"
ISTIO_SHA256="9a578825488c85578460fdf7321ce14844f62b7083c7d9f919fe93bd76d938bc"

: "${ENV_NAME:?Need to set ENV_NAME}"

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

pushd

cd "${SCRIPT_DIR}"
curl -L https://github.com/istio/istio/releases/download/${ISTIO_VERSION}/istio-${ISTIO_VERSION}-linux.tar.gz > istio.tgz
echo "${ISTIO_SHA256}  istio.tgz" > istio.tgz.sha256
shasum --check istio.tgz.sha256
tar zxf istio.tgz
cd "istio-${ISTIO_VERSION}/"

helm upgrade --install --wait --timeout 300  \
    --namespace istio-system \
    istio-init install/kubernetes/helm/istio-init

helm upgrade --install --wait --timeout 300  \
    --namespace istio-system \
    istio install/kubernetes/helm/istio

popd
