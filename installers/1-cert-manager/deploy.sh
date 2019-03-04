#!/bin/bash

set -eu
set -o pipefail

: "${ENV_NAME:?Need to set ENV_NAME}"
: "${HELM_HOST:?Need to set HELM_HOST}"
: "${LETSENCRYPT_EMAIL:?Need to set LETSENCRYPT_EMAIL}"

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

#Append $ENV_NAME to the email
LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL/@/+${ENV_NAME}@}"

echo "Installing cert-manager"

# Install the CustomResourceDefinition resources separately
kubectl apply -f https://raw.githubusercontent.com/jetstack/cert-manager/release-0.6/deploy/manifests/00-crds.yaml

if ! kubectl get ns cert-manager > /dev/null 2>&1 ; then
    echo "Creating the namespace for cert-manager"
    kubectl create namespace cert-manager
fi

# Label the cert-manager namespace to disable resource validation
kubectl label namespace cert-manager certmanager.k8s.io/disable-validation=true --overwrite

helm dependency update charts/stable/cert-manager

# Install the cert-manager Helm chart
helm upgrade --install --wait --timeout 300 \
  --namespace cert-manager \
  --version v0.6.6 \
  cert-manager charts/stable/cert-manager

echo "Installing cert issuers"
kubectl apply -f <(cat <<EOF
apiVersion: certmanager.k8s.io/v1alpha1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
  namespace: cert-manager
spec:
  acme:
    email: ${LETSENCRYPT_EMAIL}
    http01: {}
    privateKeySecretRef:
      name: letsencrypt-prod
    server: https://acme-v02.api.letsencrypt.org/directory
---
apiVersion: certmanager.k8s.io/v1alpha1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
  namespace: cert-manager
spec:
  acme:
    email: ${LETSENCRYPT_EMAIL}
    http01: {}
    privateKeySecretRef:
      name: letsencrypt-staging
    server: https://acme-staging-v02.api.letsencrypt.org/directory
EOF
)
