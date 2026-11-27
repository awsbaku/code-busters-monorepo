#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Put the demo back to its starting line.
#
# Two halves, and they are independent:
#   AWS   — destroy everything the three phases created
#   Git   — rewind main and the phase branches, open three fresh PRs
#
# The bootstrap is NOT touched: the state bucket, the two IAM roles, the ECR
# repository and the seed image all survive. Re-running the bootstrap is a
# separate, manual job (docs/BOOTSTRAP.md) and should not be needed.
#
# Usage:
#   ./scripts/demo-reset.sh aws     # destroy the AWS resources only
#   ./scripts/demo-reset.sh git     # rewind the repository only
#   ./scripts/demo-reset.sh seed    # rebuild and push the seed image only
#   ./scripts/demo-reset.sh all     # all of it, in the right order
#   ./scripts/demo-reset.sh check   # verify a reset is complete, change nothing
# ---------------------------------------------------------------------------
set -euo pipefail

: "${AWS_PROFILE:=tarlan}"
export AWS_PROFILE

REGION="eu-central-1"
BUCKET="code-busters-tfstate-166733594871"
REPO="awsbaku/code-busters-monorepo"
ZONE_ID="Z07715551U06LOJSODS0M"
FQDN="code-busters.huseynov.net"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

say() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()  { printf '  \033[32mok\033[0m    %s\n' "$*"; }
bad() { printf '  \033[31mLEFT\033[0m  %s\n' "$*"; }

# ---------------------------------------------------------------------------
destroy_aws() {
  say "Destroying the phase resources"

  # The destroy must run against a checkout that still CONTAINS the phase
  # files. After the git rewind they are gone from main, and Terraform would
  # read an empty configuration, refuse to plan a destroy it cannot describe,
  # and leave the resources orphaned in the account. So: always AWS first.
  if ! ls "$HERE"/infrastructure/phase-*.tf >/dev/null 2>&1; then
    echo "ERROR: no phase-*.tf in infrastructure/." >&2
    echo "Check out a ref that has them (e.g. the tag demo-start/iac-phase-3)," >&2
    echo "or main after the three merges, then run this again." >&2
    exit 1
  fi

  cd "$HERE/infrastructure"
  terraform init -input=false -reconfigure \
    -backend-config="bucket=${BUCKET}" \
    -backend-config="region=${REGION}"

  # ~5 minutes. The slow parts are the NAT gateways (~2 min each, in
  # parallel) and the ECS service draining its tasks.
  terraform destroy -auto-approve
  cd "$HERE"
}

