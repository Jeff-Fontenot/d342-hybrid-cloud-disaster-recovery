variable "project_name" {
  type        = string
  default     = "d342-hybrid-dr"
  description = "Name prefix for resources."
}

variable "aws_region" {
  type        = string
  default     = "us-east-2"
  description = "AWS region for DR resources."
}

variable "key_name" {
  type        = string
  description = "Existing EC2 key pair name."
}

variable "my_ip_cidr" {
  type        = string
  description = "Your public IP in CIDR form, e.g. 68.105.54.85/32"
}

variable "instance_type" {
  type        = string
  default     = "t3.micro"
  description = "EC2 instance type for DR node."
}

variable "backup_bucket_name" {
  type        = string
  description = "Pre-existing S3 bucket containing backups."
}

variable "backup_prefix" {
  type        = string
  default     = "backups/"
  description = "S3 prefix where backups are stored."
}