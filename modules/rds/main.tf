provider "aws" {
  region = var.env.region
}

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

/*data "aws_kms_key" "kms" {
  key_id = "alias/${var.tags.environment}-rds-key"
}*/

locals {
  override_remote_state = var.tags.environment == "prd" ? "${var.tags.Name}-prd" : "${var.tags.Name}-shared-non-prd"
  identifier_short = format("%s-${var.role}", var.tags.environment)
}

data "aws_kms_key" "kms" {
  key_id = "alias/${local.identifier_short}"
}

data "terraform_remote_state" "vpc" {
  backend = "s3"
  config = {
    bucket = var.env.tf_state_s3_bucket
    key    = "${local.override_remote_state}/vpc/terraform.tfstate"
    region = var.env.region
  }
}

data "aws_subnet" "s" {
  id = data.terraform_remote_state.vpc.outputs.public_subnets.id[0]
}

# data "aws_subnet" "p" {
#   id = data.terraform_remote_state.vpc.outputs.private_subnets.id[0]
# }

# Create new staging DB
resource "aws_rds_cluster_instance" "css" {
  count                   = local.rds.db_instance_count
  identifier              = "${local.rds.rds_cluster_identifier}-${count.index}"
  apply_immediately       = local.rds.apply_immediately
  engine                  = local.rds.rds_engine
  engine_version          = local.rds.engine_version
  db_subnet_group_name    = aws_db_subnet_group.db.name
  db_parameter_group_name = local.rds.param_group_name
  publicly_accessible     = "false"
  instance_class          = local.rds.instance_class
  cluster_identifier      = aws_rds_cluster.css.id
  performance_insights_enabled = var.tags.t_environment == "PRD" ? true : false
  copy_tags_to_snapshot   = "true"
  ca_cert_identifier      = "rds-ca-rsa2048-g1"

  tags = merge( var.tags, tomap({ "Name" = format("%s-instance", local.identifier_short) }) )
}


resource "aws_rds_cluster" "css" {
  cluster_identifier              = local.rds.rds_cluster_identifier
  engine                          = local.rds.rds_engine
  engine_version                  = local.rds.engine_version
  db_subnet_group_name            = aws_db_subnet_group.db.name
  apply_immediately               = "true"
  vpc_security_group_ids          = [aws_security_group.db.id]
  #final_snapshot_identifier       = "${local.rds.rds_cluster_identifier}-${formatdate("MMDDYYYY-hhmmss", timestamp())}"
  snapshot_identifier             = local.rds.snapshot_identifier
  #snapshot_identifier             = data.aws_db_snapshot.latest_snapshot.id
  skip_final_snapshot             = local.rds.skip_final_snapshot
  master_username                 = local.rds.db_master_username
  db_cluster_parameter_group_name = local.rds.cluster_param_group_name
  backup_retention_period         = local.rds.backup_retention
  preferred_maintenance_window    = local.rds.maintenance_window
  preferred_backup_window         = local.rds.backup_window
  deletion_protection             = local.rds.deletion_protection
  kms_key_id                      = data.aws_kms_key.kms.arn
  copy_tags_to_snapshot           = "true"

  lifecycle {
    ignore_changes = [snapshot_identifier]
  }

  //tags = var.tags
  tags = merge(
    var.tags,
    tomap({ "Name" = format("%s-cluster", local.identifier_short) }),
    var.tags.t_environment == "PRD" ? tomap({ t_awsbackup_default = "true" }) : var.tags
  )
}

resource "aws_db_subnet_group" "db" {
  name_prefix = "${var.tags.Name}-subnets-"
  description = "Subnet Group for CSS DB cluster ${local.rds.cluster_name} "
  subnet_ids  = [data.terraform_remote_state.vpc.outputs.private_subnets.id[0], data.terraform_remote_state.vpc.outputs.private_subnets.id[1]]

  tags        = merge( var.tags, tomap({ "Name" = format("%s-subnet-group", local.identifier_short) }) )
}

### Security Group ###
resource "aws_security_group" "db" {
  name = "${local.identifier_short}-sg"
  description = "Security Group for Aurora cluster ${local.rds.cluster_name}"
  vpc_id      = data.aws_subnet.s.vpc_id

  tags        = merge( var.tags, tomap({ "Name" = format("%s-sg", local.identifier_short) }) )
}

resource "aws_security_group_rule" "egress" {
  type      = "egress"
  from_port = local.rds.port
  to_port   = local.rds.port
  protocol  = "tcp"
  self      = true

  security_group_id = aws_security_group.db.id
}

/*data "aws_security_group" "lookup_bastion_id" {
  name = "${local.bastion_host_name}-bastion"
}

resource "aws_security_group_rule" "allow_bastion" {
  description  = "allow bastion host connection"
  type      = "ingress"
  from_port = local.rds.port
  to_port   = local.rds.port
  protocol  = "tcp"

  security_group_id = aws_security_group.db.id
  source_security_group_id = data.aws_security_group.lookup_bastion_id.id

  lifecycle {
    create_before_destroy = true
  }
}*/

resource "aws_security_group_rule" "allow_internal_ingress_cidr" {
  type              = "ingress"
  protocol          = "tcp"
  from_port = local.rds.port
  to_port   = local.rds.port
  cidr_blocks       = var.internal_ingress_cidr // any list of internal ingress rules that needs to be applied
  security_group_id = aws_security_group.db.id
}

resource "aws_security_group_rule" "ingress" {
  type      = "ingress"
  from_port = local.rds.port
  to_port   = local.rds.port
  protocol  = "tcp"
  self      = true

  security_group_id = aws_security_group.db.id


  lifecycle {
    create_before_destroy = true
  }
}

data "aws_route53_zone" "zone" {
  name         = var.env.route53_zone
}

resource "aws_route53_record" "fieldresearch-r53-readonly" {
  zone_id         = data.aws_route53_zone.zone.zone_id
  name            = var.tags.t_environment != "PRD"? "${var.role}-ro.${lower(var.tags.t_environment)}" : "${var.role}-ro"
  type            = "CNAME"
  ttl             = "300"
  allow_overwrite = "true"
  records         = [aws_rds_cluster.css.reader_endpoint]
}

resource "aws_route53_record" "fieldresearch-r53-readwrite" {
  zone_id         = data.aws_route53_zone.zone.zone_id
  name            = var.tags.t_environment != "PRD"? "${var.role}-rw.${lower(var.tags.t_environment)}" : "${var.role}-rw"
  type            = "CNAME"
  ttl             = "300"
  allow_overwrite = "true"
  records         = [aws_rds_cluster.css.endpoint]
}