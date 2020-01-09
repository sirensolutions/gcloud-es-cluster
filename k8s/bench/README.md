# Benchmark cluster on Kubernetes

## Requirements

- Connectivity to artifactory
- An authenticated GCloud SDK installation with support for Kubernetes
- gomplate >= 3.6.0 : https://github.com/hairyhenderson/gomplate/releases
- curl
- docker

## Usage

Put a file named `gcloud.json` with the service account credentials in this folder; the location of this file can be customized.

Create an `.env` file modeled after `default.env` and customize the following variables:

- `PROJECT_ID`: Google Cloud project id (default `tempclusters`).
- `ELASTICSEARCH_VERSION`: the Elasticsearch version used to build the custom Docker image (default `6.8.2`).
- `FEDERATE_VERSION`: the name of a Federate version that can be downloaded from Artifactory (default `6.8.2-19.0-SNAPSHOT`).
- `GCLOUD_SNAPSHOT_PATH`: the folder in `benchmark-snapshots` that contains the snapshots for a scenario (default `parent_child`).
- `GCLOUD_SNAPSHOT`: the name of the snapshot to restore (default `7.3.2-19.0-snapshot_p2_000_000_c5_shards40_20191210_140643`).
- `GCLOUD_SERVICE_ACCOUNT_FILE`: the name of the file with the gcloud service account credentials (default `gcloud.json`).
- `ELASTICSEARCH_HEAP`: the heap for Elasticsearch data pods in GB (default `16`).
- `SIREN_MEMORY_ROOT_LIMIT`: the value of `siren.memory.root.limit` in the Elasticsearch configuration (default `2147483648`).
- `NODES`: number of worker nodes for Elasticsearch data pods (default `10`).
- `REGISTRY`: the registry where Docker image will be pushed (default `eu.gcr.io`).
- `NODE_TYPE`: type of Kubernetes worker nodes (default `n1-highmem-8`).
- `ZONE`: zone where cluster will be started (default `europe-west2-c`).

Then run `create_cluster.sh <environment file>`; once the script completes, the following command will make the remote cluster available on localhost:

```
kubectl port-forward -n siren service/es-discovery 9200:9200
```
