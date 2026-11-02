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
