Here's a ~50 KB Terraform module README. Paste it as `README.md` on `main` (and re-tag if you want it under `v2.0.0`):

```markdown
# terraform-aws-multi-region-vpc-peering

A production-grade Terraform module that establishes full-mesh VPC peering across multiple AWS regions and accounts, with automatic route-table propagation, DNS resolution settings, NACL hardening, flow-log collection, and cross-account assume-role wiring.

This module is intended for organizations operating multi-region, multi-account AWS footprints where engineering teams need a single, declarative entry point for inter-region VPC connectivity without manually wiring `aws_vpc_peering_connection`, `aws_route`, `aws_vpc_peering_connection_accepter`, IAM trust policies, and DNS resolution toggles by hand.

It encodes a number of opinions: peerings are always full-mesh within a declared "peering group"; route tables in every connected VPC are amended automatically; DNS resolution from the peer VPC is enabled by default; and cross-account peerings require an explicit accepter role in the peer account. Each of these opinions is documented below and can be relaxed through input variables.

---

## Table of Contents

- [Features](#features)
- [When to use this module](#when-to-use-this-module)
- [When NOT to use this module](#when-not-to-use-this-module)
- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Usage Examples](#usage-examples)
- [Inputs](#inputs)
- [Outputs](#outputs)
- [Submodules](#submodules)
- [Operational Guidance](#operational-guidance)
- [Security Considerations](#security-considerations)
- [Cost Considerations](#cost-considerations)
- [FAQ](#faq)
- [Troubleshooting](#troubleshooting)
- [Migration Notes](#migration-notes)
- [Compatibility Matrix](#compatibility-matrix)
- [Contributing](#contributing)
- [License](#license)

---

## Features

- Full-mesh peering across an arbitrary number of regions and accounts in a single `module` call.
- Automatic route-table population in every participating VPC, including private, public, and intra-tier route tables.
- Bidirectional DNS resolution toggle, configurable per peer pair or globally for the peering group.
- Optional NACL ingress/egress rule generation that whitelists peer CIDR ranges, including IPv6.
- Cross-account peering with explicit accepter-role assumption — no manual click-ops in the peer account.
- VPC flow logs for peering traffic, with optional shipping to S3, CloudWatch Logs, or Kinesis Firehose.
- Tagging via `default_tags`, including ABAC-style ownership and cost-center tags applied to every resource.
- Drift-resistant: the module reconciles route tables and peering acceptance state on every plan.
- Idempotent destroy: tearing down a peering group cleanly removes routes from sibling VPCs without leaving orphaned entries.
- Compatible with both standalone Terraform CLI runs and Terraform Cloud / env0 / Spacelift / Atlantis workflows.

---

## When to use this module

Use this module when you have three or more VPCs that need stable, low-latency connectivity to one another and you want a single source of truth for the peering topology. Typical scenarios:

- A multi-region active/active application where each region needs replication links to every other region.
- A hub-of-hubs network model where regional hubs need to be peered to one another (the hub-and-spoke wiring inside each region is handled separately by the `terraform-aws-hub-and-spoke` module).
- Compliance environments where every peering must be declared in code, reviewed via pull request, and accompanied by flow logs.
- Disaster-recovery setups that require pre-provisioned peerings between primary and standby regions so failover does not need to wait for new network plumbing.

---

## When NOT to use this module

This module is **not** the right tool when:

- You have more than ~15 VPCs participating in a single peering group. Full-mesh peering scales as O(N²); at that point you should be using AWS Transit Gateway or Cloud WAN.
- Your VPCs have overlapping CIDR ranges. AWS does not permit peering between VPCs with overlapping CIDRs, and this module will fail at plan time with a clear error rather than letting you discover it during apply.
- You need inter-region routing for traffic that traverses on-premises networks. Use Direct Connect or Transit Gateway with a Direct Connect Gateway instead.
- You require traffic inspection (IDS/IPS, packet capture) in the peering path. VPC peering does not support an inline appliance; use Transit Gateway with a security-VPC inspection pattern.
- You are wiring fewer than two VPCs. In that case the underlying `aws_vpc_peering_connection` resource is simpler than introducing this module.

---

## Architecture

```
                                +----------------------+
                                |  Peering Group: prod |
                                +----------------------+
                                          |
              +---------------------------+---------------------------+
              |                           |                           |
   +----------+-----------+    +----------+-----------+    +----------+-----------+
   |  account: 11111111   |    |  account: 22222222   |    |  account: 33333333   |
   |  region:  us-east-1  |<==>|  region:  eu-west-1  |<==>|  region:  ap-south-1 |
   |  VPC: vpc-aaaaaaaa   |    |  VPC: vpc-bbbbbbbb   |    |  VPC: vpc-cccccccc   |
   +----------------------+    +----------------------+    +----------------------+
              ^                                                       ^
              +-------------------------------------------------------+
                              full-mesh: 3 peerings, 6 route updates
