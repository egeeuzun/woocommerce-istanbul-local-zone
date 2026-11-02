output "cloudfront_domain_name" {
  value = module.cdn.cloudfront_domain_name
}

output "alb_dns_name" {
  description = "Local Zone ALB'si (CloudFront disinda erisime kapali)"
  value       = module.alb.alb_dns_name
}

output "local_zone" {
  value = module.network.local_zone
}

output "local_zone_id" {
  value = module.network.local_zone_id
}

output "vpc_id" {
  value = module.network.vpc_id
}

output "nat_location" {
  description = "NAT gateway'in durdugu zone; LZ degilse dis trafik Frankfurt'tan cikar"
  value       = module.network.nat_location
}

output "nat_public_ip" {
  value = module.network.nat_public_ip
}

output "db_endpoint" {
  value = module.db.endpoint
}

output "db_instance_id" {
  value = module.db.instance_id
}

output "db_data_volume_id" {
  value = module.db.data_volume_id
}

output "ecs_cluster_name" {
  value = module.ecs.cluster_name
}

output "ecs_autoscaling_group_name" {
  value = module.capacity.autoscaling_group_name
}

output "ecr_repository_url" {
  value = module.ecr.repository_url
}

output "static_bucket_name" {
  value = module.s3.static_bucket_name
}

output "db_password_ssm_parameter" {
  value = aws_ssm_parameter.db_password.name
}

output "admin_password_ssm_name" {
  description = "WordPress yonetici parolasi: aws ssm get-parameter --with-decryption --query Parameter.Value --output text --name <bu deger>"
  value       = aws_ssm_parameter.admin_password.name
}

# residency-guard --config icin: terraform output -json residency_guard > guard.json
output "residency_guard" {
  description = "Residency Guard ayarlari (../residency-guard/README.md)"
  value = {
    region           = var.region
    local_zone       = module.network.local_zone
    local_zone_id    = module.network.local_zone_id
    vpc_id           = module.network.vpc_id
    role_arn         = try(module.residency_audit[0].role_arn, null)
    audit_bucket     = try(module.residency_audit[0].bucket_name, null)
    athena_workgroup = try(module.residency_audit[0].athena_workgroup, null)
    glue_database    = try(module.residency_audit[0].glue_database, null)
    flow_logs_table  = try(module.residency_audit[0].flow_logs_table, null)
    dns_logs_table   = try(module.residency_audit[0].dns_logs_table, null)
    capture_enabled  = try(module.residency_audit[0].capture_enabled, false)
    retention_days   = try(module.residency_audit[0].retention_days, null)
  }
}
