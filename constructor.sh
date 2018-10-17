#!/bin/bash
#
# Constructor for setting up an elasticsearch cluster

check_error() {
    if [ $? -ne 0 ]; then
        echo Failed on $1
        exit 1
    fi
}

# Function to add quote-brackets to bare ipv6 addresses only
# Use this before appending ":port" to ensure ipv6 sanity
bracketed_ip() {
    ip=$1
    # We test for an ipv6 address by trying to remove two colons
    ip_noopenbracket="${ip#[}"
    ip_removeonecolon="${ip%:*}"
    ip_removetwocolons="${ip_removeonecolon%:*}"
    if [[ ${ip_noopenbracket} == ${ip} && ${ip_removetwocolons} != ${ip_removeonecolon} ]]; then
        # promote bare-ipv6 to bracketed format
        echo "[${ip}]"
    else
        echo "$ip"
    fi
}

# Function to remove quote-brackets and :port from ip addresses
bare_ip() {
    ip=$1
    # We test for an ipv6 address by trying to remove two colons
    ip_noopenbracket="${ip#[}"
    ip_removeonecolon="${ip%:*}"
    ip_removetwocolons="${ip_removeonecolon%:*}"
    if [[ ${ip_noopenbracket} != ${ip} ]]; then
        # return bracketed-ipv6 to bare format without any trailing port
        echo "${ip_noopenbracket%]*}"
    elif [[ ${ip_noopenbracket} == ${ip} && ${ip_removetwocolons} != ${ip_removeonecolon} ]]; then
        # do nothing; we have a bare ipv6 (which can't have a :port in principle)
        echo "$ip"
    else
        # remove any trailing port from ipv4
        echo "${ip%:*}"
    fi
}

# Function to send a nonsense request to the http_proxy for debugging purposes
proxy_log() {
    [[ $DEBUG ]] || return
    [[ $http_proxy ]] || return
    curl -s "http://$HOSTNAME/$1" | true
}

##### SETTINGS #####

# Sysctl max_map_count (>=262144)
MAX_MAP_COUNT=262144

### Default values

# Software versions
ES_VERSION=2.4.4
LOGSTASH_VERSION=2.4.1
PLUGIN_VERSION=2.4.4

# The parent directory under which we create our data subdirectory.
BASE_PARENT=/opt
# The user that will own the files and processes.
ES_USER=elastic

ES_LINKNAME=elasticsearch

# How much memory to allocate to elastic. We default this to half the
# machine's total memory or 31GB (whichever is smaller)
# but the spawner can override below.
total_mem_kb=$(grep MemTotal /proc/meminfo|awk '{print $2}')
half_mem_mb=$[total_mem_kb / 2048]
if [[ $half_mem_mb -gt 31744 ]]; then
    ES_HEAP_SIZE=31744m
else
    ES_HEAP_SIZE=${half_mem_mb}m
fi

# Use default ports for simplicity
SSH_PORT=22
ES_PORT=9200
ES_TRANS_PORT=9300

# Don't show progress bar, but do show errors
CURL_ARGS="-sS -f -L"

SCRIPT_DIR="$(dirname $(readlink -f $0))"

# We can optionally override the branches of our repo dependencies
# But most of the time we probably just want "master"
GIT_DEMOS_BRANCH=master
ADMIN_TOOLS_BRANCH=master

##### END DEFAULT SETTINGS #####

echo Loading site config \"$1\"

# Pushd/popd so we can handle both absolute and relative paths sensibly.
pushd ${SCRIPT_DIR} >/dev/null
. $1
popd >/dev/null

proxy_log "loaded site config $1"
echo DEBUG=$DEBUG

systemdstat=$(systemctl --version | head -1)
if [[ $? && "$(echo $systemdstat | awk '{print $2}')" -gt 227 ]]; then
    SYSTEMD=true
else
    SYSTEMD=false
fi

DEPENDENCIES="unzip ufw oracle-java8-installer tar jq acl iperf metricbeat"
if [[ ! $SYSTEMD ]]; then
    DEPENDENCIES="$DEPENDENCIES supervisor"
fi

if [[ $http_proxy ]]; then
    # save our http_proxy configuration for future use
    cat <<EOF >/etc/profile.d/00-proxy.sh
    export http_proxy=$http_proxy
    export https_proxy=$http_proxy
