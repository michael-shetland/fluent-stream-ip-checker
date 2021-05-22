import * as cdk from '@aws-cdk/core';
import * as ec2 from "@aws-cdk/aws-ec2";
import * as ecs from "@aws-cdk/aws-ecs";
import * as ecr from "@aws-cdk/aws-ecr";
import * as elb from '@aws-cdk/aws-elasticloadbalancingv2';

interface ServiceStackProps extends cdk.StackProps {
  vpc: ec2.Vpc;
  cluster: ecs.Cluster;
  repo: ecr.Repository;
  version: string;
}

export class ServiceStack extends cdk.Stack {
  constructor(scope: cdk.Construct, id: string, props: ServiceStackProps) {
    super(scope, id, props);

    /* Create Task Definition */
    const taskDefinition = new ecs.TaskDefinition(this, 'ipcheckerTask', {
      networkMode: ecs.NetworkMode.AWS_VPC,
      compatibility: ecs.Compatibility.EC2,
    });
    
    taskDefinition.addContainer('ipcheckerContainer', {
      image: ecs.ContainerImage.fromEcrRepository(props.repo, props.version),        
      memoryLimitMiB: 1024,
      portMappings: [
        {
          protocol: ecs.Protocol.TCP,
          containerPort: 3000,
        }
      ],
      privileged: true,
    });

    /* Create Service */
    const service = new ecs.Ec2Service(this, 'ipcheckerService', {
      cluster: props.cluster,
      taskDefinition
    });

    /* Setup Application Load Balancer */
    const alb = new elb.ApplicationLoadBalancer(this, 'ipcheckerALB', { 
      vpc: props.vpc, 
      internetFacing: true,
    });
    const listener = alb.addListener('Listener', { port: 80 });
    const targetGroup1 = listener.addTargets('ipcheckerTG80', {
      port: 80,
      targets: [service]
    });
  }
}
