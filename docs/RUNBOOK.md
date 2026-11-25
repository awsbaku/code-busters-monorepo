# Runbook

## The ownership check — run after every infrastructure apply

Terraform owns the ECS service; the application pipeline owns which image it
runs. `aws_ecs_service.this` ignores changes to `task_definition`, so an
infrastructure apply must never roll the application back. Prove it:

```bash
cd infrastructure
curl -s "$(terraform output -raw app_url)/version"
```

The `commit` must still match the last successful run of the application
workflow. If it reverted to `bootstrap` or to an older SHA, the
`ignore_changes` block in `ecs.tf` was removed or narrowed — restore it, and
redeploy the application to recover.

The infrastructure workflow runs this check automatically after apply.

## Local development

```bash
cd app
python -m venv .venv && . .venv/bin/activate
pip install -r requirements-dev.txt
pytest
APP_COMMIT=$(git rev-parse HEAD) uvicorn main:app --reload --port 8080
```

Or in a container, exactly as CI does it:

```bash
docker build --build-arg APP_COMMIT=$(git rev-parse HEAD) -t code-busters app
docker run --rm -p 8080:8080 code-busters
```

## Terraform, locally

```bash
cd infrastructure
terraform init -backend-config="bucket=..." -backend-config="region=eu-central-1"
terraform fmt -recursive
terraform validate
terraform plan        # read-only; safe to run any time
```

## When the deploy fails

| Symptom | Where to look |
|---|---|
| `Not authorized to perform sts:AssumeRoleWithWebIdentity` | The `sub` claim does not match the trust policy. Read the real claim from the CloudTrail event; see BOOTSTRAP.md step 2 |
| ECS service never reaches steady state | CloudWatch log group `/ecs/code-busterss-demo`. Usually the container exits on startup or listens on the wrong port |
| Targets unhealthy, tasks running | Target group health check path, and the task security group — it must accept the app port from the ALB security group |
| `Error acquiring the state lock` | Another run holds it. Wait, or inspect the `.tflock` object beside the state file in S3. There is no DynamoDB table to clear |
| Smoke test times out on the right commit | ALB target registration lag. The step already retries for two minutes; beyond that, check deregistration of the old task |

## Phase demo

See PHASES.md. The short version: three pre-created pull requests, merged in
order, with phase 3 last.

## Teardown

```bash
cd infrastructure
terraform destroy

cd bootstrap
# the state bucket has versioning on, so it must be emptied including versions
terraform destroy
```

Check afterwards that both Elastic IPs were released — an unattached
Elastic IP keeps billing:

```bash
aws ec2 describe-addresses --query 'Addresses[].{ip:PublicIp,assoc:AssociationId}'
```

If the state bucket refuses to delete, empty it first:

```bash
aws s3api delete-objects --bucket <bucket> --delete "$(aws s3api list-object-versions \
  --bucket <bucket> --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}')"
```

Destroy the main stack **before** the bootstrap stack, or you delete the
state bucket while the state inside it still describes live resources.
