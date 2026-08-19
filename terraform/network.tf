# A minimal, self-contained VPC. We deliberately do not use the account's default
# VPC so that `terraform destroy` leaves nothing behind and the stack can be
# rebuilt identically in any region or any fresh AWS account.

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "main" {
  cidr_block           = "10.20.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.project_name}-vpc" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.project_name}-igw" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.20.1.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = { Name = "${var.project_name}-public-a" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${var.project_name}-public-rt" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# ---------------------------------------------------------------------------
# Security group: no inbound at all by default.
# Management happens through SSM Session Manager, which is an outbound-only
# connection from the instance - there is nothing to port-scan.
# ---------------------------------------------------------------------------

resource "aws_security_group" "instance" {
  name        = "${var.project_name}-sg"
  description = "Egress-only unless SSH is explicitly enabled"
  vpc_id      = aws_vpc.main.id

  egress {
    description = "All outbound - the CLI needs internet and AWS API access"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-sg" }
}

resource "aws_security_group_rule" "ssh" {
  count = var.ssh_key_name == "" ? 0 : 1

  type              = "ingress"
  security_group_id = aws_security_group.instance.id
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  cidr_blocks       = [var.ssh_ingress_cidr]
  description       = "SSH from the operator IP only"
}
