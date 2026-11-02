# Faz 4: Istanbul Local Zone. Uygulama (ECS on EC2), veritabani (EC2 uzerinde
# MariaDB) ve ALB eu-central-1-ist-1a'da; Frankfurt baseline'i ile ayni imaj.
# Ilk surum bilerek naif; Frankfurt'a hala ne gittigi lz/main.tf'in basinda.

locals {
  default_tags = {
    project     = "lz-woo"
    phase       = "lz"
    environment = var.env
    managed-by  = "terraform"
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = local.default_tags
  }
}

# CloudFront'a bagli WAF us-east-1'de olmak zorunda.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  default_tags {
    tags = local.default_tags
  }
}

module "lz" {
  source = "../../lz"

  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  project    = var.project
  env        = var.env
  region     = var.region
  local_zone = var.local_zone

  nat_in_local_zone = var.nat_in_local_zone

  ecs_instance_type = var.ecs_instance_type
  db_instance_type  = var.db_instance_type
  desired_count     = 2

  admin_extra_allowed_cidrs = var.admin_extra_allowed_cidrs
  wp_admin_password         = var.wp_admin_password

  container_image = var.container_image
  image_tag       = var.image_tag

  enable_cicd             = var.enable_cicd
  codestar_connection_arn = var.codestar_connection_arn
  repository_id           = var.repository_id
  branch                  = var.branch
}
