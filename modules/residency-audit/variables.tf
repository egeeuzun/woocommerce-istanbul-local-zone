variable "name" {
  description = "Kaynak isim oneki (project-env)"
  type        = string
}

variable "vpc_id" {
  description = "Denetlenen VPC (Local Zone VPC'si)"
  type        = string
}

variable "capture_enabled" {
  description = "Flow Logs ve DNS sorgu loglarini acar. Ikisi de IP adresi icerir: yalnizca olcum penceresinde acin, denetimden sonra kapatin."
  type        = bool
  default     = false
}

variable "retention_days" {
  description = "Denetim bucket'indaki log ve sorgu sonuclarinin saklanma suresi (gun)"
  type        = number
  default     = 3

  validation {
    condition     = var.retention_days >= 1 && var.retention_days <= 7
    error_message = "retention_days 1 ile 7 arasinda olmali; denetim loglari IP adresi icerir."
  }
}

variable "trusted_principal_arns" {
  description = "Guard rolunu ustlenebilecek IAM principal'lari. Bos = bu hesap (sts:AssumeRole yetkisi olan her kullanici/rol)."
  type        = list(string)
  default     = []
}

variable "tags" {
  type    = map(string)
  default = {}
}
