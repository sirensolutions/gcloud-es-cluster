#!/bin/bash

SCRIPT_LOCATION=$(dirname $(readlink -f $0))
GIT_BRANCH=$(cd ${SCRIPT_LOCATION}; git status | head -1 | awk '{print $3}')

ES_PORT=9200

if [[ ! $1 || $1 = "-h" || $1 = "--help" ]]; then
cat <<EOF
Usage: $0 CLUSTER_NAME

This script is invoked on the controller node to spawn a cluster on
physical machines. 

CLUSTER_NAME is the name of the cluster as defined as a group in
/etc/ansible/hosts. Machines will take their names from
/etc/ansible/hosts and their IPs must be defined in /etc/hosts .
If the connection between the controller and the members should use
different IPs than the members should use to connect to each other,
then the inter-member IPs should be defined in a separate hosts file,
and the name of the file passed in the HOSTS_FILE envar.

For advanced use, you can set the following envars [defaults]:

DEBUG []
ES_VERSION [2.4.4]
PLUGIN_VERSION [2.4.4]
LOGSTASH_VERSION [2.4.1]
FOREIGN_MEMBERS []
DISABLE_IPV6 []
HOSTS_FILE []
GITHUB_CREDENTIALS []

Note that FOREIGN_MEMBERS is a whitespace separated list of items in
the format "IP" or "IP:TRANS_PORT" (default port 9300). These are 
members that should be added to the cluster but won't be managed by
this installer script.

Credentials are supplied in the form "<username>:<password>"
EOF
fi

if [[ ! $GITHUB_CREDENTIALS ]]; then
    echo "No github credentials found; this script will not work. Aborting"
    exit 666
fi

CLUSTER=$1
PRIMARY_IP=$(hostname --ip-address)
SLAVES=$(ansible $CLUSTER -c local -m command -a "echo {{ inventory_hostname }}" | grep -v ">>" | sort -n )
NUM_MASTERS=$[ $(echo $SLAVES $FOREIGN_MEMBERS | wc -w) / 2 + 1 ]

if [[ ! $ES_VERSION ]]; then
	ES_VERSION=2.4.4
fi

if [[ ! $PLUGIN_VERSION ]]; then
	PLUGIN_VERSION=2.4.4
fi

if [[ ! $LOGSTASH_VERSION ]]; then
	LOGSTASH_VERSION=2.4.1
fi


# get our slave IPs from $HOSTS_FILE
declare -A SLAVE_IPS
if [[ $HOSTS_FILE ]]; then
  for slave in $SLAVES; do
	SLAVE_IPS[$slave]=$(grep "\b${slave}\b" $HOSTS_FILE | grep -v '^\s*#' | awk '{print $1}' | head -1)
  done
else
  for slave in $SLAVES; do
	SLAVE_IPS[$slave]=$(getent hosts ${slave} | awk '{print $1}' | head -1)
  done
fi

echo "Push cluster configuration and invoke the puller"
conffile=$(tempfile)
cat <<EOF >${conffile}
SLAVE_IPS="${SLAVE_IPS[@]} ${FOREIGN_MEMBERS}"
NUM_MASTERS=$NUM_MASTERS
DEBUG=${DEBUG}
CLUSTER_NAME=${CLUSTER}
ES_VERSION=${ES_VERSION}
LOGSTASH_VERSION=${LOGSTASH_VERSION}
PLUGIN_VERSION=${PLUGIN_VERSION}
BASE_PARENT=/data
DISABLE_IPV6=${DISABLE_IPV6}
SHOVE_BASE=${SHOVE_BASE}
GITHUB_CREDENTIALS=${GITHUB_CREDENTIALS}
EOF

# Git is not installed on hetzner
# IPv6 must be disabled on hetzner
# Make sure the remote is using the same branch as us
PULLER_ARGS="APT_INSTALL_GIT=true DISABLE_IPV6=${DISABLE_IPV6} GIT_BRANCH=${GIT_BRANCH} GITHUB_CREDENTIALS=${GITHUB_CREDENTIALS}"

for slave in $SLAVES; do
	scp ${conffile} root@$slave:/tmp/baremetal.conf
	scp ${SCRIPT_LOCATION}/baremetal-puller.sh root@$slave:/tmp/puller.sh
	ssh root@$slave /tmp/puller.sh ${PULLER_ARGS} &
done

rm ${conffile}

### Perform post-assembly tasks (common)

export ES_VERSION
export ES_PORT
$SCRIPT_LOCATION/post-assembly.sh ${SLAVES[@]}
