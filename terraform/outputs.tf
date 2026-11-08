output "instance_id" {
  value = aws_instance.homelab.id
}

output "public_ip" {
  value = aws_instance.homelab.public_ip
}

output "private_ip" {
  value = aws_instance.homelab.private_ip
}

output "availability_zone" {
  value = aws_instance.homelab.availability_zone
}

output "data_volume_id" {
  value = aws_ebs_volume.data.id
}
