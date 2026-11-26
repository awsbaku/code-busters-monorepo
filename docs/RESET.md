# Rehearsing, and getting back to the starting line

The demo is destructive in two places at once: it creates AWS resources, and
it merges pull requests. A rehearsal has to undo both, or the real demo starts
from the wrong state.

`scripts/demo-reset.sh` does it.

```bash
./scripts/demo-reset.sh check   # change nothing, tell me where I stand
./scripts/demo-reset.sh aws     # destroy the phase resources
./scripts/demo-reset.sh git     # rewind the branches, open fresh PRs
./scripts/demo-reset.sh all     # both, AWS first
```

## The anchors

Four git tags pin the starting line. They were pushed before the first
rehearsal and should never move:

```
demo-start/main            e293771
demo-start/iac-phase-1     b4ee25b
demo-start/iac-phase-2     9787231
demo-start/iac-phase-3     89172b2
```

The rewind is a force-push of each tag onto its branch. `main` has no branch
protection, which is what makes this possible — and is also why nobody else
should be pushing to this repository during the talk.

## Order matters, in one specific way

**Always destroy AWS before rewinding git.**

`terraform destroy` reads the configuration to know what to destroy. After the
rewind, `main` no longer contains `phase-*.tf`, so Terraform sees an empty
configuration, and the VPC, NAT gateways and load balancer are orphaned in the
account with no code describing them. Recovering from that is manual console
work. The script refuses to run `aws` from a checkout with no phase files for
exactly this reason.

## The run itself

| Step | Watch for |
|---|---|
| Merge PR 1 | ~3 min. Two NAT gateways are the slow part |
| Merge PR 2 | ~1 min. Nothing runs yet |
| Merge PR 3 | ~5 min, including the silent ACM validation wait |
| Push an app change | The deploy workflow, then `/version` on the live URL |
| `./scripts/demo-reset.sh all` | ~6 min |

## What survives a reset, deliberately

The bootstrap is never touched:

- the Terraform state bucket
- the two IAM roles and the OIDC trust
- the ECR repository **and the `seed` image**

The seed image is the one that matters. Phase 3 creates an ECS service that
pulls `:seed` immediately; with no image there, the service never reaches a
steady state and the apply fails in front of the room. `check` verifies it is
still present.

## Two things that will bite on a re-run

**ECR tags are immutable.** The application pipeline pushes `:$GITHUB_SHA`. If
you rehearse the application demo and then re-run the *same commit* at the
real talk, the push fails — the tag already exists. Make a fresh commit for
the live demo (changing the greeting text is the natural one), or delete that
tag first:

```bash
aws ecr batch-delete-image --region eu-central-1 \
  --repository-name code-busters-demo --image-ids imageTag=<sha>
```

**Force-pushing main can trigger an apply.** `main` runs the infrastructure
workflow on push when `infrastructure/**` changes. Rewinding main while
resources still exist in state means the pipeline sees a configuration with no
phase files and applies that — a destroy, through the pipeline, unattended.
Destroying first makes the question moot, which is the other reason for the
order above.

## If the destroy fails halfway

Re-run it. Terraform is safe to re-run and will pick up where it stopped. The
usual cause is the ECS service still draining; it resolves on the second
attempt. Then run `check` and believe only what it prints — not what the
previous command claimed.
