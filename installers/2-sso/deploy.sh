#!/bin/bash

set -eu
set -o pipefail

: "${ENV_NAME:?Need to set ENV_NAME}"
: "${SSO_GOOGLE_CLIENT_SECRET:?Need to set SSO_GOOGLE_CLIENT_SECRET}"

CLIENT_ID="$(echo ${SSO_GOOGLE_CLIENT_SECRET} | yq -r .web.client_id)"
CLIENT_SECRET="$(echo ${SSO_GOOGLE_CLIENT_SECRET} | yq -r .web.client_secret)"

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

echo "Deploying S.S. Octopus (sso)"

kubectl apply -f <(cat <<EOF
kind: Namespace
apiVersion: v1
metadata:
  name: sso
  labels:
    name: sso
EOF
)
CERTMANAGER_CLUSTER_ISSUER="letsencrypt-staging"
if [[ $ENV_NAME == "l" ]]; then
  echo "Using prod letsencrypt issuer "
  CERTMANAGER_CLUSTER_ISSUER="letsencrypt-prod"
fi

function ensure-secret-created() {
    KEY=$1
    if [[ ! $(kubectl get secret $KEY -n sso) ]]; then
        RAND="$(openssl rand -base64 32)"
        kubectl create secret generic -n sso $KEY --from-literal=$KEY="$RAND"
    fi
}

ensure-secret-created proxy-client-id
ensure-secret-created proxy-client-secret
ensure-secret-created auth-code-secret
ensure-secret-created proxy-auth-code-secret
ensure-secret-created auth-cookie-secret
ensure-secret-created proxy-cookie-secret

kubectl create secret generic -n sso google-client-secret \
  --from-literal=client-id=${CLIENT_ID} \
  --from-literal=client-secret=${CLIENT_SECRET} \
  --dry-run -o yaml | kubectl apply -f -

# Currently sso does not support reloading the upstream-configs configmap,
# so whenever it changes we need to recreate the auth-proxy pod.
# https://github.com/buzzfeed/sso/issues/68
# This is annoying to remember to do manually, so we hash the contents
# before, and recreate it if it changes
BEFORE_HASH=""
if [[ $(kubectl -n sso get configmap upstream-configs) ]]; then
  BEFORE_HASH="$(kubectl -n sso get configmap  upstream-configs -o json | jq .data | sha256sum)"
fi

