# Benchmark cluster on Kubernetes

## Requirements

- Connectivity to artifactory
- An authenticated GCloud SDK installation with support for Kubernetes
- gomplate >= 3.6.0 : https://github.com/hairyhenderson/gomplate/releases
- docker

## Usage

Export the following environment variables:

- `ELASTICSEARCH_VERSION`: the Elasticsearch version used to build the custom Docker image (default `6.8.2`).
- `FEDERATE_VERSION`: the name of a Federate version that can be downloaded from Artifactory (default `6.8.2-19.0-SNAPSHOT`).
- `NODES`: the number of nodes in the Kubernetes cluster (default `5`).
- `NODE_TYPE`: the machine type for Kubernetes nodes (default `n1-highmem-16`)
- `ELASTICSEARCH_DATA_JAVA_OPTIONS`: custom Java options for data nodes (default `-Xmx30g -Xms30g`)

Then run `create_cluster.sh`; once the script completes, the following command should make the remote cluster available on localhost:

```
kubectl port-forward -n siren service/es-discovery 9200:9200
```
