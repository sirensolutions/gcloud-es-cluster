#!/bin/bash

# This script requires sshpass

# This script takes one argument, the name of the cluster as defined
# as a group in /etc/ansible/hosts
# Machines will take their names from /etc/ansible/hosts

CLUSTER=$1
PRIMARY_IP=$(hostname --fqdn)
SLAVES=$(ansible $CLUSTER -c local -m command -a "echo {{ inventory_hostname }}" | grep -v ">>" )
 
echo "Populate root's authorized_keys in each rescue OS"
# Ansible's password caching is unusable, so we roll our own
declare -A SLAVE_PASSWDS
for slave in $SLAVES; do
	echo -n "Root password for ${slave}: "
	read -s passwd
	SLAVE_PASSWDS[$slave]="$passwd"
	echo "${SLAVE_PASSWDS[$slave]}" | sshpass ssh-copy-id root@$slave
done

echo "Configure the OS"
ansible $CLUSTER -u root -m template -a "src=hes-autosetup.template dest=/autosetup"
ansible $CLUSTER -u root -m command -a "installimage && reboot"

# Delete entries from our known_hosts because the keys will have changed
ansible $CLUSTER -c local -m command -a "ssh-keygen -f $HOME/.ssh/known_hosts -R {{ inventory_hostname }}"

echo "Waiting for each slave to come back up..."
ansible $CLUSTER -c local -m wait_for -a "port=22"

echo "Repopulate root's authorized_keys in the new base OS"
for slave in $SLAVES; do
	echo ${SLAVE_PASSWDS[$slave]} | sshpass ssh-copy-id root@$slave
done

echo "Now push cluster configuration and invoke the puller"
supplement=$(tempfile)
cat <<EOF >${supplement}
SLAVE_IPS="{% for host in groups['$CLUSTER'] %} {{ hostvars[host]['ansible_eth0']['ipv4']['address'] }} {% endfor %}"
NUM_MASTERS=\$[ \$(echo \$SLAVE_IPS | wc -w) / 2 + 1 ]
DEBUG=1
SUBNETS="${PRIMARY_IP}/32 {% for host in groups['$CLUSTER'] %} {{ hostvars[host]['ansible_eth0']['ipv4']['address'] }}/32 {% endfor %}"
CLUSTER_NAME=$CLUSTER
EOF
ansible $CLUSTER -u root -m template -b -a "src=${supplement} dest=/tmp/baremetal.conf.supplement"
rm ${supplement}

ansible $CLUSTER -u root -m copy -b -a "src=baremetal-puller.sh dest=/tmp/puller.sh"
ansible $CLUSTER -u root -m command -b -a "bash /tmp/puller.sh"