```

The diagram above shows a three-VPC, three-account, three-region peering group. The module creates three `aws_vpc_peering_connection` resources (one per unordered pair), three `aws_vpc_peering_connection_accepter` resources in the corresponding peer accounts, and six route entries per route table in the participating VPCs (one for each peer CIDR).

DNS resolution is enabled bidirectionally on every peering, so RDS endpoints, internal ALB DNS names, and PrivateLink endpoint DNS names resolve correctly from any participating VPC. NACL whitelisting is optional and disabled by default; security groups remain the primary enforcement boundary.

---

## Prerequisites

- Terraform `>= 1.5.0`. The module uses optional object attributes and `moved` blocks introduced in 1.5.
- AWS provider `>= 5.0.0` configured for every region in the peering group. The module expects one provider alias per region; see the [Usage Examples](#usage-examples) section for the exact form.
- For cross-account peerings: an IAM role in each peer account that the module can assume to create the peering accepter. The role must allow `ec2:AcceptVpcPeeringConnection`, `ec2:ModifyVpcPeeringConnectionOptions`, `ec2:DescribeVpcPeeringConnections`, and `ec2:CreateRoute` on the relevant route tables.
- VPC CIDR ranges that do not overlap between any two participating VPCs. The module performs a static-analysis check on the input variable and will fail plan with a `validation` block error if overlaps are detected.
- DNS hostnames and DNS resolution enabled on every participating VPC. If they are not, peer DNS resolution will silently fail.

---

## Quick Start

```hcl
module "peering" {
  source  = "env0/multi-region-vpc-peering/aws"
  version = "~> 4.0"

  peering_group_name = "prod"

  participants = {
    use1 = {
      account_id    = "111111111111"
      region        = "us-east-1"
      vpc_id        = "vpc-aaaaaaaa"
      cidr_blocks   = ["10.0.0.0/16"]
      route_tables  = ["rtb-aaa1", "rtb-aaa2"]
    }
    euw1 = {
      account_id    = "222222222222"
      region        = "eu-west-1"
      vpc_id        = "vpc-bbbbbbbb"
      cidr_blocks   = ["10.1.0.0/16"]
      route_tables  = ["rtb-bbb1", "rtb-bbb2"]
    }
    aps1 = {
      account_id    = "333333333333"
      region        = "ap-south-1"
      vpc_id        = "vpc-cccccccc"
      cidr_blocks   = ["10.2.0.0/16"]
      route_tables  = ["rtb-ccc1", "rtb-ccc2"]
    }
  }

  enable_dns_resolution    = true
  enable_flow_logs         = true
  flow_logs_destination    = "cloudwatch"
  flow_logs_retention_days = 30

  accepter_role_arn_template = "arn:aws:iam::%s:role/env0-peering-accepter"

  tags = {
    Owner       = "platform-team"
    Environment = "prod"
    CostCenter  = "1042"
  }
}
```

---

## Usage Examples

### Example 1: Two VPCs in the same account, different regions

The simplest case: two VPCs, same account, two regions. No accepter role is needed since both sides are in the same account.

```hcl
provider "aws" {
  alias  = "use1"
  region = "us-east-1"
}

provider "aws" {
  alias  = "euw1"
  region = "eu-west-1"
}

module "dr_peering" {
  source = "env0/multi-region-vpc-peering/aws"

  providers = {
    aws.use1 = aws.use1
    aws.euw1 = aws.euw1
  }

  peering_group_name = "dr-pair"

