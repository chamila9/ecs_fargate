output "vpc" {
  value = {
    id : aws_vpc.vpc.id
    arn : aws_vpc.vpc.arn
    enable_dns_support : aws_vpc.vpc.enable_dns_support
    enable_dns_hostnames : aws_vpc.vpc.enable_dns_hostnames
    ipv4_cidr_block : aws_vpc.vpc.cidr_block
    ipv6_cidr_block : aws_vpc.vpc.ipv6_cidr_block
    owner_id : aws_vpc.vpc.owner_id
    igw_id : join("", aws_internet_gateway.igw[*].id)
    eigw_id : join("", aws_egress_only_internet_gateway.eigw[*].id)
    vpgw_id : aws_vpn_gateway.vgw.id
  }
}

output "public_subnets" {
  value = {
    id : aws_subnet.public[*].id
    arn : aws_subnet.public[*].arn
    ipv4_cidr_block : aws_subnet.public[*].cidr_block
    ipv6_cidr_block : aws_subnet.public[*].ipv6_cidr_block
    availability_zone : aws_subnet.public[*].availability_zone
  }
}

output "private_subnets" {
  value = {
    id : aws_subnet.private[*].id
    arn : aws_subnet.private[*].arn
    ipv4_cidr_block : aws_subnet.private[*].cidr_block
    ipv6_cidr_block : aws_subnet.private[*].ipv6_cidr_block
    availability_zone : aws_subnet.private[*].availability_zone
  }
}

output "nat_gateways" {
  value = {
    id : aws_nat_gateway.nat[*].id
    public_ip : aws_nat_gateway.nat[*].public_ip
  }
}

output "s3_vpc_endpoint" {
  value = {
    id : aws_vpc_endpoint.s3.id
    prefix_list_id : aws_vpc_endpoint.s3.prefix_list_id
  }
}

output "dynamodb_vpc_endpoint" {
  value = {
    id : aws_vpc_endpoint.dynamodb.id
    prefix_list_id : aws_vpc_endpoint.dynamodb.prefix_list_id
  }
}
