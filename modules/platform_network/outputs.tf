output "vpc_id" {
  value = data.aws_vpc.main.id
}

output "vpc_cidr_block" {
  value = data.aws_vpc.main.cidr_block
}


output "main_private_subnets" {
  value = data.aws_subnet.main_private
}

output "main_public_subnets" {
  value = data.aws_subnet.main_public
}