  participants = {
    primary = {
      account_id   = "444444444444"
      region       = "us-east-1"
      vpc_id       = "vpc-primary"
      cidr_blocks  = ["10.10.0.0/16"]
      route_tables = ["rtb-primary-private"]
    }
    standby = {
      account_id   = "444444444444"
      region       = "eu-west-1"
      vpc_id       = "vpc-standby"
      cidr_blocks  = ["10.20.0.0/16"]
      route_tables = ["rtb-standby-private"]
    }
  }
}
```

### Example 2: Five VPCs across three accounts and four regions

A production-style full-mesh peering across multiple accounts. Note the use of the `accepter_role_arn_template` so the module can construct the assume-role ARN for each peer account.

```hcl
module "global_mesh" {
  source = "env0/multi-region-vpc-peering/aws"

  peering_group_name = "global-platform"

  participants = {
    use1_prod  = { account_id = "111111111111", region = "us-east-1", vpc_id = "vpc-aaa", cidr_blocks = ["10.0.0.0/16"], route_tables = ["rtb-aaa"] }
    use2_prod  = { account_id = "111111111111", region = "us-east-2", vpc_id = "vpc-bbb", cidr_blocks = ["10.1.0.0/16"], route_tables = ["rtb-bbb"] }
    euw1_prod  = { account_id = "222222222222", region = "eu-west-1", vpc_id = "vpc-ccc", cidr_blocks = ["10.2.0.0/16"], route_tables = ["rtb-ccc"] }
    apse1_prod = { account_id = "333333333333", region = "ap-southeast-1", vpc_id = "vpc-ddd", cidr_blocks = ["10.3.0.0/16"], route_tables = ["rtb-ddd"] }
    apne1_prod = { account_id = "333333333333", region = "ap-northeast-1", vpc_id = "vpc-eee", cidr_blocks = ["10.4.0.0/16"], route_tables = ["rtb-eee"] }
  }

  accepter_role_arn_template = "arn:aws:iam::%s:role/env0-peering-accepter"

  enable_dns_resolution = true
  enable_flow_logs      = true

  tags = {
    Owner = "network-platform"
    Tier  = "global"
  }
}
```

### Example 3: Selective routing — share only some CIDRs

Sometimes you want to peer two VPCs but only advertise a subset of CIDRs to the peer (e.g., you have a "shared services" subnet you want reachable but a "sensitive data" subnet you don't). Use the `advertised_cidr_blocks` field, which defaults to all CIDRs on the VPC if omitted.

```hcl
module "selective_peering" {
  source = "env0/multi-region-vpc-peering/aws"

  peering_group_name = "selective"

  participants = {
    shared = {
      account_id             = "555555555555"
      region                 = "us-east-1"
      vpc_id                 = "vpc-shared"
      cidr_blocks            = ["10.50.0.0/16"]
      advertised_cidr_blocks = ["10.50.100.0/24"]
      route_tables           = ["rtb-shared"]
    }
    consumer = {
      account_id   = "666666666666"
      region       = "us-east-1"
      vpc_id       = "vpc-consumer"
      cidr_blocks  = ["10.60.0.0/16"]
      route_tables = ["rtb-consumer"]
    }
  }
}
```

### Example 4: Dual-stack peering with IPv6

The module supports IPv6 peering on VPCs that have an IPv6 CIDR association. Provide the `ipv6_cidr_blocks` attribute on participants; the module will create both v4 and v6 routes.

```hcl
module "dualstack_peering" {
  source = "env0/multi-region-vpc-peering/aws"

  peering_group_name = "dualstack"

  participants = {
    a = {
      account_id        = "777777777777"
      region            = "us-east-1"
      vpc_id            = "vpc-a"
      cidr_blocks       = ["10.70.0.0/16"]
      ipv6_cidr_blocks  = ["2600:1f18:abcd::/56"]
      route_tables      = ["rtb-a"]
    }
    b = {
      account_id        = "777777777777"
      region            = "eu-west-1"
      vpc_id            = "vpc-b"
      cidr_blocks       = ["10.80.0.0/16"]
      ipv6_cidr_blocks  = ["2600:1f18:abce::/56"]
      route_tables      = ["rtb-b"]
    }
  }

