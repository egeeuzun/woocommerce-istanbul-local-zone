variable "project" {
  description = "Kaynak adlarinin oneki (project-env). Eski env/ dizininden tasinan bir kurulumda adlar degismesin diye eski degerler verilmeli (\"wordpress HA\" / \"Test\"); aksi halde her sey yeniden olusturulur."
  type        = string
  default     = "lz-woo"
}

variable "env" {
  type    = string
  default = "baseline"
}

variable "phase" {
  description = "phase etiketi: baseline | hybrid | lz"
  type        = string
  default     = "baseline"

  validation {
    condition     = contains(["baseline", "hybrid", "lz"], var.phase)
    error_message = "phase baseline, hybrid veya lz olmali."
  }
}

variable "region" {
  type    = string
  default = "eu-central-1"
}

variable "enable_elasticache" {
  description = "Memcached object cache. istanbul-lz'de cache yok; karsilastirma ayni uygulama mimarisiyle olsun diye varsayilan kapali."
  type        = bool
  default     = false
}

variable "create_read_replica" {
  description = "Imaj yalnizca writer endpoint'i kullanir; replica okuma yuku almaz, sadece diyagramdaki HA topolojisi icin."
  type        = bool
  default     = false
}

variable "enable_vpn" {
  type    = bool
  default = false
}

variable "vpn_admin_cidrs" {
  type    = list(string)
  default = []
}

variable "vpn_wireguard_port" {
  type    = number
  default = null
}

variable "admin_extra_allowed_cidrs" {
  description = "wp-admin'e WAF uzerinden erisebilecek ek CIDR'ler (ornegin ev IP'niz /32)"
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
  description = "Imajin build edilecegi repo, ornek: kullanici/wordpress-shop-demo"
  type        = string
  default     = ""
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
