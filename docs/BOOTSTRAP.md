# Bootstrap — run this once, before the talk

Two chicken-and-egg problems stand between an empty AWS account and a working
pipeline. Both are solved here, in order, and both are good material: they are
the questions every engineer hits the first time they automate infrastructure.

| # | The problem | The answer |
|---|---|---|
| 1 | Terraform needs an S3 bucket for state, but Terraform is what creates buckets | A tiny separate stack starts on local state, creates the bucket, then moves its own state into it |
| 2 | ECS cannot start a task whose image is not in ECR yet, and ECR is created by the same stack | Apply in two passes with `create_service = false`, push the first image in between |

You need: Terraform 1.11+, the AWS CLI, Docker, the `gh` CLI, and credentials
for a **sandbox AWS account** you are willing to create and destroy things in.

---

## Step 1 — create the bucket and the roles, on local state

```bash
cd infrastructure/bootstrap
cp terraform.tfvars.example terraform.tfvars   # then edit it, see step 2
terraform init
terraform apply
```

This creates exactly three things: the state bucket (versioned, encrypted,
TLS-only, **no DynamoDB lock table**), the GitHub OIDC identity provider, and
the two IAM roles.

State is local for now. `terraform.tfstate` is git-ignored — it contains ARNs,
not secrets, but state files are never committed on principle.

## Step 2 — get the OIDC subject claims right, first

Do this **before** the apply above, because a wrong `sub` produces a role
nobody can assume and the error message does not tell you why.

GitHub has two subject formats. Repositories created **on or after
15 July 2026** use the immutable format built from numeric owner and
repository IDs; older ones use the familiar `repo:OWNER/REPO:...` names.
`awsbaku/code-busters-monorepo` is new, so **assume the immutable format applies and
verify it**. Do not copy a sample from a blog post.

Verify it from the real repository:

```bash
# what GitHub says this repository's subject looks like
gh api /repos/awsbaku/code-busters-monorepo/actions/oidc/customization/sub

# the numeric IDs, which the immutable format is built from
gh api /repos/awsbaku/code-busters-monorepo --jq '{repo_id: .id, owner_id: .owner.id}'
```

If you are still unsure, run the workflow once against a deliberately empty
subject list, let the `AssumeRoleWithWebIdentity` call fail, and read the
exact `sub` AWS saw in the CloudTrail event. That is the ground truth.

**Never print the raw JWT in a workflow log.** It is a bearer credential for
one hour. Read the claim from CloudTrail instead.

Put the verified values in `infra_role_subjects` and `app_role_subjects`,
then apply.

## Step 3 — the bootstrap state stays local, on purpose

**Do not migrate it into the bucket.** The bootstrap keeps its state in
`infrastructure/bootstrap/terraform.tfstate` on the machine that ran it.

The tempting move is to point the bootstrap at the bucket it just created, so
that "nothing is left on a laptop". It closes a satisfying loop and it makes
teardown genuinely painful: the state describing the bucket would live inside
that same bucket, so destroying it means first migrating the state back out,
emptying every object version by hand, and only then running `destroy`. A
re-runnable demo is worth more than a tidy loop.

What this costs, stated plainly:

- **One file matters.** `terraform.tfstate` here is git-ignored and exists in
  exactly one place. Lose it and the roles, bucket and ECR repository are
  orphaned — still running, no longer managed. Back it up before the talk.
- **No locking on the bootstrap.** Fine, because one person runs it once,
  by hand. It is not what the pipeline touches.

The split that matters:

| Stack | State | Why |
|---|---|---|
| `infrastructure/bootstrap/` | **local file** | run once by hand; must stay destroyable |
| `infrastructure/` (the phases) | **S3 + `use_lockfile`** | GitHub Actions runs it; needs shared state and a lock |

So the bucket this step created holds exactly one key — `demo/terraform.tfstate`,
the phases — and never its own.

## Step 4 — tell GitHub about the roles

```bash
cd infrastructure/bootstrap
terraform output github_variables_to_set
```

Set each as a **repository variable** (Settings → Secrets and variables →
Actions → Variables). These are ARNs and names, not secrets — but variables,
not secrets, is the correct place for them either way.

```
AWS_REGION          eu-central-1
AWS_INFRA_ROLE_ARN  arn:aws:iam::...:role/code-busters-demo-terraform-infra
AWS_APP_ROLE_ARN    arn:aws:iam::...:role/code-busters-demo-app-deploy
TF_STATE_BUCKET     code-busters-tfstate-<account-id>
ECR_REPOSITORY      code-busters-demo
ECS_CLUSTER         code-busters-demo
ECS_SERVICE         code-busters-demo
ECS_TASK_FAMILY     code-busters-demo
```

Then create two environments, `demo-infra` and `demo-app`, and restrict each
to the `main` branch. The IAM trust policies reference these names, so an
environment typo is an authentication failure, not a silent downgrade.

## Step 5 — push the seed image

The bootstrap created the ECR repository. Push one image into it now, tagged
`seed`. Phase 3 creates the ECS service, and a service whose image is not in
ECR fails its deployment circuit breaker — so this step is what makes the
phase-3 apply succeed on the first attempt, in front of an audience.

```bash
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REG="${ACCOUNT}.dkr.ecr.eu-central-1.amazonaws.com"
SHA=$(git rev-parse HEAD)

aws ecr get-login-password --region eu-central-1 \
  | docker login --username AWS --password-stdin "$REG"

docker build --build-arg APP_COMMIT="$SHA" -t "$REG/code-busters-demo:seed" app
docker push "$REG/code-busters-demo:seed"
```

Verify it is really there, and that it really serves `/health`:

```bash
aws ecr describe-images --repository-name code-busters-demo \
  --query 'imageDetails[].imageTags'

docker run --rm -d --name seedcheck -p 8080:8080 "$REG/code-busters-demo:seed"
curl -sf http://localhost:8080/health && echo " OK"
docker rm -f seedcheck
```

The repository is set to IMMUTABLE tags, so `seed` can be pushed exactly once.
To replace it, delete the image first.

## Step 6 — initialise the root stack

`main` contains no infrastructure resources yet — they arrive in the three
phase branches. Initialising now means the phase-1 plan runs against a
prepared backend rather than doing it for the first time on stage.

```bash
cd infrastructure
terraform init \
  -backend-config="bucket=code-busters-tfstate-<account-id>" \
  -backend-config="region=eu-central-1"

terraform plan     # "No changes" — main declares no resources
```

## Step 7 — open the three phase pull requests

```bash
for n in 1 2 3; do
  gh pr create --base main --head iac-phase-$n --fill
done
```

Do not create these on stage. On stage you click Merge. See PHASES.md.

---

## What to show on stage

**Not this.** A first-time bootstrap on stage is ten minutes of waiting and
one typo away from a dead demo. Have all of the above finished and running
before you walk in.

Show instead:
1. the two workflow files, and their path filters
2. the three phase pull requests, merged one at a time — see PHASES.md
3. a one-line change to the application page, pushed to `main`, and the commit
   SHA on the live page changing while they watch

If you need one more safe infrastructure change after the phases, set
`log_retention_days` from 7 to 14: a one-line diff, a readable plan, no
replacement, three seconds to apply.
