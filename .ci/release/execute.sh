#!/bin/sh
set -e

# Initialize
awsProfile=personal
repoName='496719846555.dkr.ecr.us-east-1.amazonaws.com/ipchecker'

# Check Arguments
version=$1
if [ -z $version ]; then
  echo "Missing 'version' argument: ./execute.sh <version>"
  exit 99
fi

# Retag
docker tag fluent-stream-ip-checker:${version} ${repoName}:${version}

# Login
eval $(aws --profile ${awsProfile} ecr get-login --no-include-email)

# Push
docker push ${repoName}:${version}
