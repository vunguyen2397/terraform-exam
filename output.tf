output "ec2_public_ip" {
  value = contains(["dev"], terraform.workspace) ? aws_instance.dev_ec2[0].public_ip : null
}