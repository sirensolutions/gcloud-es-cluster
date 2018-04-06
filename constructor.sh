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

# We may not be able to access the artifactory directly
ARTIFACTORY_HOST=artifactory.siren.io
ARTIFACTORY_HEADER_HOST=$ARTIFACTORY_HOST

# Don't show progress bar, but do show errors
CURL_ARGS="-sS -f -L"
	
##### END DEFAULT SETTINGS #####

echo Loading site config \"$1\"

# Pushd/popd so we can handle both absolute and relative paths sensibly.
pushd $(dirname $0) >/dev/null
. $1
popd >/dev/null

echo DEBUG=$DEBUG 

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
  # The plugin tool does not read the envar ES_JAVA_OPTS in 2.x
  # https://github.com/elastic/elasticsearch/issues/21824
  PLUGIN_TOOL="bin/plugin $ES_JAVA_OPTS"
  PLUGIN_NAME=siren-join
  M_LOCK_ALL_SETTING="bootstrap.mlockall"
elif [[ ${ES_MAJOR_VERSION} -ge 5 ]]; then
  PLUGIN_TOOL=bin/elasticsearch-plugin
  PLUGIN_NAME=siren-federate
  M_LOCK_ALL_SETTING="bootstrap.memory_lock"
else
  echo "Elasticsearch version ${ES_VERSION} not supported by this script. Aborting!" 
  exit 1
fi
if [[ $DEBUG ]]; then
	echo ES_MAJOR_VERSION=$ES_MAJOR_VERSION 
fi

PLUGIN_MINOR_VERSION=${PLUGIN_VERSION%%-*}
if [[ ${PLUGIN_MINOR_VERSION} != ${PLUGIN_VERSION} ]]; then
  echo "This is a snapshot build."
  SNAPSHOT=true
  if [[ ! $PLUGIN_DIR_VERSION ]]; then
    PLUGIN_DIR_VERSION=${PLUGIN_MINOR_VERSION}-SNAPSHOT
  fi
  ARTIFACTORY_PATH=libs-snapshot-local
else
  if [[ ! $PLUGIN_DIR_VERSION ]]; then
    PLUGIN_DIR_VERSION=${PLUGIN_MINOR_VERSION}
  fi
  ARTIFACTORY_PATH=libs-release-local
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
	
if [[ $PLUGIN_VERSION ]]; then
  if [[ $PLUGIN_NAME == "siren-join" ]]; then
    PLUGIN_ZIPFILE="siren-join-${PLUGIN_VERSION}.zip"
  else
    PLUGIN_ZIPFILE="${PLUGIN_NAME}-${PLUGIN_VERSION}-plugin.zip"
  fi
  PLUGIN_URL="http://${ARTIFACTORY_HOST}/artifactory/${ARTIFACTORY_PATH}/io/siren/${PLUGIN_NAME}/${PLUGIN_DIR_VERSION}/${PLUGIN_ZIPFILE}"
fi

ES_BASE=$BASE/elasticsearch-$ES_VERSION
ES_ZIPFILE="elasticsearch-$ES_VERSION.zip"
ES_URL="https://artifacts.elastic.co/downloads/elasticsearch/$ES_ZIPFILE"
ES_URL2="https://download.elastic.co/elasticsearch/release/org/elasticsearch/distribution/zip/elasticsearch/$ES_VERSION/$ES_ZIPFILE"

LOGSTASH_BASE=$BASE/logstash-$LOGSTASH_VERSION
LOGSTASH_ZIPFILE="logstash-$LOGSTASH_VERSION.zip"
LOGSTASH_URL="https://artifacts.elastic.co/downloads/logstash/$LOGSTASH_ZIPFILE"
LOGSTASH_URL2="https://download.elastic.co/logstash/logstash/$LOGSTASH_ZIPFILE"

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

if [[ $DEBUG ]]; then
	echo PLUGIN_NAME=$PLUGIN_NAME 
	echo PLUGIN_URL=$PLUGIN_URL 
	echo PLUGIN_VERSION=$PLUGIN_VERSION 
	echo PLUGIN_ZIPFILE=$PLUGIN_ZIPFILE 
	echo ES_BASE=$ES_BASE 
	echo ES_ZIPFILE=$ES_ZIPFILE 
	echo ES_URL=$ES_URL 
	echo ES_URL2=$ES_URL2 
	echo LOGSTASH_BASE=$LOGSTASH_BASE 
	echo LOGSTASH_ZIPFILE=$LOGSTASH_ZIPFILE 
	echo LOGSTASH_URL=$LOGSTASH_URL 
	echo LOGSTASH_URL2=$LOGSTASH_URL2 
fi



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
apt-get -y install unzip supervisor ufw oracle-java8-installer

check_error "apt install"

if ! curl $CURL_ARGS -o $TMP_DIR/$ES_ZIPFILE $ES_URL ; then
  echo "Warning: problem downloading $ES_URL, trying alternative download location..." 
  if ! curl $CURL_ARGS -o $TMP_DIR/$ES_ZIPFILE $ES_URL2 ; then
    echo "Error downloading $ES_URL2" 
    exit 3
  else
    echo "Success" 
  fi
fi
unzip $TMP_DIR/$ES_ZIPFILE >/dev/null


if ! curl $CURL_ARGS -o $TMP_DIR/$LOGSTASH_ZIPFILE $LOGSTASH_URL ; then
  echo "Warning: problem downloading $LOGSTASH_URL, trying alternative download location..." 
  if ! curl $CURL_ARGS -o $TMP_DIR/$LOGSTASH_ZIPFILE $LOGSTASH_URL2 ; then
    echo "Error downloading $LOGSTASH_URL2" 
    exit 3
  else
    echo "Success" 
  fi
fi
unzip $TMP_DIR/$LOGSTASH_ZIPFILE >/dev/null


if [[ $PLUGIN_URL ]]; then
  # We will also need to download a snapshot plugin from the artifactory
  if ! curl $CURL_ARGS -o $TMP_DIR/$PLUGIN_ZIPFILE -H "Host: $ARTIFACTORY_HEADER_HOST" $PLUGIN_URL ; then
    echo "Error downloading $PLUGIN_URL" 
    exit 3
  fi
  PLUGIN_ZIPFILE=$TMP_DIR/$PLUGIN_ZIPFILE
fi

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
network.bind_host: "0"
network.publish_host: "$PRIMARY_IP"
path.repo: $BASE
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

# Now install the elasticsearch plugins
if [[ $PLUGIN_ZIPFILE ]]; then
  $ES_BASE/$PLUGIN_TOOL install file:$PLUGIN_ZIPFILE  || exit 3
else
  $ES_BASE/$PLUGIN_TOOL install io.siren/$PLUGIN_NAME/$ES_VERSION  || exit 2
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
