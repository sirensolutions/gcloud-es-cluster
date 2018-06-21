#!/bin/bash

# A QAD script to kill all nodes in a named cluster

if [[ ! $1 || $2 ]]; then
	cat <<EOF
Usage: $0 <cluster-name>

Deletes every node of the form <cluster-name>-node*
EOF
fi

# https://unix.stackexchange.com/questions/333548/how-to-prevent-word-splitting-without-preventing-empty-string-removal
GCLOUD_PARAMS=()

if [[ $ZONE ]]; then
    GCLOUD_PARAMS=(${GCLOUD_PARAMS[@]} "--zone=${ZONE}")
fi

nodes=$(gcloud compute instances list "${GCLOUD_PARAMS[@]}" | grep ^$1-node | awk '{ print $1 }')
gcloud compute instances delete -q "${GCLOUD_PARAMS[@]}" $nodes
