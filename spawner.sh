#!/bin/bash

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

for slave in $SLAVES; do
	ip=$(gcloud compute instances describe $slave|grep networkIP|awk '{print $2}')
	# Delete this IP from our known_hosts because we know it has been changed
	ssh-keygen -f "$HOME/.ssh/known_hosts" -R $ip >& /dev/null
	while ! nc -w 5 $ip 22 </dev/null >/dev/null; do
		sleep 5
	done
	echo $slave ready
done