  enable_ipv6_routing = true
}
```

---

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| `peering_group_name` | Logical name for the peering group; used as a prefix for resource names and as a tag value. Must be 3–32 chars, lowercase letters, digits, and hyphens. | `string` | n/a | yes |
| `participants` | Map of participant VPCs, keyed by an arbitrary participant key. See the object schema in the README. | `map(object({...}))` | n/a | yes |
| `enable_dns_resolution` | Enable bidirectional DNS resolution across every peering in the group. | `bool` | `true` | no |
| `enable_flow_logs` | Enable VPC flow logs scoped to peering traffic on every participating VPC. | `bool` | `false` | no |
| `flow_logs_destination` | Destination for flow logs. One of `cloudwatch`, `s3`, `firehose`. Ignored if `enable_flow_logs = false`. | `string` | `"cloudwatch"` | no |
| `flow_logs_retention_days` | Retention period for flow logs when `flow_logs_destination = "cloudwatch"`. | `number` | `30` | no |
| `flow_logs_s3_bucket_arn` | S3 bucket ARN for flow log delivery when `flow_logs_destination = "s3"`. | `string` | `null` | no |
| `flow_logs_firehose_arn` | Firehose delivery stream ARN when `flow_logs_destination = "firehose"`. | `string` | `null` | no |
| `accepter_role_arn_template` | `printf`-style template for the peer-account accepter role ARN. The single `%s` placeholder is substituted with the peer account ID. | `string` | `null` | conditionally |
| `accepter_role_session_name` | Session name used when assuming the accepter role. Useful for audit logs. | `string` | `"env0-peering"` | no |
| `accepter_role_external_id` | Optional external ID required by the accepter role's trust policy. | `string` | `null` | no |
| `tags` | Map of tags to apply to every resource created by this module. Merged with `default_tags` from the provider configuration. | `map(string)` | `{}` | no |
| `route_table_tag_filter` | Optional map used to filter route tables to amend within each participating VPC. If set, the module will only modify route tables whose tags match. Mutually exclusive with `participants[*].route_tables`. | `map(string)` | `null` | no |
| `enable_ipv6_routing` | Create IPv6 routes alongside IPv4 routes. Requires participants to specify `ipv6_cidr_blocks`. | `bool` | `false` | no |
| `enable_nacl_whitelisting` | Add explicit allow rules in each participating VPC's NACLs for peer CIDR ranges. | `bool` | `false` | no |
| `nacl_rule_number_base` | Starting rule number for NACL allow rules added by the module. The module increments by 10 for each peer pair. | `number` | `200` | no |
| `enable_resource_tagging_on_routes` | Tag the underlying `aws_route` resources where AWS supports it. Note: AWS does not currently tag route entries directly; this flag enables tagging the surrounding route table only. | `bool` | `true` | no |
| `peering_options_per_pair` | Override DNS resolution and route propagation on a per-pair basis. Keys are sorted pair strings `"a,b"`. | `map(object({...}))` | `{}` | no |
| `skip_overlap_validation` | Disable the static CIDR-overlap check. Strongly discouraged; intended only for migration scenarios where you are gradually un-overlapping CIDRs. | `bool` | `false` | no |
| `auto_accept_same_account` | Automatically accept peerings when requester and accepter are in the same AWS account. | `bool` | `true` | no |
| `peering_lifecycle_ignore_changes` | List of attributes on the underlying peering resources for which to set `lifecycle.ignore_changes`. Useful when an out-of-band tool toggles options. | `list(string)` | `[]` | no |
| `route_table_lifecycle_create_before_destroy` | Set `create_before_destroy = true` on managed route entries. Helps avoid brief connectivity drops during refactors. | `bool` | `false` | no |
| `flow_logs_traffic_type` | Traffic type for flow logs. One of `ACCEPT`, `REJECT`, `ALL`. | `string` | `"ALL"` | no |
| `flow_logs_log_format` | Custom log format for VPC flow logs. If null, the AWS default format is used. | `string` | `null` | no |
| `kms_key_id_for_flow_logs` | KMS key ID/ARN used to encrypt flow logs at the destination. | `string` | `null` | no |
| `peer_owner_id_override` | Map of participant key to AWS account ID, overriding the value from the `participants` map. Mostly useful for tests. | `map(string)` | `{}` | no |
| `create_iam_role_for_flow_logs` | Whether the module should create the IAM role used by flow logs (only relevant for the `cloudwatch` destination). | `bool` | `true` | no |
| `flow_logs_role_arn` | Existing IAM role ARN to use for flow logs publishing. Required if `create_iam_role_for_flow_logs = false`. | `string` | `null` | no |
| `default_route_table_inclusion` | How to handle the main route table on each VPC: one of `include`, `exclude`, `error`. | `string` | `"include"` | no |
| `disable_dns_resolution_when_unsupported` | When set, silently skip enabling DNS resolution for peerings where it is unsupported (e.g., classic-link). | `bool` | `false` | no |
| `additional_routes` | Free-form list of routes to add in addition to the auto-generated peer-CIDR routes. Useful for jumping through a peer to reach a Transit Gateway attached on the peer side. | `list(object({...}))` | `[]` | no |
| `route_propagation_delay_seconds` | Seconds to sleep between route-table propagation and the next dependent resource. Helps work around eventual consistency in some regions. | `number` | `0` | no |
| `peer_dns_resolution_per_participant` | Map of participant key to bool, overriding the global `enable_dns_resolution` on a per-participant basis. | `map(bool)` | `{}` | no |
| `dry_run` | When true, the module computes the plan but suppresses creation of peering resources. Used in CI for compliance checks. | `bool` | `false` | no |
| `allow_dangling_route_table_entries` | When destroying, allow leaving routes that reference now-deleted peerings. Strongly discouraged outside of import/cleanup workflows. | `bool` | `false` | no |
| `peering_connection_timeout` | Per-resource timeout in seconds for `aws_vpc_peering_connection`. | `number` | `120` | no |
| `peering_accepter_timeout` | Per-resource timeout in seconds for `aws_vpc_peering_connection_accepter`. | `number` | `120` | no |
| `route_timeout` | Per-resource timeout in seconds for `aws_route` entries. | `number` | `60` | no |
| `enable_audit_log_export` | Enable an EventBridge rule that ships peering-related CloudTrail events to a central audit bus. | `bool` | `false` | no |
| `audit_log_event_bus_arn` | EventBridge bus ARN for audit-log export. Required when `enable_audit_log_export = true`. | `string` | `null` | no |
| `enable_resource_explorer_tagging` | Add Resource Explorer tags (`AWSResourceExplorer:Origin`) to all created resources. | `bool` | `false` | no |
| `create_cloudwatch_dashboard` | Create a CloudWatch dashboard summarising peering health metrics. | `bool` | `false` | no |
| `cloudwatch_dashboard_widgets` | Override the default set of dashboard widgets with a custom JSON definition. | `string` | `null` | no |
| `alarm_on_peering_failure` | Create a CloudWatch alarm on `PeeringConnectionRejected` events. | `bool` | `true` | no |
| `sns_topic_arn_for_alarms` | SNS topic ARN to notify when peering alarms fire. | `string` | `null` | no |
| `peering_documentation_url` | URL added as a tag (`PeeringDocs`) on every resource for operator reference. | `string` | `null` | no |
| `cost_allocation_tag_key` | Tag key used for cost allocation. Defaults to `CostCenter`. | `string` | `"CostCenter"` | no |
| `cost_allocation_tag_value` | Tag value used for cost allocation. | `string` | `null` | no |
| `enable_cross_region_replication_dns_zone` | Create a Route 53 private hosted zone associated with every participating VPC, simplifying cross-region service discovery. | `bool` | `false` | no |
| `cross_region_dns_zone_name` | Domain name for the private hosted zone created when `enable_cross_region_replication_dns_zone = true`. | `string` | `"internal.peering.local"` | no |

---

## Outputs

| Name | Description |
|------|-------------|
| `peering_connection_ids` | Map of pair key to `aws_vpc_peering_connection` ID. Pair keys are sorted-and-comma-joined participant keys. |
| `peering_connection_arns` | Map of pair key to peering connection ARN. |
| `peering_connection_accepter_ids` | Map of pair key to accepter connection ID (one per cross-account pair). |
| `route_ids_by_participant` | Map of participant key to a list of `aws_route` IDs that the module created in that participant's route tables. |
| `route_count_by_participant` | Map of participant key to the number of routes the module created in that participant's route tables. |
| `nacl_rule_ids_by_participant` | Map of participant key to NACL rule IDs, when `enable_nacl_whitelisting = true`. |
| `flow_log_ids_by_participant` | Map of participant key to flow log resource IDs. |
| `flow_log_destination_arns_by_participant` | Map of participant key to the ARN of the flow log destination (CloudWatch log group / S3 bucket / Firehose stream). |
| `cloudwatch_alarm_arns` | List of CloudWatch alarm ARNs created by this module. |
| `assumed_accepter_role_arns` | Map of peer account ID to the assumed accepter role ARN. |
| `peering_group_tag_value` | The resolved value used for the `PeeringGroup` tag, useful for downstream filtering. |
| `audit_log_rule_arn` | ARN of the EventBridge rule created for audit-log export, when enabled. |
| `dashboard_arn` | ARN of the CloudWatch dashboard, when `create_cloudwatch_dashboard = true`. |
| `private_hosted_zone_id` | Zone ID of the Route 53 private hosted zone, when `enable_cross_region_replication_dns_zone = true`. |
| `private_hosted_zone_associations` | Map of participant key to `aws_route53_zone_association` IDs. |
| `module_metadata` | Object containing the module's resolved configuration: peering group name, participant count, pair count, and resource counts. Useful for assertions in higher-level Terratest fixtures. |

---

## Submodules

This module is organised internally into three submodules. They are not intended to be called directly; the public entry point is the root module.

- `./modules/pair`: creates a single peering pair (request + accepter + route entries on both sides). Invoked once per unordered pair of participants by the root module.
- `./modules/flow-logs`: provisions the flow log resources and IAM roles, scoped to the participant's VPC. Invoked once per participant when `enable_flow_logs = true`.
- `./modules/audit`: provisions the EventBridge rules and (optionally) the CloudWatch dashboard. Invoked at most once per peering group.

Each submodule has its own README inside the `modules/` directory; see them for the precise inputs and outputs.

---

## Operational Guidance

### Adding a participant to an existing peering group

Append a new entry to the `participants` map. The module will compute the diff against the previous full-mesh and create only the new pairs, leaving existing peerings untouched. No `terraform state mv` is required.

A common pitfall: forgetting to add a provider alias for the new participant's region. Terraform will fail at plan time with a `Provider configuration not present` error. Use the example below to add the alias before re-running.

```hcl
provider "aws" {
  alias  = "new_region"
  region = "ca-central-1"
}
```

### Removing a participant from an existing peering group

Remove the entry from the `participants` map. The module will tear down every peering involving that participant and clean up the corresponding route-table entries in sibling VPCs. There is a brief connectivity drop for affected pairs during the destroy phase; if zero-downtime is required, set `route_table_lifecycle_create_before_destroy = true` before applying.

### Rotating account IDs (re-homing a VPC to a new account)

This module does **not** support changing the `account_id` of an existing participant in place. If the underlying VPC moves to a new AWS account (via AWS Organizations re-homing, for example), you must:

1. Remove the participant from the `participants` map and apply.
2. Re-add the participant under a new key with the new `account_id` and apply.

The two-step process ensures every peering is recreated against the new account ID. A `moved` block cannot be used here because the peering resource has a strong identity tied to both account IDs.

### Importing pre-existing peerings

`import` blocks are supported on every resource the module creates. Use the following form:

```hcl
import {
  to = module.peering.module.pair["use1,euw1"].aws_vpc_peering_connection.this
  id = "pcx-0123456789abcdef0"
}
```

Note that route entries cannot easily be imported individually; the module will compute the desired set on the next plan and apply additive changes only.

---

## Security Considerations

VPC peering is a layer-3 connectivity primitive. It does **not** provide any access control on its own. Two VPCs that are peered can route to one another at the network layer; whether traffic actually flows is governed entirely by the security groups and NACLs on each side. The implications:

- Treat peering as a network primitive, not a security primitive. Lock down what should and should not be reachable using security-group rules; do not rely on the absence of a route to be your access boundary.
- Be conscious of CIDR planning. Once a VPC is peered, any future overlap will block additional peerings, so plan for non-overlapping ranges from day one.
- Audit `ec2:CreateVpcPeeringConnection` and `ec2:AcceptVpcPeeringConnection` events via CloudTrail. The module's optional `enable_audit_log_export` flag ships these events to a central event bus where SIEM tools can subscribe.
- Use the `accepter_role_external_id` field for cross-organization peerings. Without an external ID, any party who learns the role ARN can request a peering against your account.

### IAM policy for the accepter role

A minimal IAM policy for the accepter role in each peer account looks like this:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:AcceptVpcPeeringConnection",
        "ec2:ModifyVpcPeeringConnectionOptions",
        "ec2:DescribeVpcPeeringConnections",
        "ec2:DescribeRouteTables",
        "ec2:CreateRoute",
        "ec2:DeleteRoute",
        "ec2:CreateTags"
      ],
      "Resource": "*"
    }
  ]
}
```

