# AWS Networking & Private Infrastructure — Five Practical Labs

**Build with Brainyl** · [YouTube channel](https://www.youtube.com/@buildwithbrainyl) · [All hands-on labs](./README.md)

A guided learning path through five existing AWS live build sessions. These are practical demonstrations, not a CC​​P exam course. Watch in this order to progress from IP planning to working AWS networks, private connectivity, isolated workloads, and reusable machine images.

## Watch in order

| # | Lesson / watch now | What you'll build | GitHub resources |
|---|---|---|---|
| **1** | [AWS VPC IPAM — CIDR Planning, Pools and Subnets](https://youtu.be/Ge39TttDMFg) | Design IP space across regions and environments; configure IPAM allocations and subnets | **Console walkthrough**; see the chapter markers in the YouTube description |
| **2** | [Build an AWS VPC with IPAM and Regional NAT](https://youtu.be/ea5BtPdpohY) | Extend the IPAM design into a multi-AZ VPC, configure public/private routing, then validate with Elastic Beanstalk | **Console walkthrough**; no corresponding Terraform source for this specific recording |
| **3** | [AWS PrivateLink — Connect Two VPCs Without Peering](https://youtu.be/IxIB_GeWqsk) | Expose a service from one VPC privately through an NLB endpoint service and access it from a client VPC | [Service and client Terraform](./vpc_endpoint/) · [Written lab](./blog/vpc-endpoint-service-private-connectivity.md) |
| **4** | [Private AWS VPC — No Internet, No NAT](https://youtu.be/hHRXGJZH3mY) | Run a private EC2-hosted FastAPI container, access ECR and S3 via endpoints, and connect using SSM | [Black-box Terraform and FastAPI](./blackbox/) |
| **5** | [Build a Custom AMI with EC2 Image Builder](https://youtu.be/O0uGlDy5OsA) | Automate a reusable Docker-ready machine image, including a failed build, troubleshooting, and validation | **Console walkthrough**; Image Builder recipe/component configuration is shown in the video |

## Suggested path

Start with **1 → 2**. Lesson 2 continues the same IPAM environment, so those two are best watched together.

Continue to **3** for private service access **between VPCs** with AWS PrivateLink. Lesson **4** explores a different—but related—pattern: private access **from an isolated VPC to AWS services** such as SSM, ECR and S3. It uses a temporary public EC2 instance to prepare its initial AMI, while the later application workload remains private.

Finish with **5**. This revisits the manual AMI preparation in lesson 4 and replaces that step with a repeatable Image Builder pipeline. Lesson 5 is useful on its own, too, and can be watched before lesson 4 if building the image ahead of time is your preference.

### Key demos worth jumping to

- [IPAM allocates private subnet CIDRs without manual overlap — 42:40](https://youtu.be/Ge39TttDMFg?t=2560)
- [VPC routing troubleshooting and fixing a 502 — 42:30](https://youtu.be/ea5BtPdpohY?t=2550)
- [Test private cross-VPC HTTP over PrivateLink — 1:22:25](https://youtu.be/IxIB_GeWqsk?t=4945)
- [Run FastAPI and query S3 from the isolated workload — 1:06:00](https://youtu.be/hHRXGJZH3mY?t=3960)
- [Validate Docker on the corrected custom AMI — 28:00](https://youtu.be/O0uGlDy5OsA?t=1680)

## Lab accuracy, cost and security

The **IPAM / Regional NAT** recordings use the AWS Management Console; they do not demonstrate Terraform scripts. The **PrivateLink** recording uses Terraform for VPC foundations and the AWS Console for the service and endpoints. The **black-box** example likewise combines Terraform, Console, and CLI. Links to GitHub are companion implementations, not necessarily line-by-line transcripts of on-screen clicks.

These are teaching labs, not fully hardened production reference architectures. Some demos deliberately use permissive policies, manually provisioned components, a single instance, or a public image-building environment to expose the underlying architecture. Review IAM, security groups, HA, endpoint charges, IPAM and NAT pricing, and remove billable AWS resources afterward.

## Continue the learning journey

After networking, move into containers with the [eight-part ECS Fargate learning path](./ECS_LEARNING_PATH.md) and the [existing ECS playlist](https://www.youtube.com/playlist?list=PL5ymUCY9LDOBRP6QSz4KXRjGepIq7RjxJ).
