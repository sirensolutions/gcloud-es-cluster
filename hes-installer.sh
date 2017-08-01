#!/bin/bash

# This script takes one argument, the name of the cluster as defined
# as a group in /etc/ansible/hosts
# Machines will take their names from /etc/ansible/hosts

PRIMARY_IP=$(hostname --fqdn)
SUBNETS="${PRIMARY_IP}/32 "

echo "Populate root's authorized_keys in the rescue OS"
ansible $1 -m authorized_key -k -a "user=root key=$(ssh-add -L | head -1)"

echo "Configure the OS"
ansible $1 -u root -m template -a "src=hes-autosetup.template dest=/autosetup"
ansible $1 -u root -m command -a "installimage && reboot"

# Delete entries from our known_hosts because the keys will have changed
ansible $1 -c local -m command -a "ssh-keygen -f $HOME/.ssh/known_hosts -R {{ inventory_hostname }}"

echo "Waiting for each slave to come back up..."
ansible $1 -c local -m wait_for -a "port=22"

echo "Repopulate root's authorized_keys in the new base OS"
ansible $1 -m authorized_key -k -a "user=root key=$(ssh-add -L | head -1)"

echo "Now push cluster configuration and invoke the puller"
supplement=$(tempfile)
cat <<EOF >${supplement}
SLAVE_IPS="{% for host in groups['$CLUSTER'] %} {{ hostvars[host]['ansible_eth0']['ipv4']['address'] }} {% endfor %}"
NUM_MASTERS=\$[ \$(echo \$SLAVE_IPS | wc -w) / 2 + 1 ]
DEBUG=1
SUBNETS="${SUBNETS}"
CLUSTER_NAME=$CLUSTER
EOF
ansible $1 -u root -m template -b -a "src=${supplement} dest=/tmp/baremetal.conf.supplement"
rm ${supplement}

ansible $1 -u root -m copy -b -a "src=baremetal-puller.sh dest=/tmp/puller.sh"
ansible $1 -u root -m command -b -a "bash /tmp/puller.sh"
