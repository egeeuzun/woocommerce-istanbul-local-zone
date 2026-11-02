# Istanbul Local Zone kok modulu (Faz 4). main/ ile ayni magazayi kurar; Local
# Zone'da olmayan servislerin yerine kendi calistirdiklarimizi koyar:
#
#   Fargate      -> ECS on EC2 (modules/ecs-ec2-capacity)
#   RDS          -> EC2 + EBS uzerinde MariaDB (modules/db-ec2-mariadb)
#   ElastiCache  -> yok (object cache kapali)
#   EFS          -> yok (kod imajda, medya S3'te)
#   AWS Backup   -> DLM ile Local Zone'da kalan EBS snapshot'lari
#
# Bu ilk surum bilerek "naif": su veriler hala Frankfurt'a gidiyor ve Faz 5'te
# Residency Guard'in bulmasi bekleniyor:
#   - ECS ve ECS Exec loglari CloudWatch Logs'a (eu-central-1)
#   - NAT parent AZ'de: LZ'nin internet ve AWS API trafigi Frankfurt'tan cikar
#   - Medya bucket'i Frankfurt'ta (urun gorselleri, kisisel veri degil)

terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source                = "hashicorp/aws"
      version               = ">= 5.79.0, < 6.0.0"
      configuration_aliases = [aws.us_east_1]
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
  }
}

data "aws_ec2_managed_prefix_list" "cloudfront_origin_facing" {
  count = var.restrict_alb_to_cloudfront ? 1 : 0
  name  = "com.amazonaws.global.cloudfront.origin-facing"
}

locals {
  name = lower(replace("${var.project}-${var.env}", " ", "-"))

  # main/ ile ayni etiket standardi (Residency Guard)
  residency_tags = var.data_residency != "" ? { "data-residency" = var.data_residency } : {}

  personal_data_tags     = merge(local.residency_tags, { "data-class" = "personal" })
  non_personal_data_tags = merge(local.residency_tags, { "data-class" = "non-personal" })

  wp_salt_keys = [
    "AUTH_KEY", "SECURE_AUTH_KEY", "LOGGED_IN_KEY", "NONCE_KEY",
    "AUTH_SALT", "SECURE_AUTH_SALT", "LOGGED_IN_SALT", "NONCE_SALT",
  ]

  container_image = var.container_image != "" ? var.container_image : "${module.ecr.repository_url}:${var.image_tag}"

  # ECS cluster adi capacity provider'dan once bilinmeli (instance'lar
  # user_data'da bu ada katilir); modules/ecs ayni kurali kullanir.
  cluster_name = "${local.name}-cluster"
}

# --- Secret'lar ---------------------------------------------------------------

resource "random_password" "db" {
  length  = 24
  special = false
}

resource "aws_ssm_parameter" "db_password" {
  name  = "/${local.name}/db-password"
  type  = "SecureString"
  value = random_password.db.result

  tags = { Name = "${local.name}-db-password" }
}

resource "random_password" "wp_salt" {
  for_each = toset(local.wp_salt_keys)

  length           = 64
  override_special = "!#%*()-_=+[]{}<>:?"
}

resource "aws_ssm_parameter" "wp_salt" {
  for_each = random_password.wp_salt

  name  = "/${local.name}/wp-salts/${each.key}"
  type  = "SecureString"
  value = each.value.result

  tags = { Name = "${local.name}-wp-salt-${lower(each.key)}" }
}

# WordPress yonetici parolasi; imaj ilk acilista bununla kurar ve her acilista
# yonetici parolasini buna esitler (auto_seed). var.wp_admin_password bossa
# rastgele. Okumak icin: terraform output -raw admin_password_ssm_name
resource "random_password" "admin" {
  length  = 24
  special = false
}

resource "aws_ssm_parameter" "admin_password" {
  name  = "/${local.name}/wp-admin-password"
  type  = "SecureString"
  value = var.wp_admin_password != "" ? var.wp_admin_password : random_password.admin.result

  tags = { Name = "${local.name}-wp-admin-password" }
}

# --- Ag ----------------------------------------------------------------------

module "network" {
  source = "../modules/network-lz"

  name              = local.name
  vpc_cidr          = var.vpc_cidr
  local_zone        = var.local_zone
  nat_in_local_zone = var.nat_in_local_zone
}

# ECS instance'lari ve agent'lari ECS API'ye NAT uzerinden ulasir. Destroy'da
# NAT/route once silinirse agent task'larin durdugunu bildiremez; servis
# DRAINING'de kalir, ALB ve dolayisiyla IGW de silinemez. capacity ve ecs
# modulleri buna depends_on ile baglanir: once onlar, sonra cikis yolu silinir.
# Tum network modulune baglamak yerine bu ara kaynak: network'teki ilgisiz
# degisiklikler (etiket, yeni log ayari) ECS modullerindeki data source'lari
# apply anina ertelemesin.
resource "terraform_data" "private_egress" {
  input = module.network.private_egress_id
}

module "security" {
  source = "../modules/security"

  name           = local.name
  vpc_id         = module.network.vpc_id
  container_port = var.container_port

