#!/bin/bash

SCRIPT_LOCATION=$(dirname $(readlink -f $0))
GIT_BRANCH=$(cd ${SCRIPT_LOCATION}; git status | head -1 | awk '{print $3}')

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
SITE_CONFIG [gcloud.conf]
ES_VERSION [2.4.4]
PLUGIN_VERSION [2.4.4]
LOGSTASH_VERSION [2.4.1]
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

if [[ ! $SITE_CONFIG ]]; then
	SITE_CONFIG="gcloud.conf"
fi

if [[ ! $ES_VERSION ]]; then
	ES_VERSION=2.4.4
fi

if [[ ! $PLUGIN_VERSION ]]; then
	PLUGIN_VERSION=2.4.4
fi

if [[ ! $LOGSTASH_VERSION ]]; then
	LOGSTASH_VERSION=2.4.4
fi

# Let's go

PRIMARY_IP=$(hostname --ip-address)
SUBNET=${PRIMARY_IP%.*}.0/24
NUM_MASTERS=$[(NUM_SLAVES/2)+1]

SLAVES=()
for i in $(seq 1 $NUM_SLAVES); do
	SLAVES=(${SLAVES[@]} $CLUSTER_NAME-node$i)
done

# Now create a one-shot puller script
PULLER=$(tempfile)

# NB you need to specify http_proxy EXACTLY as "http://<ip>:<port>/" if using apt
# https://unix.stackexchange.com/questions/180312/cant-install-debian-because-installer-doesnt-parse-ip-correctly
cat <<EOF > $PULLER
#!/bin/bash
cd /tmp
CONTROLLER_IP="${PRIMARY_IP}"
export http_proxy="http://\$CONTROLLER_IP:3128/"
export https_proxy="\$http_proxy"
if ! git -c http.proxy=\$http_proxy clone -b ${GIT_BRANCH} https://github.com/sirensolutions/gcloud-es-cluster |& logger -t es-puller; then
	echo "Aborting; no git repository found" |& logger -t es-puller
fi
gcloud-es-cluster/constructor.sh "$SITE_CONFIG" |& logger -t es-constructor
EOF

gcloud compute instances create ${SLAVES[@]} --no-address --image-family=$IMAGE_FAMILY --image-project=$IMAGE_PROJECT --machine-type=$SLAVE_TYPE --metadata-from-file startup-script=$PULLER || exit $?

if [[ ! $DEBUG ]]; then
  rm $PULLER
fi

# Do all the housekeeping first, get it over with
SLAVE_IPS=()
for slave in ${SLAVES[@]}; do
	ip=$(gcloud compute instances describe $slave|grep networkIP|awk '{print $2}')
	SLAVE_IPS=(${SLAVE_IPS[@]} $ip)
	# Delete this IP from our known_hosts because we know it has been changed
	ssh-keygen -f "$HOME/.ssh/known_hosts" -R $ip >& /dev/null
done

# Now that we know all the slave IPs, we can tell the slaves themselves.
echo "Pushing metadata..."
for slave in ${SLAVES[@]}; do
	# The constructors should spin on es_spinlock_1 to avoid race conditions
	gcloud compute instances add-metadata $slave \
	--metadata es_slave_ips="${SLAVE_IPS[*]}",es_num_masters="$NUM_MASTERS",es_debug="$DEBUG",es_cluster_name="$CLUSTER_NAME",es_controller_ip="${PRIMARY_IP}",es_version="${ES_VERSION}",es_plugin_version="${PLUGIN_VERSION}",es_logstash_version="${LOGSTASH_VERSION}",es_spinlock_1=released
done

echo "Waiting for OS to come up on each slave..."
for ip in ${SLAVE_IPS[@]}; do
	while ! nc -w 5 $ip 22 </dev/null >/dev/null; do
		sleep 5
	done
	echo "$ip running"
done
# Repopulate known_hosts
ssh-keyscan $SLAVES >> $HOME/.ssh/known_hosts

### Perform post-assembly tasks (common)

export ES_VERSION
export ES_PORT
$SCRIPT_LOCATION/post-assembly.sh ${SLAVE_IPS[@]}
