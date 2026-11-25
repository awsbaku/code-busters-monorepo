# What this demo costs

These are the **shapes** of the bill, not quoted prices. Check the current AWS
pricing pages for `eu-central-1` before quoting a number on stage — prices
change, and a stale number said with confidence is worse than no number.

| Resource | Billing driver | Running when idle? |
|---|---|---|
| **2 NAT gateways** | Per hour each, plus per GB processed | **Yes — the largest line item** |
| Application Load Balancer | Per hour, plus capacity units | **Yes** |
| 2 Fargate tasks | Per vCPU-second and GB-second, 0.25 vCPU / 0.5 GB each | **Yes** |
| 2 Elastic IPs | Per hour while allocated | Yes, but small |
| ECR | Per GB-month stored | Small — lifecycle policy keeps 10 images |
| CloudWatch Logs | Per GB ingested and stored | Small — 7-day retention |
| Data transfer out | Per GB | Negligible for a demo |
| DynamoDB lock table | — | **None.** S3 native locking replaces it |

**The NAT gateways are the price of high availability.** Two of them, one per
Availability Zone, so losing a zone does not take the other zone's outbound
traffic with it. One NAT gateway would halve that line and introduce a
single point of failure for image pulls and log delivery. This architecture
deliberately does not make that trade — but say so out loud, because for a
genuinely short-lived demo environment, one NAT (or VPC endpoints, or tasks in
public subnets) are all defensible choices.

Everything here bills **by the hour whether anyone visits or not**. The cost of
this demo is how long you leave it up, not how much traffic it serves.

## Controls already in the code

Two tasks at the smallest Fargate size, 7-day log retention, Container
Insights disabled, an ECR lifecycle policy, no deletion protection on the load
balancer so teardown never needs a console click.

## Strongly recommended

- An **AWS Budget with an alert** at a few dollars on the sandbox account
- `terraform destroy` **the same day** — see RUNBOOK.md for the order
- Confirm the Elastic IPs are released afterwards; an unattached Elastic IP
  keeps billing
