terraform {
  backend "s3" {}
  required_version = ">= 0.14.0"
  required_providers {
    aws = ">=2.16.0"
  }
}

provider "aws" {
  region = var.env.region
}

provider "aws" {
  alias = "virginia"
  region = "us-east-1"
}

locals {
  identifier_short = format("%s-${var.role}", var.tags.environment)
}


data "aws_iam_policy" "drt_policy" {
  name = var.drt_policy
}

# Create SRT IAM role
resource "aws_iam_role" "drt_role" {
  name = "${local.identifier_short}-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "drt.shield.amazonaws.com"
        }
      },
    ]
  })

  tags = merge( var.tags, tomap({ "Name" = format("%s-iam-role", local.identifier_short) }) )
}

#Attach policy for SRT access
resource "aws_iam_role_policy_attachment" "srt" {
  role       = aws_iam_role.drt_role.name
  policy_arn = data.aws_iam_policy.drt_policy.arn
}

# Associate drt role to shield 
resource "null_resource" "associate_drt_role" {
  triggers = {
    drt_role_arn = aws_iam_role.drt_role.arn
  }

  provisioner "local-exec" {
    command = "aws shield associate-drt-role --role-arn ${aws_iam_role.drt_role.arn}"
  }
}

resource "aws_shield_protection_group" "group_eip" {
  protection_group_id = "${var.tags.Name}-${var.role}-eip-grp"
  aggregation         = "SUM"
  pattern             = "BY_RESOURCE_TYPE"
  resource_type       = "ELASTIC_IP_ALLOCATION"

  tags = merge( var.tags, tomap({ "Name" = format("%s-eip-grp", local.identifier_short) }) )
}

resource "aws_shield_protection_group" "group_alb" {
  protection_group_id = "${var.tags.Name}-${var.role}-alb-grp"
  aggregation         = "MEAN"
  pattern             = "BY_RESOURCE_TYPE"
  resource_type       = "APPLICATION_LOAD_BALANCER"

  tags = merge( var.tags, tomap({ "Name" = format("%s-alb-grp", local.identifier_short) }) )
}

resource "aws_shield_protection_group" "group_r53" {
  protection_group_id = "${var.tags.Name}-${var.role}-r53-grp"
  aggregation         = "SUM"
  pattern             = "BY_RESOURCE_TYPE"
  resource_type       = "ROUTE_53_HOSTED_ZONE"

  tags = merge( var.tags, tomap({ "Name" = format("%s-r53-grp", local.identifier_short) }) )
}

resource "aws_shield_protection_group" "group_cfd" {
  protection_group_id = "${var.tags.Name}-${var.role}-cfd-grp"
  aggregation         = "MAX"
  pattern             = "BY_RESOURCE_TYPE"
  resource_type       = "CLOUDFRONT_DISTRIBUTION"

  tags = merge( var.tags, tomap({ "Name" = format("%s-cfd-grp", local.identifier_short) }) )
}


//--------------WAFv2------------------
/*
data "terraform_remote_state" "network" {
  backend = "s3"
  config = {
    bucket = "prsn-terraform-state-${var.env.region}-${var.env.account_id}"
    key    = "vpc/terraform.tfstate"
    region = var.env.region
  }
}
*/

data "aws_wafv2_rule_group" "cf_rule_group" {
  name     = "PCMSanctionsRuleGroupCloudFront"
  scope    = "CLOUDFRONT"
  provider =  aws.virginia
}

