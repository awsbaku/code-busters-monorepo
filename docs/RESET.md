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

## The phase branches are generated, not maintained

There are no anchor tags any more. `main` is the single source of truth, and
each phase branch is **main plus exactly one more phase file**, rebuilt from
scratch on every reset:

```
main            workflows, app, docs, shared Terraform, no phases
iac-phase-1     main + phase-1-network.tf
iac-phase-2     main + phase-1 + phase-2-compute.tf
iac-phase-3     main + phase-1 + phase-2 + phase-3-delivery.tf
```

This is why the branches can never go stale: they do not persist between
rehearsals, they are regenerated from whatever main currently holds.

**Do not try to keep them up to date by merging main into them.** It looks
like the obvious move and it is wrong. By the time you want to sync, main is
carrying all three phase files, so merging it into `iac-phase-1` hands phase 1
the entire stack and its pull request proposes everything at once. The
incremental demo is gone.

## Restoring main: force-push dev, never delete it

`main` is restored by force-pushing `dev` onto it:

```bash
git push --force origin dev:main
```

One atomic ref update, and the result is byte-identical to the starting line
rather than "main with some files deleted".

**Do not delete and recreate `main`.** GitHub refuses to delete the default
branch, so recreating it means repointing the default somewhere else first —
and that **auto-closes every open pull request**, your phase PRs included,
then leaves the rulesets and the default-branch setting to be put back. Four
fragile steps for the same result one gives you.

`dev` is protected against deletion and non-fast-forward pushes, so it can
only ever move forward. The phase branches are force-pushed with
`--force-with-lease`; the ruleset on them blocks *deletion*, which a
force-push is not.

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
real talk, the push fails: the tag already exists. Make a fresh commit for
the live demo (changing the greeting text is the natural one), or delete that
tag first:

```bash
aws ecr batch-delete-image --region eu-central-1 \
  --repository-name code-busters-demo --image-ids imageTag=<sha>
```

**Taking the phases off main triggers an apply.** `main` runs the
infrastructure workflow whenever `infrastructure/**` changes, and removing the
three phase files is such a change. If resources still exist in state at that
moment, the pipeline sees a configuration describing nothing and applies it:
a full destroy, through CI, unattended, with nobody watching the output.

It would even work. Relying on it would not — a circuit-breaker rollback or an
expired role mid-run leaves you half torn down with a talk to give. Destroy
first, deliberately, and this push becomes a no-op. That is the second reason
for the ordering rule above.

## If the destroy fails halfway

Re-run it. Terraform is safe to re-run and will pick up where it stopped. The
usual cause is the ECS service still draining; it resolves on the second
attempt. Then run `check` and believe only what it prints — not what the
previous command claimed.
