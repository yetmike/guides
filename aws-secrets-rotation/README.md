# AWS Secrets Manager rotation with Lambda

Companion to the video **AWS Secrets Manager Rotation with Lambda, Explained with a Live Demo**.
Secrets Manager calls one Lambda four times to change a Postgres password, while an app keeps logging in.

| Step | What the Lambda does |
|---|---|
| `createSecret` | new random password, stored as a new version labelled `AWSPENDING` |
| `setSecret` | `ALTER ROLE` in the database |
| `testSecret` | logs in with the new password |
| `finishSecret` | moves `AWSCURRENT` to the new version, the old one becomes `AWSPREVIOUS` |

## Files

| Path | What |
|---|---|
| [lambda/rotate.py](lambda/rotate.py) | the rotation function (single-user strategy), based on the [AWS rotation template](https://github.com/aws-samples/aws-secrets-manager-rotation-lambdas) |
| [lambda/test_rotate.py](lambda/test_rotate.py) | local test: real Postgres in Docker, Secrets Manager mocked with moto |
| [app.sh](app.sh) | the "app": logs in every second, reads the secret again after a failed login |
| [terraform/main.tf](terraform/main.tf) | the secret, the Lambda, its IAM role, the permission for Secrets Manager to call it |
| [setup.sh](setup.sh) | creates the `app` role in Postgres and applies Terraform |

## Run it

Needs: AWS CLI with an admin IAM user or SSO role (not the root user), Terraform, Python 3, `psql`, `jq`, and a Postgres.
The video uses a free [Neon](https://neon.com) project; its region is reused for AWS.

```bash
./setup.sh 'postgresql://neondb_owner:...@ep-xxx.<region>.aws.neon.tech/neondb?sslmode=require'
export AWS_REGION=<region>                   # the region setup.sh printed
./app.sh &                                   # the app, logs in every second

aws secretsmanager rotate-secret --secret-id rotation-demo/app-db \
  --rotation-lambda-arn "$(terraform -chdir=terraform output -raw lambda_arn)" \
  --rotation-rules '{"ScheduleExpression":"rate(4 hours)"}'      # rotates right away, then every 4 h

aws secretsmanager describe-secret --secret-id rotation-demo/app-db --query VersionIdsToStages
aws logs tail /aws/lambda/secret-rotator --since 5m --format short
```

Local test without AWS:

```bash
docker run -d --rm --name rot-pg -e POSTGRES_PASSWORD=admin -p 55432:5432 postgres:17
pip install moto boto3 pg8000 && cd lambda && python test_rotate.py
```

## What the demo showed

- With one database user, the app can see one failed login during rotation. Read the secret again and retry.
  Zero failed logins needs the alternating-users strategy (two users).
- A broken rotation is safe: `AWSCURRENT` keeps working, a new `rotate-secret` is refused
  ("A previous rotation isn't complete"), and Secrets Manager retries the stuck one by itself once the cause is fixed.
- Cost: $0.40 per secret per month, Lambda within the free tier.

## Clean up

```bash
./setup.sh destroy <region>
aws logs delete-log-group --log-group-name /aws/lambda/secret-rotator
```
Then delete the Neon project.
