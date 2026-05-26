#################################################
# NAT Gateway for Private App Subnets
#################################################

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.env}-nat-eip"
  })
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = data.terraform_remote_state.network.outputs.public_subnet_ids[0]

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.env}-nat-gateway"
  })

  depends_on = [
    aws_eip.nat
  ]
}

resource "aws_route" "private_app_default_to_nat" {
  route_table_id         = data.terraform_remote_state.network.outputs.private_app_route_table_id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.main.id
}