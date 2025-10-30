# Fetch available AZs dynamically for HA configuration
data "aws_availability_zones" "available" {
  state = "available"
}

# --- 1. Define VPC (Virtual Private Cloud) ---
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = {
    Name        = "${var.environment}-vpc"
    Environment = var.environment
  }
}

# --- 2. Define Subnets (4 total: 2 Public, 2 Private) ---

# We use the slice function to ensure we only use the first two AZs for simplicity
locals {
  az_names = slice(data.aws_availability_zones.available.names, 0, 2)
}

# Public Subnets (for Load Balancer and NAT Gateway)
resource "aws_subnet" "public_subnet" {
  count             = length(local.az_names)
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index) # 10.0.0.0/24, 10.0.1.0/24
  availability_zone = local.az_names[count.index]
  map_public_ip_on_launch = true # Instances launched here get a public IP by default

  tags = {
    Name = "${var.environment}-public-subnet-${count.index + 1}"
  }
}

# Private Subnets (for Application and Database Tiers)
resource "aws_subnet" "private_subnet" {
  count             = length(local.az_names)
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 2) # 10.0.2.0/24, 10.0.3.0/24
  availability_zone = local.az_names[count.index]
  
  tags = {
    Name = "${var.environment}-private-subnet-${count.index + 1}"
  }
}

# --- 4. Setup Public Access: Internet Gateway and Route Table ---
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.environment}-igw" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = { Name = "${var.environment}-public-route-table" }
}

# Attach public route table to public subnets
resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public_subnet)
  subnet_id      = aws_subnet.public_subnet[count.index].id
  route_table_id = aws_route_table.public.id
}


# --- 5. Setup Private Access: NAT Gateway ---
# A NAT Gateway needs an Elastic IP (EIP)
resource "aws_eip" "nat" {
  domain = "vpc"
}

# NAT Gateway is placed in one of the Public Subnets
resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public_subnet[0].id # Place NAT in the first public subnet

  tags = { Name = "${var.environment}-nat-gateway" }
  # Ensure EIP is provisioned before creating the NAT Gateway
  depends_on = [aws_internet_gateway.igw] 
}

# --- 6. Route Private Traffic ---
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  # Route all traffic for private subnets through the NAT Gateway
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }
  tags = { Name = "${var.environment}-private-route-table" }
}

# Attach private route table to ALL private subnets
resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private_subnet)
  subnet_id      = aws_subnet.private_subnet[count.index].id
  route_table_id = aws_route_table.private.id
}
