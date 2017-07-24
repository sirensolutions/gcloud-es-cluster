#!/bin/bash
#
# Constructor for setting up an elasticsearch cluster

##### SETTINGS #####

LOGGER='logger -t es-constructor'

# Sysctl max_map_count (>=262144)
MAX_MAP_COUNT=262144

### Default values

# Software versions
ES_VERSION=2.4.4
LOGSTASH_VERSION=2.4.1
PLUGIN_VERSION=4.6.4

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

# We need a proxy to get to the artifactory, because we don't want to 
# maintain VPN state. This should be the IP of our controller node.
ARTIFACTORY_HOST=10.0.0.1:8080

##### END SETTINGS #####


# Evaluate all the command line arguments.
# These will normally be variable assignments overriding the above, but
# they can in principle be anything. So be careful.

echo Evaluating \"$*\" |& $SLOGGER
eval "$*" |& $LOGGER



if [[ $DEBUG ]]; then
	CURL_ARGS="-f"
else
	CURL_ARGS="-s -f"
fi
	

ES_MAJOR_VERSION=${ES_VERSION%%.*}
if [[ $DEBUG ]]; then
	echo ES_MAJOR_VERSION=$ES_MAJOR_VERSION |& $LOGGER
fi

if [[ ${ES_MAJOR_VERSION} == "2" ]]; then
  PLUGIN_TOOL=bin/plugin
  PLUGIN_NAME=siren-join
elif [[ ${ES_MAJOR_VERSION} == "5" ]]; then
  PLUGIN_TOOL=bin/elasticsearch-plugin
  PLUGIN_NAME=platform-core
else
  echo "Elasticsearch version ${ES_VERSION} not supported by this script. Aborting!" |& $LOGGER
  exit 1
fi
if [[ $DEBUG ]]; then
	echo ES_MAJOR_VERSION=$ES_MAJOR_VERSION |& $LOGGER
fi


# Check that the user exists
if ! grep -q "^${USER}:" /etc/passwd; then
	adduser --disabled-login --system $USER |& $LOGGER
fi
 

### Shouldn't need to change any of these

SRC_DIR=$PWD
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
  PLUGIN_URL="http://${ARTIFACTORY_HOST}/artifactory/${ARTIFACTORY_PATH}/solutions/siren/${PLUGIN_NAME}/${PLUGIN_DIR_VERSION}/${PLUGIN_ZIPFILE}"
fi

ES_BASE=$BASE/elasticsearch-$ES_VERSION
ES_ZIPFILE="elasticsearch-$ES_VERSION.zip"
ES_URL="https://artifacts.elastic.co/downloads/elasticsearch/$ES_ZIPFILE"
ES_URL2="https://download.elasticsearch.org/elasticsearch/release/org/elasticsearch/distribution/zip/elasticsearch/$ES_VERSION/$ES_ZIPFILE"

LOGSTASH_BASE=$BASE/logstash-$LOGSTASH_VERSION
LOGSTASH_ZIPFILE="logstash-$LOGSTASH_VERSION.zip"
LOGSTASH_URL="https://artifacts.elastic.co/downloads/logstash/$LOGSTASH_ZIPFILE"
LOGSTASH_URL2="https://download.elastic.co/logstash/logstash/$LOGSTASH_ZIPFILE"

if ! mkdir -p $BASE; then
  echo "Could not create directory $BASE. Aborting"
  exit 1
fi
if [[ $DEBUG ]]; then
	echo PLUGIN_NAME=$PLUGIN_NAME |& $LOGGER
	echo PLUGIN_URL=$PLUGIN_URL |& $LOGGER
	echo PLUGIN_VERSION=$PLUGIN_VERSION |& $LOGGER
	echo PLUGIN_ZIPFILE=$PLUGIN_ZIPFILE |& $LOGGER
	echo ES_BASE=$ES_BASE |& $LOGGER
	echo ES_ZIPFILE=$ES_ZIPFILE |& $LOGGER
	echo ES_URL=$ES_URL |& $LOGGER
	echo ES_URL2=$ES_URL2 |& $LOGGER
	echo LOGSTASH_BASE=$LOGSTASH_BASE |& $LOGGER
	echo LOGSTASH_ZIPFILE=$LOGSTASH_ZIPFILE |& $LOGGER
	echo LOGSTASH_URL=$LOGSTASH_URL |& $LOGGER
	echo LOGSTASH_URL2=$LOGSTASH_URL2 |& $LOGGER
