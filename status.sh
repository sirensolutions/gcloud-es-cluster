#!/bin/bash

# QAD script to get the status of all known clusters

ES_PORT=9200

all_nodes=$(gcloud compute instances list | egrep ^\\\S-node | awk '{ print $1 }')

cluster_list=""
for node in $all_nodes; do
	node_cluster=${node%-node*}
	cluster_list="cluster_list
$node_cluster"
done

unique_clusters=$(echo $cluster_list|sort -u)
echo "Found clusters: $unique_clusters"

for cluster in $unique_clusters; do
	# get the slave ip from 'describe' rather than 'list' because 'list'
	# returns empty columns sometimes, making parsing difficult
	first_slave=$(gcloud compute instances list | egrep ^${cluster}-node | head -1 | awk '{ print $1 }')
	ip=$(gcloud compute instances describe $first_slave|grep networkIP|awk '{print $2}')
	curl -XGET http://$ip:$ES_PORT/_cluster/state?pretty
done
