output "site_url" {
  value = "https://${module.lz.cloudfront_domain_name}"
}

output "local_zone" {
  value = module.lz.local_zone
}

output "local_zone_id" {
  value = module.lz.local_zone_id
}

output "nat_location" {
  value = module.lz.nat_location
}

output "alb_dns_name" {
  value = module.lz.alb_dns_name
}

output "db_endpoint" {
  value = module.lz.db_endpoint
}

output "db_instance_id" {
  value = module.lz.db_instance_id
}

output "ecs_cluster_name" {
  value = module.lz.ecs_cluster_name
}

output "ecr_repository_url" {
  value = module.lz.ecr_repository_url
}

output "static_bucket_name" {
  value = module.lz.static_bucket_name
}

output "admin_password_ssm_name" {
  value = module.lz.admin_password_ssm_name
}

output "residency_guard" {
  description = "terraform output -json residency_guard > ../../residency-guard/guard.json"
  value       = module.lz.residency_guard
}
