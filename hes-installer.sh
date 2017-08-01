#!/bin/bash

# This script takes one argument, the name of the cluster as defined
# as a group in /etc/ansible/hosts
# Machines will take their names from /etc/ansible/hosts

echo "Populate authorized_keys"
ansible $1 -c local -m command -k -a "ssh_copy_id root@{{ ansible_hostname }}"
ansible $1 -u root -m template -a "src=hes-autosetup.template dest=/autosetup"
ansible $1 -u root -m command -a "installimage"

echo "Waiting for each slave to come back up..."
ansible $1 -c local -m wait_for -a "port=22"

echo "Repopulate root's authorized_keys"
ansible $1 -c local -m command -k -a "ssh-copy-id root@{{ inventory_hostname }}"

echo "Now invoke the puller"
ansible $1 -u root -m template -b -a "src=baremetal-puller.template dest=/tmp/puller.sh"
ansible $1 -u root -m command -b -a "bash /tmp/puller.sh"
