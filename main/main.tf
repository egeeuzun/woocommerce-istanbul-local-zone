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

data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  name = lower(replace("${var.project}-${var.env}", " ", "-"))

  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  az_suffix = { for az in local.azs : az => substr(az, -2, 2) }

  public_subnet_map = [
    for i, az in local.azs : {
      name = "${local.name}-public-subnet-${local.az_suffix[az]}"
      az   = az
      cidr = cidrsubnet(var.vpc_cidr, 8, i + 1)
    }
  ]

  app_subnet_map = [
    for i, az in local.azs : {
      name = "${local.name}-app-private-subnet-${local.az_suffix[az]}"
      az   = az
      cidr = cidrsubnet(var.vpc_cidr, 8, i + 10)
    }
  ]

  data_subnet_map = [
    for i, az in local.azs : {
      name = "${local.name}-data-private-subnet-${local.az_suffix[az]}"
      az   = az
      cidr = cidrsubnet(var.vpc_cidr, 8, i + 20)
    }
  ]

  db_primary_az = var.db_multi_az ? null : local.azs[1]
  db_replica_az = local.azs[0]

  admin_allowed_cidrs = concat(
    var.enable_vpn ? ["${one(module.vpn[*].public_ip)}/32"] : [],
    var.admin_extra_allowed_cidrs,
  )

  # Residency Guard'in etiket standardi: data-residency verinin hangi ulkede
  # kalmasi gerektigini, data-class kisisel veri icerip icermedigini soyler.
  # WooCommerce musteri ve siparisleri ayni DB'de tuttugu icin DB, onun
  # kopyalari (replica, snapshot, yedek), object cache ve IP iceren loglar
  # kisisel; urun gorselleri kisisel degil.
  residency_tags = var.data_residency != "" ? { "data-residency" = var.data_residency } : {}

  personal_data_tags     = merge(local.residency_tags, { "data-class" = "personal" })
  non_personal_data_tags = merge(local.residency_tags, { "data-class" = "non-personal" })

  wp_salt_keys = [
    "AUTH_KEY", "SECURE_AUTH_KEY", "LOGGED_IN_KEY", "NONCE_KEY",
    "AUTH_SALT", "SECURE_AUTH_SALT", "LOGGED_IN_SALT", "NONCE_SALT",
  ]

  container_image = var.container_image != "" ? var.container_image : "${module.ecr.repository_url}:${var.image_tag}"
}

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

# WordPress'in oturum cerezlerini imzaladigi anahtarlar. Imajdaki wp-config.php
# bunlari WORDPRESS_<ANAHTAR> ortam degiskenlerinden okur; verilmezse herkesin
# bildigi sabit varsayilanlara duser ve cerezler taklit edilebilir.
# Degistirmek tum oturumlari kapatir.
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

module "network" {
  source = "../modules/network"

  name     = local.name
  vpc_cidr = var.vpc_cidr

  public_subnet_map = local.public_subnet_map
  app_subnet_map    = local.app_subnet_map
  data_subnet_map   = local.data_subnet_map
}

module "vpn" {
  source = "../modules/vpn"
  count  = var.enable_vpn ? 1 : 0

  name            = local.name
  vpc_id          = module.network.vpc_id
  subnet_id       = module.network.public_subnet_id_by_az[local.azs[0]]
  admin_cidrs     = var.vpn_admin_cidrs
  wireguard_port  = var.vpn_wireguard_port
  instance_type   = var.vpn_instance_type
  ubuntu_codename = var.vpn_ubuntu_codename
  ami_id          = var.vpn_ami_id

  depends_on = [module.network]
}

module "security" {
  source = "../modules/security"

  name           = local.name
  vpc_id         = module.network.vpc_id
  container_port = var.container_port
  vpn_sg_ids     = module.vpn[*].security_group_id

  alb_ingress_cidrs           = var.restrict_alb_to_cloudfront ? [] : var.alb_ingress_cidrs
  alb_ingress_prefix_list_ids = var.restrict_alb_to_cloudfront ? [data.aws_ec2_managed_prefix_list.cloudfront_origin_facing[0].id] : []
  alb_origin_ports            = [var.alb_certificate_arn != "" ? 443 : 80]
}

