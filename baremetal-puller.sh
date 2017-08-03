#!/bin/bash
cd /tmp

GIT_BRANCH=master

for arg in $@; do
	case "$arg" in
	*=*)
		eval $arg
		;;
	*)
		eval $arg=true
		;;
	esac
done

if [[ $DISABLE_IPV6 ]]; then
	# This is temporary, we'll fix it permanently in the constructor
	sysctl -w "net.ipv6.conf.all.disable_ipv6=1" |& logger -t es-puller
fi

if [[ $http_proxy ]]; then
	export http_proxy
	export https_proxy="$http_proxy"
	GIT_OPTIONS="-c http.proxy=$http_proxy"
fi

if [[ $APT_INSTALL_GIT ]]; then
	apt-get update |& logger -t es-puller
	DEBIAN_FRONTEND=noninteractive apt-get install -y git |& logger -t es-puller
fi

if ! git ${GIT_OPTIONS} clone -b ${GIT_BRANCH} https://github.com/sirensolutions/gcloud-es-cluster |& logger -t es-puller; then
	echo "Aborting; no git repository found" |& logger -t es-puller
fi

gcloud-es-cluster/constructor.sh "/tmp/baremetal.conf" |& logger -t es-constructor
