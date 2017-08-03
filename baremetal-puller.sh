#!/bin/bash
cd /tmp

apt update && apt install git

if ! git clone https://github.com/sirensolutions/gcloud-es-cluster |& logger -t es-puller; then
	echo "Aborting; no git repository found" |& logger -t es-puller
fi

gcloud-es-cluster/constructor.sh "/tmp/baremetal.conf" |& logger -t es-constructor
