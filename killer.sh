#!/bin/bash

# A QAD script to kill all nodes in a named cluster

nodes=$(gcloud compute instances list | grep ^$1-node | awk '{ print $1 }')
gcloud compute instances delete -q $nodes
