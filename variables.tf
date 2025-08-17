variable "region" {
  type    = string
  default = "us-east-1"
}

variable "cp_instance_type" {
  type    = string
  default = "t3.medium"
}

variable "dp_instance_type" {
  type    = string
  default = "t3.medium"
}

variable "ami_id" {
  description = "AMI ID for the EC2 instance"
  type        = string
  # Use Any Preferred AMI ID
  default     = "ami-***"
}

variable "key_name" {
  description = "EC2 key pair name for SSH"
  type        = string
}

# Demo-only: fixed kubeadm token (must match ^[a-z0-9]{6}\.[a-z0-9]{16}$)
variable "kubeadm_token" {
  type        = string
  description = "Bootstrap token used by kubeadm"
  default     = "abcdef.0123456789abcdef"
  sensitive   = true
}

