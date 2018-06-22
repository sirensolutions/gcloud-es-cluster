#!/bin/bash

### Perform post-assembly tasks (common)

# Pass in the list of slave IPS.
# This also requires two envars:
# 	ES_PORT
# 	ES_VERSION

# Don't show progress bar, but do show errors
CURL_ARGS="-sS -f -L"

SLAVES=("$@")
declare -A status
for slave in ${SLAVES[@]}; do
    status[$slave]="unknown"
done

check_status() {
    for slave in ${SLAVES[@]}; do
        if [[ status[$slave] != "alive" ]]; then
            return 1
        fi
    done
}

echo "Waiting for elasticsearch to come up on each slave..."
while ! check_status; do
    for slave in ${SLAVES[@]}; do
        if nc -w 5 $slave $ES_PORT </dev/null >/dev/null; then
            if [[ ${status[$slave]} != alive ]]; then
                echo "$slave is up on port $ES_PORT"
                status[$slave]=alive
            fi
        else
            if [[ ${status[$slave]} == alive ]]; then
                echo "$slave has stopped responding on $ES_PORT"
                status[$slave]=unknown
            fi
            # if ! nc -w 5 $slave 22 </dev/null >/dev/null; then
            #     if [[ ${status[$slave]} != dead ]]; then
            #         echo "$slave not responding on ssh port; dead?"
            #         status[$slave]=dead
            #     fi
            # else
            #     if [[ ${status[$slave]} == dead ]]; then
            #         echo "$slave is responding again on ssh port"
            #         status[$slave]=unknown
            #     fi
            # fi
        fi
    done
    sleep 10
done

# We no longer need to set index caching preferences in ES v5

# Now get the status of the cluster from the first node
curl $CURL_ARGS -XGET http://${SLAVES[0]}:$ES_PORT/_cluster/state?pretty