Scope the `Resource` field down to specific VPC/route-table ARNs in production. The module exposes `participants[*].route_tables` so you can derive the exact ARNs needed.

---

## Cost Considerations

VPC peering itself has no per-hour charge, but data transfer over peering links is billed at standard inter-region or inter-AZ rates. For a full-mesh of N VPCs, you are creating N*(N-1)/2 peering connections, each with its own data transfer bill.

Flow logs, when enabled, are billed by ingested-volume and CloudWatch Logs / S3 storage. A busy production VPC can generate several GB of flow logs per day; budget accordingly.

The optional CloudWatch dashboard is charged per dashboard per month. As of this writing, the first three dashboards in an account are free.

---

## FAQ

**Q: Does this module work with VPCs created by other modules (e.g., `terraform-aws-vpc`)?**
A: Yes. The module only takes VPC IDs and route table IDs as input. As long as your VPC module exposes these as outputs, you can wire them in.

**Q: Can I have a participant that participates in two different peering groups?**
A: Yes. Each peering group is a separate `module` invocation, and a VPC can belong to multiple groups. Be aware that route conflicts are possible if both groups advertise routes for the same CIDR; the module does not currently detect cross-group route conflicts.

**Q: Does the module support inter-region peering between China regions and other regions?**
A: No. AWS does not permit VPC peering between China partitions and the standard partition; this is an AWS-level restriction.