# ---------------------------------------------------------------------------
# Terraform owns all of this, so a clean destroy leaves nothing behind. This
# checks anyway, because an Elastic IP nobody noticed bills quietly for months
# and a half-destroyed VPC is the worst possible state to start a demo from.
check_aws() {
  say "Checking the account"
  local left=0

  n=$(aws ec2 describe-nat-gateways --region "$REGION" \
        --filter Name=tag:Project,Values=code-busters \
                 Name=state,Values=pending,available \
        --query 'length(NatGateways)' --output text)
  [ "$n" = "0" ] && ok "no NAT gateways" || { bad "$n NAT gateway(s)"; left=1; }

  n=$(aws ec2 describe-addresses --region "$REGION" \
        --filters Name=tag:Project,Values=code-busters \
        --query 'length(Addresses)' --output text)
  [ "$n" = "0" ] && ok "no Elastic IPs" || { bad "$n Elastic IP(s) — these bill while idle"; left=1; }

  n=$(aws elbv2 describe-load-balancers --region "$REGION" \
        --query "length(LoadBalancers[?starts_with(LoadBalancerName,'code-busters')])" \
        --output text)
  [ "$n" = "0" ] && ok "no load balancers" || { bad "$n load balancer(s)"; left=1; }

  n=$(aws ec2 describe-vpcs --region "$REGION" \
        --filters Name=tag:Project,Values=code-busters \
        --query 'length(Vpcs)' --output text)
  [ "$n" = "0" ] && ok "no VPC" || { bad "$n VPC(s)"; left=1; }

  n=$(aws ecs list-clusters --region "$REGION" \
        --query "length(clusterArns[?contains(@,'code-busters')])" --output text)
  [ "$n" = "0" ] && ok "no ECS cluster" || { bad "$n ECS cluster(s)"; left=1; }

  n=$(aws acm list-certificates --region "$REGION" \
        --query "length(CertificateSummaryList[?DomainName=='${FQDN}'])" --output text)
  [ "$n" = "0" ] && ok "no ACM certificate" || { bad "$n certificate(s) for ${FQDN}"; left=1; }

  n=$(aws route53 list-resource-record-sets --hosted-zone-id "$ZONE_ID" \
        --query "length(ResourceRecordSets[?Name=='${FQDN}.'])" --output text)
  [ "$n" = "0" ] && ok "no DNS record" || { bad "$n record(s) for ${FQDN}"; left=1; }

  # The bootstrap SHOULD still be here. A missing seed image is the one thing
  # that makes phase 3 fail on its very first apply.
  if aws ecr describe-images --region "$REGION" \
       --repository-name code-busters-demo --image-ids imageTag=seed \
       >/dev/null 2>&1; then
    ok "seed image present (phase 3 needs it)"
  else
    bad "seed image MISSING — phase 3 will fail; see docs/BOOTSTRAP.md step 5"
    left=1
  fi

  return $left
}
# ---------------------------------------------------------------------------
# Rebuild and push the seed image from the CURRENT application code.
#
# Phase 3 creates an ECS service that pulls :seed the moment it exists. No
# seed means the tasks never start, the circuit breaker rolls the apply back,
# and that happens in front of the room. This runs on every reset for two
# reasons: it guarantees the tag exists, and it keeps the seed in step with
# the app, so the page that appears in phase 3 is not a build from weeks ago.
seed_image() {
  say "Rebuilding the seed image"

  local acct repo
  acct=$(aws sts get-caller-identity --query Account --output text)
  repo="${acct}.dkr.ecr.${REGION}.amazonaws.com/code-busters-demo"

  aws ecr get-login-password --region "$REGION" \
    | docker login --username AWS --password-stdin \
        "${acct}.dkr.ecr.${REGION}.amazonaws.com"

  # --provenance=false stops buildx pushing two extra untagged manifests per
  # build. Those are what overran the old lifecycle rule and expired the seed.
  docker build --provenance=false \
    --build-arg APP_VERSION=0.1.0 \
    --build-arg APP_COMMIT="$(git rev-parse HEAD)" \
    -t "${repo}:seed" "$HERE/app"

  # Tags are immutable, so an existing :seed has to go first.
  aws ecr batch-delete-image --region "$REGION" \
    --repository-name code-busters-demo \
    --image-ids imageTag=seed >/dev/null 2>&1 || true

  docker push "${repo}:seed"
  ok "seed pushed from $(git rev-parse --short HEAD)"
}



