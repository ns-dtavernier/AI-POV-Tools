# IAM permissions for deploying the combined AI Services stack

These are the AWS permissions needed by the **person or CI principal running `terraform apply`** in `ai-services-all/new-vpc-public/`. They are broader than the AIG-only policy in [`aig/docs/iam-permissions.md`](../../../aig/docs/iam-permissions.md) because this template also creates VPC endpoints, SSM parameters, CloudWatch log groups and a Route 53 zone.

Instance roles (what the EC2 instances themselves can do) are created by the template and are not listed here.

The IAM identity running `terraform apply` needs permissions across several services. No S3 permissions are required for the Guardrails image bucket — that access is granted to the Guardrails EC2 instance role, not the Terraform operator.

## EC2

```
ec2:Describe*
ec2:AllocateAddress / ReleaseAddress / AssociateAddress / DisassociateAddress
ec2:CreateVpc / DeleteVpc / ModifyVpcAttribute
ec2:CreateSubnet / DeleteSubnet / ModifySubnetAttribute
ec2:CreateInternetGateway / DeleteInternetGateway / AttachInternetGateway / DetachInternetGateway
ec2:CreateNatGateway / DeleteNatGateway
ec2:CreateRouteTable / DeleteRouteTable / AssociateRouteTable / DisassociateRouteTable / CreateRoute / DeleteRoute
ec2:CreateSecurityGroup / DeleteSecurityGroup
ec2:AuthorizeSecurityGroupIngress / AuthorizeSecurityGroupEgress
ec2:RevokeSecurityGroupIngress / RevokeSecurityGroupEgress
ec2:RunInstances / TerminateInstances / StopInstances
ec2:CreateVpcEndpoint / DeleteVpcEndpoints / ModifyVpcEndpoint
ec2:CreateTags / DeleteTags
```

## IAM

```
iam:CreateRole / DeleteRole / GetRole
iam:CreateInstanceProfile / DeleteInstanceProfile / GetInstanceProfile
iam:AddRoleToInstanceProfile / RemoveRoleFromInstanceProfile
iam:PutRolePolicy / DeleteRolePolicy / GetRolePolicy / ListRolePolicies
iam:AttachRolePolicy / DetachRolePolicy / ListAttachedRolePolicies  ← AmazonSSMManagedInstanceCore for Guardrails
iam:PassRole  (scoped to ec2.amazonaws.com)
```

## Secrets Manager

```
secretsmanager:CreateSecret / DeleteSecret / DescribeSecret
secretsmanager:GetSecretValue / PutSecretValue / TagResource
```

## SSM

```
ssm:PutParameter / GetParameter / DeleteParameter   ← Guardrails readiness gate
ssm:SendCommand / GetCommandInvocation              ← DLPoD readiness gate (polls via Guardrails)
ssm:DescribeInstanceInformation
```

## CloudWatch Logs

```
logs:CreateLogGroup / DeleteLogGroup / DescribeLogGroups
logs:PutRetentionPolicy
```

## Route 53

```
route53:CreateHostedZone / DeleteHostedZone / GetHostedZone / ListHostedZones
route53:ChangeResourceRecordSets / ListResourceRecordSets
```

## Remote state (optional — recommended)

```
s3:GetObject / PutObject / DeleteObject   on your tfstate bucket
dynamodb:GetItem / PutItem / DeleteItem   on your lock table (if using DynamoDB locking)
```

---