EOF

    # elasticsearch does not parse proxy envars, so define java properties
    # note that elasticsearch is inconsistent, so we need to cover MANY options
    # https://github.com/elastic/puppet-elasticsearch/issues/152
    # we assume here that http and https proxies will be the same
    http_proxy_host=${http_proxy%:*}
    http_proxy_host=${http_proxy_host#http://}
    http_proxy_port=${http_proxy##*:}
    http_proxy_port=${http_proxy_port%/}
    export ES_JAVA_OPTS="\
-Dhttp.proxyHost=$http_proxy_host -Dhttp.proxyPort=$http_proxy_port \
-Dhttps.proxyHost=$http_proxy_host -Dhttps.proxyPort=$http_proxy_port \
-DproxyHost=$http_proxy_host -DproxyPort=$http_proxy_port \
"
fi


### Shouldn't need to change any of these

SRC_DIR=/root
TMP_DIR=$(mktemp -d)
BASE=$BASE_PARENT/elastic

# Check that the user exists
if ! grep -q "^${ES_USER}:" /etc/passwd; then
    proxy_log "adding user $ES_USER"
    adduser --disabled-login --system --home $BASE --no-create-home $ES_USER
fi

# sometimes (I'm looking at you, Hetzner) we can find ourselves with a
# bad IPv6 configuration. If so, disable it here.
if [[ $DISABLE_IPV6 && "$DISABLE_IPV6" !="false" ]]; then
    proxy_log "disabling ipv6"
    echo "net.ipv6.conf.all.disable_ipv6 = 1" > /etc/sysctl.d/99-disable-ipv6-all.conf
    sysctl -p /etc/sysctl.d/99-disable-ipv6-all.conf
fi

# Find a fallback listening ip for now; probably won't use it
PRIMARY_INTERFACE=$(route -n | grep ^0.0.0.0 | head -1 | awk '{print $8}')
PRIMARY_IP_CIDR=$(ip address list dev $PRIMARY_INTERFACE |grep "\binet\b"|awk '{print $2}')
PRIMARY_IP=${PRIMARY_IP_CIDR%%/*}

# Find the common member of (slave ip list, our ip list) to listen on
MY_IPS=$(ip address list |grep inet|awk '{print $2}'|awk -F/ '{print $1}')
for ip in $SLAVE_IPS; do
    ip=$(bare_ip $ip)
    for my_ip in $MY_IPS; do
        if [[ $my_ip == $ip ]]; then
            PRIMARY_IP=$(bracketed_ip $ip)
        fi
    done
done

if [[ $DEBUG ]]; then
    echo SRC_DIR=$SRC_DIR
    echo TMP_DIR=$TMP_DIR
    echo BASE=$BASE
    echo PRIMARY_IP=$PRIMARY_IP
fi

# Make sure our workspace is clean
if [[ -d $BASE ]]; then
    if [[ $SHOVE_BASE && "$SHOVE_BASE" != "false" ]]; then
        OLD_BASE=$BASE.$(date +%s)
        proxy_log "shove_base"
        if ! mv $BASE $OLD_BASE; then
            echo "Could not move $BASE to $OLD_BASE. Aborting"
            exit 1
        fi
    else
        echo "Directory $BASE already exists. Aborting"
        exit 1
    fi
fi
proxy_log "mkdir $BASE"
if ! mkdir -p $BASE; then
    echo "Could not create directory $BASE. Aborting"
    exit 1
else
    cd $BASE
fi


##### PULL OTHER GIT REPOS #####

pushd ${TMP_DIR} >/dev/null

proxy_log "git clone demos"
git -c http.proxy=$http_proxy clone -b ${GIT_DEMOS_BRANCH} https://github.com/sirensolutions/demos
check_error "git clone demos"
DEMO_SCRIPT_DIR=$PWD/demos

proxy_log "git clone admin-tools"
git -c http.proxy=$http_proxy clone -b ${ADMIN_TOOLS_BRANCH} https://github.com/andrewgdotcom/admin-tools
check_error "git clone admin-tools"
ADMIN_TOOLS_DIR=$PWD/admin-tools

popd >/dev/null

##### END PULL OTHER GIT REPOS #####


##### DOWNLOAD SOFTWARE #####

add-apt-repository ppa:webupd8team/java
${ADMIN_TOOLS_DIR}/apt-repo add beats "https://artifacts.elastic.co/packages/6.x/apt stable main" https://artifacts.elastic.co/GPG-KEY-elasticsearch

proxy_log "apt"
export DEBIAN_FRONTEND=noninteractive
apt-get update
dpkg --configure -a
apt-get -f install
# preseed the debian installer with our Java license acceptance
echo 'oracle-java8-installer shared/accepted-oracle-license-v1-1 boolean true' | debconf-set-selections
# make sure the installer does not prompt; there's nobody listening
apt-get -y install $DEPENDENCIES

check_error "apt install"

##### END DOWNLOAD SOFTWARE #####


##### FIREWALL CONFIGURATION #####

# Always allow the ssh remote client and the controller ip
SSH_REMOTE_HOST=${SSH_CLIENT%% *}

for ip in $SSH_REMOTE_HOST $CONTROLLER_IP $SLAVE_IPS; do
    ip=$(bare_ip $ip)
    for port in $SSH_PORT $ES_PORT $ES_TRANS_PORT; do
        proxy_log "ufw allow to any port $port from $ip"
        ufw allow to any port $port from $ip comment "es-constructor"
    done
done

proxy_log "ufw enable"
sudo ufw --force enable

##### END FIREWALL CONFIGURATION #####


proxy_log "start elastic config"

##### ELASTICSEARCH CONFIGURATION #####

# CALL OUT TO MODULAR SCRIPT
BASE="$BASE" \
    ES_VERSION="$ES_VERSION" \
    PLUGIN_VERSION="$PLUGIN_VERSION" \
    ES_PORT="$ES_PORT" \
    ES_TRANS_PORT="$ES_TRANS_PORT" \
    ES_USER="$ES_USER" \
    DEBUG="$DEBUG" \
    SYSTEMD="$SYSTEMD" \
    SLAVE_IPS="$SLAVE_IPS" \
    NUM_MASTERS="$NUM_MASTERS" \
    ES_DOWNLOAD_URL="$ES_DOWNLOAD_URL" \
    ES_NODE_CONFIG="$ES_NODE_CONFIG" \
    ES_JAVA_OPTS="$ES_JAVA_OPTS $CUSTOM_ES_JAVA_OPTS" \
    ES_HEAP_SIZE="$ES_HEAP_SIZE" \
    MAX_MAP_COUNT="$MAX_MAP_COUNT" \
    PRIMARY_IP="$PRIMARY_IP" \
    BIND_HOST="0" \
    SERVICE_NAME="elastic" \
    CLUSTER_NAME="$CLUSTER_NAME" \
    ES_LINKNAME="$ES_LINKNAME" \
    ${DEMO_SCRIPT_DIR}/make-elastic.sh || exit 99


proxy_log "cleanup"

##### STORE CONFIGURATION VARIABLES #####

cat <<EOF >/var/cache/es-constructor.conf
# Stored configuration from the es-constructor.
# Source this to populate handy variables, saves looking for them.

ES_BASE=$ES_BASE
#LOGSTASH_BASE=$LOGSTASH_BASE
ES_VERSION=$ES_VERSION
#LOGSTASH_VERSION=$LOGSTASH_VERSION
PLUGIN_VERSION=$PLUGIN_VERSION
ES_PORT=$ES_PORT
ES_TRANS_PORT=$ES_TRANS_PORT
ES_HEAP_SIZE=$ES_HEAP_SIZE
ES_JAVA_OPTS=$ES_JAVA_OPTS
CUSTOM_ES_JAVA_OPTS=$CUSTOM_ES_JAVA_OPTS
ES_NODE_CONFIG=$ES_NODE_CONFIG
CONTROLLER_IP=$CONTROLLER_IP
PRIMARY_IP=$PRIMARY_IP
SLAVE_IPS=$SLAVE_IPS
ES_USER=$ES_USER
EOF

##### END STORE CONFIGURATION VARIABLES #####


if [[ ! $DEBUG ]]; then
    rm -rf $TMP_DIR
fi
