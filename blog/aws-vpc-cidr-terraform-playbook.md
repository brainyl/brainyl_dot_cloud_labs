
VPCs are the blast walls of AWS—they define isolation, control egress, and set the foundation for resilient architectures. If you understand how to plan CIDR blocks, attach the right route tables, and tighten network ACLs, you avoid painful rewrites later. This guide walks through a visual-first plan for a 10.0.0.0/22 VPC in `us-west-2`, then proves the design with Terraform.

You'll learn how to map a dual-AZ layout, tag every subnet with its job, and understand why elements like internet gateways, NAT gateways, route tables, and network ACLs show up in the diagram. The finish line is deploying the exact CIDRs from the picture using infrastructure-as-code.

### What You'll Build

You're creating a dual-AZ, two-tier VPC in `us-west-2` with the CIDRs shown below. A public ALB lives in the public subnets, while app workloads stay private and reach the internet through per-AZ NAT gateways. Route tables pin each subnet to the right next hop, and a single network ACL per subnet layer keeps traffic predictable.

| Component | Purpose | CIDR / Placement |
|-----------|---------|------------------|
| VPC | Overall network boundary with IGW and flow logs | `10.0.0.0/22` |
| Public subnets | ALBs, NAT gateways, bastion or ingress services | `10.0.0.0/24` (AZ-a), `10.0.1.0/24` (AZ-b) |
| Private subnets | App compute (EC2/ECS/EKS nodes) | `10.0.2.0/24` (AZ-a), `10.0.3.0/24` (AZ-b) |

### Prerequisites

* Terraform v1.13.4+ and AWS provider v6.x.
* AWS CLI v2 with permissions to create VPCs, subnets, IGWs, NAT gateways, ALBs, and VPC flow logs.
* An AWS account in `us-west-2` (AZ suffixes assume `us-west-2a` and `us-west-2b`).
* Estimated cost: keep the NAT gateways only while testing—they are the biggest recurring line item. Destroy the stack when you're done.
* Security: use least-privilege IAM for Terraform, avoid long-lived keys in CI (OIDC with GitHub Actions is safer), and keep secrets in SSM Parameter Store or Secrets Manager.

### Step-by-Step Playbook

#### 1) Validate the VPC CIDR visually

1. Open <a href="https://cidr.xyz/" target="_blank" rel="noreferrer">cidr.xyz</a> and enter `10.0.0.0/22`. This shows 1024 addresses—enough for public and private tiers in two AZs while leaving space for growth.
2. Toggle the subnet size preview until `/24` is highlighted so you can see how four /24s fit inside the /22. That preview maps to the subnets we'll carve below.

#### 2) Carve subnets with davidc.net

1. Head to <a href="https://www.davidc.net/sites/default/subnets/subnets.html" target="_blank" rel="noreferrer">davidc.net subnet calculator</a>.
2. Enter `10.0.0.0/22` and click **Update**.
3. Select `/24` in **Divide into smaller subnets** and note the ranges. Tag them with AZs to match the diagram:
   * Public: `10.0.0.0/24` (`us-west-2a`), `10.0.1.0/24` (`us-west-2b`)
   * Private: `10.0.2.0/24` (`us-west-2a`), `10.0.3.0/24` (`us-west-2b`)
4. Export or copy the list. This is your single source of truth for Terraform variables.

#### 3) Map the architecture to routing and security

* **Internet Gateway (IGW):** attaches to the VPC and is the default route for public subnets. Public ALBs and NAT gateways use it for egress.
* **NAT Gateways:** one per AZ keeps egress localized. Private subnets route `0.0.0.0/0` to the NAT in the same AZ so an AZ failure doesn't blackhole traffic.
* **Route tables:** public tables point to the IGW; private tables point to the per-AZ NAT gateway. Associating subnets to the right route table is what makes a subnet “public” or “private.”
* **Network ACLs (NACLs):** a single NACL per layer (public vs. private) simplifies troubleshooting. Keep them stateless but aligned with your security groups (e.g., allow ephemeral response ports for outbound traffic on private subnets).
* **Public ALB:** terminates TLS and forwards to private-tier targets. Add AWS WAF here for production.
* **Security groups:**
    * ALB SG: allow 80/443 from the internet, forward to app SG.
    * App SG: allow HTTP/S from ALB SG, egress to required services.
