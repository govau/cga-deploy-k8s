#!/bin/bash

set -eu
set -o pipefail

: "${ALERTMANAGER_SLACK_API_URL:?Need to set ALERTMANAGER_SLACK_API_URL}"
: "${ENV_NAME:?Need to set ENV_NAME}"

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

if [[ $ENV_NAME == "k" ]]; then
  # TODO is there a better way to accomplish this?
  echo "Disabling slack in k-cld"
  ALERTMANAGER_SLACK_API_URL="https://hooks.slack.com/services/foo"
fi

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
