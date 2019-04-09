#!/bin/bash

set -eu
set -o pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

echo "Test contour"
NAMESPACE=heptio-contour-ci-test
TEST_DOMAIN=$NAMESPACE.kapps.${ENV_NAME}.cld.gov.au

kubectl apply -f <(cat <<EOF
kind: Namespace
apiVersion: v1
metadata:
  name: ${NAMESPACE}
  labels:
    name: ${NAMESPACE}
EOF
)

kubectl apply -n ${NAMESPACE} -f <(cat <<EOF
apiVersion: apps/v1 # for versions before 1.9.0 use apps/v1beta2
kind: Deployment
metadata:
  name: nginx-deployment
spec:
  selector:
    matchLabels:
      app: nginx
  replicas: 2 # tells deployment to run 2 pods matching the template
  template:
    metadata:
      labels:
        app: nginx
    spec:
      containers:
      - name: nginx
        image: nginx:1.7.9
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: nginx
spec:
  ports:
  - port: 8080
    protocol: TCP
    targetPort: 80
  selector:
    app: nginx
---
apiVersion: extensions/v1beta1
kind: Ingress
metadata:
  name: nginx
spec:
  rules:
  - host: ${TEST_DOMAIN}
    http:
      paths:
      - backend:
          serviceName: nginx
          servicePort: 8080
EOF
)

echo "Wait for contour-test app to be deployed"
end=$((SECONDS+60))
while :
do
  # if ! curl -i http://${TEST_DOMAIN} >/dev/null 2>&1; then
  if $(curl --output /dev/null --silent --head --fail http://${TEST_DOMAIN}); then
    echo "success"
    break;
  fi
  if (( ${SECONDS} >= end )); then
    echo "Timeout: Wait for contour-test app to be deployed"
    exit 1
  fi
  echo -n "."
  sleep 5
done

curl -i http://${TEST_DOMAIN}

kubectl delete ns ${NAMESPACE}
