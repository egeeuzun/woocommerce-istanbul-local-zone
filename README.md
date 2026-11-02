# terraform-aws-wordpress-ha

Terraform code for a WooCommerce store on AWS, and a project to move it from
**Frankfurt** to the **AWS Istanbul Local Zone** so that customer data stays in
Türkiye.

The store is *Yerel Market*, a fake grocery shop from
[wordpress-shop-demo](https://github.com/egeeuzun/wordpress-shop-demo). Its
customers, orders and national ID numbers are all made up, but they look like
the real thing, so we can track where personal data ends up.

## The idea in one minute

A Local Zone is a small piece of an AWS region placed in another city. The
Istanbul Local Zone (`eu-central-1-ist-1a`) belongs to the Frankfurt region, but
its servers and disks are physically in Istanbul.

So the plan is simple: run the store and its database on servers in Istanbul,
and keep Frankfurt only for the things that are not customer data.

The catch: the Local Zone offers only some AWS services. There are EC2 servers,
EBS disks, S3 (One Zone-IA), load balancers and ECS. There is **no** RDS,
Fargate, EFS or ElastiCache. Each missing service needs a replacement that we
run ourselves.

## Today: everything in Frankfurt

```
Customer ──► CloudFront + WAF ──► Load balancer ──► WordPress on ECS Fargate (2 AZs)
                  │                                   ├── RDS MariaDB (managed database)
                  │                                   └── ElastiCache (cache, off by default)
                  └── /wp-content/uploads ──► S3 bucket (product images)

All of it in Frankfurt (eu-central-1).
```

This is `envs/frankfurt-baseline`. It is the "before" picture we measure
against. The application side matches `envs/istanbul-lz`, so the difference
comes from the location and the platform (Fargate, RDS): the same image and
`image_tag`, the same automatic install and seed, no EFS, no object cache and
no read replica (both can be switched on with `enable_elasticache` and
`create_read_replica`), and the same CloudFront price class.

## Target: the Istanbul Local Zone

This is `envs/istanbul-lz`.

```
Customer in Türkiye
   │
   ▼
CloudFront + WAF            (CloudFront has an edge in Istanbul)
   │
   ▼
Load balancer               ┐
   │                        │
   ▼                        │  Istanbul Local Zone
WordPress on ECS, EC2       │  (eu-central-1-ist-1a)
   └── MariaDB on EC2 + EBS │
       └── nightly EBS      │
           snapshots        ┘

Still in Frankfurt: product images (S3), logs (CloudWatch), the NAT
gateway the zone uses to reach the internet, the container registry
(ECR), secrets (SSM), Terraform state and the AWS management APIs.
```

The first version is deliberately simple. Some things that do not belong in
Frankfurt are still there (see [What is still in Frankfurt](#what-is-still-in-frankfurt)).
Finding them is the next step of the project.

### What changes, and why

| Part | Frankfurt today | Istanbul Local Zone | Why |
| --- | --- | --- | --- |
| Servers for WordPress | ECS on **Fargate** | ECS on **EC2** instances (C7i / M7i) | Fargate does not run in Local Zones. We now patch and replace the servers ourselves. |
| Database | **RDS** MariaDB | MariaDB on an **EC2** instance with an encrypted EBS disk | RDS is not offered there. Backups, updates and monitoring become our job. |
| Database backups | RDS backups + AWS Backup | Nightly **EBS snapshots** stored in the zone itself, 7 kept | The backup copy must stay in Istanbul too. A normal snapshot would be stored in Frankfurt. |
| Product images | S3 bucket in Frankfurt | Still the S3 bucket in Frankfurt (for now) | S3 in the zone is a different kind of bucket (a "directory bucket"). We have not checked yet that the media plugin and CloudFront work with it. Product photos are not personal data. |
| Shared files (EFS) | Not used | Not used | Code is in the image, images are in S3. We removed EFS in Frankfurt first, so both setups look the same. |
| Cache | ElastiCache (optional, off by default so both setups match) | No cache (for now) | ElastiCache is not offered there, and the cache holds customer data. The store works without it, a bit slower. |
| Load balancer | ALB across 2 AZs | A separate ALB in the zone's subnets | An ALB cannot mix normal AZ subnets with Local Zone subnets. |
| Firewall (WAF) | On CloudFront | Still on CloudFront | A Local Zone ALB cannot have a WAF attached. Ours was already on CloudFront. |

### What we give up

- **One location instead of two or three.** The Local Zone is a single site. If
  it goes down, the store goes down. The database is a single instance. We say
  this openly; disaster recovery options are written up as a separate decision.
- **More work.** No managed database, no Fargate. Servers need updates, the
  database needs backups that we test.
- **Not every page gets faster.** CloudFront already serves cached pages from
  Istanbul. The gain is on pages that cannot be cached: cart, checkout, "my
  account" and wp-admin.

What we get: the database, its backups and the servers that handle customer
data are in Türkiye, and we can show it.

### What is still in Frankfurt

| What | Personal data? | Plan |
| --- | --- | --- |
| Logs (CloudWatch Logs) | Yes: visitor IP addresses | Found by Residency Guard, then fixed (keep in the zone, or mask IPs) |
| NAT gateway | Passes through: everything the zone sends to the internet or to AWS APIs | Move it into the zone if Istanbul supports NAT gateways (`nat_in_local_zone = true`) |
| Product images (S3) | No | Move to a bucket in the zone once the plugin works with it |
| Container registry, secrets, Terraform state | No | Stay in Frankfurt |

### "Is the data really in Türkiye?"

Moving the servers is not enough. Data leaks out in less obvious ways: logs sent
to CloudWatch in Frankfurt, old database snapshots left behind, plugins that call
outside services (Gravatar, Google Fonts, Akismet).

So the first Local Zone version is deliberately done the simple, naive way.
Then a checking tool, **Residency Guard**, lists every resource tagged
`data-residency=tr` and reports where it really is. We fix what it finds and run
it again. Every data resource in this repo already carries these tags, so the
Frankfurt setup shows up as "everything outside Türkiye" in the first report.

> This is not legal advice and does not claim KVKK compliance. The claim is
> narrower: the resources that hold personal data are in Türkiye, and an
> automatic check proves it.

## Project status

| Step | What | Status |
| --- | --- | --- |
| 1 | Frankfurt setup in Terraform (`envs/frankfurt-baseline`) | Code ready, not yet measured |
| 2 | Demo store with fake data (wordpress-shop-demo) | Done |
| 3 | "Hybrid" period: app in Frankfurt, database on-premises over a VPN | Planned |
| 4 | Move to the Istanbul Local Zone (`envs/istanbul-lz`) | First version written, not yet applied |
| 5–6 | Residency Guard: check, fix, check again | First report done (02.11.2026: 12 ❌, 4 ⚠️, 14 ✅); fixes and second run pending |
| 7 | CI checks that block a database outside Türkiye | Planned |
| 8 | Compare speed, cost and effort for each step | Planned |

Steps 1 and 4 have been checked with `terraform validate` only. Neither has
been applied to an AWS account yet.

## Repository layout

| Path | What it is |
| --- | --- |
| `bootstrap/` | Run once per account: S3 bucket for Terraform state and a monthly AWS Budgets alarm. Local state. |
| `envs/frankfurt-baseline/` | Phase 1 baseline: Frankfurt, Fargate, RDS. Stateless tasks (no EFS, media on S3). |
| `envs/istanbul-lz/` | Phase 4: Istanbul Local Zone, ECS on EC2, MariaDB on EC2. |
| `main/` | Root module for the Frankfurt setup. |
| `lz/` | Root module for the Local Zone setup. |
| `docs/adr/` | Decision records (why EC2 instead of Fargate, why MariaDB on EC2). |
| `modules/` | The building blocks below. |
| `../residency-guard/` | Separate repo, checked out next to this one: the read-only audit tool (Python, boto3) that reads `terraform output residency_guard`, and its reports. See its README (in Turkish). |
| `docs/00-envanter.md` | Inventory of what this repo and the image deploy (in Turkish). |

## Modules

| Module | Purpose |
| --- | --- |
| `network` | VPC with public / app / data subnets across `az_count` AZs, NAT gateway per AZ |
| `network-lz` | VPC with public / app / data subnets in a Local Zone, NAT in the parent AZ or the zone |
| `security` | Security groups for each tier |
| `alb` | Application Load Balancer, target group, health checks |
| `ecs` | ECS service on Fargate or an EC2 capacity provider, task definition, autoscaling, ECS Exec |
| `ecs-ec2-capacity` | Auto Scaling group of ECS instances and its capacity provider (for Local Zones) |
| `ecr` | Container registry for the WordPress image |
| `rds` | MariaDB with optional read replica and Multi-AZ standby |
| `db-ec2-mariadb` | MariaDB on one EC2 instance, data on its own EBS disk, local snapshots with DLM |
| `elasticache` | Object cache |
| `efs` | Optional shared `wp-content/uploads` (and `plugins`/`themes`) across tasks |
| `s3` | Static and media bucket with versioning and lifecycle rules |
| `cdn` | CloudFront distribution, S3 origin via OAC, WAF |
| `backup` | AWS Backup plan and vault |
| `vpn` | Pritunl VPN server for admin access to private subnets |
| `cicd` | CodePipeline and CodeBuild for image build and ECS deploy |
| `residency-audit` | Read-only role for Residency Guard, audit bucket, Athena tables; VPC Flow Logs and DNS query logs during an audit window |

## Usage

**1. Bootstrap (once per account)**

```bash
cd bootstrap
cp terraform.tfvars.example terraform.tfvars   # set budget_emails
terraform init && terraform apply
terraform output -raw backend_hcl > ../envs/frankfurt-baseline/backend.hcl
```

AWS sends a confirmation e-mail for the budget alarm; nothing arrives until you
accept it. The state bucket has `prevent_destroy`.

**2. An environment**

```bash
cd envs/frankfurt-baseline
cp terraform.tfvars.example terraform.tfvars   # admin IPs, image_tag
terraform init -backend-config=backend.hcl
terraform apply
```

State is locked with S3's own lock file (`use_lockfile`), so there is no
DynamoDB table. Every resource gets the default tags `project=lz-woo`,
`phase`, `environment` and `managed-by`.

**2b. The Istanbul Local Zone environment**

Same steps in `envs/istanbul-lz` (its own `backend.hcl` and `terraform.tfvars`).
Terraform opts the account into the Local Zone for you. It runs next to the
baseline in the same account: resource names, state and VPC ranges differ.

The servers take a few minutes after `apply`: ECS adds EC2 instances for the
tasks, and the database instance installs MariaDB on first boot. To look at
the database server:

```bash
aws ssm start-session --target $(terraform output -raw db_instance_id)
```

**3. Fill the store**

Push the image through the CI/CD pipeline (or set `container_image`).

Each environment has its own ECR repository, created in the same `apply` as the
ECS service. When you push the image by hand, create the repository first, push,
then apply the rest. The image must be `linux/amd64` (the instances are C7i/M7i):

```bash
terraform apply -target=module.lz.module.ecr     # module.main.module.ecr in frankfurt-baseline
docker push <ecr_repository_url>:<tag>
terraform apply -var image_tag=<tag>
```

Set `image_tag` to the commit SHA for measurement runs: `latest` moves, and the
next `apply` rolls the service back to whatever `image_tag` points at.

Both environments fill the store by themselves (`enable_auto_seed`, on by
default). When a task starts, the image installs WordPress in Turkish if it is
not installed yet, then runs the seed kit if this database has not seen this
version of it. Only one task does the work; watch it in the container log
(lines starting with `[auto-seed]`). The admin user is `admin`; its password is
**not** `admin123` (that is only the local default of the app repo). Terraform
generates it and keeps it in SSM:

```bash
aws ssm get-parameter --with-decryption --query Parameter.Value --output text \
  --name $(terraform output -raw admin_password_ssm_name)
```

To choose it yourself, set `wp_admin_password` in `terraform.tfvars`. On every
task start the image sets the admin password to the SSM value, so it also
fixes a WordPress installed earlier with another password; a password changed
in wp-admin or with `wp user update` is reset on the next task start. Changing
the value changes the task definition, so `terraform apply` rolls the tasks.
The seed still runs once on the next deploy. To run the seed by hand, use ECS
Exec:

```bash
aws ecs execute-command --cluster <ecs_cluster_name> --task <TASK_ID> --container wordpress \
  --interactive --command "su -s /bin/sh www-data -c 'wp eval-file /usr/src/shop-seed/seed.php'"
```

All input variables are documented in `main/variables.tf`.

### Moving from the old `env/` directory

`env/test_prod.tf` became `envs/frankfurt-baseline`. Its local state is not
moved automatically. To keep the existing resources, set `project = "wordpress HA"`
and `env = "Test"` in `terraform.tfvars` (resource names come from these), then:

```bash
terraform init -backend-config=backend.hcl
terraform state push ../../env/terraform.tfstate
terraform plan
```

The baseline turns EFS off. On an existing deployment that destroys the file
system and anything in it; set `enable_efs = true` in `envs/frankfurt-baseline/main.tf`
first if uploads are not yet on S3.

## Notes

- **WordPress salts** are generated with `random_password`, stored in SSM
  Parameter Store under `/<name>/wp-salts/` and passed to the task as
  `WORDPRESS_*` secrets. Without them the image falls back to fixed, public
  defaults. Recreating them logs everyone out.
- **Stateless mode (`enable_efs = false`)** needs `offload_uploads_to_s3 = true`
  and `enable_plugin_installs = false`; the plan stops otherwise. Code comes from
  the image, media from S3, and a task can be replaced without losing anything.
  Local Zones have no EFS, so this keeps the baseline comparable.
- **Task definition changes reach the service.** The ECS service follows the
  Terraform task definition. The CodePipeline deploy copies the service's current
  revision and only swaps the image, so the next `terraform apply` rolls the
  service back to the same image under `:latest`.
- **Data tags.** Resources that hold store data are tagged
  `data-residency=<data_residency>` (default `tr`) and `data-class`
  (`personal` for the database and its replica, snapshots and backups, EFS,
  ElastiCache and the ECS log groups; `non-personal` for the media bucket).
  The residency checks later in the project use these tags.
- The ALB health check uses the image's `/health.php`, which does not load
  WordPress (`health_check_path`).
- `MEMCACHED_HOST` lists every ElastiCache node; the image's client does not do
  auto-discovery.
- `vpn_admin_cidrs` is required when `enable_vpn = true`; `0.0.0.0/0` is rejected.
- The database password is generated with `random_password` and stored in SSM Parameter Store. It (and the salts) are also written to state in plain text; the bootstrap state bucket is encrypted and private.
- `static_bucket_force_destroy` defaults to `true`; set it to `false` in production.
- Enable `offload_uploads_to_s3` only if the container image has a plugin that writes media to S3.

## Requirements

- Terraform >= 1.11 for the `envs/` and `bootstrap/` roots (`main/` alone works with >= 1.5)
- AWS provider >= 5.79, < 6.0
- Configured AWS credentials
