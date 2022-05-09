output "vpc_id" {
  value = data.aws_vpc.main.id
}

output "main_private_subnets" {
  value = data.aws_subnet.main_private
}

output "main_public_subnets" {
  value = data.aws_subnet.main_public
}
