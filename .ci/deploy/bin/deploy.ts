#!/usr/bin/env node
import 'source-map-support/register';
import * as cdk from '@aws-cdk/core';
import { ClusterStack } from '../lib/cluster-stack';
import { RepoStack } from '../lib/repo-stack';
import { ServiceStack } from '../lib/service-stack';

const app = new cdk.App();
const version = app.node.tryGetContext("version");
if (!version) throw new Error('Missing -c version=X.X.X');

const clusterStack = new ClusterStack(app, 'ClusterStack');
const repoStack = new RepoStack(app, 'RepoStack');
const serviceStack = new ServiceStack(app, 'ServiceStack', {
  vpc: clusterStack.vpc,
  cluster: clusterStack.cluster,
  repo: repoStack.repo,
  version,
});
