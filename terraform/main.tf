data "aws_vpc" "default" {
  default = true
}

data "aws_subnet" "this" {
  id = var.subnet_id
}

data "aws_key_pair" "homelab" {
  key_name = var.key_name
}

resource "aws_security_group" "node" {
  name        = "launch-wizard-4"
  description = "launch-wizard-4 created 2026-10-29T07:36:41.786Z"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 30076
    to_port     = 30076
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 30078
    to_port     = 30078
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 30079
    to_port     = 30079
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 30080
    to_port     = 30080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 30081
    to_port     = 30081
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 30096
    to_port     = 30096
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "SG_cloud-native-homelab"
  }
}

resource "aws_instance" "homelab" {
  ami                    = var.ami_id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [aws_security_group.node.id]
  key_name               = data.aws_key_pair.homelab.key_name
  ebs_optimized          = true
  user_data              = file("${path.module}/../bootstrap/cloud-init.yaml")

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  root_block_device {
    volume_size           = 25
    volume_type           = "gp3"
    delete_on_termination = true
    encrypted             = false
  }

  tags = {
    Name        = var.instance_name
    Project     = "cloud-native-homelab"
    Environment = "prod"
    ManagedBy   = "terraform"
    Owner       = var.owner
  }

  lifecycle {
    ignore_changes = [user_data]
  }
}

resource "aws_ebs_volume" "data" {
  availability_zone = var.availability_zone
  size              = 10
  type              = "gp3"
  iops              = 3000
  throughput        = 125
  encrypted         = false

  tags = {
    Name        = "cnh-data"
    Project     = "cloud-native-homelab"
    Environment = "prod"
    ManagedBy   = "terraform"
    Owner       = var.owner
  }
}

resource "aws_volume_attachment" "data" {
  device_name = "/dev/sdd"
  volume_id   = aws_ebs_volume.data.id
  instance_id = aws_instance.homelab.id
}

