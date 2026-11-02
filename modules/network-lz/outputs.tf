output "vpc_id" {
  value = aws_vpc.this.id
}

output "local_zone" {
  value = var.local_zone
}

output "local_zone_id" {
  description = "Ornek: euc1-ist1-az1"
  value       = data.aws_availability_zone.lz.zone_id
}

output "parent_zone_name" {
  value = data.aws_availability_zone.lz.parent_zone_name
}

output "public_subnet_id" {
  value = aws_subnet.public.id
}

output "app_subnet_id" {
  value = aws_subnet.app.id
}

output "data_subnet_id" {
  value = aws_subnet.data.id
}

output "data_subnet_cidr" {
  value = aws_subnet.data.cidr_block
}

output "nat_public_ip" {
  value = aws_eip.nat.public_ip
}

output "nat_location" {
  description = "NAT gateway'in durdugu zone"
  value       = var.nat_in_local_zone ? var.local_zone : data.aws_availability_zone.lz.parent_zone_name
}

output "private_egress_id" {
  description = "Ozel subnet'lerin internete cikisini tasiyan kaynaklar (NAT, route table ve baglantilari). Bunlara bagli olmasi gerekenler icin (bkz. lz/main.tf, terraform_data.private_egress)."
  # NAT'in kendi subnet'inin IGW yolu da dahil: o silinirse NAT internete
  # cikamaz, ECS agent'lari kopar ve destroy servis DRAINING'de takilir.
  value = join(",", concat([
    aws_nat_gateway.this.id,
    aws_route_table.private.id,
    aws_route_table_association.app.id,
    aws_route_table_association.data.id,
    aws_route_table.public.id,
    aws_route_table_association.public.id,
  ], aws_route_table_association.nat_parent[*].id))
}
