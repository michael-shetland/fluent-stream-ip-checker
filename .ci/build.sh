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

docker tag fluent-stream-ip-checker:${tag} 496719846555.dkr.ecr.us-east-1.amazonaws.com/ipchecker:${tag}

eval $(aws --profile personal ecr get-login --no-include-email)
docker push 496719846555.dkr.ecr.us-east-1.amazonaws.com/ipchecker:${tag}
