#!/bin/bash
#
# pull-constructor.sh; invoke by appending the following to `gcloud compute instance create`:
#   --metadata-from-file startup-script=./gcloud-es-cluster/pull-constructor.sh
#
# NB this script is invoked from the *controller* node

git clone https://github.com/sirensolutions/gcloud-es-cluster && /bin/bash ./gcloud-es-cluster/constructor.sh
