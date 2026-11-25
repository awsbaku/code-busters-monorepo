# The IaC phases

Infrastructure arrives in three pull requests, one branch each. Every phase
adds **exactly one new file** and edits nothing that already exists, so each
pull request diff is the teaching material: here is the new infrastructure,
with no noise around it.

| Branch | File | Adds | `Plan:` | Apply |
|---|---|---|---|---|
| `iac-phase-1` | `infrastructure/phase-1-network.tf` | VPC, IGW, 2 public + 2 private subnets, public route table, 2 NAT gateways + 2 Elastic IPs, 2 private route tables, 2 security groups + 4 rules | ~26 | ~2.5 min |
| `iac-phase-2` | `infrastructure/phase-2-compute.tf` | Log group, task execution role + policy attachment, task role, ECS cluster, task definition | 6 | ~20 s |
| `iac-phase-3` | `infrastructure/phase-3-delivery.tf` | ALB, target group, listener, ECS service | 4 | ~4 min |

The branches are independent — each one is cut from `main` and touches a
different file, so there are no merge conflicts and no stacking.
**Phase 3 must be merged last**, because it is the only one that references
the other two. Phases 1 and 2 are independent of each other.

## The loop, for each phase

1. Open the pull request (pre-created — do not create these on stage)
2. The `infrastructure` workflow runs `fmt`, `validate`, then `plan`
3. **Read the plan.** Ask the room how many resources before revealing it
4. Merge
5. The `apply` job runs behind the `demo-infra` environment gate
6. Verify in AWS

## What each phase ends on

### Phase 1 — the network

Nothing runs. The place things will run in exists.

Verify in the console: **VPC → your VPC → Resource map**. It draws the subnets,
route tables and gateways for you, and it is the one AWS console view that is
genuinely better than a terminal.

```bash
aws ec2 describe-nat-gateways \
  --filter Name=vpc-id,Values=$(terraform output -raw vpc_id) \
  --query 'NatGateways[].{az:SubnetId,state:State,ip:NatGatewayAddresses[0].PublicIp}'
```

Talk about: two zones, two NAT gateways, two private route tables each
pointing at the NAT in its *own* zone. And the security-group rule whose
source is another security group rather than a CIDR block.

### Phase 2 — the blueprint

A cluster with nothing in it, and a registered task definition that nothing is
running.

```bash
aws ecs describe-task-definition --task-definition code-busters-demo \
  --query 'taskDefinition.{rev:revision,image:containerDefinitions[0].image}'
aws ecs list-tasks --cluster code-busters-demo        # empty
```

Talk about: AWS now knows exactly how to run this container — image, cpu,
memory, port, roles, where the logs go — and has not been asked to run it.
Registering a recipe is not cooking.

### Phase 3 — delivery

**Keep the application URL open in a browser tab before you merge.** The load
balancer answers roughly two minutes before the first task passes its health
check, so the page goes **503 → 200 while the room watches.** That transition
is the best thirty seconds of the demo: a load balancer with no healthy
targets is a door with nobody home.

```bash
terraform output -raw app_url
aws ecs describe-services --cluster code-busters-demo --services code-busters-demo \
  --query 'services[0].{desired:desiredCount,running:runningCount}'
```

Then refresh a few times and watch the **Task** tile on the page change — that
is the load balancer moving between the two Availability Zones.

Infrastructure is now complete. The application CI/CD demo follows.

## Timing

Roughly 15 minutes for all three including GitHub Actions overhead (~90 s for
a plan run, ~45 s of overhead before each apply). Rehearse it twice and write
down the real numbers; the ALB in particular varies.

## Reliability

- **Pre-create all three pull requests.** On stage you only click Merge.
- **Record a screen capture of the whole sequence** the day before. If the
  venue network or GitHub Actions is slow, narrate the recording.
- **Run the full sequence once from an empty account** so you know phase 1
  works from zero, then destroy it.
- **Confirm the seed image is in ECR and serves `/health`** before trusting
  phase 3. A service with nothing to pull fails the apply in front of the room.
- Keep a second tab on the Actions run page, so logs are one click away.

## If phase 1 feels too heavy

Split it: **1a** VPC, subnets, IGW, public routing, security groups; **1b**
Elastic IPs, NAT gateways, private route tables. 1b stands on its own as the
cost conversation — the NAT gateways are the most expensive line in this
architecture and the most commonly misunderstood resource in it.
