import * as cdk from '@aws-cdk/core';
import * as autoscaling from '@aws-cdk/aws-autoscaling';
import * as ec2 from '@aws-cdk/aws-ec2';
import * as ecs from '@aws-cdk/aws-ecs';

export class ClusterStack extends cdk.Stack {
  public readonly vpc: ec2.Vpc;
  public readonly cluster: ecs.Cluster;

  constructor(scope: cdk.Construct, id: string, props?: cdk.StackProps) {
    super(scope, id, props);

    /* Create VPC */
    this.vpc = new ec2.Vpc(this, "ipcheckerVpc", {
      maxAzs: 3
    });

    /* Create ECS Cluster */
    this.cluster = new ecs.Cluster(this, "ipcheckerCluster", {
      vpc: this.vpc
    });

    /* Setup Server(s) for Cluster */
    const autoScalingGroup = new autoscaling.AutoScalingGroup(this, 'ASG', {
      vpc: this.vpc,
      instanceType: new ec2.InstanceType('t2.small'),
      machineImage: ecs.EcsOptimizedImage.amazonLinux2(),
      desiredCapacity: 1,
    });
    const autoScaleGroupCapacityProvider = new ecs.AsgCapacityProvider(this, 'ipcheckerASG', {
      autoScalingGroup,
    });

    this.cluster.addAsgCapacityProvider(autoScaleGroupCapacityProvider);
  }
}
