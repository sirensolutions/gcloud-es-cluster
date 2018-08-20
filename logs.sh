#! /bin/bash

if [[ $1 == "help" || $1 == "-h" || $1 == "--help" ]]; then
	cat <<EOF
Usage: $0 <CLUSTER_NAME>

This script retrieves logs from the spawned machines for a particular Elasticsearch cluster.
The Elasticsearch cluster does not need to be up and running.
Logs retrieved are syslog and from the elastic systemd service.
EOF
fi

cluster_id=$1
nodes=$(gcloud compute instances list --format "value( 'INTERNAL_IP' )" --filter "NAME ~ ^${cluster_id}-node")

while read -r node; do
	syslog=$(ssh $node grep es-constructor /var/log/syslog)
	journal=$(ssh $node journalctl --unit=elastic --no-pager)
	echo -e "Node ${node}:\n--> syslog:\n${syslog}\n--> journal:\n${journal}"
done <<< "$nodes"