//GLOBAL waf for CloudFront
resource "aws_wafv2_web_acl" "waf_wacl_Global" {
  provider    =  aws.virginia
  name        = "${var.tags.environment}-acl-global"
  description = "WAFv2 CloudFront ACL for ${var.tags.Name}"
  scope       = "CLOUDFRONT"

  tags = merge( var.tags, tomap({ "Name" = format("%s-waf-acl-global", var.tags.environment) }) )

  default_action {
      dynamic "allow" {
        for_each = var.default_action == "allow" ? [1] : []
        content {}
      }

      dynamic "block" {
        for_each = var.default_action == "block" ? [1] : []
        content {}
      }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    sampled_requests_enabled   = true
    metric_name                = "${var.tags.environment}-cloudfront"
  }

  dynamic "rule" {
    for_each = var.managed_rules
    content {
        name     = rule.value.name
        priority = rule.value.priority

        override_action {
          dynamic "none" {
            for_each = rule.value.override_action == "none" ? [1] : []
            content {}
          }

          dynamic "count" {
            for_each = rule.value.override_action == "count" ? [1] : []
            content {}
          }
        }

        statement {
          managed_rule_group_statement {
            name        = rule.value.name
            vendor_name = "AWS"

            dynamic "rule_action_override" {
              for_each = rule.value.excluded_rules
              content {
                name = rule_action_override.value
                action_to_use {
                  count {}
                }
              }
            }
          }
        }

        visibility_config {
          cloudwatch_metrics_enabled = true
          sampled_requests_enabled   = true
          metric_name                = rule.value.name
        }

    }
  }

  dynamic "rule" {
    for_each = var.group_rules
    content {
        name     = rule.value.name
        priority = rule.value.priority

        override_action {
          dynamic "none" {
            for_each = rule.value.override_action == "none" ? [1] : []
            content {}
          }

          dynamic "count" {
            for_each = rule.value.override_action == "count" ? [1] : []
            content {}
          }
        }

        statement {
          rule_group_reference_statement {
            arn = rule.value.arn_cf

            dynamic "excluded_rule" {
              for_each = rule.value.excluded_rules
              content {
                name = excluded_rule.value
              }
            }
          }
        }

        visibility_config {
          cloudwatch_metrics_enabled = true
          sampled_requests_enabled   = true
          metric_name                = rule.value.name
        }
    }
  }

  rule {
        name     = "${var.tags.Name}-DDoS-rule"
        priority = 2
        action {
            block {}
        }
        statement {
            rate_based_statement {
              limit = var.ip-limit
              aggregate_key_type = "IP"
            }
        }
        visibility_config {
          cloudwatch_metrics_enabled = true
          sampled_requests_enabled   = true
          metric_name                = "${var.tags.Name}-DDoS-rule"
        }
    }

  rule {
    name     = "PCMSanctionsRuleGroupCloudFront"
    priority = 1

    override_action {
      none {}
    }

    statement {
      rule_group_reference_statement {
        arn = data.aws_wafv2_rule_group.cf_rule_group.arn
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      sampled_requests_enabled   = true
      metric_name                = "CF_Rule_Group"
    }
  }

  lifecycle {
    ignore_changes = [tags]
  }

}

data "aws_wafv2_rule_group" "regional" {
  name  = "PCMSanctionsRuleGroupRegional"
  scope = "REGIONAL"
}

//Regional waf for ALBs
resource "aws_wafv2_web_acl" "waf_wacl_regional" {
  name        = "${var.tags.environment}-acl-regional"
  description = "WAFv2 Regional ACL for ${var.tags.Name}"
  scope       = "REGIONAL"

  tags = merge( var.tags, tomap({ "Name" = format("%s-waf-acl-regional", var.tags.environment) }) )

  default_action {
      dynamic "allow" {
        for_each = var.default_action == "allow" ? [1] : []
        content {}
      }

      dynamic "block" {
        for_each = var.default_action == "block" ? [1] : []
        content {}
      }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    sampled_requests_enabled   = true
    metric_name                = "${var.tags.environment}-regional"
  }

  dynamic "rule" {
    for_each = var.managed_rules
    content {
        name     = rule.value.name
        priority = rule.value.priority

        override_action {
          dynamic "none" {
            for_each = rule.value.override_action == "none" ? [1] : []
            content {}
          }

          dynamic "count" {
            for_each = rule.value.override_action == "count" ? [1] : []
            content {}
          }
        }

        statement {
          managed_rule_group_statement {
            name        = rule.value.name
            vendor_name = "AWS"

            dynamic "rule_action_override" {
              for_each = rule.value.excluded_rules
              content {
                name = rule_action_override.value
                action_to_use {
                  count {}
                }
              }
            }
          }
        }

        visibility_config {
          cloudwatch_metrics_enabled = true
          sampled_requests_enabled   = true
          metric_name                = rule.value.name
        }

    }
  }

  dynamic "rule" {
    for_each = var.group_rules
    content {
        name     = rule.value.name
        priority = rule.value.priority

        override_action {
          dynamic "none" {
            for_each = rule.value.override_action == "none" ? [1] : []
            content {}
          }

          dynamic "count" {
            for_each = rule.value.override_action == "count" ? [1] : []
            content {}
          }
        }

        statement {
          rule_group_reference_statement {
            arn = rule.value.arn_regional

            dynamic "excluded_rule" {
              for_each = rule.value.excluded_rules
              content {
                name = excluded_rule.value
              }
            }
          }
        }

        visibility_config {
          cloudwatch_metrics_enabled = true
          sampled_requests_enabled   = true
          metric_name                = rule.value.name
        }
    }
  }

  rule {
    name     = "${var.tags.Name}-DDoS-rule"
    priority = 2
    action {
      block {}
    }
    statement {
      rate_based_statement {
        limit = var.ip-limit
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      sampled_requests_enabled   = true
      metric_name                = "${var.tags.Name}-DDoS-rule"
    }
  }

  rule {
    name     = "PCMSanctionsRuleGroupRegional"
    priority = 1

    override_action {
      none {}
    }

    statement {
      rule_group_reference_statement {
        arn = data.aws_wafv2_rule_group.regional.arn
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      sampled_requests_enabled   = true
      metric_name                = "<Regional_Restriction_Group>"
    }
  }

  lifecycle {
    ignore_changes = [tags]
  }
}
