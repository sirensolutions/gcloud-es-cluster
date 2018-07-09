#!/bin/bash

# A QAD script to kill all nodes in a named cluster

if [[ ! $1 || $2 ]]; then
	cat <<EOF
Usage: $0 <cluster-name>

Deletes every node of the form <cluster-name>-node*
EOF
    exit 1
fi

nodes=$(gcloud compute instances list | grep ^$1-node | awk '{ print $1 }')
if [[ ! $nodes ]]; then
    echo "Could not find cluster $1"
    exit 1
fi
gcloud compute instances delete -q $nodes
