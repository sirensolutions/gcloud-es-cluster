#!/bin/bash

ES_PORT=9200

if [[ $1 == "help" || $1 == "-h" || $1 == "--help" ]]; then
cat <<EOF
Usage: $0 [NUM_SLAVES [SLAVE_TYPE]]

This script is invoked on the controller node to spawn a cluster.

In normal operation, the only values you should have to provide are 
the number and type of slaves, and these are given on the command line.
They default to 1 and 'f1-micro' respectively, but note that f1-micro
is unlikely to be useful for real applications.

For advanced use, you can set the following envars [defaults]:

IMAGE [ubuntu-os-cloud/ubuntu-1604-lts]
CLUSTER_NAME [es-<timestamp>]
DEBUG []
CONSTRUCTOR_ARGS []
EOF
fi

if [[ $1 ]]; then
	NUM_SLAVES=$1
else
	NUM_SLAVES=1
fi

if [[ $2 ]]; then
	SLAVE_TYPE=$2
else
	SLAVE_TYPE=f1-micro
fi

if [[ $IMAGE ]]; then
	IMAGE_FAMILY=${IMAGE#*/}
	IMAGE_PROJECT=${IMAGE%/*}
else
	IMAGE_FAMILY=ubuntu-1604-lts
	IMAGE_PROJECT=ubuntu-os-cloud
fi

if [[ ! $CLUSTER_NAME ]]; then
	CLUSTER_NAME=es-$(date +%s)
fi

# Let's go

PRIMARY_IP=$(hostname --ip-address)

SLAVES=""
for i in $(seq 1 $NUM_SLAVES); do
	SLAVES="$SLAVES $CLUSTER_NAME-node$i"
done

# Now create a one-shot puller script
PULLER=$(tempfile)

# NB you need to specify http_proxy EXACTLY as "http://<ip>:<port>/" if using apt
# https://unix.stackexchange.com/questions/180312/cant-install-debian-because-installer-doesnt-parse-ip-correctly
cat <<EOF > $PULLER
#!/bin/bash
cd /tmp
export http_proxy="http://$PRIMARY_IP:3128/"
export https_proxy="\$http_proxy"
if ! git -c http.proxy=\$http_proxy clone https://github.com/sirensolutions/gcloud-es-cluster |& logger -t es-puller; then
	echo "Aborting; no git repository found" |& logger -t es-puller
fi
gcloud-es-cluster/constructor.sh "CONTROLLER_IP=$PRIMARY_IP; DEBUG=$DEBUG; $CONSTRUCTOR_ARGS" |& logger -t es-constructor
EOF

gcloud compute instances create $SLAVES --no-address --image-family=$IMAGE_FAMILY --image-project=$IMAGE_PROJECT --machine-type=$SLAVE_TYPE --metadata-from-file startup-script=$PULLER || exit $?

if [[ ! $DEBUG ]]; then
  rm $PULLER
fi

# Now poll the info for each slave and wait until they are all connectible

SLAVE_IPS=""
for slave in $SLAVES; do
	ip=$(gcloud compute instances describe $slave|grep networkIP|awk '{print $2}')
	SLAVE_IPS="$SLAVE_IPS $ip"
	SLAVE_IPS_QUOTED="$SLAVE_IPS_QUOTED \"$ip\","
	# Delete this IP from our known_hosts because we know it has been changed
	ssh-keygen -f "$HOME/.ssh/known_hosts" -R $ip >& /dev/null
	while ! nc -w 5 $ip $ES_PORT </dev/null >/dev/null; do
		sleep 5
	done
	echo $slave running
done
# Remove trailing comma
SLAVE_IPS_QUOTED=${SLAVE_IPS_QUOTED%,}

NUM_MASTERS=$[int(NUM_SLAVES/2)+1]

echo Assembling cluster
# Push cluster options to each slave
for ip in $SLAVE_IPS; do
	curl -XPUT http://$ip:$ES_PORT/_cluster/settings?pretty -d '{
		"persistent" : {
			"discovery.zen.minimum_master_nodes" : $NUM_MASTERS,
			"discovery.zen.ping.unicast.hosts" : [ $SLAVE_IPS_QUOTED ]
		}
	}'
done