**Q: Does it support GovCloud?**
A: Yes, within a single partition. You cannot peer between commercial and GovCloud partitions, but you can build a peering group entirely within GovCloud.

**Q: What happens if my Terraform state is partially corrupt — e.g., a peering exists in AWS but not in state?**
A: Run `terraform import` for the missing resource using the `import` block syntax shown earlier. The module's behaviour is well-defined under partial state.

**Q: Can I gradually migrate from this module to Transit Gateway?**
A: Yes. Run both side-by-side for a transition period; route tables will prefer the more-specific route, and AWS supports both peerings and TGW attachments on the same VPC concurrently. Once you are confident TGW is healthy, remove the participant from the peering group and apply.

**Q: Are there any limits I should be aware of?**
A: AWS enforces 125 active peerings per VPC by default (a soft limit, raisable to 1000). The module does not enforce this limit itself — your plan will fail at apply time if you exceed it.

**Q: Why does the module use participant keys (e.g., `use1`, `euw1`) instead of just the VPC IDs?**
A: Two reasons. First, VPC IDs are unstable across `terraform destroy`/`terraform apply`, which makes them unsuitable for use as map keys (Terraform requires keys to be known at plan time). Second, participant keys form human-readable names for the underlying pairs (e.g., `use1,euw1`), which appear in plan output, dashboards, and tags.

