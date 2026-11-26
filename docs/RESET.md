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

## The teardown is a demo beat, and it is tested

**Verified on 26 November 2026**, against the live stack:

```
git push --force origin dev:main
  -> infrastructure workflow only
  -> Plan: 0 to add, 0 to change, 43 to destroy
  -> Apply complete! Resources: 0 added, 0 changed, 43 destroyed
  -> green, 3 min 40 s
```

Afterwards: no VPC, no NAT gateways, no Elastic IPs, no load balancer, no ECS
cluster, no certificate, no DNS record. The account was clean.

This is worth doing on stage, as the closing move. The line is something like:

> "We never wrote a teardown script. The pipeline applies whatever the
> repository says, and the repository now says there is no infrastructure.
> Watch."

It lands because it is the same mechanism the audience just watched build
everything, running in reverse, with nobody typing `destroy`. It is the most
honest possible demonstration that the repository — not a console, not a
runbook — is the source of truth.

**The application pipeline does not run.** `app/` is identical on `dev` and
`main`, so the path filter excludes it. Only `infrastructure/**` changed. That
is a second point worth making out loud: the two pipelines are genuinely
independent, and you can prove it in the Actions tab.

### Do not add `[skip ci]`

You may be tempted, since a reset you have already destroyed by hand produces
a no-op run. Don't:

- The no-op apply (`0 to add, 0 to change, 0 to destroy`, ~90 s) is free
  verification that state and configuration agree before you walk on stage.
- GitHub applies skip instructions only to "the workflow run(s) that would be
  triggered by the commit that contains the skip instructions". The head
  commit of this force-push is **dev's tip**, so the marker would have to live
  permanently in dev's tip message and be re-applied on every cherry-pick.

Maintaining a permanent marker to avoid a 90-second confirmation is a bad
trade.

## Two ways to tear down, both valid

**On stage — let the pipeline do it.** Force-push `dev` onto `main` and watch
the infrastructure workflow destroy 43 resources. Tested, green, 3m40s. This
is the demo beat above.

```bash
git push --force origin dev:main
```

**Off stage — destroy by hand first.** When you want the teardown finished
before you touch git, or you are tidying up after a failed run:

```bash
cd infrastructure && terraform destroy
git push --force origin dev:main        # now a no-op apply
```

### The rule that applies to both

Never rewind `main` and then try to `terraform destroy` locally. `destroy`
reads the configuration to know what to destroy; once `main` has no
`phase-*.tf`, Terraform sees an empty configuration and the VPC, NAT gateways
and load balancer are orphaned with no code describing them. Recovering means
console work.

Either destroy first, or let the pipeline destroy as part of the push. What
you must not do is rewind, *then* reach for the local CLI. `demo-reset.sh aws`
refuses to run from a checkout with no phase files for exactly this reason.

## The run itself

| Step | Watch for |
|---|---|
| Merge PR 1 | ~3 min. Two NAT gateways are the slow part |
| Merge PR 2 | ~1 min. Nothing runs yet |
| Merge PR 3 | ~5 min, including the silent ACM validation wait |
| Push an app change | The deploy workflow, then `/version` on the live URL |
| `git push --force origin dev:main` | ~4 min. The pipeline destroys 43 resources |
| `./scripts/demo-reset.sh all` | ~8 min including the seed rebuild |

## What survives a reset, deliberately

The bootstrap is never touched:

- the Terraform state bucket (holding only `demo/terraform.tfstate`)
- the two IAM roles and the OIDC trust
- the ECR repository

Keeping the bootstrap is deliberate. Tearing it down and rebuilding it every
time would mean emptying a versioned bucket by hand on every rehearsal, for no
teaching benefit — and the bootstrap is better *shown* than re-run: open it,
walk through `terraform plan`, explain why this one stack is the only thing a
human runs.

**The seed image is rebuilt, not preserved.** It used to be in the list above,
and that was wrong: on 26 November the lifecycle policy expired it. Every
pipeline deploy pushes three artifacts — the image plus two untagged buildx
attestation manifests — so four deploys blew past a `tagStatus: any, keep 10`
rule and evicted the oldest thing in the repository, which was the seed.

Two fixes, both in place:

- the policy now sweeps untagged manifests separately and counts only tagged
  images, with a cap of 20
- `demo-reset.sh seed` rebuilds and re-pushes `:seed` from the current `app/`
  on every reset, so it can neither go missing nor drift out of date

Phase 3 creates an ECS service that pulls `:seed` the moment it exists. With
no image there, the tasks never start, the circuit breaker rolls the apply
back, and it happens in front of the room. `check` fails loudly if it is
absent.

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

**Any push that removes the phase files destroys everything.** That is the
feature above, and it is also the footgun: it does not care whether you meant
it. A stray force-push of `dev` onto `main` mid-rehearsal takes the whole
stack down. There is no confirmation step, because a pipeline applying what
the repository says is the entire point.

Know which of the two teardown paths you are on before you push.

## If the destroy fails halfway

Re-run it. Terraform is safe to re-run and will pick up where it stopped. The
usual cause is the ECS service still draining; it resolves on the second
attempt. Then run `check` and believe only what it prints — not what the
previous command claimed.
