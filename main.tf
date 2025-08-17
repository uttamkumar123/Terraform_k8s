terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.50"
    }
  }
}

provider "aws" {
  region = var.region
}

########################
# Networking (simple)
########################

resource "aws_vpc" "main" {
  cidr_block           = "10.20.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = { Name = "k8s-vpc" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags = { Name = "k8s-igw" }
}

resource "aws_subnet" "public_a" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.20.1.0/24"
  map_public_ip_on_launch = true
  availability_zone       = data.aws_availability_zones.available.names[0]
  tags = { Name = "k8s-public-a" }
}

data "aws_availability_zones" "available" {}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = { Name = "k8s-public-rt" }
}

resource "aws_route_table_association" "public_a" {
  subnet_id      = aws_subnet.public_a.id
  route_table_id = aws_route_table.public.id
}

########################
# Security Groups
########################

# Allow SSH from anywhere (demo); tighten to your IP in production.
resource "aws_security_group" "k8s_nodes" {
  name        = "k8s-nodes-sg"
  description = "K8s nodes security group"
  vpc_id      = aws_vpc.main.id

  # SSH
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Kubernetes API server (master): allow from VPC
  ingress {
    description = "K8s API 6443"
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.main.cidr_block]
  }

  # Kubelet, nodeports, etc. (intra-SG)
  ingress {
    description      = "All intra-SG traffic"
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    self             = true
  }

  # Egress all
  egress {
    description = "All egress"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "k8s-nodes-sg" }
}

########################
# IAM role for EC2 (lets worker discover master IP)
########################

resource "aws_iam_role" "ec2_role" {
  name               = "k8s-demo-ec2-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_policy" "describe_ec2" {
  name        = "k8s-demo-describe-ec2"
  description = "Allow describe to find control-plane instance"
  policy      = data.aws_iam_policy_document.describe_ec2.json
}

data "aws_iam_policy_document" "describe_ec2" {
  statement {
    actions   = ["ec2:DescribeInstances", "ec2:DescribeTags"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy_attachment" "attach_describe" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = aws_iam_policy.describe_ec2.arn
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "k8s-demo-ec2-profile"
  role = aws_iam_role.ec2_role.name
}

########################
# Launch Templates
########################

# Common user-data parts rendered via templatefile for readability
locals {
  kubeadm_token = var.kubeadm_token
  pod_cidr      = "10.244.0.0/16"
}

# CONTROL PLANE LT
resource "aws_launch_template" "cp_lt" {
  name_prefix   = "k8s-cp-"
  image_id      = var.ami_id
  instance_type = var.cp_instance_type
  key_name      = var.key_name

  iam_instance_profile {
    name = aws_iam_instance_profile.ec2_profile.name
  }

  vpc_security_group_ids = [aws_security_group.k8s_nodes.id]

  user_data = base64encode(templatefile("${path.module}/userdata-controlplane.sh.tpl", {
    kubeadm_token = local.kubeadm_token
    pod_cidr      = local.pod_cidr
    region        = var.region
    PRIVATE_IP    = "$(hostname -I | awk '{print $1}')"
  }))

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name       = "k8s-control-plane"
      k8s-role   = "control-plane"
      k8s-cluster= "demo"
    }
  }
}

# WORKER LT
resource "aws_launch_template" "wk_lt" {
  name_prefix   = "k8s-wk-"
  image_id      = var.ami_id
  instance_type = var.dp_instance_type
  key_name      = var.key_name

  iam_instance_profile {
    name = aws_iam_instance_profile.ec2_profile.name
  }

  vpc_security_group_ids = [aws_security_group.k8s_nodes.id]

  user_data = base64encode(templatefile("${path.module}/userdata-worker.sh.tpl", {
    kubeadm_token = local.kubeadm_token
    region        = var.region
    CP_IP         = "$(aws ec2 describe-instances --region \"${var.region}\" --filters \"Name=tag:k8s-role,Values=control-plane\" \"Name=instance-state-name,Values=running\" --query \"Reservations[].Instances[].PrivateIpAddress\" --output text | head -n1)"
  }))

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name       = "k8s-worker"
      k8s-role   = "worker"
      k8s-cluster= "demo"
    }
  }
}

########################
# Auto Scaling Groups
########################

resource "aws_autoscaling_group" "cp_asg" {
  name                      = "k8s-cp-asg"
  min_size                  = 0
  max_size                  = 2
  desired_capacity          = 1
  vpc_zone_identifier       = [aws_subnet.public_a.id]
  health_check_type         = "EC2"
  health_check_grace_period = 300

  launch_template {
    id      = aws_launch_template.cp_lt.id
    version = "$Latest"
  }

  tag {
    key                 = "k8s-asg"
    value               = "control-plane"
    propagate_at_launch = true
  }
}

resource "aws_autoscaling_group" "wk_asg" {
  name                      = "k8s-wk-asg"
  min_size                  = 1
  max_size                  = 2
  desired_capacity          = 1
  vpc_zone_identifier       = [aws_subnet.public_a.id]
  health_check_type         = "EC2"
  health_check_grace_period = 300

  launch_template {
    id      = aws_launch_template.wk_lt.id
    version = "$Latest"
  }

  tag {
    key                 = "k8s-asg"
    value               = "worker"
    propagate_at_launch = true
  }
}

########################
# Outputs
########################

output "control_plane_asg" {
  value = aws_autoscaling_group.cp_asg.name
}

output "worker_asg" {
  value = aws_autoscaling_group.wk_asg.name
}

