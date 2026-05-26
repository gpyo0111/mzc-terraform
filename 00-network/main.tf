locals {
  common_tags = {
    Project     = var.project_name
    Environment = var.env
    ManagedBy   = "terraform"
  }
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(local.common_tags, {
    Name = var.vpc_name
  })
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "cloud-dev-igw"
  })
}

#################################################
# Subnets
#################################################

resource "aws_subnet" "public_a" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.0.0/26"
  availability_zone       = var.az_a
  map_public_ip_on_launch = false

  tags = merge(local.common_tags, {
    Name = "cloud-dev-public-az-a"
    Tier = "public"
  })
}

resource "aws_subnet" "public_c" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.0.64/26"
  availability_zone       = var.az_c
  map_public_ip_on_launch = false

  tags = merge(local.common_tags, {
    Name = "cloud-dev-public-az-c"
    Tier = "public"
  })
}

resource "aws_subnet" "private_app_a" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.0.128/25"
  availability_zone       = var.az_a
  map_public_ip_on_launch = false

  tags = merge(local.common_tags, {
    Name = "cloud-dev-private-app-az-a"
    Tier = "private-app"
  })
}

resource "aws_subnet" "private_app_c" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/25"
  availability_zone       = var.az_c
  map_public_ip_on_launch = false

  tags = merge(local.common_tags, {
    Name = "cloud-dev-private-app-az-c"
    Tier = "private-app"
  })
}

resource "aws_subnet" "private_data_a" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.128/26"
  availability_zone       = var.az_a
  map_public_ip_on_launch = false

  tags = merge(local.common_tags, {
    Name = "cloud-dev-private-data-az-a"
    Tier = "private-data"
  })
}

resource "aws_subnet" "private_data_c" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.192/26"
  availability_zone       = var.az_c
  map_public_ip_on_launch = false

  tags = merge(local.common_tags, {
    Name = "cloud-dev-private-data-az-c"
    Tier = "private-data"
  })
}

#################################################
# Route Tables
#################################################

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "cloud-dev-rtb-public"
  })
}

resource "aws_route" "public_default_to_igw" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

resource "aws_route_table_association" "public_a" {
  subnet_id      = aws_subnet.public_a.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_c" {
  subnet_id      = aws_subnet.public_c.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private_app" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "cloud-dev-rtb-private-app"
  })
}

resource "aws_route_table_association" "private_app_a" {
  subnet_id      = aws_subnet.private_app_a.id
  route_table_id = aws_route_table.private_app.id
}

resource "aws_route_table_association" "private_app_c" {
  subnet_id      = aws_subnet.private_app_c.id
  route_table_id = aws_route_table.private_app.id
}

resource "aws_route_table" "private_data" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "cloud-dev-rtb-private-data"
  })
}

resource "aws_route_table_association" "private_data_a" {
  subnet_id      = aws_subnet.private_data_a.id
  route_table_id = aws_route_table.private_data.id
}

resource "aws_route_table_association" "private_data_c" {
  subnet_id      = aws_subnet.private_data_c.id
  route_table_id = aws_route_table.private_data.id
}