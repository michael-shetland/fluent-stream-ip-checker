#!/bin/sh
set -e

# Check Arguments
version=$1
if [ -z $version ]; then
  echo "Missing 'version' argument: ./execute.sh <version>"
  exit 99
fi

# Build
docker build \
  --build-arg version=${version} \
  --tag=fluent-stream-ip-checker:${version} \
  --force-rm \
  --file=./.ci/build/Dockerfile \
  .
