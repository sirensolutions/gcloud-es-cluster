#!/bin/bash

SCRIPT_LOCATION=$(dirname $(readlink -f $0))
GIT_BRANCH=$(cd ${SCRIPT_LOCATION}; git status | head -1 | awk '{print $3}')

ES_PORT=9200

if [[ $1 == "help" || $1 == "-h" || $1 == "--help" ]]; then
cat <<EOF
Usage: $0 [NUM_SLAVES [SLAVE_TYPE]]

This script is invoked on the controller node to spawn a cluster.

In normal operation, the only values you should have to provide are
the number and type of slaves, and these can be given on the command line.
They default to 1 and 'f1-micro' respectively, but note that f1-micro
is unlikely to be useful for real applications.

For advanced use, you can set the following envars [defaults]:

IMAGE [ubuntu-os-cloud/ubuntu-1604-lts]
BOOT_DISK_TYPE [pd-ssd]
BOOT_DISK_SIZE [16GB]
CLUSTER_NAME [es-<timestamp>]
DEBUG []
SITE_CONFIG [gcloud.conf]
ES_VERSION [2.4.4]
PLUGIN_VERSION [2.4.4]
LOGSTASH_VERSION [2.4.1]
GITHUB_CREDENTIALS []
NUM_SLAVES [1]
SLAVE_TYPE [f1-micro]
CPU_PLATFORM []
ES_NODE_CONFIG []
ES_DOWNLOAD_URL []

Credentials are supplied in the form "<username>:<password>".
Command line arguments will override the NUM_SLAVES and SLAVE_TYPE envars.

ES_NODE_CONFIG contains config parameters that should be added to the default
elasticsearch.yml file. These are comma-separated and should not contain any
other commas or leading whitespace (no JSON-style arrays, no indentation).

The special value PLUGIN_VERSION="none" will disable plugin configuration.

ES_DOWNLOAD_URL is used to force a particular URL for downloading the
elasticsearch package. Note that ES_VERSION must still be given, as a hint to
the automatic configurator.
EOF
fi

GCLOUD_PARAMS=()

if [[ ! $GITHUB_CREDENTIALS ]]; then
    echo "No github credentials found; this script will not work. Aborting"
    exit 666
fi

if [[ $1 ]]; then
	NUM_SLAVES=$1
elif [[ ! $NUM_SLAVES ]]; then
	NUM_SLAVES=1
fi

if [[ $2 ]]; then
	SLAVE_TYPE=$2
elif [[ ! $SLAVE_TYPE ]]; then
	SLAVE_TYPE=f1-micro
fi

if [[ $IMAGE ]]; then
	IMAGE_FAMILY=${IMAGE#*/}
	IMAGE_PROJECT=${IMAGE%/*}
else
	IMAGE_FAMILY=ubuntu-1604-lts
	IMAGE_PROJECT=ubuntu-os-cloud
fi

if [[ ! $BOOT_DISK_TYPE ]]; then
	BOOT_DISK_TYPE="pd-ssd"
fi

if [[ ! $BOOT_DISK_SIZE ]]; then
	BOOT_DISK_SIZE="16GB"
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

if [[ $CPU_PLATFORM ]]; then
    # https://unix.stackexchange.com/questions/333548/how-to-prevent-word-splitting-without-preventing-empty-string-removal
    GCLOUD_PARAMS=(${GCLOUD_PARAMS[@]} "--min-cpu-platform=${CPU_PLATFORM}")
fi

# Let's go

PRIMARY_INTERFACE=$(route -n | grep ^0.0.0.0 | head -1 | awk '{print $8}')
PRIMARY_IP_CIDR=$(ip address list dev $PRIMARY_INTERFACE |grep "\binet\b"|awk '{print $2}')
PRIMARY_IP=${PRIMARY_IP_CIDR%%/*}
SUBNET=${PRIMARY_IP%.*}.0/24
NUM_MASTERS=$((NUM_SLAVES/2+1))

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
cd \$(mktemp -d)
CONTROLLER_IP="${PRIMARY_IP}"
export http_proxy="http://\$CONTROLLER_IP:3128/"
export https_proxy="\$http_proxy"

if [[ -n "$GITHUB_CREDENTIALS" ]]; then
	cat <<FOO >~/.git-credentials
https://${GITHUB_CREDENTIALS}@github.com
FOO
	chmod og= ~/.git-credentials
    # For some reason, HOME is not set at this stage. Fix it.
	HOME=/root git config --global credential.helper store
fi

if ! git -c http.proxy=\$http_proxy clone -b ${GIT_BRANCH} https://github.com/sirensolutions/gcloud-es-cluster |& logger -t es-puller; then
	echo "Aborting; no git repository found" |& logger -t es-puller
fi
gcloud-es-cluster/constructor.sh "$SITE_CONFIG" |& logger -t es-constructor
EOF

gcloud compute instances create ${SLAVES[@]} "${GCLOUD_PARAMS[@]}" \
    --boot-disk-type $BOOT_DISK_TYPE --boot-disk-size $BOOT_DISK_SIZE \
    --no-address --image-family=$IMAGE_FAMILY --image-project=$IMAGE_PROJECT \
    --machine-type=$SLAVE_TYPE --metadata-from-file startup-script=$PULLER || exit $?

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
    # NB there must be NO WHITESPACE in the metadata string!
	gcloud compute instances add-metadata $slave --metadata \
es_slave_ips="${SLAVE_IPS[*]}",\
es_num_masters="$NUM_MASTERS",\
es_debug="$DEBUG",\
es_cluster_name="$CLUSTER_NAME",\
es_controller_ip="${PRIMARY_IP}",\
es_version="${ES_VERSION}",\
es_plugin_version="${PLUGIN_VERSION}",\
es_logstash_version="${LOGSTASH_VERSION}",\
es_node_config="${ES_NODE_CONFIG}",\
es_download_url="${ES_DOWNLOAD_URL}",\
es_spinlock_1=released
done

echo "Waiting for OS to come up on each slave..."
for slave in ${SLAVE_IPS[@]}; do
	while ! nc -w 5 $slave 22 </dev/null >/dev/null; do
		sleep 5
	done
	echo "ssh running on $slave"
done
# Repopulate known_hosts
ssh-keyscan ${SLAVE_IPS[@]} >> $HOME/.ssh/known_hosts

### Perform post-assembly tasks (common)

export ES_VERSION
export ES_PORT
$SCRIPT_LOCATION/post-assembly.sh ${SLAVE_IPS[@]}