fi



##### DOWNLOAD SOFTWARE #####

apt-get -y install unzip supervisor |& $LOGGER

if ! curl $CURL_ARGS -o $TMP_DIR/$ES_ZIPFILE $ES_URL |& $LOGGER; then
  echo "Error downloading $ES_URL, trying alternative download location..." |& $LOGGER
  if ! curl $CURL_ARGS -o $TMP_DIR/$ES_ZIPFILE $ES_URL2 |& $LOGGER; then
    echo "Error downloading $ES_URL2" |& $LOGGER
    exit 3
  else
    echo "Success" |& $LOGGER
  fi
fi
unzip $TMP_DIR/$ES_ZIPFILE |& $LOGGER


if ! curl $CURL_ARGS -o $TMP_DIR/$LOGSTASH_ZIPFILE $LOGSTASH_URL |& $LOGGER; then
  echo "Error downloading $LOGSTASH_URL, trying alternative download location..." |& $LOGGER
  if ! curl $CURL_ARGS -o $TMP_DIR/$LOGSTASH_ZIPFILE $LOGSTASH_URL2 |& $LOGGER; then
    echo "Error downloading $LOGSTASH_URL2" |& $LOGGER
    exit 3
  else
    echo "Success" |& $LOGGER
  fi
fi
unzip $TMP_DIR/$LOGSTASH_ZIPFILE |& $LOGGER


#### TODO: REMOVE THIS 'false' WHEN WE HAVE A WORKING PLUGIN DOWNLOAD
if [[ $PLUGIN_URL && false ]]; then
  # We will also need to download a snapshot plugin from the artifactory
  if ! curl $CURL_ARGS -o $TMP_DIR/$PLUGIN_ZIPFILE $PLUGIN_URL |& $LOGGER; then
    echo "Error downloading $PLUGIN_URL" |& $LOGGER
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
  $ES_BASE/$PLUGIN_TOOL install file:$PLUGIN_ZIPFILE |& $LOGGER || exit 3
else
  $ES_BASE/$PLUGIN_TOOL install solutions.siren/$PLUGIN_NAME/$ES_VERSION |& $LOGGER || exit 2
fi

# only need this if we are using enterprise edition v4
if [[ $ES_MAJOR_VERSION -lt 5 ]]; then
  $ES_BASE/$PLUGIN_TOOL install lmenezes/elasticsearch-kopf  |& $LOGGER|| exit 2
  if [[ -f $SRC_DIR/license-siren-$ES_VERSION.zip ]]; then
	$ES_BASE/$PLUGIN_TOOL install file:$SRC_DIR/license-siren-$ES_VERSION.zip  |& $LOGGER|| exit 3
  fi
fi

# For new ES, we also need to increase the system defaults.
current_max_map_count=$(sysctl -n vm.max_map_count)
if [[ $current_max_map_count -lt $MAX_MAP_COUNT ]]; then
  echo "vm.max_map_count = $MAX_MAP_COUNT" > /etc/sysctl.d/99-elasticsearch.conf
  sysctl -w "vm.max_map_count = $MAX_MAP_COUNT" |& $LOGGER
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

if [[ $CONTROLLER_IP && -x /usr/sbin/ufw ]]; then
	ufw allow to any port 22 from $CONTROLLER_IP
	# Should also configure elastic ports here for local subnet only
	sudo ufw enable
fi

##### END FIREWALL CONFIGURATION #####


if [[ ! $DEBUG ]]; then
	rm -rf $TMP_DIR
fi
