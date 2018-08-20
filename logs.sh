#! /bin/bash

cluster_id=$1
nodes=$(gcloud compute instances list --format "value( 'INTERNAL_IP' )" --filter "NAME ~ ^${cluster_id}-node")

while read -r node; do
	syslog=$(ssh $node grep es-constructor /var/log/syslog)
	journal=$(ssh $node journalctl --unit=elastic --no-pager)
	echo -e "Node ${node}:\n--> syslog:\n${syslog}\n--> journal:\n${journal}"
done <<< "$nodes"
