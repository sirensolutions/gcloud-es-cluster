#!/bin/bash

# QAD script to list all running clusters
# Use -v to get elasticsearch status of each

ES_PORT=9200

all_nodes=$(gcloud compute instances list | egrep ^\\\S+-node | awk '{ print $1 }')

cluster_list=()
for node in $all_nodes; do
	node_cluster=${node%-node*}
	cluster_list=(${cluster_list[@]} $node_cluster)
done
IFS_SAVE=$IFS
IFS="\n"
unique_clusters=$(echo "${cluster_list[*]}"|sort -u)
IFS=$IFS_SAVE

for cluster in $unique_clusters; do
	# get the slave ip from 'describe' rather than 'list' because 'list'
	# returns empty columns sometimes, making parsing difficult
	slaves=$(gcloud compute instances list | egrep ^${cluster}-node | awk '{ print $1 }')
	echo "Found cluster: $cluster ($slaves)"
	if [[ $1 == "-v" ]]; then
		first_slave=${slaves%%\ *}
		ip=$(gcloud compute instances describe $first_slave|grep networkIP|awk '{print $2}')
		curl -XGET http://$ip:$ES_PORT/_cluster/state?pretty
	fi
done
