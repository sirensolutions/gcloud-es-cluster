#!/bin/bash

### Perform post-assembly tasks (common)

# Pass in the list of slave IPS.
# This also requires two envars:
# 	ES_PORT
# 	ES_VERSION

SLAVE_IPS=("$@")

echo "Waiting for elasticsearch to come up on each slave..."
for ip in ${SLAVE_IPS[@]}; do
	while ! nc -w 5 $ip $ES_PORT </dev/null >/dev/null; do
		sleep 5
	done
	echo "$ip running"
done

# For ES 5, we set cache preferences here
# For ES 2, we set it elsewhere using the constructor
if [[ ${ES_VERSION%%.*} -ge 5 ]]; then
	curl -XPUT http://${SLAVE_IPS[0]}:$ES_PORT/_all/_settings?preserve_existing=true -d '{
		"index.queries.cache.enabled" : "true",
		"index.queries.cache.everything" : "true",
		"indices.queries.cache.all_segments" : "true"
	}'
fi

# Now get the status of the cluster from the first node
curl -XGET http://${SLAVE_IPS[0]}:$ES_PORT/_cluster/state?pretty
