import * as cdk from '@aws-cdk/core';
import * as ecr from '@aws-cdk/aws-ecr';

export class RepoStack extends cdk.Stack {
  public readonly repo: ecr.Repository;

  constructor(scope: cdk.Construct, id: string, props?: cdk.StackProps) {
    super(scope, id, props);

    /* Create Repoistory */
    this.repo = new ecr.Repository(this, "ipcheckerRepo", {
      repositoryName: 'ipchecker'
    });
  }
}
