#!/bin/bash

SCRIPT_LOCATION=$(dirname $(readlink -f $0))
GIT_BRANCH=$(cd ${SCRIPT_LOCATION}; git status | head -1 | awk '{print $3}')

ES_PORT=9200

if [[ ! $1 || $1 = "-h" || $1 = "--help" ]]; then
cat <<EOF
Usage: $0 CLUSTER_NAME [rescue]

This script is invoked on the controller node to spawn a cluster on
physical machines. 

CLUSTER_NAME is the name of the cluster as defined as a group in
/etc/ansible/hosts. Machines will take their names from
/etc/ansible/hosts and their IPs must be defined in /etc/hosts .
If the connection between the controller and the members should use
different IPs than the members should use to connect to each other,
then the inter-member IPs should be defined in a separate hosts file,
and the name of the file passed in the HOSTS_FILE envar.

The optional argument "rescue" causes the script to first install a
base OS using the Hetzner rescue installer. Currently only Xenial is
supported, and the machines must already have been booted into rescue
mode (this can be selected in the Hetzner provisioner).

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

CLUSTER=$1
if [[ $2 == "rescue" ]]; then
	RESCUE=true
fi

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

if [[ $RESCUE ]]; then
	# We need to install the OS from the hetzner rescue OS
	
	# Make sure sshpass is installed
	apt-get -y install sshpass

	# Clean and repopulate known_hosts because the keys may have changed
	for entry in $SLAVES ${SLAVE_IPS[@]}; do
		ssh-keygen -f $HOME/.ssh/known_hosts -R $entry
	done
	ssh-keyscan $SLAVES >> $HOME/.ssh/known_hosts
	
	echo "Populate root's authorized_keys in each rescue OS"
	# Ansible's password caching is unusable, so we roll our own
	# Let's do some other housekeeping in this loop
	declare -A SLAVE_PASSWDS
	for slave in $SLAVES; do
		echo "Enter a blank password if your pubkey is already installed"
		echo -n "Root password for ${slave}: "
		read -s passwd
		SLAVE_PASSWDS[$slave]="$passwd"
		echo
		echo "${SLAVE_PASSWDS[$slave]}" | sshpass ssh-copy-id root@$slave
	done
	
	echo "Configure the OS"
	ansible $CLUSTER -u root -m template -a "src=hes-autosetup.template dest=/autosetup"
	# we use cat to make ansible wait for the connection to drop
	ansible $CLUSTER -u root -m command -a "bash -c '/root/.oldroot/nfs/install/installimage && reboot && cat'"
	
	echo "Waiting for each slave to come back up..."
	for ip in ${SLAVE_IPS[@]}; do
		while ! nc -w 5 $ip 22 </dev/null >/dev/null; do
			sleep 5
		done
		echo "$ip running"
	done
	
	# Clean and repopulate known_hosts because the keys will have changed
	for entry in $SLAVES ${SLAVE_IPS[@]}; do
		ssh-keygen -f $HOME/.ssh/known_hosts -R $entry
	done
	ssh-keyscan $SLAVES >> $HOME/.ssh/known_hosts
	
	echo "Repopulate root's authorized_keys in the new base OS"
	for slave in $SLAVES; do
		echo "${SLAVE_PASSWDS[$slave]}" | sshpass ssh-copy-id root@$slave
	done
	
	echo "Disabling password authentication for root"
	ansible $CLUSTER -u root -m command -a "passwd -l root"

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
	scp baremetal-puller.sh root@$slave:/tmp/puller.sh
	ssh root@$slave /tmp/puller.sh ${PULLER_ARGS} &
done

rm ${conffile}

### Perform post-assembly tasks (common)

export ES_VERSION
export ES_PORT
$SCRIPT_LOCATION/post-assembly.sh ${SLAVES[@]}