module "alb" {
  source = "../modules/alb"

  name              = local.name
  vpc_id            = module.network.vpc_id
  public_subnet_ids = module.network.public_subnet_ids
  alb_sg_id         = module.security.alb_sg_id
  container_port    = var.container_port
  certificate_arn   = var.alb_certificate_arn
  health_check_path = var.health_check_path
}

module "efs" {
  source = "../modules/efs"
  count  = var.enable_efs ? 1 : 0

  name            = local.name
  data_subnet_ids = module.network.data_subnet_ids
  efs_sg_id       = module.security.efs_sg_id

  shared_code_dirs = var.enable_plugin_installs
  tags             = local.personal_data_tags
}

moved {
  from = module.efs
  to   = module.efs[0]
}

module "rds" {
  source = "../modules/rds"

  name                      = local.name
  data_subnet_ids           = module.network.data_subnet_ids
  rds_sg_id                 = module.security.rds_sg_id
  db_name                   = var.db_name
  db_username               = var.db_username
  db_password               = random_password.db.result
  instance_class            = var.db_instance_class
  multi_az                  = var.db_multi_az
  primary_availability_zone = local.db_primary_az
  create_read_replica       = var.create_read_replica
  replica_availability_zone = local.db_replica_az
  tags                      = local.personal_data_tags
}

moved {
  from = module.elasticache
  to   = module.elasticache[0]
}

module "elasticache" {
  source = "../modules/elasticache"
  count  = var.enable_elasticache ? 1 : 0

  name            = local.name
  data_subnet_ids = module.network.data_subnet_ids
  cache_sg_id     = module.security.cache_sg_id
  tags            = local.personal_data_tags
}

module "ecr" {
  source = "../modules/ecr"

  name = local.name
}

module "ecs" {
  source = "../modules/ecs"

  name                   = local.name
  region                 = var.region
  app_subnet_ids         = module.network.app_subnet_ids
  ecs_sg_id              = module.security.ecs_sg_id
  target_group_arn       = module.alb.target_group_arn
  container_image        = local.container_image
  container_port         = var.container_port
  desired_count          = var.desired_count
  enable_execute_command = var.enable_ecs_exec
  db_host                = module.rds.endpoint
  db_name                = module.rds.db_name
  db_username            = module.rds.db_username
  db_password_ssm_arn    = aws_ssm_parameter.db_password.arn
  wp_salt_ssm_arns       = { for k, p in aws_ssm_parameter.wp_salt : k => p.arn }
  memcached_endpoint     = var.enable_elasticache ? join(",", [for a in module.elasticache[0].node_addresses : "${a}:11211"]) : ""
  wp_home                = "https://${module.cdn.cloudfront_domain_name}"

  auto_seed              = var.enable_auto_seed
  admin_password_ssm_arn = aws_ssm_parameter.admin_password.arn
  admin_password_version = aws_ssm_parameter.admin_password.version

  efs_enabled          = var.enable_efs
  efs_id               = one(module.efs[*].efs_id)
  efs_arn              = one(module.efs[*].efs_arn)
  efs_access_point_id  = one(module.efs[*].access_point_id)
  efs_access_point_arn = one(module.efs[*].access_point_arn)

  shared_code_enabled          = var.enable_plugin_installs
  efs_plugins_access_point_id  = one(module.efs[*].plugins_access_point_id)
  efs_plugins_access_point_arn = one(module.efs[*].plugins_access_point_arn)
  efs_themes_access_point_id   = one(module.efs[*].themes_access_point_id)
  efs_themes_access_point_arn  = one(module.efs[*].themes_access_point_arn)

  media_bucket_enabled = var.offload_uploads_to_s3
  media_bucket_name    = module.s3.static_bucket_name
  media_bucket_arn     = module.s3.static_bucket_arn
  media_base_url       = "https://${module.cdn.cloudfront_domain_name}"
  media_remove_local   = var.media_remove_local

  tags = local.personal_data_tags
}

module "s3" {
  source = "../modules/s3"

  name                               = local.name
  cloudfront_distribution_arn        = module.cdn.distribution_arn
  force_destroy                      = var.static_bucket_force_destroy
  versioning_enabled                 = var.static_bucket_versioning
  noncurrent_version_expiration_days = var.static_bucket_noncurrent_expiration_days
  intelligent_tiering_enabled        = var.static_bucket_intelligent_tiering

