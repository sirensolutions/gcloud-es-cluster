#!/bin/bash

set -eo pipefail
err_report() {
    echo "errexit on line $(caller)" >&2
}
trap err_report ERR

die() {
    echo $2 >&2
    exit $1
}

SCRIPT_DIR=$(dirname $(readlink -f $0))
GIT_BRANCH=$(cd ${SCRIPT_DIR}; git status | awk '{print $3; exit}')

ES_PORT=9200

. ${SCRIPT_DIR}/defaults

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

For advanced use, you can set the following envars / cmdline flags [defaults]:

DEBUG / --debug []
ES_VERSION / --es-version [${ES_DEFAULT}]
PLUGIN_VERSION / --plugin-version [${PLUGIN_DEFAULT}]
LOGSTASH_VERSION / --logstash-version [${LOGSTASH_DEFAULT}]
FOREIGN_MEMBERS / --foreign-members []
GITHUB_CREDENTIALS / --github-credentials []
ES_NODE_CONFIG / --es-node-config []
ES_DOWNLOAD_URL / --es-download-url []
CONTROLLER_IP / --controller-ip []
CUSTOM_ES_JAVA_OPTS / --custom-es-java-opts []
HOSTS_FILE / --hosts-file []
DISABLE_IPV6 / --[no-]disable-ipv6
SHOVE_BASE / --[no-]shove-base

Note that FOREIGN_MEMBERS is a whitespace separated list of items in
the format "IP" or "IP:TRANS_PORT" (default port 9300). These are
members that should be added to the cluster but won't be managed by
this installer script.

Credentials are supplied in the form "<username>:<password>"

ES_NODE_CONFIG contains config parameters that should be added to the default
elasticsearch.yml file. These are comma-separated and should not contain any
other commas or leading whitespace (no JSON-style arrays, no indentation).

The special value PLUGIN_VERSION="none" will disable plugin configuration.

ES_DOWNLOAD_URL is used to force a particular URL for downloading the
elasticsearch package. Note that ES_VERSION must still be given, as a hint to
the automatic configurator.
EOF
fi

[[ -f ${SCRIPT_DIR}/poshlib/parse-opt.sh ]] || die 1 "Could not find poshlib"

# No short arguments
declare -A PO_SHORT_MAP

# All long arguments are lowercase versions of their corresponding envars
declare -A PO_LONG_MAP
for envar in HOSTS_FILE FOREIGN_MEMBERS \
    ES_VERSION PLUGIN_VERSION LOGSTASH_VERSION GITHUB_CREDENTIALS \
    ES_NODE_CONFIG ES_DOWNLOAD_URL CONTROLLER_IP \
    CUSTOM_ES_JAVA_OPTS DEBUG; do
    PO_LONG_MAP["$(echo $envar | tr A-Z_ a-z-):"]="$envar"
done
for envar in SHOVE_BASE DISABLE_IPV6; do
    PO_LONG_MAP["$(echo $envar | tr A-Z_ a-z-)"]="$envar"
done

# parse command line options
. /opt/git/admin-tools/parse-opt.sh


if [[ ! $GITHUB_CREDENTIALS ]]; then
    echo "No github credentials found; this script will not work. Aborting"
    exit 666
fi

CLUSTER=$1
PRIMARY_IP=$(hostname --ip-address)
SLAVES=$(ansible $CLUSTER -c local -m command -a "echo {{ inventory_hostname }}" | grep -v ">>" | sort -n )
NUM_MASTERS=$[ $(echo $SLAVES $FOREIGN_MEMBERS | wc -w) / 2 + 1 ]

if [[ ! $ES_VERSION ]]; then
	ES_VERSION=$ES_DEFAULT
fi

if [[ ! $PLUGIN_VERSION ]]; then
	PLUGIN_VERSION=$PLUGIN_DEFAULT
fi

if [[ ! $LOGSTASH_VERSION ]]; then
	LOGSTASH_VERSION=$LOGSTASH_DEFAULT
fi


# get our slave IPs from $HOSTS_FILE
declare -A SLAVE_IPS
if [[ $HOSTS_FILE ]]; then
    for slave in $SLAVES; do
        slave_name=$slave
        while [[ $slave_name ]]; do
            ip=$(grep "\s${slave_name}\b" $HOSTS_FILE | grep -v '^\s*#' | awk '{print $1; exit}')
            if [[ $ip ]]; then
                SLAVE_IPS[$slave]="$ip"
                break
            elif [[ ${slave_name%.*} == ${slave_name} ]]; then
                slave_name=""
            else
                slave_name="${slave_name%.*}"
            fi
        done
        if [[ ! "${SLAVE_IPS[$slave]}" ]]; then
            echo "Could not find slave ${slave} in ${HOSTS_FILE}; aborting"
            exit 77
        fi
    done
else
  for slave in $SLAVES; do
	SLAVE_IPS[$slave]=$(getent hosts ${slave} | awk '{print $1; exit}')
  done
fi

echo "Push cluster configuration and invoke the puller"
conffile=$(tempfile)
cat <<EOF >${conffile}
SLAVE_IPS="${SLAVE_IPS[@]} ${FOREIGN_MEMBERS}"
SLAVE_NAMES="${SLAVES} ${FOREIGN_MEMBERS}"
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
ES_NODE_CONFIG=${ES_NODE_CONFIG}
ES_DOWNLOAD_URL=${ES_DOWNLOAD_URL}
CONTROLLER_IP=${CONTROLLER_IP}
CUSTOM_ES_JAVA_OPTS=${CUSTOM_ES_JAVA_OPTS}
EOF

# Git is not installed on hetzner
# IPv6 must be disabled on hetzner
# Make sure the remote is using the same branch as us
PULLER_ARGS="APT_INSTALL_GIT=true DISABLE_IPV6=${DISABLE_IPV6} GIT_BRANCH=${GIT_BRANCH} GITHUB_CREDENTIALS=${GITHUB_CREDENTIALS}"

for slave in $SLAVES; do
	scp ${conffile} root@$slave:/tmp/baremetal.conf
	scp ${SCRIPT_DIR}/baremetal-puller.sh root@$slave:/tmp/puller.sh
	ssh root@$slave /tmp/puller.sh ${PULLER_ARGS} &
done

rm ${conffile}

### Perform post-assembly tasks (common)

export ES_VERSION
export ES_PORT
$SCRIPT_DIR/post-assembly.sh ${SLAVES[@]}
