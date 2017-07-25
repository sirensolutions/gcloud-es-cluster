#!/bin/bash
#
# Constructor for setting up an elasticsearch cluster

##### SETTINGS #####

# Sysctl max_map_count (>=262144)
MAX_MAP_COUNT=262144

### Default values

# Software versions
ES_VERSION=2.4.4
LOGSTASH_VERSION=2.4.1
PLUGIN_VERSION=2.4.4

# The parent directory under which we create our data subdirectory. 
# If SHOVE_BASE is defined, any conflicting subdir will be renamed.
BASE_PARENT=/opt
# The user that will own the files and processes.
USER=elastic
# How much memory to allocate to elastic.
ES_HEAP_SIZE=4g

# Use default ports for simplicity
ES_PORT=9200
ES_TRANS_PORT=9300

# Don't show progress bar, but do show errors
CURL_ARGS="-sS -f"
	
##### END SETTINGS #####


# Evaluate all the command line arguments.
# These will normally be variable assignments overriding the above, but
# they can in principle be anything. So be careful.

echo Evaluating \"$*\" 
eval $(echo $*) 

echo DEBUG=$DEBUG 

# save our http_proxy configuration for future use
cat <<EOF >/etc/profile.d/00-proxy.sh
export http_proxy=$http_proxy
EOF

ES_MAJOR_VERSION=${ES_VERSION%%.*}
if [[ $DEBUG ]]; then
	echo ES_MAJOR_VERSION=$ES_MAJOR_VERSION 
fi

if [[ ${ES_MAJOR_VERSION} == "2" ]]; then
  PLUGIN_TOOL=bin/plugin
  PLUGIN_NAME=siren-join
elif [[ ${ES_MAJOR_VERSION} == "5" ]]; then
  PLUGIN_TOOL=bin/elasticsearch-plugin
  PLUGIN_NAME=platform-core
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
  PLUGIN_DIR_VERSION=${PLUGIN_MINOR_VERSION}-SNAPSHOT
  ARTIFACTORY_PATH=libs-snapshot-local
else
  PLUGIN_DIR_VERSION=${PLUGIN_MINOR_VERSION}
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
  PLUGIN_URL="http://artifactory.siren.io:8081/artifactory/${ARTIFACTORY_PATH}/solutions/siren/${PLUGIN_NAME}/${PLUGIN_DIR_VERSION}/${PLUGIN_ZIPFILE}"
fi

ES_BASE=$BASE/elasticsearch-$ES_VERSION
ES_ZIPFILE="elasticsearch-$ES_VERSION.zip"
ES_URL="https://artifacts.elastic.co/downloads/elasticsearch/$ES_ZIPFILE"
ES_URL2="https://download.elastic.co/elasticsearch/release/org/elasticsearch/distribution/zip/elasticsearch/$ES_VERSION/$ES_ZIPFILE"

LOGSTASH_BASE=$BASE/logstash-$LOGSTASH_VERSION
LOGSTASH_ZIPFILE="logstash-$LOGSTASH_VERSION.zip"
LOGSTASH_URL="https://artifacts.elastic.co/downloads/logstash/$LOGSTASH_ZIPFILE"
LOGSTASH_URL2="https://download.elastic.co/logstash/logstash/$LOGSTASH_ZIPFILE"

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

cat <<EOF >/etc/apt/sources.list.d/webupd8team-java-trusty.list
deb http://ppa.launchpad.net/webupd8team/java/ubuntu trusty main
# deb-src http://ppa.launchpad.net/webupd8team/java/ubuntu trusty main
EOF

cat <<EOF | gpg --no-default-keyring --keyring /etc/apt/trusted.gpg.d/webupd8team-java.gpg --import
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
# make sure it's readable by the 'apt' user
chmod og=r /etc/apt/trusted.gpg.d/webupd8team-java.gpg

apt-get update
# preseed the debian installer with our Java license acceptance
echo 'oracle-java8-installer shared/accepted-oracle-license-v1-1 boolean true' | debconf-set-selections
# make sure the installer does not prompt; there's nobody listening
DEBIAN_FRONTEND=noninteractive apt-get -y install unzip supervisor ufw oracle-java8-installer


if ! curl $CURL_ARGS -o $TMP_DIR/$ES_ZIPFILE $ES_URL ; then
  echo "Error downloading $ES_URL, trying alternative download location..." 
  if ! curl $CURL_ARGS -o $TMP_DIR/$ES_ZIPFILE $ES_URL2 ; then
    echo "Error downloading $ES_URL2" 
    exit 3
  else
    echo "Success" 
  fi
fi
unzip $TMP_DIR/$ES_ZIPFILE >/dev/null


if ! curl $CURL_ARGS -o $TMP_DIR/$LOGSTASH_ZIPFILE $LOGSTASH_URL ; then
  echo "Error downloading $LOGSTASH_URL, trying alternative download location..." 
  if ! curl $CURL_ARGS -o $TMP_DIR/$LOGSTASH_ZIPFILE $LOGSTASH_URL2 ; then
    echo "Error downloading $LOGSTASH_URL2" 
    exit 3
  else
    echo "Success" 
  fi
fi
unzip $TMP_DIR/$LOGSTASH_ZIPFILE >/dev/null


#### TODO: REMOVE THIS 'false' WHEN WE HAVE A WORKING PLUGIN DOWNLOAD
if [[ $PLUGIN_URL && false ]]; then
  # We will also need to download a snapshot plugin from the artifactory
  if ! curl $CURL_ARGS -o $TMP_DIR/$PLUGIN_ZIPFILE $PLUGIN_URL ; then
    echo "Error downloading $PLUGIN_URL" 
    exit 3
  fi
  PLUGIN_ZIPFILE=$TMP_DIR/$PLUGIN_ZIPFILE
fi

##### END DOWNLOAD SOFTWARE #####




##### ELASTICSEARCH CONFIGURATION #####

mv $ES_BASE/config/elasticsearch.yml $ES_BASE/config/elasticsearch.yml.dist
cat > $ES_BASE/config/elasticsearch.yml <<EOF
http.port: $ES_PORT
transport.tcp.port: $ES_TRANS_PORT
path.repo: $BASE
EOF

# Now install the elasticsearch plugins
if [[ $PLUGIN_ZIPFILE ]]; then
  $ES_BASE/$PLUGIN_TOOL install file:$PLUGIN_ZIPFILE  || exit 3
else
  $ES_BASE/$PLUGIN_TOOL install solutions.siren/$PLUGIN_NAME/$ES_VERSION  || exit 2
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
  sysctl -w "vm.max_map_count = $MAX_MAP_COUNT" 
fi

##### END ELASTICSEARCH CONFIGURATION #####


# Fix permissions
chown -R $USER $BASE
chmod -R og=rx $BASE


##### SUPERVISOR CONFIGURATION #####

cat > /etc/supervisor/conf.d/elastic.conf <<EOF
[program:elastic]
user=$USER
directory=$ES_BASE
command=$ES_BASE/bin/elasticsearch
environment=
	ES_JAVA_OPTS="-Xms$ES_HEAP_SIZE -Xmx$ES_HEAP_SIZE"
autorestart=True
EOF

supervisorctl update

##### END SUPERVISOR CONFIGURATION #####



##### FIREWALL CONFIGURATION #####

if [[ $CONTROLLER_IP ]]; then
	ufw allow to any port 22 from $CONTROLLER_IP
	# Should also configure elastic ports here for local subnet only
	sudo ufw enable
fi

##### END FIREWALL CONFIGURATION #####


if [[ ! $DEBUG ]]; then
	rm -rf $TMP_DIR
fi
