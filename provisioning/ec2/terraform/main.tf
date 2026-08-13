# provisioning/ec2/terraform/main.tf
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  required_version = ">= 1.5"
}

provider "aws" {
  region = var.region
}

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_vpc" "rack" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = { Name = "cogniforge-rack-vpc" }
}

resource "aws_internet_gateway" "rack" {
  vpc_id = aws_vpc.rack.id
  tags   = { Name = "cogniforge-rack-igw" }
}

resource "aws_subnet" "rack" {
  vpc_id            = aws_vpc.rack.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, 0)
  availability_zone = var.az
  tags              = { Name = "cogniforge-rack-subnet" }
}

resource "aws_route_table" "rack" {
  vpc_id = aws_vpc.rack.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.rack.id
  }
  tags = { Name = "cogniforge-rack-rt" }
}

resource "aws_route_table_association" "rack" {
  subnet_id      = aws_subnet.rack.id
  route_table_id = aws_route_table.rack.id
}

resource "aws_security_group" "rack" {
  name        = "cogniforge-rack"
  description = "RKE2 (6443), NodePorts, SSH, inspect traffic"
  vpc_id      = aws_vpc.rack.id

  ingress {
    # SSH
    from_port = 22; to_port = 22; protocol = "tcp"; cidr_blocks = [var.ssh_cidr]
  }
  ingress {
    # RKE2 server
    from_port = 6443; to_port = 6443; protocol = "tcp"; cidr_blocks = [var.ssh_cidr]
  }
  ingress {
    # RKE2 agent -> server, plus weave between nodes
    from_port = 9345; to_port = 9345; protocol = "tcp"; cidr_blocks = [var.ssh_cidr]
  }
  ingress {
    # NodePort range (Rack Engine API + frontend)
    from_port = 30000; to_port = 32767; protocol = "tcp"; cidr_blocks = [var.ssh_cidr]
  }
  ingress {
    # Same-VPC node traffic (Calico/Flannel/weave + metrics)
    from_port = 0; to_port = 65535; protocol = "tcp"; cidr_blocks = [aws_vpc.rack.cidr_block]
  }
  egress {
    from_port = 0; to_port = 0; protocol = "-1"; cidr_blocks = ["0.0.0.0/0"]
  }
}

# --- ECR repositories, one per image produced by build-images.sh ----------
locals {
  repos = ["rack-engine", "rack-engine-frontend", "wan21", "stub-video", "base"]
}
resource "aws_ecr_repository" "rack" {
  for_each = toset(local.repos)
  name     = "cogniforge/${each.value}"
  image_scanning_configuration { scan_on_push = true }
  tags = { Name = "cogniforge/${each.value}" }
}
resource "aws_ecr_lifecycle_policy" "rack" {
  for_each = aws_ecr_repository.rack
  repository = each.value.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "keep 10 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}

# --- IAM role so nodes can pull/push from ECR via instance profile ---------
resource "aws_iam_role" "rack" {
  name = "cogniforge-rack-node"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action = ["sts:AssumeRole"]
    }]
  })
}
resource "aws_iam_role_policy_attachment" "rack_ecr" {
  role       = aws_iam_role.rack.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser"
}
resource "aws_iam_role_policy_attachment" "rack_ssm" {
  role       = aws_iam_role.rack.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}
resource "aws_iam_instance_profile" "rack" {
  name = "cogniforge-rack-node"
  role = aws_iam_role.rack.name
}

# --- Control plane (tier1, also a worker in single-node mode) -------------
resource "aws_instance" "cp" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = "t3.medium"
  subnet_id                   = aws_subnet.rack.id
  key_name                    = var.ssh_key_name
  vpc_security_group_ids      = [aws_security_group.rack.id]
  iam_instance_profile        = aws_iam_instance_profile.rack.name
  associate_public_ip_address = true

  # user_data runs provisioning/ec2/bringup-ec2.sh on first boot with the
  # control-plane env. The GPU workers below depend on this resource so their
  # user_data can embed the CP private IP as RKE2_SERVER.
  user_data = <<-EOT
    #!/bin/bash
    set -eu
    apt-get update -y || yum update -y || true
    command -v git >/dev/null || (yum install -y git)
    git clone ${var.git_repo} /opt/cogniforge-rack
    cd /opt/cogniforge-rack
    export REGION=${var.region}
    export REGISTRY=${replace(aws_ecr_repository.rack["rack-engine"].repository_url, "/rack-engine$", "")}
    export NODE_TIER=tier1
    export RKE2_TOKEN=${var.rke2_token}
    export RACK_ENGINE_URL=${var.rack_engine_url}
    export IMAGE_TAG=${var.image_tag}
    export GIT_REPO=${var.git_repo}
    export RACK_DIR=/opt/cogniforge-rack
    cd / && bash -c 'cd /opt/cogniforge-rack && bash provisioning/ec2/bringup-ec2.sh'
  EOT

  root_block_device {
    volume_size = 60
  }
  tags = { Name = "cogniforge-cp", role = "tier1" }
}

# --- GPU workers (tier2 / tier3) -------------------------------------------
resource "aws_instance" "gpu" {
  count                       = var.gpu_worker_count
  ami                         = data.aws_ami.al2023.id
  instance_type               = var.gpu_instance_type
  subnet_id                   = aws_subnet.rack.id
  key_name                    = var.ssh_key_name
  vpc_security_group_ids      = [aws_security_group.rack.id]
  iam_instance_profile        = aws_iam_instance_profile.rack.name
  associate_public_ip_address = true

  user_data = <<-EOT
    #!/bin/bash
    set -eu
    yum install -y git || apt-get update -y && apt-get install -y git
    git clone ${var.git_repo} /opt/cogniforge-rack
    cd /opt/cogniforge-rack
    export REGION=${var.region}
    export REGISTRY=${replace(aws_ecr_repository.rack["rack-engine"].repository_url, "/rack-engine$", "")}
    export NODE_TIER=${var.gpu_tier}
    export RKE2_TOKEN=${var.rke2_token}
    export RKE2_SERVER=${aws_instance.cp.private_ip}
    export GIT_REPO=${var.git_repo}
    cd / && bash -c 'cd /opt/cogniforge-rack && bash provisioning/ec2/bringup-ec2.sh'
  EOT

  root_block_device {
    volume_size = 200
  }
  tags = { Name = "cogniforge-gpu-${count.index}", role = var.gpu_tier }
  depends_on = [aws_instance.cp]
}