  cors_allowed_origins = var.domain_name != "" ? ["https://${var.domain_name}"] : []
  tags                 = local.non_personal_data_tags
}

moved {
  from = module.cdn.aws_s3_bucket.static
  to   = module.s3.aws_s3_bucket.static
}

moved {
  from = module.cdn.aws_s3_bucket_public_access_block.static
  to   = module.s3.aws_s3_bucket_public_access_block.static
}

moved {
  from = module.cdn.aws_s3_bucket_policy.static
  to   = module.s3.aws_s3_bucket_policy.static
}

module "cdn" {
  source = "../modules/cdn"

  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  name                = local.name
  alb_dns_name        = module.alb.alb_dns_name
  alb_https_enabled   = var.alb_certificate_arn != ""
  enable_waf          = var.enable_waf
  admin_allowed_cidrs = local.admin_allowed_cidrs
  domain_name         = var.domain_name
  hosted_zone_id      = var.hosted_zone_id
  acm_certificate_arn = var.acm_certificate_arn_us_east_1

  static_bucket_regional_domain_name = module.s3.static_bucket_regional_domain_name
  offload_uploads_to_s3              = var.offload_uploads_to_s3
}

module "backup" {
  source = "../modules/backup"

  name          = local.name
  resource_arns = compact([one(module.efs[*].efs_arn), module.rds.db_arn])
  tags          = local.personal_data_tags
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

output "availability_zones" {
  description = "Altyapinin yayildigi AZ'ler"
  value       = module.network.azs
}

output "vpc_id" {
  value = module.network.vpc_id
}

output "public_subnet_ids" {
  value = module.network.public_subnet_ids
}

output "app_subnet_ids" {
  value = module.network.app_subnet_ids
}

output "data_subnet_ids" {
  value = module.network.data_subnet_ids
}

output "nat_public_ips" {
  description = "AZ basina NAT cikis IP'leri"
  value       = module.network.nat_public_ips
}

output "vpn_admin_url" {
  description = "Pritunl yonetim konsolu (enable_vpn = true ise)"
  value       = one(module.vpn[*].admin_url)
}

output "vpn_setup_key_command" {
  description = "Pritunl kurulum sihirbazinin istedigi setup key'i alir (1. adim)"
  value       = one(module.vpn[*].setup_key_command)
}

output "vpn_default_password_command" {
  description = "Sihirbaz bittikten sonra ilk yonetici parolasini alir (2. adim)"
  value       = one(module.vpn[*].default_password_command)
}

output "vpn_mongodb_uri" {
  description = "Kurulum sihirbazinin sordugu MongoDB adresi"
  value       = one(module.vpn[*].mongodb_uri)
}

output "alb_dns_name" {
  description = "ALB adresi (dogrudan test icin)"
  value       = module.alb.alb_dns_name
}

output "cloudfront_domain_name" {
  description = "Siteye erisim adresi"
  value       = module.cdn.cloudfront_domain_name
}

output "static_bucket_name" {
  value = module.s3.static_bucket_name
}

output "rds_endpoint" {
  value = module.rds.endpoint
}

output "rds_replica_address" {
  value = module.rds.replica_address
}

output "memcached_endpoint" {
  description = "enable_elasticache kapaliyken null"
  value       = one(module.elasticache[*].configuration_endpoint)
}

output "admin_password_ssm_name" {
  description = "WordPress yonetici parolasi: aws ssm get-parameter --with-decryption --query Parameter.Value --output text --name <bu deger>"
  value       = aws_ssm_parameter.admin_password.name
}

output "efs_id" {
  description = "enable_efs kapaliyken null"
  value       = one(module.efs[*].efs_id)
}

output "ecs_cluster_name" {
  value = module.ecs.cluster_name
}

output "ecr_repository_url" {
  value = module.ecr.repository_url
}

output "container_image" {
  description = "ECS task definition'in taban imaji"
  value       = local.container_image
}

output "db_password_ssm_parameter" {
  description = "DB parolasinin saklandigi SSM parametresi"
  value       = aws_ssm_parameter.db_password.name
}
