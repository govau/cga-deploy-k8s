#!/bin/bash

set -eu
set -o pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

echo "Test aws-servicebroker"

svcat describe broker aws-servicebroker

# TODO fix this test
# echo "Wait for at least one service broker class"
# end=$((SECONDS+300))
# while :
# do
#   if (( $(svcat get classes --scope cluster -o json | jq -r '. | length') >= 1 )); then
#     echo "success"
#     break;
#   fi
#   if (( ${SECONDS} >= end )); then
#     echo "Timeout: Wait for at least one service broker class"
#     exit 1
#   fi
#   echo -n "."
#   sleep 5
# done
