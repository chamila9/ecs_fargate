terraform {
  backend "s3" {}
}

provider "aws" {
  region = var.env.region
}

locals  {
  identifier_short = format("%s-%s-${var.role}", var.tags["Name"], var.tags.environment)
}


resource "aws_kms_key" "execmd" {
  description             = "KMS key for execute command ${var.tags.Name}-${var.tags.environment}"
  key_usage               = "ENCRYPT_DECRYPT"
  deletion_window_in_days = var.ecs.kms_key_deletion_window_in_days
  is_enabled              = true
  enable_key_rotation     = var.ecs.kms_key_enable_key_rotation

  tags = merge( var.tags, tomap({ "Name" = format("%s-kms-execmd", local.identifier_short) }) )
}

//cloudwatch log group
resource "aws_cloudwatch_log_group" "execmd_log" {
  name = "/${var.tags.environment}/execmd-logs"
  retention_in_days = var.ecs.retention_in_days
  #kms_key_id = aws_kms_key.execmd.arn

  lifecycle {
    prevent_destroy = false
  }

  depends_on = [aws_kms_key.execmd]
}

// ECS Cluster -  one for the application
resource "aws_ecs_cluster" "ecs_cluster" {
  name = "${var.tags.Name}-${var.tags.environment}"

  //capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  setting {
    name  = "containerInsights"
    value = var.container_insights
  }

  /*
  default_capacity_provider_strategy {
    capacity_provider = local.ecs.capacity_provider
    weight            = local.ecs.weight
    base              = local.ecs.base
  }*/

  configuration {
    execute_command_configuration {
      kms_key_id = aws_kms_key.execmd.arn
      logging    = "OVERRIDE"

      log_configuration {
        cloud_watch_encryption_enabled = false
        cloud_watch_log_group_name     = aws_cloudwatch_log_group.execmd_log.name
        }
      }
    }

  tags = merge( var.tags, tomap({ "Name" = format("%s", local.identifier_short) }) )
}

resource "aws_ecs_cluster_capacity_providers" "ecs_cluster_capacity" {
  cluster_name = aws_ecs_cluster.ecs_cluster.name

  capacity_providers = ["${var.ecs.capacity_provider}"]

  default_capacity_provider_strategy {
    base              = var.ecs.base
    weight            = var.ecs.weight
    capacity_provider = "${var.ecs.capacity_provider}"
  }
}