  alb_ingress_cidrs           = var.restrict_alb_to_cloudfront ? [] : var.alb_ingress_cidrs
  alb_ingress_prefix_list_ids = var.restrict_alb_to_cloudfront ? [data.aws_ec2_managed_prefix_list.cloudfront_origin_facing[0].id] : []
  alb_origin_ports            = [80]
}

# Local Zone ALB'si: yalnizca LZ subnet'i (AZ subnet'iyle karistirilamaz) ve
# WAF baglanamaz; WAF CloudFront'ta.
module "alb" {
  source = "../modules/alb"

  name              = local.name
  vpc_id            = module.network.vpc_id
  public_subnet_ids = [module.network.public_subnet_id]
  alb_sg_id         = module.security.alb_sg_id
  container_port    = var.container_port
  health_check_path = var.health_check_path
}

# --- Veritabani ---------------------------------------------------------------

module "db" {
  source = "../modules/db-ec2-mariadb"

  name              = local.name
  local_zone        = module.network.local_zone
  subnet_id         = module.network.data_subnet_id
  private_ip        = cidrhost(module.network.data_subnet_cidr, 10)
  security_group_id = module.security.rds_sg_id
  instance_type     = var.db_instance_type
  data_volume_size  = var.db_data_volume_size

  db_name              = var.db_name
  db_username          = var.db_username
  db_password_ssm_name = aws_ssm_parameter.db_password.name
  db_password_ssm_arn  = aws_ssm_parameter.db_password.arn

  tags = local.personal_data_tags
}

# --- Uygulama -----------------------------------------------------------------

module "ecr" {
  source = "../modules/ecr"

  name = local.name
}

module "capacity" {
  source = "../modules/ecs-ec2-capacity"

  name          = local.name
  vpc_id        = module.network.vpc_id
  subnet_ids    = [module.network.app_subnet_id]
  cluster_name  = local.cluster_name
  instance_type = var.ecs_instance_type
  min_size      = var.ecs_instances_min
  max_size      = var.ecs_instances_max

  # Task'lar istek islerken musteri verisi bellekte ve gecici diskte durur
  tags = local.personal_data_tags

  depends_on = [terraform_data.private_egress]
}

module "ecs" {
  source = "../modules/ecs"

  name                   = local.name
  region                 = var.region
  app_subnet_ids         = [module.network.app_subnet_id]
  ecs_sg_id              = module.security.ecs_sg_id
  target_group_arn       = module.alb.target_group_arn
  container_image        = local.container_image
  container_port         = var.container_port
  desired_count          = var.desired_count
  enable_execute_command = var.enable_ecs_exec
  capacity_provider_name = module.capacity.capacity_provider_name

  db_host             = module.db.endpoint
  db_name             = var.db_name
  db_username         = var.db_username
  db_password_ssm_arn = aws_ssm_parameter.db_password.arn
  wp_salt_ssm_arns    = { for k, p in aws_ssm_parameter.wp_salt : k => p.arn }
  wp_home             = "https://${module.cdn.cloudfront_domain_name}"

  auto_seed              = var.enable_auto_seed
  admin_password_ssm_arn = aws_ssm_parameter.admin_password.arn
  admin_password_version = aws_ssm_parameter.admin_password.version

  efs_enabled = false

  media_bucket_enabled = true
  media_bucket_name    = module.s3.static_bucket_name
  media_bucket_arn     = module.s3.static_bucket_arn
  media_base_url       = "https://${module.cdn.cloudfront_domain_name}"
  media_remove_local   = true

  tags = local.personal_data_tags

  depends_on = [terraform_data.private_egress]
}

# --- Medya ve CDN -------------------------------------------------------------

# Medya simdilik Frankfurt'taki normal bir bucket'ta. Local Zone'da S3 yalnizca
# directory bucket olarak var (S3 Express oturum yetkilendirmesi, One Zone-IA);
# WP Offload Media'nin ve CloudFront OAC'nin bununla calistigi dogrulanmadi.
# Urun gorselleri kisisel veri degil (data-class=non-personal).
module "s3" {
  source = "../modules/s3"

  name                        = local.name
  cloudfront_distribution_arn = module.cdn.distribution_arn
  force_destroy               = var.static_bucket_force_destroy

  tags = local.non_personal_data_tags
}

module "cdn" {
  source = "../modules/cdn"

  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  name                = local.name
  alb_dns_name        = module.alb.alb_dns_name
  alb_https_enabled   = false
  enable_waf          = var.enable_waf
  admin_allowed_cidrs = var.admin_extra_allowed_cidrs

  static_bucket_regional_domain_name = module.s3.static_bucket_regional_domain_name
  offload_uploads_to_s3              = true
}

module "cicd" {
  source = "../modules/cicd"
  count  = var.enable_cicd ? 1 : 0

  name                    = local.name
  region                  = var.region
  ecr_repository_url      = module.ecr.repository_url
  ecr_repository_arn      = module.ecr.repository_arn
  ecs_cluster_name        = module.ecs.cluster_name
  ecs_service_name        = module.ecs.service_name
  codestar_connection_arn = var.codestar_connection_arn
  repository_id           = var.repository_id
  branch                  = var.branch
}
