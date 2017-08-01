#!/bin/bash

# This script takes one argument, the name of the cluster as defined
# as a group in /etc/ansible/hosts

# Machines will be named using whatever is configured in ansible

ansible $1 -u root -m template -a "src=hes-autosetup.template dest=/autosetup"
ansible $1 -u root -m command -a "installimage"

echo "Waiting for each slave to come back up..."
ansible $1 -c local -m wait_for -a "port=22"

ansible $1 -u root -m template -a "src=baremetal-puller.template dest=/tmp/puller.sh"
ansible $1 -u root -m command -a "bash /tmp/puller.sh"
