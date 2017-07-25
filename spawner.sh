#!/bin/bash
#
# This script is invoked on the controller node to spawn a cluster with
# a given configuration. It should have sensible (i.e. inexpensive!) defaults.

if [[ $1 == "help" || $1 == "-h" || $1 == "--help" ]]; then
cat <<EOF
Usage: $0 [NUM_SLAVES [SLAVE_TYPE]]

It also reads the following envars for defaults:

IMAGE [ubuntu-os-cloud/ubuntu-1604-lts]
SLAVE_PREFIX [es-<timestamp>]
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

if [[ ! $SLAVE_PREFIX ]]; then
	SLAVE_PREFIX=es-$(date +%s)
fi

# Let's go

MASTER_IP=$(hostname --ip-address)

SLAVES=""
for i in $(seq 1 $NUM_SLAVES); do
	SLAVES="$SLAVES $SLAVE_PREFIX-node$i"
done

# Now create a one-shot puller script
PULLER=$(tempfile)

cat <<EOF > $PULLER
#!/bin/bash
cd /tmp
git clone https://github.com/sirensolutions/gcloud-es-cluster && /bin/bash ./gcloud-es-cluster/constructor.sh "MASTER_IP=$MASTER_IP; $CONSTRUCTOR_ARGS" |& logger -t es-constructor
EOF

gcloud compute instances create $SLAVES --no-address --image-family=$IMAGE_FAMILY --image-project=$IMAGE_PROJECT --machine-type=$SLAVE_TYPE --metadata-from-file startup-script=$PULLER || exit $?

rm $PULLER

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
