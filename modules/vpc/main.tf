terraform {
  backend "s3" {}
  required_version = ">= 1.5.4"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

# Reference region via datasource in case region tfvar is empty, and we're relying on env vars to configure it
data "aws_region" "current" {}

locals {
    natgw_count = length(var.public_cidrs) > 0 && length(var.private_cidrs) > 0 ? length(var.public_cidrs) : 0

    vpc = {
        cidr                 = lookup(var.vpc, "cidr", "172.16.0.0/20")
        dns_support          = lookup(var.vpc, "dns_support", true)
        dns_hostnames        = lookup(var.vpc, "dns_hostnames", true)
        enable_ipv6          = lookup(var.vpc, "enable_ipv6", false)
        vpg_asn              = lookup(var.vpc, "vpg_asn", 64523)
        vpg_naas_spoke_value = lookup(var.vpc, "vpg_naas_spoke_value", "awsu1")
    }

    identifier_short = format("%s-%s-${var.role}", var.tags["Name"], var.vpc_identifier)
}

/*
** VPC and subnets
*/

# Removing IPv6 from a subnet currently does not work
# REF: https://github.com/terraform-providers/terraform-provider-aws/issues/8515
resource "aws_vpc" "vpc" {
    cidr_block = local.vpc["cidr"]

    enable_dns_support   = local.vpc["dns_support"]
    enable_dns_hostnames = local.vpc["dns_hostnames"]
    //enable_classiclink   = false

    # An AWS-provided /56 IPv6 CIDR block (can not configure address or size)
    assign_generated_ipv6_cidr_block = local.vpc["enable_ipv6"]

    tags = merge( var.tags, tomap({ "Name" = format("%s", local.identifier_short) }) )
}

resource "aws_subnet" "public" {
    count = length(var.public_cidrs)

    vpc_id            = aws_vpc.vpc.id
    availability_zone = element(data.aws_availability_zones.available.names, count.index)
    cidr_block        = var.public_cidrs[count.index]
    # ipv6_cidr_block   = aws_vpc.vpc.assign_generated_ipv6_cidr_block ? cidrsubnet(aws_vpc.vpc.ipv6_cidr_block, 8, count.index) : ""

    map_public_ip_on_launch         = true
    assign_ipv6_address_on_creation = aws_vpc.vpc.assign_generated_ipv6_cidr_block

    tags = merge(
        var.tags,
        tomap({ "Name" = format("%s-public-subnet", local.identifier_short) }),
        tomap({ "network" = format("%s", "public") }),
        tomap({ "availability-zone" = element(data.aws_availability_zones.available.names, count.index) })
    )
}

resource "aws_subnet" "private" {
    count = length(var.private_cidrs)

    vpc_id            = aws_vpc.vpc.id
    availability_zone = element(data.aws_availability_zones.available.names, count.index)
    cidr_block        = var.private_cidrs[count.index]
    # ipv6_cidr_block   = aws_vpc.vpc.assign_generated_ipv6_cidr_block ? cidrsubnet(aws_vpc.vpc.ipv6_cidr_block, 8, count.index + 32) : ""

    assign_ipv6_address_on_creation = aws_vpc.vpc.assign_generated_ipv6_cidr_block

    tags = merge(
        var.tags,
        tomap({ "Name" = format("%s-private-subnet", local.identifier_short) }),
        tomap({ "network" = format("%s", "private") }),
        tomap({ "availability-zone" = element(data.aws_availability_zones.available.names, count.index) })
  )
}

/*
** Gateways (internet, nat, vpn, IPv6 egress-only)
*/

resource "aws_internet_gateway" "igw" {
    count  = length(aws_subnet.public) > 0 ? 1 : 0
    vpc_id = aws_vpc.vpc.id
    tags = merge( var.tags, tomap({ "Name" = format("%s-igw", local.identifier_short) }) )
}

resource "aws_egress_only_internet_gateway" "eigw" {
    count  = length(aws_subnet.private) > 0 && aws_vpc.vpc.assign_generated_ipv6_cidr_block ? 1 : 0
    vpc_id = aws_vpc.vpc.id
}

resource "aws_eip" "eip" {
    count = local.natgw_count
    //vpc   = true
    tags  = merge( var.tags, tomap({ "Name" = format("%s-eip", local.identifier_short) }) )

    depends_on = [aws_internet_gateway.igw]
}

//=============== Add NAT EIPs to Shield protection ===============
resource "aws_shield_protection" "igw_eip" {
    count        = local.natgw_count
    name         = "${var.tags.Name}-${var.role}-igw-${count.index}"
    resource_arn = "arn:aws:ec2:${var.env.region}:${var.env.aws_account}:eip-allocation/${aws_eip.eip[count.index].id}"

    tags  = merge( var.tags, tomap({"Name" = format("%s-${var.role}-igw-${count.index}-shield", local.identifier_short)}) )
}

resource "aws_nat_gateway" "nat" {
    count         = local.natgw_count
    subnet_id     = aws_subnet.public[count.index].id
    allocation_id = aws_eip.eip[count.index].id
    depends_on    = [aws_internet_gateway.igw]

    tags          = merge( var.tags, tomap({ "Name" = format("%s-natgw", local.identifier_short) }) )
}

resource "aws_vpn_gateway" "vgw" {
    vpc_id          = aws_vpc.vpc.id
    amazon_side_asn = local.vpc["vpg_asn"]

    tags = merge(
        var.tags, 
        tomap({ "Name" = format("%s-vpngw", local.identifier_short) }),
        tomap({ "naas:spoke" = local.vpc["vpg_naas_spoke_value"]})
    )
}

/*
** Route tables and default routes
*/

resource "aws_route_table" "public" {
    count  = length(aws_subnet.public) > 0 ? 1 : 0
    vpc_id = aws_vpc.vpc.id
    tags   = merge( var.tags, tomap({"Name" = format("%s-rt-public", local.identifier_short)}) )

    propagating_vgws = [aws_vpn_gateway.vgw.id]
}

resource "aws_route_table_association" "public" {
    count          = length(aws_subnet.public)
    route_table_id = aws_route_table.public[0].id
    subnet_id      = aws_subnet.public[count.index].id
}

resource "aws_route" "ipv4_default_public" {
    count          = length(aws_route_table.public)
    route_table_id = aws_route_table.public[count.index].id
    gateway_id     = aws_internet_gateway.igw[0].id

    destination_cidr_block = "0.0.0.0/0"
}

resource "aws_route" "ipv6_default_public" {
    count          = length(aws_route_table.public)
    route_table_id = aws_route_table.public[count.index].id
    gateway_id     = aws_internet_gateway.igw[0].id

    destination_ipv6_cidr_block = "::/0"
}

resource "aws_route_table" "private" {
    count  = length(aws_subnet.private)
    vpc_id = aws_vpc.vpc.id
    tags   = merge(
            var.tags,
            tomap( {"Name"              = format("%s-rt-private", local.identifier_short)} ),
            tomap( {"availability-zone" = aws_subnet.private[count.index].availability_zone} )
        )

    propagating_vgws = [aws_vpn_gateway.vgw.id]
}

resource "aws_route_table_association" "private" {
    count          = length(aws_route_table.private)
    route_table_id = aws_route_table.private[count.index].id
    subnet_id      = element(aws_subnet.private[*].id, count.index)
}

resource "aws_route" "ipv4_default_private" {
    count          = length(aws_route_table.private) > 0 && local.natgw_count > 0 ? length(aws_route_table.private) : 0
    route_table_id = aws_route_table.private[count.index].id
    nat_gateway_id = element(aws_nat_gateway.nat[*].id, count.index)

    destination_cidr_block = "0.0.0.0/0"
}

resource "aws_route" "ipv6_default_private" {
    count                  = length(aws_route_table.private) > 0 && aws_vpc.vpc.assign_generated_ipv6_cidr_block ? length(aws_route_table.private) : 0
    route_table_id         = aws_route_table.private[count.index].id
    egress_only_gateway_id = aws_egress_only_internet_gateway.eigw[0].id

    destination_ipv6_cidr_block = "::/0"
}

/*
** VPC gateway endpoints for S3 & dynamodb + route table entries
*/

resource "aws_vpc_endpoint" "s3" {
    service_name = "com.amazonaws.${data.aws_region.current.name}.s3"
    vpc_id       = aws_vpc.vpc.id
    tags         = merge( var.tags, tomap({"Name" = format("%s-s3", aws_vpc.vpc.tags["Name"])}) )
}

resource "aws_vpc_endpoint_route_table_association" "s3_public" {
    count           = length(aws_route_table.public)
    route_table_id  = aws_route_table.public[count.index].id
    vpc_endpoint_id = aws_vpc_endpoint.s3.id
}

resource "aws_vpc_endpoint_route_table_association" "s3_private" {
    count           = length(aws_route_table.private)
    route_table_id  = aws_route_table.private[count.index].id
    vpc_endpoint_id = aws_vpc_endpoint.s3.id
}

resource "aws_vpc_endpoint" "dynamodb" {
    service_name = "com.amazonaws.${data.aws_region.current.name}.dynamodb"
    vpc_id       = aws_vpc.vpc.id
    tags         = merge( var.tags, tomap({"Name" = format("%s-dynamodb", aws_vpc.vpc.tags["Name"])}) )
}

resource "aws_vpc_endpoint_route_table_association" "dynamodb_public" {
    count           = length(aws_route_table.public)
    route_table_id  = aws_route_table.public[count.index].id
    vpc_endpoint_id = aws_vpc_endpoint.dynamodb.id
}

resource "aws_vpc_endpoint_route_table_association" "dynamodb_private" {
    count           = length(aws_route_table.private)
    route_table_id  = aws_route_table.private[count.index].id
    vpc_endpoint_id = aws_vpc_endpoint.dynamodb.id
}
