variable "name" {
  type = string
}

variable "data_subnet_ids" {
  type = list(string)
}

variable "rds_sg_id" {
  type = string
}

variable "db_name" {
  type    = string
  default = "wordpress"
}

variable "db_username" {
  type    = string
  default = "wp_admin"
}

variable "db_password" {
  type      = string
  sensitive = true
}

variable "instance_class" {
  type    = string
  default = "db.m7i.large"
}

variable "allocated_storage" {
  type    = number
  default = 20
}

variable "multi_az" {
  description = "AWS yönetimli senkron standby'ı ikinci AZ'ye kurar ve failover'ı otomatikleştirir. Açıkken primary_availability_zone kullanılamaz; yerleşimi AWS yapar."
  type        = bool
  default     = false
}

variable "primary_availability_zone" {
  description = "Master instance'ın sabitleneceği AZ (diyagramda 1b). null bırakılırsa AWS seçer. multi_az = true iken null olmalı."
  type        = string
  default     = null
}

variable "replica_availability_zone" {
  description = "Read replica'nın AZ'si (diyagramda 1a). Master'dan farklı bir AZ verilmesi replica'nın HA değerini korur."
  type        = string
  default     = null
}

variable "create_read_replica" {
  description = "Diyagramdaki gibi diger AZ'de read replica olustur"
  type        = bool
  default     = true
}

variable "tags" {
  description = "Veri tutan kaynaklara eklenecek etiketler (data-residency, data-class)"
  type        = map(string)
  default     = {}
}
