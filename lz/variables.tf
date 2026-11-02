variable "project" {
  type = string
}

variable "env" {
  type = string
}

variable "region" {
  description = "Local Zone'un parent region'i"
  type        = string
  default     = "eu-central-1"
}

variable "local_zone" {
  type    = string
  default = "eu-central-1-ist-1a"
}

variable "vpc_cidr" {
  description = "Frankfurt baseline'indan (10.0.0.0/16) farkli; ileride iki VPC baglanabilsin."
  type        = string
  default     = "10.1.0.0/16"
}

variable "nat_in_local_zone" {
  description = "NAT gateway'i Local Zone'a koyar. Kapaliyken (varsayilan) LZ'nin dis trafigi parent AZ'deki NAT'tan, yani Frankfurt'tan cikar."
  type        = bool
  default     = false
}

variable "ecs_instance_type" {
  type    = string
  default = "m7i.large"
}

variable "ecs_instances_min" {
  type    = number
  default = 1
}

variable "ecs_instances_max" {
  type    = number
  default = 4
}

variable "db_instance_type" {
  type    = string
  default = "m7i.large"
}

variable "db_data_volume_size" {
  type    = number
  default = 20
}

variable "db_snapshot_time_utc" {
  description = "DLM'in gunluk EBS snapshot saati (UTC, HH:MM). DLM snapshot'i bu saatten sonraki bir saat icinde baslatir. Denetim icin geceyi beklememek uzere apply'dan ~1 saat sonrasina cekilebilir."
  type        = string
  default     = "00:00"

  validation {
    condition     = can(regex("^([01][0-9]|2[0-3]):[0-5][0-9]$", var.db_snapshot_time_utc))
    error_message = "HH:MM biciminde olmali, ornegin 14:30."
  }
}

variable "db_name" {
  type    = string
  default = "wordpress"
}

variable "db_username" {
  type    = string
  default = "wp_admin"
}

variable "container_image" {
  description = "ECR disi bir imajla calismak icin override. Bos birakilirsa ecr modulunun urettigi repo ve image_tag kullanilir."
  type        = string
  default     = ""
}

variable "image_tag" {
  type    = string
  default = "latest"
}

variable "container_port" {
  type    = number
  default = 80
}

variable "health_check_path" {
  type    = string
  default = "/health.php"
}

variable "desired_count" {
  type    = number
  default = 2
}

variable "wp_admin_password" {
  description = "WordPress yonetici parolasi (admin). Bos = Terraform rastgele uretir. Imaj her task acilisinda parolayi bu degerle esitler; degistirmek task'lari yeniler."
  type        = string
  default     = ""
  sensitive   = true
}

variable "enable_auto_seed" {
  description = "Imaj acilista WordPress'i kurar ve seed'i calistirir; elle wp core install / seed gerekmez."
  type        = bool
  default     = true
}

variable "enable_ecs_exec" {
  type    = bool
  default = true
}

variable "enable_waf" {
  type    = bool
  default = true
}

variable "restrict_alb_to_cloudfront" {
  type    = bool
  default = true
}

variable "alb_ingress_cidrs" {
  description = "restrict_alb_to_cloudfront kapaliyken ALB'ye erisebilecek CIDR'ler"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "admin_extra_allowed_cidrs" {
  description = "wp-admin'e WAF uzerinden erisebilecek CIDR'ler. Bos = kisit yok."
  type        = list(string)
  default     = []
}

variable "static_bucket_force_destroy" {
  type    = bool
  default = true
}

variable "data_residency" {
  type    = string
  default = "tr"
}

variable "enable_cicd" {
  type    = bool
  default = false
}

variable "codestar_connection_arn" {
  type    = string
  default = ""
}

variable "repository_id" {
  type    = string
  default = ""
}

variable "branch" {
  type    = string
  default = "main"
}

variable "enable_residency_audit" {
  description = "Residency Guard'in salt okunur rolunu, denetim bucket'ini ve Athena tablolarini kurar"
  type        = bool
  default     = true
}

variable "residency_capture_enabled" {
  description = "LZ VPC'sinin Flow Logs'unu ve DNS sorgu loglarini acar (IP adresi icerir). Yalnizca denetim penceresinde true yapin."
  type        = bool
  default     = false
}

variable "residency_log_retention_days" {
  type    = number
  default = 3
}

variable "residency_guard_trusted_principal_arns" {
  description = "Guard rolunu ustlenebilecek principal'lar. Bos = bu hesap."
  type        = list(string)
  default     = []
}
