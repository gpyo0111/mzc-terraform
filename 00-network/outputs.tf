output "vpc_id" {
  value = aws_vpc.main.id
}

output "vpc_cidr_block" {
  value = aws_vpc.main.cidr_block
}

output "igw_id" {
  value = aws_internet_gateway.main.id
}

output "public_subnet_ids" {
  value = [
    aws_subnet.public_a.id,
    aws_subnet.public_c.id
  ]
}

output "private_app_subnet_ids" {
  value = [
    aws_subnet.private_app_a.id,
    aws_subnet.private_app_c.id
  ]
}

output "private_data_subnet_ids" {
  value = [
    aws_subnet.private_data_a.id,
    aws_subnet.private_data_c.id
  ]
}

output "public_route_table_id" {
  value = aws_route_table.public.id
}

output "private_app_route_table_id" {
  value = aws_route_table.private_app.id
}

output "private_data_route_table_id" {
  value = aws_route_table.private_data.id
}

output "private_app_subnet_cidrs" {
  value = [
    aws_subnet.private_app_a.cidr_block,
    aws_subnet.private_app_c.cidr_block
  ]
}