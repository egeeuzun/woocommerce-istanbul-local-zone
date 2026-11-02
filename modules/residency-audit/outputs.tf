output "role_arn" {
  description = "Guard'in ustlendigi salt okunur rol"
  value       = aws_iam_role.guard.arn
}

output "bucket_name" {
  value = aws_s3_bucket.audit.id
}

output "athena_workgroup" {
  value = aws_athena_workgroup.this.name
}

output "glue_database" {
  value = aws_glue_catalog_database.this.name
}

output "flow_logs_table" {
  value = aws_glue_catalog_table.flow_logs.name
}

output "dns_logs_table" {
  value = aws_glue_catalog_table.dns_logs.name
}

output "capture_enabled" {
  value = var.capture_enabled
}

output "retention_days" {
  value = var.retention_days
}
