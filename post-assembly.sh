#!/bin/bash

### Perform post-assembly tasks (common)

# Pass in the list of slave IPS.
# This also requires two envars:
# 	ES_PORT
# 	ES_VERSION

# Don't show progress bar, but do show errors
CURL_ARGS="-sS -f -L"

SLAVES=("$@")

echo "Waiting for elasticsearch to come up on each slave..."
for slave in ${SLAVES[@]}; do
	while ! nc -w 5 $slave $ES_PORT </dev/null >/dev/null; do
        if ! nc -w 5 $slave 22 </dev/null >/dev/null; then
            echo "$slave not responding on ssh port; dead?"
        fi
		sleep 5
	done
	echo "elasticsearch running on $slave"
done

# We no longer need to set index caching preferences in ES v5

# Now get the status of the cluster from the first node
curl $CURL_ARGS -XGET http://${SLAVES[0]}:$ES_PORT/_cluster/state?pretty
