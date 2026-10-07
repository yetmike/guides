# AWS NAT Gateway vs AlterNAT

Companion to the video **AWS NAT Gateway Is Too Expensive. Do This Instead**.
A NAT Gateway charges $0.045 per GB processed. [AlterNAT](https://github.com/chime/terraform-aws-alternat) runs NAT on small EC2 instances
(no per-GB fee) and keeps a NAT Gateway on standby: a Lambda checks the internet and flips the route if the instance dies.

| 50 TB a month, 3 zones, us-east-1 | Per month |
|---|---|
| NAT Gateway (3 x hourly + $0.045/GB) | ~$2,360 |
| AlterNAT on c6gn.medium (+ standby NAT Gateways, IPs, EC2 endpoint, Lambda) | ~$265 |
| Internet traffic out ($0.09/GB) | the same with both |

Free fix first: an S3 or DynamoDB **gateway endpoint** costs nothing and takes that traffic off the NAT meter.

## Files

| Path | What |
|---|---|
| [vpc.tf](vpc.tf) | provider + a VPC with 1 public and 1 private subnet in one zone |
| [alternat.tf](alternat.tf) | the AlterNAT module, `t4g.small` NAT instance (the module default is `c6gn.8xlarge`, ~$1,009 a month per zone) |
| [test-server.tf](test-server.tf) | a tiny private test server, reached with SSM (no SSH, no public IP) |
| [test-server-ssm.tf](test-server-ssm.tf) | SSM endpoints so the shell keeps working while the NAT fails over |
| [failover.sh](failover.sh) | runs on the test server: prints the time and the public IP every second |
| [route.sh](route.sh) | shows where the private subnet's internet route points right now |

## Run the failover test

Costs about $0.10 an hour while it runs (NAT Gateway, instances, endpoints). Needs: AWS CLI (an IAM user or SSO role, not root),
Terraform, the [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html).

```bash
export AWS_REGION=us-east-1
terraform init && terraform apply
export TEST=$(terraform output -raw test_instance_id) RT=$(terraform output -raw route_table_id)

aws ssm start-session --target $TEST      # terminal 1: on the test server, paste the loop from failover.sh
./route.sh                                # terminal 2: 0.0.0.0/0 -> eni-... (NAT instance)
NAT=$(aws ec2 describe-instances --filters Name=tag:Name,Values=alternat-us-east-1a Name=instance-state-name,Values=running \
  --query 'Reservations[].Instances[].InstanceId' --output text)
aws ec2 terminate-instances --instance-ids $NAT
watch -n 2 ./route.sh                     # -> standby NAT Gateway, then back to a new NAT instance
```

In the video: 18 s without internet, then the standby NAT Gateway took over; a new instance carried the traffic again ~75 s after the kill.
Open connections drop at each switch, so apps must retry.

## Clean up

```bash
terraform destroy      # ~35 min: AWS releases the Lambda's network interfaces slowly
```

Check that no NAT Gateway, Elastic IP or instance is left: they cost money.
