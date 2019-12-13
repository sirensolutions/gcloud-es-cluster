#!/bin/sh
set -e

BASEDIR=$(cd `dirname $0` && pwd)

PROJECT_ID="${PROJECT_ID:-tempclusters}"

ELASTICSEARCH_VERSION="${ELASTICSEARCH_VERSION:-6.8.2}"
FEDERATE_VERSION="${FEDERATE_VERSION:-6.8.2-19.0-SNAPSHOT}"
REGISTRY=eu.gcr.io

NODES="${NODES:-5}"
NODE_TYPE="${NODE_TYPE:-n1-highmem-16}"
CLUSTER_NAME="${CLUSTER_NAME:-siren}"
ZONE="${ZONE:-europe-west2-c}"

GCLOUD_OPTIONS="--project=$PROJECT_ID --zone=$ZONE"
CREATION_OPTIONS="--num-nodes=$NODES --enable-autoscaling --min-nodes=$NODES --max-nodes=$NODES --machine-type=$NODE_TYPE --local-ssd-count=$NODES"

ELASTICSEARCH_DOCKER_IMAGE="${REGISTRY}/${PROJECT_ID}/elasticsearch:${FEDERATE_VERSION}" 
ELASTICSEARCH_DATA_JAVA_OPTIONS="-Xmx30g -Xms30g"

echo Building image... "${ELASTICSEARCH_DOCKER_IMAGE}"

docker build --build-arg ELASTICSEARCH_VERSION="${ELASTICSEARCH_VERSION}" --build-arg FEDERATE_VERSION="${FEDERATE_VERSION}" -t "${ELASTICSEARCH_DOCKER_IMAGE}" docker/elasticsearch
docker push "${ELASTICSEARCH_DOCKER_IMAGE}"


echo "Creating cluster..."

gcloud container clusters create $CLUSTER_NAME $GCLOUD_OPTIONS $CREATION_OPTIONS

if [ $? != 0 ]; then
  echo "\nCould not create cluster, check the gcloud output for more information."
  echo "Run the following if you want to destroy the cluster: gcloud container clusters delete $CLUSTER_NAME $GCLOUD_OPTIONS"
  exit $?
fi

gcloud container clusters get-credentials $CLUSTER_NAME $GCLOUD_OPTIONS

if [ $? != 0 ]; then
  echo "\nCould not fetch Kubernetes config for cluster."
  exit $?
fi

echo "To destroy the cluster run: gcloud container clusters delete $CLUSTER_NAME $GCLOUD_OPTIONS"

echo "Creating default storage classes..."

kubectl apply -f storage/pd.yml

echo "Creating namespace..."

kubectl create namespace siren

echo "Installing Zalando operator..."

kubectl apply -f operator/cluster-roles.yaml
kubectl apply -f operator/crd.yaml
kubectl apply -f operator/operator.yaml

echo "Creating overlay..."
mkdir -p k8s/overlays/custom
gomplate --input-dir k8s/base --output-dir k8s/overlays/custom

echo "Starting cluster..."
kubectl apply -k k8s/overlays/custom

echo "To forward the cluster rest API to your machine execute kubectl port-forward -n siren service/es-discovery 9200:9200"