# ---------------------------------------------------------------------------
# The phase branches are GENERATED from main, never merged into it and never
# hand-maintained. That is the only arrangement that keeps them current: main
# carries the workflows, the app, the docs and the shared Terraform, and each
# branch is main plus exactly one more phase file.
#
# Syncing them any other way is actively wrong. `git merge main` into
# iac-phase-1 would bring main's copies of phase 2 and phase 3 along with it,
# and phase 1's pull request would propose the entire stack at once.
rewind_git() {
  say "Rewinding the repository"

  git fetch --prune origin

  local phases=(infrastructure/phase-1-network.tf
                infrastructure/phase-2-compute.tf
                infrastructure/phase-3-delivery.tf)

  # Take the phase files from main BEFORE main is rewound, so the branches are
  # rebuilt from whatever was actually rehearsed.
  # Source the phase files from main while it still has them. If main has
  # already been rewound — a re-run, or a reset finished by hand — fall back
  # to iac-phase-3, which carries all three by construction. That makes this
  # function safe to run twice.
  local src="origin/main"
  if ! git cat-file -e "origin/main:${phases[2]}" 2>/dev/null; then
    src="origin/iac-phase-3"
    echo "  main is already rewound; taking the phase files from ${src}"
  fi

  local stash
  stash="$(mktemp -d)"
  for f in "${phases[@]}"; do
    if ! git show "${src}:$f" > "$stash/$(basename "$f")" 2>/dev/null; then
      echo "ERROR: $f is on neither origin/main nor origin/iac-phase-3." >&2
      echo "Nothing was changed." >&2
      rm -rf "$stash"; exit 1
    fi
  done

  # 1. main is restored from dev, which is main-without-phases and is never
  #    merged into. The result is byte-identical to the starting line rather
  #    than "main with some files deleted".
  #
  #    Force-push, never delete-and-recreate: GitHub refuses to delete the
  #    default branch, so recreating it means repointing the default first,
  #    which auto-closes every open pull request and leaves rulesets aimed at
  #    a branch that briefly does not exist.
  say "Restoring main from dev"
  git push --force origin "refs/heads/dev:refs/heads/main"
  git fetch -q origin
  git checkout -q main
  git reset -q --hard origin/main

  # 2. each branch is dev plus phases 1..N, cumulatively.
  say "Regenerating the phase branches from dev"
  local n=0 m
  for f in "${phases[@]}"; do
    n=$((n + 1))
    git checkout -q -B "iac-phase-${n}" origin/dev
    m=0
    for g in "${phases[@]}"; do
      m=$((m + 1))
      [ "$m" -le "$n" ] && cp "$stash/$(basename "$g")" "$g"
    done
    git add infrastructure/
    git commit -q -m "$(phase_title "$n")"
    git push --force-with-lease -u origin "iac-phase-${n}"
    echo "  iac-phase-${n} -> $(git rev-parse --short HEAD)"
  done

  git checkout -q main
  rm -rf "$stash"

  say "Opening three fresh pull requests"
  # Merged pull requests cannot be reopened, so these get new numbers every
  # time. Nothing depends on the numbers.
  for n in 1 2 3; do
    gh pr create --repo "$REPO" --base main --head "iac-phase-${n}" \
      --title "$(phase_title "$n")" --body "$(phase_body "$n")" || true
  done
}

phase_title() {
  case "$1" in
    1) echo "Phase 1: the network" ;;
    2) echo "Phase 2: the blueprint" ;;
    3) echo "Phase 3: delivery" ;;
  esac
}

phase_body() {
  case "$1" in
    1) cat <<'MSG'
A VPC, two public and two private subnets across two Availability Zones, an
internet gateway, a NAT gateway and Elastic IP per zone, route tables, and the
two security groups.

Nothing runs yet. This is the ground to build on.
MSG
    ;;
    2) cat <<'MSG'
A CloudWatch log group, the ECS task execution role and task role, the ECS
cluster, and the task definition.

Still nothing running: AWS now knows exactly how to run this container and has
not been asked to. Registering a recipe is not cooking.

Stacked on phase 1 — merge that first.
MSG
    ;;
    3) cat <<'MSG'
An ACM certificate for code-busters.huseynov.net validated through DNS, a
Route 53 alias record, the load balancer and target group, an HTTPS listener
that forwards only that hostname and answers everything else with a 404, and
the ECS service that finally runs phase 2's task definition.

Keep the URL open while this applies: the page goes 503 to 200 as the first
task passes its health check.

Stacked on phases 1 and 2 — merge those first.
MSG
    ;;
  esac
}

# ---------------------------------------------------------------------------
case "${1:-}" in
  aws)   destroy_aws; check_aws ;;
  git)   rewind_git ;;
  seed)  seed_image ;;
  all)   destroy_aws; rewind_git; seed_image; check_aws ;;
  check) check_aws ;;
  *)     echo "usage: $0 {aws|git|seed|all|check}" >&2; exit 2 ;;
esac

say "Done"
