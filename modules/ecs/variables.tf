variable "name" {
  type = string
}

variable "region" {
  type = string
}

variable "app_subnet_ids" {
  type = list(string)
}

variable "ecs_sg_id" {
  type = string
}

variable "target_group_arn" {
  type = string
}

variable "container_image" {
  type    = string
  default = "wordpress:6-php8.2-apache"
}

variable "container_port" {
  description = "Konteynerin dinlediği port; ALB target group ve security group ile aynı olmak zorunda"
  type        = number
  default     = 80
}

variable "desired_count" {
  type    = number
  default = 2
}

variable "cpu" {
  type    = number
  default = 512
}

variable "memory" {
  type    = number
  default = 1024
}

variable "db_host" {
  type = string
}

variable "db_name" {
  type = string
}

variable "db_username" {
  type = string
}

variable "db_password_ssm_arn" {
  description = "DB parolasini tutan SSM SecureString parametresinin ARN'i"
  type        = string
}

variable "wp_salt_ssm_arns" {
  description = "WordPress anahtar adi (AUTH_KEY, ...) -> SSM SecureString ARN'i. Konteynere WORDPRESS_<ANAHTAR> olarak verilir."
  type        = map(string)
  default     = {}
}

variable "memcached_endpoint" {
  description = "Virgulle ayrilmis host:port listesi. Imajdaki istemci auto-discovery bilmedigi icin node'lar tek tek verilir. Bos = object cache kapali."
  type        = string
  default     = ""
}

variable "wp_home" {
  description = "Sitenin kanonik adresi (ornek: https://xxx.cloudfront.net). WordPress'in urettigi tum URL'leri sabitler; bos birakilirsa WordPress Host basligina bakar ve ALB adresine yonlendirir."
  type        = string
  default     = ""
}

variable "efs_enabled" {
  description = "uploads dizinini EFS'ten mount eder. Kapaliyken uploads konteynerin gecici diskindedir; medya S3'e offload edilmiyorsa dosyalar task'la birlikte kaybolur."
  type        = bool
  default     = true
}

variable "efs_id" {
  type    = string
  default = null
}

variable "efs_access_point_id" {
  type    = string
  default = null
}

variable "efs_access_point_arn" {
  type    = string
  default = null
}

variable "efs_arn" {
  type    = string
  default = null
}

variable "enable_execute_command" {
  description = "ECS Exec: çalışan Fargate konteynerinde kabuk açmayı sağlar (aws ecs execute-command). Konteynere doğrudan shell erişimi verdiği için oturumlar CloudWatch'a kaydedilir."
  type        = bool
  default     = false
}

variable "autoscaling_min" {
  type    = number
  default = 2
}

variable "autoscaling_max" {
  type    = number
  default = 6
}

variable "media_bucket_enabled" {
  description = "Task role'e medya bucket'i izni verilip verilmeyecegi. Ayri bir bayrak, cunku bucket ARN'i apply oncesinde bilinmiyor ve count/for_each iceren bir kosulda kullanilamiyor."
  type        = bool
  default     = false
}

variable "media_bucket_name" {
  description = "Medya offload bucket'inin adi. media_bucket_enabled acikken zorunlu."
  type        = string
  default     = ""
}

variable "media_bucket_arn" {
  type    = string
  default = ""
}

variable "media_base_url" {
  description = "Bucket'taki nesnelerin ziyaretciye sunuldugu taban adres. Bucket'in kendi adresi degil, CloudFront adresi olmali: nesneler yalnizca OAC ile imzalanmis CloudFront istekleriyle okunabilir."
  type        = string
  default     = ""
}

variable "media_remove_local" {
  description = "Offload basarili olunca dosyanin yerel (EFS) kopyasini siler. Kapatilirsa medya hem S3'te hem EFS'te durur."
  type        = bool
  default     = true
}

variable "shared_code_enabled" {
  description = "plugins ve themes dizinlerini EFS'ten mount eder ve wp-admin uzerinden eklenti/tema kurulumunu acar (WORDPRESS_DISALLOW_FILE_MODS=0). Kapaliyken kod tamamen imajdan gelir."
  type        = bool
  default     = false
}

variable "efs_plugins_access_point_id" {
  type    = string
  default = null
}

variable "efs_plugins_access_point_arn" {
  type    = string
  default = null
}

variable "efs_themes_access_point_id" {
  type    = string
  default = null
}

variable "efs_themes_access_point_arn" {
  type    = string
  default = null
}

variable "tags" {
  description = "Veri tutan kaynaklara eklenecek etiketler (data-residency, data-class)"
  type        = map(string)
  default     = {}
}

variable "capacity_provider_name" {
  description = "EC2 capacity provider adi. null = Fargate. Local Zone'larda Fargate olmadigi icin orada dolu verilir."
  type        = string
  default     = null
}

variable "auto_seed" {
  description = "Imaj acilista WordPress'i kursun ve seed'i calistirsin (SHOP_AUTO_SEED=1). Seed kiti degismedikce tekrar calismaz."
  type        = bool
  default     = false
}

variable "admin_username" {
  type    = string
  default = "admin"
}

variable "admin_email" {
  type    = string
  default = "demo@example.com"
}

variable "admin_password_version" {
  description = "Yonetici parolasi SSM parametresinin surumu. Task tanimina yazilir: parola degisince yeni deployment acilir ve imaj parolayi esitler."
  type        = number
  default     = 0
}

variable "admin_password_ssm_arn" {
  description = "auto_seed acikken yonetici parolasini tutan SSM SecureString parametresinin ARN'i"
  type        = string
  default     = ""
}

variable "exec_logging" {
  description = "ECS Exec oturum çıktısının kaydı: OVERRIDE = CloudWatch Logs'a yazar, NONE = kaydetmez. Local Zone'da CloudWatch olmadığından LZ'de NONE kullanılır (RG-002)."
  type        = string
  default     = "OVERRIDE"

  validation {
    condition     = contains(["OVERRIDE", "NONE"], var.exec_logging)
    error_message = "OVERRIDE ya da NONE olmalı."
  }
}
