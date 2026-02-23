output "ec2_public_ip" {
  value = aws_instance.dr.public_ip
}

output "ec2_public_dns" {
  value = aws_instance.dr.public_dns
}

output "backup_bucket_verified" {
  value = data.aws_s3_bucket.backups.bucket
}