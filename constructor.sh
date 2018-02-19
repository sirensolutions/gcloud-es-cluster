#!/bin/bash
#
# Constructor for setting up an elasticsearch cluster

check_error() {
  if [ $? -ne 0 ]; then
    echo Failed on $1
    exit 1
  fi
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
USER=elastic

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
ES_PORT=9200
ES_TRANS_PORT=9300

# Don't show progress bar, but do show errors
CURL_ARGS="-sS -f -L"

# We can optionally override the branches of our repo dependencies
# But most of the time we probably just want "master"
GIT_DEMOS_BRANCH=master

##### END DEFAULT SETTINGS #####

echo Loading site config \"$1\"

# Pushd/popd so we can handle both absolute and relative paths sensibly.
pushd $(dirname $(readlink -f $0)) >/dev/null
. $1
popd >/dev/null

echo DEBUG=$DEBUG 

systemdstat=$(systemctl --version)
if [[ $? && "$(echo $systemdstat | awk '{print $2}')" -gt 227 ]]; then
	SYSTEMD=true
fi

DEPENDENCIES="unzip ufw oracle-java8-installer"
if [[ !$SYSTEMD ]]; then
	DEPENDENCIES="$DEPENDENCIES supervisor"
fi

# save our http_proxy configuration for future use
cat <<EOF >/etc/profile.d/00-proxy.sh
export http_proxy=$http_proxy
EOF

# elasticsearch does not parse proxy envars, so define java properties
# note that elasticsearch is inconsistent, so we need to cover MANY options
# https://github.com/elastic/puppet-elasticsearch/issues/152
# we assume here that http and https proxies will be the same
http_proxy_host=${http_proxy%:*}
http_proxy_host=${http_proxy_host#http://}
http_proxy_port=${http_proxy##*:}
http_proxy_port=${http_proxy_port%/}
export ES_JAVA_OPTS="-Dhttp.proxyHost=$http_proxy_host -Dhttp.proxyPort=$http_proxy_port -Dhttps.proxyHost=$http_proxy_host -Dhttps.proxyPort=$http_proxy_port -DproxyHost=$http_proxy_host -DproxyPort=$http_proxy_port" 


ES_MAJOR_VERSION=${ES_VERSION%%.*}
if [[ $DEBUG ]]; then
	echo ES_MAJOR_VERSION=$ES_MAJOR_VERSION 
fi

if [[ ${ES_MAJOR_VERSION} == "2" ]]; then
  M_LOCK_ALL_SETTING="bootstrap.mlockall"
elif [[ ${ES_MAJOR_VERSION} == "5" ]]; then
  M_LOCK_ALL_SETTING="bootstrap.memory_lock"
else
  echo "Elasticsearch version ${ES_VERSION} not supported by this script. Aborting!" 
  exit 1
fi
if [[ $DEBUG ]]; then
	echo ES_MAJOR_VERSION=$ES_MAJOR_VERSION 
fi


# Check that the user exists
if ! grep -q "^${USER}:" /etc/passwd; then
	adduser --disabled-login --system $USER 
fi
 

### Shouldn't need to change any of these

SRC_DIR=/root
TMP_DIR=$(mktemp -d)
BASE=$BASE_PARENT/elastic

PRIMARY_INTERFACE=$(route -n | grep ^0.0.0.0 | head -1 | awk '{print $8}')
PRIMARY_IP_CIDR=$(ip address list dev $PRIMARY_INTERFACE |grep "\binet\b"|awk '{print $2}')
PRIMARY_IP=${PRIMARY_IP_CIDR%%/*}

# sometimes (I'm looking at you, Hetzner) we can find ourselves with a
# bad IPv6 configuration. If so, we can disable it here.
if [[ $DISABLE_IPV6 ]]; then
	echo "net.ipv6.conf.all.disable_ipv6 = 1" > /etc/sysctl.d/99-disable-ipv6-all.conf
	sysctl -w "net.ipv6.conf.all.disable_ipv6=1" 
EOF
	sysctl --system
fi

if [[ $DEBUG ]]; then
	echo SRC_DIR=$SRC_DIR
	echo TMP_DIR=$TMP_DIR
	echo BASE=$BASE
fi

# Make sure our workspace is clean
if [[ -d $BASE ]]; then
	if [[ $SHOVE_BASE ]]; then
		OLD_BASE=$BASE.$(date --iso-8601=seconds)
		if ! mv $BASE $OLD_BASE; then
		  echo "Could not move $BASE to $OLD_BASE. Aborting"
		  exit 1
		fi
	else
		echo "Directory $BASE already exists. Aborting"
		exit 1
	fi
fi
if ! mkdir -p $BASE; then
  echo "Could not create directory $BASE. Aborting"
  exit 1
else
  cd $BASE
fi


##### PULL OTHER GIT REPOS #####

pushd $(dirname $(readlink -f $0))/.. >/dev/null

git -c http.proxy=$http_proxy clone -b ${GIT_DEMOS_BRANCH} https://github.com/sirensolutions/demos
check_error "git clone demos"
DEMO_SCRIPT_DIR=$PWD/demos

popd >/dev/null

##### END PULL OTHER GIT REPOS #####


##### DOWNLOAD SOFTWARE #####

# TODO: in stretch and later, we should follow the procedure in
# https://wiki.debian.org/DebianRepository/UseThirdParty instead.

cat <<EOF >/etc/apt/sources.list.d/webupd8team-java-trusty.list
deb http://ppa.launchpad.net/webupd8team/java/ubuntu trusty main
# deb-src http://ppa.launchpad.net/webupd8team/java/ubuntu trusty main
EOF

cat <<EOF | gpg --no-default-keyring --keyring $TMP_DIR/webupd8team-java.gpg --import
-----BEGIN PGP PUBLIC KEY BLOCK-----
Version: GnuPG v1

mI0ES9/P3AEEAPbI+9BwCbJucuC78iUeOPKl/HjAXGV49FGat0PcwfDd69MVp6zU
tIMbLgkUOxIlhiEkDmlYkwWVS8qy276hNg9YKZP37ut5+GPObuS6ZWLpwwNus5Ph
LvqeGawVJ/obu7d7gM8mBWTgvk0ErnZDaqaU2OZtHataxbdeW8qH/9FJABEBAAG0
DUxhdW5jaHBhZCBWTEOItgQTAQIAIAUCS9/P3AIbAwYLCQgHAwIEFQIIAwQWAgMB
Ah4BAheAAAoJEMJRgkjuoUiG5wYEANCdjhXXEpPUbP7cRGXL6cFvrUFKpHHopSC9
NIQ9qxJVlUK2NjkzCCFhTxPSHU8LHapKKvie3e+lkvWW5bbFN3IuQUKttsgBkQe2
aNdGBC7dVRxKSAcx2fjqP/s32q1lRxdDRM6xlQlEA1j94ewG9SDVwGbdGcJ43gLx
BmuKvUJ4
=0Cp+
-----END PGP PUBLIC KEY BLOCK-----
EOF
gpg --no-default-keyring --keyring $TMP_DIR/webupd8team-java.gpg --export C2518248EEA14886 > /etc/apt/trusted.gpg.d/webupd8team-java.gpg
# make sure it's readable by the 'apt' user
chmod og=r /etc/apt/trusted.gpg.d/webupd8team-java.gpg

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
  ufw allow to any port 22 from ${ip%%:*}
  ufw allow to any port $ES_PORT from ${ip%%:*}
  ufw allow to any port $ES_TRANS_PORT from ${ip%%:*}
done

sudo ufw --force enable

##### END FIREWALL CONFIGURATION #####



##### ELASTICSEARCH CONFIGURATION #####

# Use modular scripts
ES_BASE=$BASE/$ES_LINKNAME
${DEMO_SCRIPT_DIR}/install-elastic.sh "${ES_VERSION}" "${BASE}" "${ES_LINKNAME}" || exit 99
${DEMO_SCRIPT_DIR}/install-vanguard.sh "${PLUGIN_VERSION}" "${ES_BASE}" || exit 99

# we put the persistent data in separate subdirs for ease of upgrades
mkdir $BASE/elasticsearch-snapshots
mkdir $BASE/elasticsearch-data
mkdir $BASE/elasticsearch-logs

# We configure the node name to be the hostname

# first put our slave ip list into json format (QAD)
SLAVE_IPS_QUOTED_ARRAY=()
for i in $SLAVE_IPS; do
	SLAVE_IPS_QUOTED_ARRAY=(${SLAVE_IPS_QUOTED_ARRAY[@]} \"$i\")
done
IFS_SAVE=$IFS
IFS=","
SLAVE_IPS_QUOTED="${SLAVE_IPS_QUOTED_ARRAY[*]}"
IFS=$IFS_SAVE

# In DEBUG mode, set the logger level of Elasticsearch to DEBUG too
if [[ $DEBUG ]]; then
	cp $ES_BASE/config/log4j2.properties $ES_BASE/config/log4j2.properties.dist
	sed -i 's/rootLogger\.level = info/rootLogger.level = debug/' $ES_BASE/config/log4j2.properties
fi

mv $ES_BASE/config/elasticsearch.yml $ES_BASE/config/elasticsearch.yml.dist
cat > $ES_BASE/config/elasticsearch.yml <<EOF
http.port: $ES_PORT
transport.tcp.port: $ES_TRANS_PORT
path.repo: $BASE/elasticsearch-snapshots
path.data: $BASE/elasticsearch-data
path.logs: $BASE/elasticsearch-logs
network.bind_host: "0"
network.publish_host: "$PRIMARY_IP"
cluster.name: ${CLUSTER_NAME}
node.name: ${HOSTNAME}
discovery.zen.ping.unicast.hosts: [ $SLAVE_IPS_QUOTED ]
discovery.zen.minimum_master_nodes: $NUM_MASTERS
${M_LOCK_ALL_SETTING}: true
$(echo $ES_NODE_CONFIG | tr ' ' '\n'| sed 's/:/: /g' )
EOF

# For ES 2, we set cache preferences here
# For ES 5, we set it elsewhere AFTER the cluster is assembled.
if [[ ${ES_MAJOR_VERSION} -lt 5 ]]; then
	cat >> $ES_BASE/config/elasticsearch.yml <<EOF

# Vanguard plugin recommended settings
index.queries.cache.enabled: true
index.queries.cache.everything: true
indices.queries.cache.all_segments: true
EOF
fi

# only need this if we are using enterprise edition v4
if [[ $ES_MAJOR_VERSION -lt 5 ]]; then
  $ES_BASE/$PLUGIN_TOOL install lmenezes/elasticsearch-kopf  || exit 2
  if [[ -f $SRC_DIR/license-siren-$ES_VERSION.zip ]]; then
	$ES_BASE/$PLUGIN_TOOL install file:$SRC_DIR/license-siren-$ES_VERSION.zip  || exit 3
  fi
fi

# For new ES, we also need to increase the system defaults.
current_max_map_count=$(sysctl -n vm.max_map_count)
if [[ $current_max_map_count -lt $MAX_MAP_COUNT ]]; then
  echo "vm.max_map_count = $MAX_MAP_COUNT" > /etc/sysctl.d/99-elasticsearch.conf
  sysctl -w "vm.max_map_count=$MAX_MAP_COUNT" 
fi

##### END ELASTICSEARCH CONFIGURATION #####


# Fix permissions
chown -R $USER $BASE
chmod -R og=rx $BASE


if [[ $SYSTEMD ]]; then

##### SYSTEMD CONFIGURATION #####

	cat <<EOF >${ES_BASE}.environment
ES_JAVA_OPTS="-Xms$ES_HEAP_SIZE -Xmx$ES_HEAP_SIZE $ES_JAVA_OPTS $CUSTOM_ES_JAVA_OPTS"
EOF

	cat <<EOF >/etc/systemd/system/elastic.service
[Unit]
Description=Elasticsearch (custom)
After=network.target auditd.service

[Service]
WorkingDirectory=$ES_BASE
EnvironmentFile=-${ES_BASE}.environment
ExecStart=$ES_BASE/bin/elasticsearch
KillMode=process
Restart=on-failure
RestartPreventExitStatus=255
Type=simple
User=$USER
LimitMEMLOCK=infinity
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
Alias=elastic.service
EOF

	ln -s ../elastic.service /etc/systemd/system/multi-user.target.wants/
	systemctl daemon-reload
	systemctl start elastic.service

##### END SYSTEMD CONFIGURATION #####

else

##### SUPERVISOR CONFIGURATION #####

	# This is nasty. The only way we can get memlock to be unlimited from
	# supervisor without rebooting the machine is to run the service as
	# root, set the limit, and then sudo to the service account. But sudo
	# will throw away the environment, so...

	cat > /etc/supervisor/conf.d/elastic.conf <<EOF
[program:elastic]
user=root
directory=$ES_BASE
command="/usr/local/bin/elastic-unlimiter.sh"
autorestart=True
EOF

	cat <<EOF > /usr/local/bin/elastic-unlimiter.sh
#!/bin/bash
ulimit -l unlimited
ulimit -n 65536
sudo -u $USER /usr/local/bin/elastic-launcher.sh
EOF
	chmod +x /usr/local/bin/elastic-unlimiter.sh

	cat <<EOF > /usr/local/bin/elastic-launcher.sh
#!/bin/bash
export ES_JAVA_OPTS="-Xms$ES_HEAP_SIZE -Xmx$ES_HEAP_SIZE $ES_JAVA_OPTS $CUSTOM_ES_JAVA_OPTS"
$ES_BASE/bin/elasticsearch
EOF
	chmod +x /usr/local/bin/elastic-launcher.sh

	supervisorctl update

##### END SUPERVISOR CONFIGURATION #####

fi

##### STORE CONFIGURATION VARIABLES #####

cat <<EOF >/var/cache/es-constructor.conf
# Stored configuration from the es-constructor.
# Source this to populate handy variables, saves looking for them.

ES_BASE=$ES_BASE
LOGSTASH_BASE=$LOGSTASH_BASE
ES_VERSION=$ES_VERSION
LOGSTASH_VERSION=$LOGSTASH_VERSION
PLUGIN_VERSION=$PLUGIN_VERSION
PLUGIN_NAME=$PLUGIN_NAME
ES_PORT=$ES_PORT
ES_TRANS_PORT=$ES_TRANS_PORT
ES_HEAP_SIZE=$ES_HEAP_SIZE
ES_JAVA_OPTS=$ES_JAVA_OPTS
PRIMARY_IP=$PRIMARY_IP
SLAVE_IPS=$SLAVE_IPS
USER=$USER
EOF

##### END STORE CONFIGURATION VARIABLES #####


if [[ ! $DEBUG ]]; then
	rm -rf $TMP_DIR
fi
