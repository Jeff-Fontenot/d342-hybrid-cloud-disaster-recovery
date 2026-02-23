terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

data "aws_s3_bucket" "backups" {
  bucket = var.backup_bucket_name
}

# Minimal VPC for DR (since default VPC/subnets are missing)
resource "aws_vpc" "dr_vpc" {
  cidr_block           = "10.50.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.project_name}-vpc"
  }
}

resource "aws_internet_gateway" "dr_igw" {
  vpc_id = aws_vpc.dr_vpc.id

  tags = {
    Name = "${var.project_name}-igw"
  }
}

resource "aws_subnet" "dr_public_subnet" {
  vpc_id                  = aws_vpc.dr_vpc.id
  cidr_block              = "10.50.1.0/24"
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.project_name}-public-subnet"
  }
}

resource "aws_route_table" "dr_public_rt" {
  vpc_id = aws_vpc.dr_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.dr_igw.id
  }

  tags = {
    Name = "${var.project_name}-public-rt"
  }
}

resource "aws_route_table_association" "dr_public_assoc" {
  subnet_id      = aws_subnet.dr_public_subnet.id
  route_table_id = aws_route_table.dr_public_rt.id
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_iam_role" "ec2_role" {
  name_prefix = "${var.project_name}-ec2-role-"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Action    = "sts:AssumeRole",
      Effect    = "Allow",
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "ec2_s3_read" {
  name_prefix = "${var.project_name}-ec2-s3read-"
  role        = aws_iam_role.ec2_role.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
          Sid    = "ListBucket",
          Effect = "Allow",
          Action = ["s3:ListBucket"],
          Resource = [data.aws_s3_bucket.backups.arn]
      },
      {
          Sid    = "GetObjects",
          Effect = "Allow",
          Action = ["s3:GetObject"],
          Resource = ["${data.aws_s3_bucket.backups.arn}/*"]
      }
    ]
  })
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name_prefix = "${var.project_name}-profile-"
  role        = aws_iam_role.ec2_role.name
}

resource "aws_security_group" "ec2_sg" {
  name_prefix = "${var.project_name}-sg-"
  vpc_id      = aws_vpc.dr_vpc.id

  ingress {
    description = "SSH from my IP"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.my_ip_cidr]
  }

  ingress {
    description = "Flask app from my IP"
    from_port   = 5000
    to_port     = 5000
    protocol    = "tcp"
    cidr_blocks = [var.my_ip_cidr]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

locals {
  user_data = templatefile("${path.module}/userdata.sh", {
    s3_bucket = var.backup_bucket_name
    s3_prefix = var.backup_prefix
    region    = var.aws_region
  })
}

resource "aws_instance" "dr" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.dr_public_subnet.id
  vpc_security_group_ids      = [aws_security_group.ec2_sg.id]
  key_name                    = var.key_name
  iam_instance_profile        = aws_iam_instance_profile.ec2_profile.name
  associate_public_ip_address = true
  user_data                   = local.user_data

  tags = {
    Name = "${var.project_name}-dr-ec2"
  }
}