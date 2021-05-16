#!/bin/sh
set -e

version=$1

if [ -z $version ]; then
  version=0.0.0
  tag=local
else
  tag=$version
fi

docker build \
  --build-arg version=$version \
  --tag=fluent-stream-ip-checker:${tag} \
  --force-rm \
  --file=./.ci/Dockerfile \
  .
  