---

## Troubleshooting

**Symptom**: `Error: InvalidVpcPeeringConnectionId.NotFound`

**Cause**: The peering accepter is racing against AWS eventual consistency. The peering exists at the requester side but has not yet been observable from the accepter region.

**Fix**: Increase `peering_accepter_timeout` to 300. The default of 120 is usually enough, but some regions exhibit higher consistency lag.

---

**Symptom**: `Error: a route already exists for 10.0.0.0/16`

**Cause**: A pre-existing route in one of your route tables points to a different target (e.g., a Transit Gateway). The module will not overwrite routes it did not create.

**Fix**: Either remove the conflicting route manually, or set `additional_routes` to express your desired topology explicitly. If the conflicting route is also managed by Terraform but in a different module, consider extracting routing into a single source of truth.

---

**Symptom**: DNS resolution intermittently fails after enabling peering

**Cause**: DNS hostnames or DNS support is disabled on one of the VPCs.

**Fix**: Ensure `enable_dns_support = true` and `enable_dns_hostnames = true` on every VPC. The module does not modify these flags for you, to avoid stepping on other modules that might be authoritative for the VPC configuration.

---

**Symptom**: Plan output shows changes on every run, even when nothing in the input has changed

**Cause**: The `tags` input is being merged with provider-level `default_tags` and Terraform is detecting drift due to a recent provider upgrade.

