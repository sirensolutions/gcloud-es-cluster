#! /bin/bash

local nodes=$(gcloud compute instances list --format "value( 'INTERNAL_IP' )" --filter "NAME ~ ^${getClusterId()}-node")

for node in nodes; do
	local syslog=$(ssh $node grep es-constructor /var/log/syslog)
	local journal=$(ssh $node journalctl --unit=elastic --no-pager)
	echo -e "Node ${node}:\n--> syslog:\n${syslog}\n--> journal:\n${journal}"
done
