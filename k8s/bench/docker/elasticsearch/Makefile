SHELL:=/bin/bash
IMAGE=elasticsearch
VERSION:=latest
REGISTRY=eu.gcr.io
PROJECT_ID=tempclusters

build:
	@docker build -t ${REGISTRY}/${PROJECT_ID}/${IMAGE}:${VERSION} .

publish: build
	@docker push ${REGISTRY}/${PROJECT_ID}/${IMAGE}:${VERSION}
