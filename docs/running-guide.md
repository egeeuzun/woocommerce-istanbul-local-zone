# Running guide

**English** · [Türkçe](calistirma-kilavuzu.md) · [README](../README.md)

This guide takes you step by step from an empty AWS account to a working
*Yerel Market* store, and back to zero cost. You can deploy either environment
(or both, side by side in the same account):

| Environment | Directory | Where it runs |
| --- | --- | --- |
| Frankfurt baseline | `envs/frankfurt-baseline` | `eu-central-1`, 2 AZs, ECS Fargate + RDS |
| Istanbul Local Zone | `envs/istanbul-lz` | `eu-central-1-ist-1a`, ECS on EC2 + MariaDB on EC2 |

> ⚠️ **Cost warning.** These setups run NAT gateways, an ALB, CloudFront, WAF
> and `m7i.large`-class servers, all billed by the hour. [Tear the environment
> down](#11-tear-down) after every test or measurement run. The budget alarm
> from bootstrap is there to catch what you forget, not to replace this step.

## Overview

```
1. Install tools   ─►  2. Connect to AWS   ─►  3. Clone the repos
4. Bootstrap (once): state bucket + budget alarm
5. Environment settings (backend.hcl, terraform.tfvars) ─► terraform init
6. Create the ECR repository ─► 7. Build and push the image
8. terraform apply ─► 9. Check it (site, logs, admin password)
10. (Optional) Residency Guard audit
11. terraform destroy + snapshot clean-up
```

## 1. Prerequisites

| Tool | Version | What for |
| --- | --- | --- |
| [Terraform](https://developer.hashicorp.com/terraform/install) | **>= 1.11** | The `envs/` and `bootstrap/` roots (S3 native state locking needs 1.11) |
| [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) | current | Authentication, ECR login, SSM, logs |
| [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html) | current | `aws ssm start-session` and `aws ecs execute-command` |
| Docker + buildx | current | Building the WordPress image for `linux/amd64` |
| git | — | Cloning the repos |

You also need:

- An **AWS account** and an IAM user or role with broad permissions. The setup
  touches many services (VPC, IAM roles, ECS, RDS/EC2, CloudFront, WAF, SSM,
  S3, DLM, Budgets); in a sandbox account `AdministratorAccess` is the
  simplest path.
- An **e-mail address** for the budget alarms.
- On an Apple Silicon (ARM) Mac, always build the image with
  `--platform linux/amd64` (see [step 7](#7-build-and-push-the-image)).

Check the versions:

```bash
terraform version
aws --version
session-manager-plugin --version
docker buildx version
```

## 2. Connect to AWS

Set up your credentials as a profile (use `aws configure sso` for SSO):

```bash
aws configure --profile lz-woo
```

```bash
export AWS_PROFILE=lz-woo
export AWS_REGION=eu-central-1
```

Make sure you are in the right account:

```bash
aws sts get-caller-identity
```

Run every command in this guide in the same terminal, with these two
variables set.

## 3. Clone the repos

The three repos sit next to each other. Residency Guard is only needed for the
audit.

```bash
mkdir lz-woo && cd lz-woo
git clone https://github.com/egeeuzun/woocommerce-istanbul-local-zone.git
git clone https://github.com/egeeuzun/wordpress-shop-demo.git
git clone https://github.com/egeeuzun/residency-guard.git
```

Result:

```
lz-woo/
├── woocommerce-istanbul-local-zone/   ← this repo (Terraform)
├── wordpress-shop-demo/               ← WordPress + WooCommerce image and seed kit
└── residency-guard/                   ← data residency audit tool
```

In the rest of this guide, `<repo>` is the root of this repo.

## 4. Bootstrap (once per account)

Bootstrap creates the encrypted S3 bucket that holds the environments'
Terraform state, and a monthly budget alarm. Its own state is local
(`bootstrap/terraform.tfstate`); do not delete that file.

```bash
cd <repo>/bootstrap
cp terraform.tfvars.example terraform.tfvars
```

Put your address in `budget_emails` in `terraform.tfvars`. Optionally change
the thresholds with `budget_thresholds_usd` (default `[30, 60, 100]` USD).
Then:

```bash
terraform init
terraform apply
```

Write `backend.hcl` for both environments:

```bash
terraform output -raw backend_hcl > ../envs/frankfurt-baseline/backend.hcl
terraform output -raw backend_hcl > ../envs/istanbul-lz/backend.hcl
```

✅ **Check:** AWS sends each address a subscription confirmation e-mail. No
budget alarm arrives until you confirm it.

> The state bucket has `prevent_destroy`; `terraform destroy` will not delete
> it. This is on purpose: losing the state means Terraform can no longer see
> the resources it created.

## 5. Configure the environment

Go to the directory of the environment you want. The examples use Istanbul;
for Frankfurt use `envs/frankfurt-baseline`, the steps are the same.

```bash
cd <repo>/envs/istanbul-lz
cp terraform.tfvars.example terraform.tfvars
```

The important fields in `terraform.tfvars`:

| Variable | What it does | Suggestion |
| --- | --- | --- |
| `admin_extra_allowed_cidrs` | WAF opens `wp-admin` and `wp-login.php` only to these IPs. Left empty, wp-admin is unrestricted. | Your own IP as `/32` |
| `wp_admin_password` | The WordPress `admin` password. Left commented out, Terraform generates one and stores it in SSM. | Leave it commented out |
| `image_tag` | The image tag to pull from ECR. Default `latest`. | A commit SHA |
| `enable_cicd` and related | Builds and deploys the image with CodePipeline. | [7B](#7b-with-the-cicd-pipeline-optional) |
| `nat_in_local_zone` | *(Istanbul only)* Puts the NAT gateway in the Local Zone instead of Frankfurt. | `true` once NAT support in Istanbul is confirmed |
| `ecs_instance_type`, `db_instance_type` | *(Istanbul only)* Default `m7i.large`. | Change if not offered in the zone ([troubleshooting](#12-troubleshooting)) |
| `enable_vpn`, `vpn_admin_cidrs` | *(Frankfurt only)* Pritunl admin VPN. | Off unless needed |

To find your public IP:

```bash
curl -s https://checkip.amazonaws.com
```

Initialise Terraform:

```bash
terraform init -backend-config=backend.hcl
```

All variables and their descriptions: `envs/<env>/variables.tf`,
`main/variables.tf` (Frankfurt) and `lz/variables.tf` (Istanbul).

## 6. Create the ECR repository

The environment's container registry (ECR) must exist before you push the
image. Create only that first:

```bash
# Istanbul:
terraform apply -target=module.lz.module.ecr
```

```bash
# Frankfurt:
terraform apply -target=module.main.module.ecr
```

Terraform warns about `-target`; that is expected at this step.

## 7. Build and push the image

Two ways: push by hand (7A, recommended for a first run) or the CI/CD
pipeline (7B).

### 7A. Push by hand

Get the ECR address and log Docker in to ECR (from the environment directory):

```bash
REPO_URL=$(terraform output -raw ecr_repository_url)
```

```bash
aws ecr get-login-password | docker login --username AWS --password-stdin "${REPO_URL%%/*}"
```

Build the image from the `wordpress-shop-demo` repo and push it, tagged with
the commit SHA:

```bash
cd ../../../wordpress-shop-demo
TAG=$(git rev-parse --short HEAD)
docker buildx build --platform linux/amd64 -t "$REPO_URL:$TAG" --push .
cd -
```

> The image **must be `linux/amd64`**: the servers are Intel-based (C7i/M7i).
> With an ARM image the tasks exit with `exec format error`.

### 7B. With the CI/CD pipeline (optional)

1. In the AWS console, under **Developer Tools → Settings → Connections**,
   create a GitHub connection and approve it (status must be *Available*).
2. Turn it on in `terraform.tfvars`:

   ```hcl
   enable_cicd             = true
   codestar_connection_arn = "arn:aws:codestar-connections:eu-central-1:<ACCOUNT>:connection/<ID>"
   repository_id           = "<user>/wordpress-shop-demo"
   branch                  = "main"
   ```

3. After the `apply` in [step 8](#8-deploy-the-environment), the pipeline runs
   its first build, then builds and deploys again on every push to that
   branch.

> The pipeline copies the service's current task definition and only swaps the
> image. The next `terraform apply` rolls the service back to whatever
> `image_tag` points at. Pin `image_tag` to a SHA for measurement runs.

## 8. Deploy the environment

```bash
terraform apply -var image_tag=$TAG
```

(No `-var` needed if you put `image_tag` in `terraform.tfvars`.)

Read the plan and type `yes`. The first deploy takes roughly 15–30 minutes;
the CloudFront distribution is the slowest part.

Give it a few more minutes after `apply` finishes:

- **Istanbul:** ECS starts EC2 instances for the tasks; the database instance
  installs MariaDB on first boot.
- **Both:** the first task installs WordPress in Turkish and fills the store
  with the seed kit (`enable_auto_seed`, on by default).

> The Istanbul environment opts your account into the Local Zone for you
> (`aws_ec2_availability_zone_group`). The opt-in cannot be undone through the
> AWS API; `destroy` only removes it from state. It costs nothing.

## 9. Check it

### The site

```bash
terraform output -raw site_url
```

Open the address in a browser; the *Yerel Market* home page should load. If
you get a 502/503 right away, wait a few minutes for the seed to finish.

To see that the tasks are running:

```bash
CLUSTER=$(terraform output -raw ecs_cluster_name)
aws ecs list-tasks --cluster "$CLUSTER" --desired-status RUNNING
```

### Admin login

The user name is `admin`. The password (**not** `admin123`):

```bash
aws ssm get-parameter --with-decryption --query Parameter.Value --output text \
  --name $(terraform output -raw admin_password_ssm_name)
```

Log in at `<site_url>/wp-admin`. A 403 means your IP is not in
`admin_extra_allowed_cidrs`.

### Container logs and the seed

Seed lines start with `[auto-seed]`.

**Frankfurt** — logs are in CloudWatch Logs (`/ecs/<project>-<env>-wordpress`,
by default `lz-woo-baseline`):

```bash
aws logs tail /ecs/lz-woo-baseline-wordpress --follow | grep auto-seed
```

**Istanbul** — so that data does not leave Türkiye, logs are written to the
ECS instance's disk (`json-file`), not to CloudWatch. First find the
instance:

```bash
aws ecs describe-container-instances --cluster "$CLUSTER" \
  --container-instances $(aws ecs list-container-instances --cluster "$CLUSTER" --query 'containerInstanceArns' --output text) \
  --query 'containerInstances[].ec2InstanceId' --output text
```

Then connect and read the container log:

```bash
aws ssm start-session --target <ec2-instance-id>
```

```bash
sudo docker ps --format '{{.ID}} {{.Names}}' | grep wordpress
sudo docker logs -f <container-id> 2>&1 | grep auto-seed
```

### Get into the container and run the seed by hand (ECS Exec)

```bash
TASK=$(aws ecs list-tasks --cluster "$CLUSTER" --query 'taskArns[0]' --output text)
```

```bash
aws ecs execute-command --cluster "$CLUSTER" --task "$TASK" --container wordpress \
  --interactive --command "su -s /bin/sh www-data -c 'wp eval-file /usr/src/shop-seed/seed.php'"
```

### Connect to the database server (Istanbul only)

```bash
aws ssm start-session --target $(terraform output -raw db_instance_id)
```

Other useful outputs: `terraform output` (all of them), `local_zone`,
`nat_location`, `db_endpoint`, `alb_dns_name`.

## 10. Residency Guard audit (optional, Istanbul)

Residency Guard reports where the resources tagged `data-residency=tr` really
are. Details and how to run the tool itself:
[residency-guard README](https://github.com/egeeuzun/residency-guard).

1. **Open the audit window** (Flow Logs and DNS query logs; they contain IP
   addresses). In `terraform.tfvars`:

   ```hcl
   residency_capture_enabled    = true
   residency_log_retention_days = 3
   # Skip waiting for the night for the first DB snapshot: ~1 hour after apply (UTC).
   # Türkiye is UTC+3: "12:30" for 15:30 local time.
   db_snapshot_time_utc = "12:30"
   ```

   ```bash
   terraform apply
   ```

2. Browse the site, add products to the cart, place an order, so there is
   traffic to look at.
3. Hand the settings to Residency Guard (from the environment directory):

   ```bash
   terraform output -json residency_guard > ../../../residency-guard/guard.json
   ```

4. Run Residency Guard as its README describes and read the report.
5. **Close the window:** set `residency_capture_enabled = false`, delete the
   `db_snapshot_time_utc` line and run `terraform apply`.

## 11. Tear down

Tear the environment down after every test or measurement run:

```bash
cd <repo>/envs/istanbul-lz      # or envs/frankfurt-baseline
terraform destroy
```

`destroy` leaves some things behind on purpose:

| Left behind | Why | What to do |
| --- | --- | --- |
| **EBS snapshots taken by DLM** (Istanbul) | DLM created them, not Terraform | Delete them with the commands below |
| Local Zone opt-in | Cannot be turned off through the API | Free, leave it |
| Bootstrap state bucket and budget alarm | `prevent_destroy`; the other environments use it | Keep until the project is completely done |

Find and delete the leftover database snapshots (they contain personal data):

```bash
aws ec2 describe-snapshots --owner-ids self \
  --filters Name=tag-key,Values=lz-woo-snapshot \
  --query 'Snapshots[].[SnapshotId,StartTime,Tags[?Key==`lz-woo-snapshot`]|[0].Value]' --output table
```

```bash
aws ec2 delete-snapshot --snapshot-id <snap-id>
```

When the project is completely done you can remove bootstrap too: first remove
the `prevent_destroy = true` line in `bootstrap/main.tf`, empty the state
bucket (including old versions, since it is versioned), then run
`terraform destroy` in `bootstrap`.

## 12. Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `terraform init`: `Unsupported Terraform Core version` | Terraform older than 1.11 | Upgrade Terraform |
| `init`: bucket not found / no `backend.hcl` | Bootstrap output not written | Run the `terraform output -raw backend_hcl` commands from [step 4](#4-bootstrap-once-per-account) |
| `Error acquiring the state lock` | An interrupted `apply` left a lock file | Make sure no other `apply` is running, then `terraform force-unlock <LOCK_ID>` |
| Tasks keep going `STOPPED` with `CannotPullContainerError` | Image not in ECR, or wrong `image_tag` | Repeat [step 7](#7-build-and-push-the-image), check `image_tag` |
| `exec format error` in the task log | Image built for ARM | Rebuild with `--platform linux/amd64` |
| No instances start in Istanbul (`Unsupported` / `InsufficientInstanceCapacity`) | Instance type not offered in the zone, or no capacity | List the offered types with the command below and change `ecs_instance_type`/`db_instance_type` |
| The site returns 502/503 | Tasks not healthy yet, or the seed is still running | Wait a few minutes, check the logs |
| `wp-admin` returns 403 | Your IP is not in the WAF list | Add it to `admin_extra_allowed_cidrs` and `apply` |
| Admin password rejected | A password changed in wp-admin is reset to the SSM value on the next task start | Use the SSM value, or set `wp_admin_password` |
| `aws ssm start-session` / `execute-command`: `SessionManagerPlugin is not found` | Plugin not installed | Install the [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html) |
| After editing `main.tf`, the plan stops with an EFS error | `enable_efs = false` needs `offload_uploads_to_s3 = true` and `enable_plugin_installs = false` | See *Notes* in the README |
| No budget alarm arrives | Subscription e-mail not confirmed | Confirm the AWS e-mail (check spam) |

Instance types offered in the Istanbul Local Zone:

```bash
aws ec2 describe-instance-type-offerings --location-type availability-zone \
  --filters Name=location,Values=eu-central-1-ist-1a \
  --query 'InstanceTypeOfferings[].InstanceType' --output text
```

## Command summary

```bash
# Once
cd <repo>/bootstrap && cp terraform.tfvars.example terraform.tfvars   # set your e-mail
terraform init && terraform apply
terraform output -raw backend_hcl > ../envs/istanbul-lz/backend.hcl

# Environment
cd ../envs/istanbul-lz && cp terraform.tfvars.example terraform.tfvars   # set your IP
terraform init -backend-config=backend.hcl
terraform apply -target=module.lz.module.ecr
REPO_URL=$(terraform output -raw ecr_repository_url)
aws ecr get-login-password | docker login --username AWS --password-stdin "${REPO_URL%%/*}"
(cd ../../../wordpress-shop-demo && docker buildx build --platform linux/amd64 -t "$REPO_URL:$(git rev-parse --short HEAD)" --push .)
terraform apply -var image_tag=$(git -C ../../../wordpress-shop-demo rev-parse --short HEAD)
terraform output -raw site_url

# When done
terraform destroy
```
