#!/bin/sh
BASEDIR=$(cd `dirname $0` && pwd)
ENVIRONMENT="${1:-default.env}"

if [[ ! -f "$ENVIRONMENT" ]]; then
  echo "\nCould not find environment file $ENVIRONMENT"
  exit 1
fi

source $ENVIRONMENT

GCLOUD_OPTIONS="--project=$PROJECT_ID --zone=$ZONE"
CREATION_OPTIONS="--num-nodes=$NODES --enable-autoscaling --min-nodes=$NODES --max-nodes=$NODES --machine-type=$NODE_TYPE --local-ssd-count=$NODES"

ELASTICSEARCH_DOCKER_IMAGE="${REGISTRY}/${PROJECT_ID}/elasticsearch:${FEDERATE_VERSION}" 
ELASTICSEARCH_DATA_JAVA_OPTIONS="-Xmx${ELASTICSEARCH_HEAP}g -Xms${ELASTICSEARCH_HEAP}g -Dsiren.io.netty.maxDirectMemory=$((SIREN_MEMORY_ROOT_LIMIT + 512))"

echo "To destroy the cluster run: gcloud container clusters delete $CLUSTER_NAME $GCLOUD_OPTIONS"
echo Building image... "${ELASTICSEARCH_DOCKER_IMAGE}"

docker build --build-arg ELASTICSEARCH_VERSION="${ELASTICSEARCH_VERSION}" --build-arg FEDERATE_VERSION="${FEDERATE_VERSION}" -t "${ELASTICSEARCH_DOCKER_IMAGE}" docker/elasticsearch
docker push "${ELASTICSEARCH_DOCKER_IMAGE}"

echo "\nCreating cluster..."

gcloud container clusters create $CLUSTER_NAME $GCLOUD_OPTIONS \
  --num-nodes=$((NODES + 2)) \
  --machine-type=$NODE_TYPE \
  --disk-type=pd-ssd \
  --min-cpu-platform="Intel Skylake"

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

export ELASTICSEARCH_MAJOR_VERSION
export ELASTICSEARCH_DATA_CORES_REQUEST
export ELASTICSEARCH_DATA_MEMORY_REQUEST
export ELASTICSEARCH_DOCKER_IMAGE
export ELASTICSEARCH_DATA_JAVA_OPTIONS
export NODES
export SIREN_MEMORY_ROOT_LIMIT
gomplate --input-dir k8s/base --output-dir k8s/overlays/custom

echo "\nCreating secrets..."

kubectl -n siren create secret generic gcloud --from-file=account.json="$GCLOUD_SERVICE_ACCOUNT_FILE"

if [ $? != 0 ]; then
  echo "\nCould not create Google Cloud service account secret, please check that the file ${GCLOUD_SERVICE_ACCOUNT_FILE} exists."
  exit $?
fi

echo "Starting cluster..."
kubectl apply -k k8s/overlays/custom

echo "Waiting for boostrap master to be ready..."
kubectl -n siren wait --for=condition=ready pod/es-master-0 --timeout=300s

if [ $? != 0 ]; then
  echo "\nMaster not ready within timeout, please check its status with kubectl -n siren logs es-master-0"
  exit $?
fi

echo "\nWaiting for cluster to be green..."
kubectl -n siren exec es-master-0 -- curl -fs "http://localhost:9200/_cluster/health?wait_for_status=green&timeout=180s&pretty"

if [ $? != 0 ]; then
  echo "\nCluster not green within timeout, please check logs with kubectl -n siren logs es-master-0"
  exit $?
fi

echo "\nWaiting for data nodes..."
kubectl -n siren exec es-master-0 -- curl -fs "http://localhost:9200/_cluster/health?wait_for_nodes=$((NODES + 3))&timeout=180s&pretty"

if [ $? != 0 ]; then
  echo "\nDid not find expected data nodes within timeout, please check namespace with kubectl -n siren get all"
  exit $?
fi

echo "\nRegistering snapshot repository..."
kubectl -n siren exec es-master-0 -- curl -fs -H "Content-Type: application/json" -XPUT http://localhost:9200/_snapshot/gcloud -d '
{
  "type": "gcs",
  "settings": {
    "bucket": "benchmark-snapshots",
    "client": "default",
    "base_path": "'${GCLOUD_SNAPSHOT_PATH}/${GCLOUD_SNAPSHOT}'"
  }
}'

if [ $? != 0 ]; then
  echo "\nCould not register snapshot repository."
  exit $?
fi

echo "\nRestoring snapshot..."

kubectl -n siren exec es-master-0 -- curl -fs -H "Content-Type: application/json" -XPOST "http://localhost:9200/_snapshot/gcloud/${GCLOUD_SNAPSHOT}/_restore?wait_for_completion=true"

echo "\nDisabling request cache..."

kubectl -n siren exec es-master-0 -- curl -fs -H "Content-Type: application/json" -XPUT "http://localhost:9200/_settings" -d '{
  "index.federate.queries.cache.enabled": false
}'

echo "\nTo forward the cluster rest API to your machine execute kubectl -n siren port-forward service/es-discovery 9200:9200"
