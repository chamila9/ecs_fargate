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

data "aws_lb" "app_alb" {
  name = "${var.tags.environment}-app-lb"
}

// ========== s3 bucket lookup ==========
data "aws_s3_bucket" "s3_cf" {
  bucket = var.cf_s3_bucket
}

# not able to get cert in region
data "aws_acm_certificate" "int" {
  domain      = var.env.route53_zone
  types       = ["IMPORTED"]
	provider    = aws.virginia
}

# // ======== Create R53 Record ========
data "aws_route53_zone" "hosted_int_zone" {
  name = var.env.route53_zone
}


data "aws_wafv2_web_acl" "waf_wacl_global" {
  name      = "${var.tags.environment}-acl-global"
  scope     = "CLOUDFRONT"
  provider  = aws.virginia
}

resource "aws_route53_record" "int_record" {

	depends_on = [aws_cloudfront_distribution.app]
  #name = "${var.cf.dns_prefix}.${var.cf.int_domain}"
  #name = var.cf.dns_prefix != "" ? "${var.cf.dns_prefix}.${var.cf.int_domain}" : var.cf.int_domain
  name       = var.tags.t_environment != "PRD"? "${lower(var.tags.t_environment)}.${var.env.route53_zone}" : "${var.env.route53_zone}"
  zone_id    = data.aws_route53_zone.hosted_int_zone.zone_id
  type       = "A"

	alias {
		name                   = aws_cloudfront_distribution.app.domain_name
		zone_id                = aws_cloudfront_distribution.app.hosted_zone_id
		evaluate_target_health = false
	}

  lifecycle {
    create_before_destroy = true
  }
}

/*
// ========== Add R53 record to shield ==========
resource  "aws_shield_protection" "r53_int_shield"{
  name         = "${var.tags.Name}-${local.app.app_suffix}-r53-int-shield"
  resource_arn = aws_route53_record.int_record.arn

  tags         = merge(var.tags, { "Name" = format("${var.tags.Name}-r53-int-shield") })
}
*/

// ========== CloudFront =================
resource "aws_cloudfront_origin_access_identity" "bo_access_id" {
  comment = "access-identity-${var.cf_s3_bucket}.s3.amazonaws.com"
}

resource "aws_cloudfront_distribution" "app" {
  depends_on  = [aws_cloudfront_origin_access_identity.bo_access_id]
  origin {
    domain_name = data.aws_lb.app_alb.dns_name
    origin_id = "UI-ELB-${var.tags.environment}"

    custom_origin_config {
      http_port                 = 80
      https_port                = 443
      origin_protocol_policy    = "http-only"
      origin_ssl_protocols      = ["TLSv1.2"]
      origin_keepalive_timeout  = 60
      origin_read_timeout       = 60
    }
  }

  origin {
    domain_name = data.aws_s3_bucket.s3_cf.bucket_domain_name
    origin_id   = "UI-S3-${var.tags.environment}"

    s3_origin_config {
      origin_access_identity = aws_cloudfront_origin_access_identity.bo_access_id.cloudfront_access_identity_path
    }
  }

  aliases    = [  var.tags.t_environment != "PRD"? "${lower(var.tags.t_environment)}.${var.env.route53_zone}" : "${var.env.route53_zone}" ]
  web_acl_id = aws_wafv2_web_acl.allow-only-ingress-cidrs.arn

	price_class         = "PriceClass_100"
	enabled             = true
  default_root_object = "index.html"

	default_cache_behavior {
		allowed_methods  = ["GET", "HEAD"]
		cached_methods   = ["GET", "HEAD"]
		target_origin_id = "UI-S3-${var.tags.environment}"

		forwarded_values {
			query_string = false

			cookies {
				forward = "none"
			}
		}

		viewer_protocol_policy = "redirect-to-https"
		min_ttl                = 0
		default_ttl            = 30
		max_ttl                = 45
	}

	ordered_cache_behavior {
    allowed_methods  = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "UI-ELB-${var.tags.environment}"

    path_pattern = "/clinicalscor/*"

    forwarded_values {
      query_string = true
      headers = ["*"]

      cookies {
        forward = "all"
      }
    }

    viewer_protocol_policy = "redirect-to-https"
    min_ttl                = 0
    default_ttl            = 86400
    max_ttl                = 31536000
  }

	restrictions {
		geo_restriction {
			restriction_type = "whitelist"
			locations        = ["US", "CA", "AU", "NL", "GB", "SE", "DK", "NO", "IN"]
		}
	}

	viewer_certificate {
		acm_certificate_arn      = data.aws_acm_certificate.int.arn
		ssl_support_method       = "sni-only"
		minimum_protocol_version = "TLSv1.2_2021"
	}

  tags = merge( var.tags, tomap({ "Name" = format("%s-cfd-app", local.identifier_short) }) )
}


data "aws_iam_policy_document" "s3_policy" {

  statement {
    actions   = ["s3:GetObject"]
    resources = ["${data.aws_s3_bucket.s3_cf.arn}/*"]

    principals {
      type        = "AWS"
      identifiers = [aws_cloudfront_origin_access_identity.bo_access_id.iam_arn]
    }
  }
}

resource "aws_s3_bucket_policy" "bucket" {
  bucket = data.aws_s3_bucket.s3_cf.id
  policy = data.aws_iam_policy_document.s3_policy.json
}


// ========== Add CFD to shield ==========
data "aws_cloudfront_distribution" "data_cfd_app" {
  id = aws_cloudfront_distribution.app.id
}

resource  "aws_shield_protection" "cfd_bo_shield"{
  name         = "${var.tags.environment}-cfd-bo-shield"
  resource_arn = data.aws_cloudfront_distribution.data_cfd_app.arn

  tags         = merge( var.tags, tomap({ "Name" = format("%s-shield", local.identifier_short) }) )
}

#------WAF2 rule to allow traffic only from internal ingress IPs to CSS UI-------
resource "aws_wafv2_ip_set" "ingress-cidrs" {
  name               = "${var.tags.environment}-${var.role}-ingress-ip-set"
  description        = "IP CIDR blocks in ingress list"
  scope              = "CLOUDFRONT"
  provider           = aws.virginia
  ip_address_version = "IPV4"
  addresses          = var.internal_ingress_cidr

  tags = merge( var.tags, tomap({ "Name" = format("%s-ingress-ip-set", local.identifier_short) }) )
}

resource "aws_wafv2_web_acl" "allow-only-ingress-cidrs" {
    name        = "${var.tags.environment}-${var.role}-acl"
    description = "WAFv2 rule to allow only traffic from defined CIDR blocks in ${var.tags.environment} CSS front-end since its Pearson internal use only"
    scope       = "CLOUDFRONT"
    provider    = aws.virginia

    default_action {
      block {}
    }

    rule {
      name      = "white-listed-cidrs"
      priority  = 1

      action {
        allow {}
      }

      statement {
        ip_set_reference_statement {
          arn = aws_wafv2_ip_set.ingress-cidrs.arn
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = var.tags.environment == "PRD" ? true : false
        metric_name                = "${var.tags.environment}-css-ui-allowed"
        sampled_requests_enabled   = var.tags.environment == "PRD" ? true : false
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = var.tags.environment == "PRD" ? true : false
      metric_name                = "${var.tags.environment}-css-ui-blocked"
      sampled_requests_enabled   = var.tags.environment == "PRD" ? true : false
    }

    tags = merge( var.tags, tomap({ "Name" = format("%s-acl", local.identifier_short) }) )
}