#!/bin/bash

# QAD script to list all running clusters
# Use -v to get elasticsearch status of each

ES_PORT=9200

# https://unix.stackexchange.com/questions/333548/how-to-prevent-word-splitting-without-preventing-empty-string-removal
GCLOUD_PARAMS=()

if [[ $ZONE ]]; then
    GCLOUD_PARAMS=(${GCLOUD_PARAMS[@]} "--zone=${ZONE}")
fi

all_nodes=$(gcloud compute instances list "${GCLOUD_PARAMS[@]}" | egrep ^\\\S+-node | awk '{ print $1 }')

cluster_list=()
for node in $all_nodes; do
	node_cluster=${node%-node*}
	cluster_list=(${cluster_list[@]} $node_cluster)
done
IFS_SAVE=$IFS
IFS="
"
unique_clusters=$(echo "${cluster_list[*]}"|sort -u)
IFS=$IFS_SAVE

for cluster in $unique_clusters; do
	# get the slave ip from 'describe' rather than 'list' because 'list'
	# returns empty columns sometimes, making parsing difficult
	# the extra "echo" normalises the output to space-separated
	slaves=$(echo $(gcloud compute instances list "${GCLOUD_PARAMS[@]}" | egrep ^${cluster}-node | awk '{ print $1 }') )
	echo "Found cluster: $cluster ($(echo $slaves|wc -w) nodes)"
	if [[ $1 == "-v" ]]; then
		first_slave=${slaves%% *}
		ip=$(gcloud compute instances describe "${GCLOUD_PARAMS[@]}" $first_slave|grep networkIP|awk '{print $2}')
		curl -XGET http://$ip:$ES_PORT/_cluster/state?pretty
	fi
done
