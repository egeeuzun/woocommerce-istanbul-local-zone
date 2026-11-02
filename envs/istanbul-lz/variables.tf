variable "project" {
  type    = string
  default = "lz-woo"
}

variable "env" {
  description = "Baseline'dan farkli olmali; kaynak adlari project-env'den gelir ve ayni hesapta cakismamali."
  type        = string
  default     = "ist"
}

variable "region" {
  type    = string
  default = "eu-central-1"
}

variable "local_zone" {
  type    = string
  default = "eu-central-1-ist-1a"
}

variable "nat_in_local_zone" {
  description = "Istanbul'da NAT gateway destegi dogrulanirsa true yapin; varsayilan NAT Frankfurt'ta (parent AZ)."
  type        = bool
  default     = false
}

variable "ecs_instance_type" {
  type    = string
  default = "m7i.large"
}

variable "db_instance_type" {
  type    = string
  default = "m7i.large"
}

variable "admin_extra_allowed_cidrs" {
  description = "wp-admin'e WAF uzerinden erisebilecek CIDR'ler (ornegin ev IP'niz /32)"
  type        = list(string)
  default     = []
}

variable "container_image" {
  description = "Tam imaj adresi (repo:tag veya repo@sha256:...). Bos = bu ortamin ECR repo'su + image_tag."
  type        = string
  default     = ""
}

variable "image_tag" {
  description = "ECR'dan cekilecek tag. Olcum turlarinda commit SHA'si verin: latest degisir, pipeline SHA'li tag'i deploy eder ve sonraki apply servisi image_tag'e geri alir."
  type        = string
  default     = "latest"
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

variable "wp_admin_password" {
  description = "WordPress yonetici parolasi. Bos = rastgele (SSM'den okunur)."
  type        = string
  default     = ""
  sensitive   = true
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

variable "residency_capture_enabled" {
  description = "Residency Guard denetim penceresi: Flow Logs ve DNS sorgu loglarini acar (IP adresi icerir, retention gun sonra silinir). Denetimden sonra false yapip tekrar apply edin."
  type        = bool
  default     = false
}

variable "residency_log_retention_days" {
  type    = number
  default = 3
}
