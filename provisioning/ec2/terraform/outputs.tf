# provisioning/ec2/terraform/outputs.tf
output "control_plane_public_ip" {
  description = "Public IP of the Rack control plane (SSH)"
  value       = aws_instance.cp.public_ip
}

output "control_plane_private_ip" {
  description = "Private IP workers use as RKE2_SERVER"
  value       = aws_instance.cp.private_ip
}

output "gpu_worker_public_ips" {
  description = "Public IPs of the GPU workers"
  value       = aws_instance.gpu[*].public_ip
}

output "registry_prefix" {
  description = "ECR prefix to use with REGISTRY= in build-images.sh / deploy-cluster.sh"
  value       = replace(aws_ecr_repository.rack["rack-engine"].repository_url, "/rack-engine$", "")
}

output "rack_engine_url" {
  description = "Base URL for the API service (NodePort)"
  value       = "http://${aws_instance.cp.public_ip}:30080"
}

output "lens_url" {
  description = "Frontend URL"
  value       = "http://${aws_instance.cp.public_ip}:30081"
}