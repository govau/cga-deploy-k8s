#!/bin/bash

set -eu
set -o pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

echo "Test aws-servicebroker"

svcat describe broker aws-servicebroker

echo "Wait for at least one entry in the marketplace"
end=$((SECONDS+300))
while :
do
  if (( "$(svcat marketplace -o json | jq '. | length')" > "0" )); then
    break;
  fi
  if (( ${SECONDS} >= end )); then
    echo "Timeout: Wait for at least one entry in the marketplace"
    exit 1
  fi
  sleep 5
done
