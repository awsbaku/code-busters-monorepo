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
#   ./scripts/demo-reset.sh all     # both, AWS first
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
rewind_git() {
  say "Rewinding the repository"

  git fetch --tags --force origin

  # Force-push is the point of this function, so be loud about what it rewrites.
  for b in main iac-phase-1 iac-phase-2 iac-phase-3; do
    git push --force origin "refs/tags/demo-start/${b}:refs/heads/${b}"
    echo "  ${b} -> $(git rev-parse --short "refs/tags/demo-start/${b}")"
  done

  git checkout -q main
  git reset -q --hard "refs/tags/demo-start/main"
  for b in iac-phase-1 iac-phase-2 iac-phase-3; do
    git branch -q -f "$b" "refs/tags/demo-start/${b}"
  done

  say "Opening three fresh pull requests"
  # Merged pull requests cannot be reopened, so these get new numbers every
  # rehearsal. Nothing depends on the numbers.
  gh pr create --repo "$REPO" --base main --head iac-phase-1 \
    --title "Phase 1: the network" \
    --body "VPC, two public and two private subnets across two Availability Zones, an internet gateway, a NAT gateway and Elastic IP per zone, route tables, and the two security groups." || true
  gh pr create --repo "$REPO" --base main --head iac-phase-2 \
    --title "Phase 2: the blueprint" \
    --body "CloudWatch log group, ECS task execution role and task role, the ECS cluster, and the task definition. Nothing runs yet — registering a recipe is not cooking.

Stacked on phase 1: merge #1 first." || true
  gh pr create --repo "$REPO" --base main --head iac-phase-3 \
    --title "Phase 3: delivery" \
    --body "ACM certificate for code-busters.huseynov.net validated through DNS, a Route 53 alias record, the load balancer and target group, an HTTPS listener that forwards only that hostname and 404s everything else, and the ECS service.

Stacked on phases 1 and 2: merge those first." || true
}

# ---------------------------------------------------------------------------
case "${1:-}" in
  aws)   destroy_aws; check_aws ;;
  git)   rewind_git ;;
  all)   destroy_aws; check_aws; rewind_git ;;
  check) check_aws ;;
  *)     echo "usage: $0 {aws|git|all|check}" >&2; exit 2 ;;
esac

say "Done"
