# Code Busters

> One monorepo. Two pipelines. No AWS keys.

The demo repository for the talk **From Commit to AWS Cloud — Powered by
GitHub Actions**, given at Git Talks by the Azerbaijan GitHub Community.

A small FastAPI page says hello to the Code Busters. This repository is how it
reaches a public URL on AWS, how the infrastructure underneath it is created,
and how both happen without a single long-lived credential anywhere.

```
code-busters-monorepo/
├── app/                          the application: one page, three endpoints
│   ├── main.py
│   ├── Dockerfile
│   └── tests/
├── infrastructure/               the AWS estate, in Terraform
│   ├── bootstrap/                run once by hand: state bucket, OIDC, roles, ECR
│   ├── variables.tf  locals.tf   shared, complete from the start
│   ├── backend.tf                S3 remote state, native locking, no DynamoDB
│   └── phase-N-*.tf              added one per phase — see docs/PHASES.md
├── .github/workflows/
│   ├── infrastructure.yml        infrastructure/** -> plan, then gated apply
│   └── application.yml           app/**            -> test, build, push, deploy
└── docs/
    ├── BOOTSTRAP.md              start here
    ├── PHASES.md                 the three infrastructure pull requests
    ├── RUNBOOK.md  COSTS.md
```

## The three ideas

**One repository, two pipelines.** Path filters decide which automation starts.
A change under `app/` ships a container; a change under `infrastructure/`
plans a Terraform diff. A change to both starts both.

**One OIDC trust, two roles.** GitHub mints a short-lived signed token
describing the exact workflow run. AWS checks it against a role's trust policy
and returns credentials that expire in an hour. The infrastructure role may
change infrastructure; the application role may push an image and roll the
service. Neither can do the other's job, and there is no AWS access key to leak.

**State locking without DynamoDB.** The S3 backend takes its own lock by
writing a `.tflock` object beside the state file (`use_lockfile = true`). The
DynamoDB lock table that older tutorials tell you to create is deprecated, and
this repository does not have one.

## Architecture

Two Availability Zones. A public subnet and a private subnet in each. An
internet-facing load balancer in the public subnets; the Fargate tasks in the
private ones with no public IP, reachable only through the load balancer and
only on the application port. A NAT gateway with its own Elastic IP in each
zone, so losing a zone does not take the other zone's image pulls and log
delivery with it.

Diagrams: `tech-talk-master/talks/code-buster/diagrams/simple/`.

## Infrastructure arrives in three pull requests

| Branch | Adds | `Plan:` |
|---|---|---|
| `iac-phase-1` | VPC, subnets, routing, NAT gateways, security groups | ~26 |
| `iac-phase-2` | Log group, task roles, ECS cluster, task definition | 6 |
| `iac-phase-3` | Load balancer, target group, listener, ECS service | 4 |

Each phase adds exactly one new file and edits nothing that exists, so every
pull request diff is purely the new infrastructure. The branches are stacked
and **must be merged in order**: a pull request is validated against `main`
plus the branch, so a later phase needs its predecessors present.

`main` is the deployment branch: merging a phase applies it. Full walkthrough
in [`docs/PHASES.md`](docs/PHASES.md).

## Running it

| | |
|---|---|
| Local app | `cd app && pip install -r requirements-dev.txt && pytest && uvicorn main:app --port 8080` |
| First-time AWS setup | [`docs/BOOTSTRAP.md`](docs/BOOTSTRAP.md) |
| The phase demo | [`docs/PHASES.md`](docs/PHASES.md) |
| Day-to-day, and when it breaks | [`docs/RUNBOOK.md`](docs/RUNBOOK.md) |
| What it costs, and teardown | [`docs/COSTS.md`](docs/COSTS.md) |

## Endpoints

| Path | Purpose |
|---|---|
| `GET /` | The page. Version, commit SHA, environment, task ID |
| `GET /health` | Load balancer health check. Returns a constant, on purpose |
| `GET /version` | JSON. The deploy polls this until it sees the pushed SHA |

The commit SHA on the page is the point: push a change and watch the value on
a live public URL change while the room is looking at it. The task ID changes
too, as the load balancer moves between Availability Zones.

## Deliberate simplifications

- **HTTP, not HTTPS.** No domain, so no certificate and no Route 53 record. An
  ACM certificate and a 443 listener are a short addition with a real domain.
- **A broad-ish Terraform role.** Scoped by service and by IAM path, never
  `AdministratorAccess`, documented in `infrastructure/bootstrap/iam.tf`. It
  belongs in an isolated sandbox account.
- **Action versions are tags, not commit SHAs.** Pin them before the demo; the
  command is in the header of each workflow.
- **No Slack notification and no required status checks.** Both are real
  practice; both were cut because they add workflow surface without teaching
  anything the pipeline does not already show.

## Not GitOps

This is Git-centric delivery: Git is the trigger, and a pipeline pushes changes
outward. Real GitOps adds a controller that continuously reconciles the cluster
against declared desired state and corrects drift on its own. Nothing here
reconciles. Worth saying out loud, because the two get conflated constantly.
