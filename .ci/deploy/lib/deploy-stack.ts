import * as cdk from '@aws-cdk/core';
import * as ec2 from "@aws-cdk/aws-ec2";
import * as ecs from "@aws-cdk/aws-ecs";
import * as ecs_patterns from "@aws-cdk/aws-ecs-patterns";
import { HttpCode } from '@nestjs/common';

export class DeployStack extends cdk.Stack {
  constructor(scope: cdk.Construct, id: string, props?: cdk.StackProps) {
    super(scope, id, props);

    /* Create VPC */
    const vpc = new ec2.Vpc(this, "ipcheckerVpc", {
      maxAzs: 3
    });

    /* Create ECS Cluster */
    const cluster = new ecs.Cluster(this, "ipcheckerCluster", {
      vpc: vpc
    });

    /* Create a load-balanced Fargate service and make it public */
    new ecs_patterns.ApplicationLoadBalancedFargateService(this, "ipcheckerService", {
      cluster: cluster,
      cpu: 512,
      desiredCount: 3,
      taskImageOptions: { 
        image: ecs.ContainerImage.fromRegistry("496719846555.dkr.ecr.us-east-1.amazonaws.com/ipchecker:2021.5.18"),        
        containerPort: 3000,
      },
      memoryLimitMiB: 2048,
      publicLoadBalancer: true,
    });
  }
}
