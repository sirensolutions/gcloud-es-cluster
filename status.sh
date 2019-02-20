#!/bin/bash

# QAD script to list all running clusters
# Use -v to get the full elasticsearch status of the cluster.
# Use -n to get elasticsearch cluster nodes state.

ES_PORT=9200

all_nodes=$(gcloud compute instances list | awk '/^[^ \t]+-node/ { print $1 }')

cluster_list=()
for node in $all_nodes; do
    node_cluster=${node%-node*}
    cluster_list=(${cluster_list[@]} $node_cluster)
done
unique_clusters=$(IFS=$'\n'; echo "${cluster_list[*]}"|sort -u)

for cluster in $unique_clusters; do
    # get the slave ip from 'describe' rather than 'list' because 'list'
    # returns empty columns sometimes, making parsing difficult
    # the extra "echo" normalises the output to space-separated
    slaves=$(echo $(gcloud compute instances list | awk "/^${cluster}-node/ { print \$1 }") )
    echo "Found cluster: $cluster ($(echo $slaves|wc -w) nodes)"
    if [[ $1 == "-v" ]]; then
        first_slave=${slaves%% *}
        ip=$(gcloud compute instances describe $first_slave | awk '/networkIP/ {print $2}')
        curl -XGET http://$ip:$ES_PORT/_cluster/state?pretty
    elif [[ $1 == "-n" ]]; then
        # Get the nodes information only.
        first_slave=${slaves%% *}
        ip=$(gcloud compute instances describe $first_slave | awk '/networkIP/ {print $2}')
        curl -XGET http://$ip:$ES_PORT/_cluster/state/nodes
    fi
done
