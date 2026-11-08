variable "region" {
  description = "AWS region"
  type        = string
  default     = "eu-north-1"
}

variable "instance_name" {
  description = "Name tag for the instance"
  type        = string
  default     = "cloud-native-homelab"
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "m7i-flex.large"
}

variable "ami_id" {
  description = "AMI of the existing instance"
  type        = string
  default     = "ami-021aaf3749be66813"
}

variable "subnet_id" {
  description = "Subnet of the existing instance"
  type        = string
  default     = "subnet-0f1044a9e363b59ba"
}

variable "availability_zone" {
  description = "AZ of the existing instance and data volume"
  type        = string
  default     = "eu-north-1b"
}

variable "key_name" {
  description = "Existing EC2 key pair"
  type        = string
  default     = "cloud-native-homelab"
}

variable "owner" {
  description = "Owner tag"
  type        = string
}
