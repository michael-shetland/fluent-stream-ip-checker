import { expect as expectCDK, matchTemplate, MatchStyle } from '@aws-cdk/assert';
import * as cdk from '@aws-cdk/core';
import { ClusterStack } from '../lib/cluster-stack';

test('Empty Stack', () => {
    const app = new cdk.App();
    // WHEN
    const stack = new ClusterStack(app, 'ClusterStack');
    // THEN
    expectCDK(stack).to(matchTemplate({
      "Resources": {}
    }, MatchStyle.EXACT))
});