kubectl apply -f <(cat <<EOF
apiVersion: extensions/v1beta1
kind: Deployment
metadata:
  name: sso-auth
  labels:
    k8s-app: sso-auth
  namespace: sso
spec:
  replicas: 1
  template:
    metadata:
      labels:
        k8s-app: sso-auth
    spec:
      containers:
      - image: buzzfeed/sso:latest
        name: sso-auth
        command: ["/bin/sso-auth"]
        ports:
        - containerPort: 4180
        env:
          - name: SSO_EMAIL_DOMAIN
            value: 'digital.gov.au'
          - name: HOST
            value: sso-auth.${ENV_NAME}.cld.gov.au
          - name: REDIRECT_URL
            value: https://sso-auth.${ENV_NAME}.cld.gov.au
          - name: PROXY_ROOT_DOMAIN
            value: ${ENV_NAME}.cld.gov.au
          - name: CLIENT_ID
            valueFrom:
              secretKeyRef:
                name: google-client-secret
                key: client-id
          - name: CLIENT_SECRET
            valueFrom:
              secretKeyRef:
                name: google-client-secret
                key: client-secret
          - name: PROXY_CLIENT_ID
            valueFrom:
              secretKeyRef:
                name: proxy-client-id
                key: proxy-client-id
          - name: PROXY_CLIENT_SECRET
            valueFrom:
              secretKeyRef:
                name: proxy-client-secret
                key: proxy-client-secret
          - name: AUTH_CODE_SECRET
            valueFrom:
              secretKeyRef:
                name: auth-code-secret
                key: auth-code-secret
          - name: COOKIE_SECRET
            valueFrom:
              secretKeyRef:
                name: auth-cookie-secret
                key: auth-cookie-secret
          # STATSD_HOST and STATSD_PORT must be defined or the app wont launch, they dont need to be a real host / port
          - name: STATSD_HOST
            value: localhost
          - name: STATSD_PORT
            value: "11111"
          - name: CLUSTER
            value: eks
          - name: VIRTUAL_HOST
            value: sso-auth.${ENV_NAME}.cld.gov.au
        readinessProbe:
          httpGet:
            path: /ping
            port: 4180
            scheme: HTTP
        livenessProbe:
          httpGet:
            path: /ping
            port: 4180
            scheme: HTTP
          initialDelaySeconds: 10
          timeoutSeconds: 1
        resources:
          limits:
            memory: "256Mi"
            cpu: "200m"
---
apiVersion: v1
kind: Service
metadata:
  name: sso-auth
  namespace: sso
  labels:
    k8s-app: sso-auth
spec:
  ports:
  - port: 80
    targetPort: 4180
    name: http
  selector:
    k8s-app: sso-auth
---
apiVersion: extensions/v1beta1
kind: Ingress
metadata:
  name: sso-auth
  namespace: sso
  annotations:
    kubernetes.io/tls-acme: "true"
    certmanager.k8s.io/cluster-issuer: "${CERTMANAGER_CLUSTER_ISSUER}"
    ingress.kubernetes.io/force-ssl-redirect: "true"
spec:
  tls:
  - secretName: sso-auth-${ENV_NAME}-cld-gov-au
    hosts:
    - "sso-auth.${ENV_NAME}.cld.gov.au"
  rules:
    - host: "sso-auth.${ENV_NAME}.cld.gov.au"
      http:
        paths:
          - path: /
            backend:
              serviceName: sso-auth
              servicePort: 80
---
apiVersion: extensions/v1beta1
kind: Deployment
metadata:
  name: sso-proxy
  labels:
    k8s-app: sso-proxy
  namespace: sso
spec:
  replicas: 1
  template:
    metadata:
      labels:
        k8s-app: sso-proxy
    spec:
      containers:
      - image: buzzfeed/sso:latest
        name: sso-proxy
        command: ["/bin/sso-proxy"]
        ports:
        - containerPort: 4180
        env:
          - name: EMAIL_DOMAIN
            value: 'digital.gov.au'
          - name: UPSTREAM_CONFIGS
            value: /sso/upstream_configs.yml
          - name: PROVIDER_URL
            value: https://sso-auth.${ENV_NAME}.cld.gov.au
          - name: CLIENT_ID
            valueFrom:
              secretKeyRef:
                name: proxy-client-id
                key: proxy-client-id
          - name: CLIENT_SECRET
            valueFrom:
              secretKeyRef:
                name: proxy-client-secret
                key: proxy-client-secret
          - name: AUTH_CODE_SECRET
            valueFrom:
              secretKeyRef:
                name: proxy-auth-code-secret
                key: proxy-auth-code-secret
          - name: COOKIE_SECRET
            valueFrom:
              secretKeyRef:
                name: proxy-cookie-secret
                key: proxy-cookie-secret
          # STATSD_HOST and STATSD_PORT must be defined or the app wont launch, they dont need to be a real host / port, but they do need to be defined.
          - name: STATSD_HOST
            value: localhost
          - name: STATSD_PORT
            value: "11111"
          - name: CLUSTER
            value: eks
          - name: VIRTUAL_HOST
            value: "*.sso.${ENV_NAME}.cld.gov.au"
        readinessProbe:
          httpGet:
            path: /ping
            port: 4180
            scheme: HTTP
        livenessProbe:
          httpGet:
            path: /ping
            port: 4180
            scheme: HTTP
          initialDelaySeconds: 10
          timeoutSeconds: 1
        resources:
          limits:
            memory: "256Mi"
            cpu: "200m"
        volumeMounts:
        - name: upstream-configs
          mountPath: /sso
      volumes:
        - name: upstream-configs
          configMap:
            name: upstream-configs
---
apiVersion: v1
kind: Service
metadata:
  name: sso-proxy
  namespace: sso
  labels:
    k8s-app: sso-proxy
spec:
  ports:
  - port: 80
    targetPort: 4180
    name: http
  selector:
    k8s-app: sso-proxy
---
apiVersion: extensions/v1beta1
kind: Ingress
metadata:
  name: sso-proxy
  namespace: sso
  annotations:
    kubernetes.io/tls-acme: "true"
    certmanager.k8s.io/cluster-issuer: "${CERTMANAGER_CLUSTER_ISSUER}"
    ingress.kubernetes.io/force-ssl-redirect: "true"
spec:
  # sso-proxy could work with a host wildcard i.e. *.sso.x.cld.gov.au, however Contour
  # does not support this: https://github.com/heptio/contour/issues/13
  # Additionally - certs are currently issued using http challenge, so if we want a wild card
  # we'd also need to change to dns challenge.
  # So each app behind sso-proxy must be listed out here, as well as added to
  # upstream-configs below.
  # Note that if you modify upstream-configs, you will need to recreate the auth-proxy pod to
  # ensure it picks it up. This is done in the deploy script.
  # TODO: someone who likes bash could probably script this so we only have to define a host/service pair in one place
  tls:
  - secretName: alertmanager-sso-${ENV_NAME}-cld-gov-au
    hosts:
    - "alertmanager.sso.${ENV_NAME}.cld.gov.au"
  - secretName: prometheus-sso-${ENV_NAME}-cld-gov-au
    hosts:
    - "prometheus.sso.${ENV_NAME}.cld.gov.au"
  - secretName: grafana-sso-${ENV_NAME}-cld-gov-au
    hosts:
    - "grafana.sso.${ENV_NAME}.cld.gov.au"
  rules:
    - host: "alertmanager.sso.${ENV_NAME}.cld.gov.au"
      http:
        paths:
          - path: /
            backend:
              serviceName: sso-proxy
              servicePort: 80
    - host: "prometheus.sso.${ENV_NAME}.cld.gov.au"
      http:
        paths:
          - path: /
            backend:
              serviceName: sso-proxy
              servicePort: 80
    - host: "grafana.sso.${ENV_NAME}.cld.gov.au"
      http:
        paths:
          - path: /
            backend:
              serviceName: sso-proxy
              servicePort: 80
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: upstream-configs
  namespace: sso
data:
  upstream_configs.yml: |-
    - service: prometheus-operator-alertmanager
      default:
        from: alertmanager.sso.${ENV_NAME}.cld.gov.au
        to: http://prometheus-operator-alertmanager.prometheus-operator.svc.cluster.local:9093
    - service: prometheus-operator-prometheus
      default:
        from: prometheus.sso.${ENV_NAME}.cld.gov.au
        to: http://prometheus-operator-prometheus.prometheus-operator.svc.cluster.local:9090
    - service: prometheus-operator-grafana
      default:
        from: grafana.sso.${ENV_NAME}.cld.gov.au
        to: http://prometheus-operator-grafana.prometheus-operator.svc.cluster.local
EOF
)

if [[ $(kubectl -n sso get configmap  upstream-configs -o json | jq .data | sha256sum) != $BEFORE_HASH ]]; then
    echo "upstream-configs has changed. Deleting auth-proxy pod so the deployment will recreate it and pick up the new config"
    kubectl -n sso delete pod -l k8s-app=sso-proxy
fi