* **Flow logs:** ship to S3 for auditing; bucket policy should deny insecure transport.

#### 4) Deploy the VPC with Terraform (module example)

Use the community-supported <a href="https://registry.terraform.io/modules/terraform-aws-modules/vpc/aws/latest" target="_blank" rel="noreferrer">terraform-aws-modules/vpc/aws</a> to mirror the diagram exactly: one VPC, two AZs, two public /24s, and two private /24s.

```hcl
terraform {
  required_version = ">= 1.13.4"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.20.0"
    }
  }
}

provider "aws" {
  region = "us-west-2"
}

locals {
  region = "us-west-2"
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.9"

  name = "demo-vpc"
  cidr = "10.0.0.0/22"

  azs             = ["us-west-2a", "us-west-2b"]
  public_subnets  = ["10.0.0.0/24", "10.0.1.0/24"]
  private_subnets = ["10.0.2.0/24", "10.0.3.0/24"]

  enable_dns_support   = true
  enable_dns_hostnames = true

  enable_nat_gateway     = true
  single_nat_gateway     = false
  one_nat_gateway_per_az = true
  create_igw             = true

  manage_default_security_group = true
  default_security_group_ingress = []
  default_security_group_egress  = []

  enable_flow_log = true
}
```

Notes for production:

* Keep `one_nat_gateway_per_az = true` so each AZ remains independent during failure events.
* Use distinct route tables for public vs. private subnets to keep intent obvious for auditors and teammates.
* Add tags that match your security controls (e.g., `karpenter.sh/discovery` for EKS or `kubernetes.io/role/internal-elb` for LBs).

Apply it:

```bash
terraform init
terraform plan -out tfplan
terraform apply tfplan
```

#### 5) Connect services to the layout

* Attach a public ALB to the two public subnets, register targets that live in the private subnets, and terminate TLS at the ALB.
* If you later add an internal ALB, keep it in private subnets and restrict its security group to known app CIDRs.
* For observability, keep ALB access logs and VPC flow logs flowing into the CloudWatch Log Group created by the module or an S3 bucket you control.

#### 6) Validate and troubleshoot

* Use `aws ec2 describe-route-tables` to confirm default routes: public tables should target the IGW, private tables the NAT in the same AZ.
* From a private instance, `curl -v https://ifconfig.me` should succeed (egress via NAT). Confirm ALB reachability from the internet and restrict any internal endpoints to the private CIDRs.

### Cleanup

Always destroy lab infrastructure to avoid NAT gateway charges:

```bash
terraform destroy
```

### Further reading

* Internal traffic patterns: [Expose private services with VPC endpoint services](./vpc-endpoint-service-private-connectivity.md).
* Cluster add-ons: [Bootstrap EKS Auto Mode with Terraform](./eks-auto-mode-quick-bootstrap-terraform.md).
* Security layers: [Secure EKS workloads with AWS Signer and Gatekeeper](./secure-eks-workloads-aws-signer-notation-ratify-gatekeeper.md).

### Conclusion

A solid AWS VPC starts with intentional CIDR sizing. Visual planners like [cidr.xyz](https://cidr.xyz/) and [davidc.net subnet calculator](https://www.davidc.net/sites/default/subnets/subnets.html) make the address space easy to grasp—even for beginners—and Terraform ensures you deploy the same multi-AZ layout every time. This two-tier design—public ingress with NAT egress, and private compute subnets—sets you up for EKS, ECS, or VM-based workloads without rework. Destroy when done, and reuse the module whenever you need a repeatable, production-minded network foundation.
