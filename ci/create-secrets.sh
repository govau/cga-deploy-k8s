#!/usr/bin/env bash

# Create the secrets needed by this pipeline.
# Where possible, credentials are rotated each time this script is run.
# This might interfere with any CI jobs that are currently running.

PIPELINE=k8s

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

: "${CI_IAM_USERNAME:?Need to set CI_IAM_USERNAME - the name of the iam user used by CI}"

function trim_to_one_access_key(){
    iam_user=$1
    key_count=$(aws iam list-access-keys --user-name "${iam_user}" | jq '.AccessKeyMetadata | length')
    if [[ $key_count > 1 ]]; then
        oldest_key_id=$(aws iam list-access-keys --user-name "${iam_user}" | jq -r '.AccessKeyMetadata |= sort_by(.CreateDate) | .AccessKeyMetadata | first | .AccessKeyId')
        aws iam delete-access-key --user-name "${iam_user}" --access-key-id "${oldest_key_id}"
    fi
}

set_credhub_value() {
  KEY="$1"
  VALUE="$2"
  https_proxy=socks5://localhost:8112 \
  credhub set -n "/concourse/apps/$PIPELINE/$KEY" -t value -v "${VALUE}"
}

echo "Ensuring you are logged in to credhub"
if ! https_proxy=socks5://localhost:8112 credhub find > /dev/null; then
  https_proxy=socks5://localhost:8112 credhub login --sso
fi

echo "Setting ci iam user creds"
trim_to_one_access_key $CI_IAM_USERNAME
output="$(aws iam create-access-key --user-name ${CI_IAM_USERNAME})"
aws_access_key_id="$(echo $output | jq -r .AccessKey.AccessKeyId)"
aws_secret_access_key="$(echo $output | jq -r .AccessKey.SecretAccessKey)"

export https_proxy=socks5://localhost:8112
set_credhub_value aws_access_key_id "${aws_access_key_id}"
set_credhub_value aws_secret_access_key "${aws_secret_access_key}"
unset https_proxy

trim_to_one_access_key $CI_IAM_USERNAME

for ENV_NAME in k l; do
  echo ENV_NAME=$ENV_NAME
  CREDS_FILE="$SCRIPT_DIR/../client_secret_${ENV_NAME}.json"
  echo CREDS_FILE=$CREDS_FILE
  # if ! https_proxy=socks5://localhost:8112 credhub get -n "/concourse/apps/${PIPELINE}/sso_google_client_secret_k" > /dev/null 2>&1 ; then
  if [ ! -e $CREDS_FILE ]; then
    echo $CREDS_FILE not found
    if ! https_proxy=socks5://localhost:8112 credhub get -n "/concourse/apps/${PIPELINE}/sso_google_client_secret_${ENV_NAME}" > /dev/null 2>&1 ; then
      cat <<EOF
      You must manually create a Google Client ID for sso in each env.

      Go to the DTA SSO project at <https://console.developers.google.com/apis/credentials>

      Create an OAuth Client ID credential (Do one for each env):
      - Type: Web application
      - Name: sso ${ENV_NAME}-cld (not important)
      - Redirect URIs:
          - https://sso-auth.${ENV_NAME}.cld.gov.au/oauth2/callback

      Click the Download JSON link, copy the file to $CREDS_FILE
      i.e. run
      mv ~/Downloads/client_secret_xxxx.json ${CREDS_FILE}
EOF
      exit 1
    fi
  else
    echo $CREDS_FILE found
    SSO_GOOGLE_CLIENT_SECRET="$(cat ${CREDS_FILE})"
    set_credhub_value "sso_google_client_secret_${ENV_NAME}" "${SSO_GOOGLE_CLIENT_SECRET}"
  fi

done

echo "Ensuring letsencrypt email is set if its in our env"
if [[ ! -v LETSENCRYPT_EMAIL ]]; then
  if ! https_proxy=socks5://localhost:8112 credhub get -n "/concourse/apps/${PIPELINE}/letsencrypt_email" > /dev/null 2>&1 ; then
    echo "Letsencrypt email not set. Add LETSENCRYPT_EMAIL to your environment (e.g. use .envrc) and re-run this script"
    exit 1
  fi
else
  set_credhub_value letsencrypt_email "${LETSENCRYPT_EMAIL}"
fi

echo "Ensuring alertmanager slack api url is set if its in our env"
if [[ ! -v ALERTMANAGER_SLACK_API_URL ]]; then
  if ! https_proxy=socks5://localhost:8112 credhub get -n "/concourse/apps/${PIPELINE}/alertmanager_slack_api_url" > /dev/null 2>&1 ; then
    echo "Alertmanager slack api url not set. Add ALERTMANAGER_SLACK_API_URL to your environment (e.g. use .envrc) and re-run this script"
    exit 1
  fi
else
  set_credhub_value alertmanager_slack_api_url "${ALERTMANAGER_SLACK_API_URL}"
fi
