#!/bin/bash

set -eu
set -o pipefail

: "${ALERTMANAGER_SLACK_API_URL:?Need to set ALERTMANAGER_SLACK_API_URL}"
: "${ENV_NAME:?Need to set ENV_NAME}"

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
NAMESPACE=prometheus-operator

if [[ $ENV_NAME == "k" ]]; then
  # TODO is there a better way to accomplish this?
  echo "Disabling slack in k-cld"
  ALERTMANAGER_SLACK_API_URL="https://hooks.slack.com/services/foo"
fi

kubectl apply -f <(cat <<EOF
kind: Namespace
apiVersion: v1
metadata:
  name: ${NAMESPACE}
EOF
)

kubectl -n ${NAMESPACE} apply -f <(cat <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: prometheus-prometheus-operator-prometheus-db-prometheus-prometheus-operator-prometheus-0
  labels:
    app: prometheus
    prometheus: prometheus-operator-prometheus
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 40Gi
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: alertmanager-prometheus-operator-alertmanager-db-alertmanager-prometheus-operator-alertmanager-0
  labels:
    alertmanager: prometheus-operator-alertmanager
    app: alertmanager
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 5Gi
EOF
)

cat << EOF > values.yml
# Monitoring kube controller and scheduler doesnt seem to work on eks
# https://github.com/coreos/prometheus-operator/issues/2437
kubeControllerManager:
  enabled: false
kubeScheduler:
  enabled: false
alertmanager:
  alertmanagerSpec:
    externalUrl: https://alertmanager.sso.${ENV_NAME}.cld.gov.au
    retention: 336h # 14 days
    storage:
      volumeClaimTemplate:
        spec:
          selector:
            matchLabels:
              alertmanager: prometheus-operator-alertmanager
              app: alertmanager
  config:
    global:
      slack_api_url: "${ALERTMANAGER_SLACK_API_URL}"
    route:
      receiver: "default"
      group_by:
      - job
      routes:
      - receiver: "null"
        match:
          alertname: DeadMansSwitch
      group_wait: 30s
      group_interval: 5m
      repeat_interval: 12h
    receivers:
      - name: "null"
      - name: default
        slack_configs:
        - send_resolved: true
          channel: "cloud-gov-au-log"
          http_config: {}
          color: '{{ if eq .Status "firing" }}danger{{ else }}good{{ end }}'
          title: '{{ template "slack.default.title" . }}'
          title_link: '{{ template "slack.default.titlelink" . }}'
          pretext: '{{ template "slack.default.pretext" . }}'
          text: |-
            {{ range .Alerts }}{{ .Annotations.description }}
            {{ end }}
          footer: '{{ template "slack.default.footer" . }}'
          fallback: '{{ template "slack.default.fallback" . }}'
          icon_emoji: '{{ template "slack.default.iconemoji" . }}'
          icon_url: '{{ template "slack.default.iconurl" . }}'
kubelet:
  serviceMonitor:
    # Fixes scraping issues, more context here:
    # https://github.com/awslabs/amazon-eks-ami/issues/128
    https: true
prometheus:
  prometheusSpec:
    externalUrl: https://prometheus.sso.${ENV_NAME}.cld.gov.au
    retention: 14d
    ruleNamespaceSelector:
      any: true
    storageSpec:
      volumeClaimTemplate:
        spec:
          selector:
            matchLabels:
              app: prometheus
              prometheus: prometheus-operator-prometheus
EOF

helm dependency update charts/stable/prometheus-operator

# Install prometheus-operator
helm upgrade --install --wait --timeout 300  \
    --namespace prometheus-operator \
    -f values.yml \
    prometheus-operator charts/stable/prometheus-operator

echo "Allowing users/serviceaccounts with the 'edit' cluster role to use these prometheus CustomResourceDefinitions"
kubectl apply -f <(cat <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: aggregate-edit-prometheus-operator
  labels:
    rbac.authorization.k8s.io/aggregate-to-edit: "true"
rules:
- apiGroups:
  - monitoring.coreos.com
  resources:
  - prometheusrules
  - servicemonitors
  verbs:
  - '*'
EOF
)

echo "Waiting for prometheus-operator deployments to start"
DEPLOYMENTS="$(kubectl -n prometheus-operator get deployments -o json | jq -r .items[].metadata.name)"
for DEPLOYMENT in $DEPLOYMENTS; do
    kubectl rollout status --namespace=prometheus-operator --timeout=2m \
        --watch deployment/${DEPLOYMENT}
done

echo "Waiting for prometheus-operator pods to be running"
end=$((SECONDS+120))
while :
do
  if [[ "$(kubectl -n prometheus-operator get pods --field-selector=status.phase!=Running -o json | jq -r '.items | length')" == "0" ]]; then
    echo "done"
    break;
  fi
  if (( ${SECONDS} >= end )); then
    echo "Timeout: Waiting for prometheus-operator pods to be running"
    exit 1
  fi
  sleep 5
done