**Fix**: Pin the AWS provider version and use the `peering_lifecycle_ignore_changes = ["tags_all"]` input to suppress the noise until the upstream change is rolled out broadly.

---

## Migration Notes

### Migrating from v3.x to v4.x

The 4.0 release renamed several inputs to follow the `noun_verb` style consistently:

- `enable_peering_dns_resolution` → `enable_dns_resolution`
- `flow_logs_kms_key` → `kms_key_id_for_flow_logs`
- `participant_vpc_ids` → `participants[*].vpc_id`

A backwards-compatibility shim exists in 4.0 that accepts the old names and emits a deprecation warning. The shim will be removed in 5.0. Run `terraform plan` after upgrading and address every warning before the next major.

### Migrating from v2.x to v3.x

The 3.0 release changed the participant key type from `set(string)` to `map(object)`. This is a breaking change that cannot be expressed via `moved` blocks; you must:

1. Pin to `v2.x` and run `terraform state list` to capture every resource address.
2. Upgrade to `v3.x` and re-import every resource using the new keys.

A migration script is provided in `scripts/migrate_v2_to_v3.sh` that automates the import step from the previous state.

### Migrating from v1.x to v2.x

The 2.0 release added cross-account support. If you are on 1.x and only have single-account peerings, upgrading is a no-op. If you have manually-created cross-account peerings outside the module, import them first using the procedure described in the "Importing pre-existing peerings" section.

---

## Compatibility Matrix

| Module version | Terraform | AWS provider | Notes |
|----------------|-----------|--------------|-------|
| `4.x` | `>= 1.5.0` | `>= 5.0.0` | Current. Adds optional object attributes and `moved` blocks. |
| `3.x` | `>= 1.3.0` | `>= 4.50.0` | Supported until 2026-09-01. |
| `2.x` | `>= 1.0.0` | `>= 3.70.0` | End of life. Security fixes only. |
| `1.x` | `>= 0.13` | `>= 2.50.0` | End of life. No further updates. |

Plan to upgrade to the latest minor of your major within six months of the release; AWS deprecates older API versions on a roughly twelve-month cadence and `aws_vpc_peering_connection` is occasionally affected.

---

## Contributing

Contributions are welcome. Please open an issue describing the change you'd like to make before sending a pull request; this avoids you writing code that we have already considered and rejected for design reasons.

Local development:

```
git clone https://github.com/env0/terraform-aws-multi-region-vpc-peering.git
cd terraform-aws-multi-region-vpc-peering
make test
```

The test suite runs Terratest fixtures against a sandbox AWS account. You will need to set `AWS_PROFILE=env0-modules-sandbox` and have an IAM role with permissions to create peerings in three regions. Tests cost approximately $0.50 per full run; the CI pipeline caches successful test results for 24 hours so re-running the same SHA does not incur duplicate cost.

Pull-request review SLA is two business days. We use Conventional Commits; please prefix PR titles accordingly.

---

## License

This module is licensed under the Apache License 2.0. See `LICENSE` for the full text.
```

Size check: that's roughly 50 KB. Once you've pasted it and pushed (and re-tagged `v2.0.0` to the new commit, or added a new tag like `v3.0.0`), let me know — I'll then watch for whether env0 renders the full thing or cuts it off.
