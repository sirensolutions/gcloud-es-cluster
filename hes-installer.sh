#!/bin/bash

# This script requires sshpass

# This script takes one argument, the name of the cluster as defined
# as a group in /etc/ansible/hosts
# Machines will take their names from /etc/ansible/hosts and their
# IPs must be defined in /etc/hosts

CLUSTER=$1
PRIMARY_IP=$(hostname --ip-address)
SLAVES=$(ansible $CLUSTER -c local -m command -a "echo {{ inventory_hostname }}" | grep -v ">>" | sort -n )
NUM_MASTERS=$[ $(echo $SLAVES | wc -w) / 2 + 1 ]

echo "Populate root's authorized_keys in each rescue OS"
# Ansible's password caching is unusable, so we roll our own
# Let's do some other housekeeping in this loop
declare -A SLAVE_PASSWDS
declare -A SLAVE_IPS
declare -A SUBNETS
for slave in $SLAVES; do
	SLAVE_IPS[$slave]=$(grep "\b${slave}\b" /etc/hosts|awk '{print $1}')
	SUBNETS[$slave]="${SLAVE_IPS[$slave]}/32"
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

# Delete entries from our known_hosts because the keys will have changed
for slave in $SLAVES; do
	ssh-keygen -f $HOME/.ssh/known_hosts -R $slave
done
# And replace them, to prevent annoying prompts
ssh-keyscan $SLAVES >> $HOME/.ssh/known_hosts

echo "Waiting for each slave to come back up..."
ansible $CLUSTER -c local -m wait_for -a "port=22"

echo "Repopulate root's authorized_keys in the new base OS"
for slave in $SLAVES; do
	echo ${SLAVE_PASSWDS[$slave]} | sshpass ssh-copy-id root@$slave
done

echo "Now push cluster configuration and invoke the puller"
supplement=$(tempfile)
cat <<EOF >${supplement}
SLAVE_IPS="${SLAVE_IPS[@]}"
NUM_MASTERS=$NUM_MASTERS
DEBUG=1
SUBNETS="${SUBNETS[@]}"
CLUSTER_NAME=$CLUSTER
EOF
ansible $CLUSTER -u root -m copy -b -a "src=${supplement} dest=/tmp/baremetal.conf.supplement"
rm ${supplement}

ansible $CLUSTER -u root -m copy -b -a "src=baremetal-puller.sh dest=/tmp/puller.sh"
ansible $CLUSTER -u root -m command -b -a "bash /tmp/puller.sh"
