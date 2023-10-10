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

locals {
  identifier_short = format("%s-${var.role}", var.tags.environment)
}

data "aws_dynamodb_table" "confd" {
  name = "${var.tags.environment}-dynamodb"
}


data "aws_wafv2_web_acl" "waf_wacl_regional" {
  name  = "${var.tags.environment}-acl-regional"
  scope = "REGIONAL"
}

data "terraform_remote_state" "vpc" {
  backend = "s3"
  config = {
    bucket = var.env.tf_state_s3_bucket
    key    = "${var.s3_tf_vpc_bucket}/vpc/terraform.tfstate"
    region = var.env.region
  }
}

data "aws_security_group" "db" {
  name = "${var.tags.environment}-rds-sg"
}

// getting db security group from rds remote state
data "terraform_remote_state" "rds" {
  backend = "s3"
  config = {
    bucket = var.env.tf_state_s3_bucket
    key    = "${var.tags.environment}/rds/terraform.tfstate"
    region = var.env.region
  }
}

//cloudwatch log group
resource "aws_cloudwatch_log_group" "app_log" {
  name = "/${var.tags.environment}/app"

  retention_in_days = local.app.retention_in_days

  lifecycle {
    prevent_destroy = false
  }

  tags = merge( var.tags, tomap({ "Name" = format("%s-log-group", local.identifier_short) }) )
}

data "template_file" "logging_policy" {
  template = file("${path.module}/templates/logging_policy.json")

  vars = {
    region         = var.env.region
    environment    = var.tags.environment
    log_group_name = var.app.log_group_name
  }
}

resource "aws_iam_policy" "logging" {
  name        = "${local.identifier_short}-logging"
  description = "Allows logging of events for ${var.tags.environment}"
  policy      = data.template_file.logging_policy.rendered
}

// ======== Create security group =====
resource "aws_security_group" "app" {
  name                    = "${local.identifier_short}-sg"
  description             = "APP security group for environment ${var.tags.environment}"
	vpc_id      						= data.terraform_remote_state.vpc.outputs.vpc.id

  lifecycle {
    create_before_destroy = false
  }

  tags = merge( var.tags, tomap({ "Name" = format("%s-sg", local.identifier_short) }) )
}

resource "aws_security_group_rule" "app_allow_all_out" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = -1
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.app.id
}

resource "aws_security_group" "alb" {
  name         = "${local.identifier_short}-alb-sg"
  description  = "ALB security group for environment ${var.tags.environment}"
  vpc_id       = data.terraform_remote_state.vpc.outputs.vpc.id

  lifecycle {
    create_before_destroy = false
  }

  tags = merge( var.tags, tomap({ "Name" = format("%s-alb-sg", local.identifier_short) }) )
}

resource "aws_security_group_rule" "alb_egress" {
  type = "egress"
  from_port = 0
  to_port = 0
  protocol = -1
  cidr_blocks = ["0.0.0.0/0"]
  security_group_id = aws_security_group.alb.id
}

resource "aws_security_group_rule" "allow_http" {
  type              = "ingress"
  protocol          = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_blocks       = var.internal_ingress_cidr // any list of internal ingress rules that needs to be applied
  security_group_id = aws_security_group.alb.id
}

resource "aws_security_group_rule" "allow_https" {
  type              = "ingress"
  protocol          = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_blocks       = var.internal_ingress_cidr // any list of internal ingress rules that needs to be applied
  security_group_id = aws_security_group.alb.id
}

resource "aws_security_group_rule" "allow_alb_to_task" {
  type                     = "ingress"
  protocol                 = -1
  from_port                = 0
  to_port                  = 0
  source_security_group_id = aws_security_group.alb.id
  security_group_id        = aws_security_group.app.id
  depends_on               = [aws_security_group.app, aws_security_group.alb]
  description = "Allow ALB traffic to Fargate"
}

resource "aws_security_group_rule" "allow_task_to_db" {
  type                     = "ingress"
  protocol                 = -1
  from_port                = 3306
  to_port                  = 3306
  source_security_group_id = aws_security_group.app.id
  security_group_id        = data.aws_security_group.db.id
  depends_on               = [aws_security_group.app, aws_security_group.alb]
  description              = "Allow ALB traffic to Fargate"
}


// ======== Create Target Group ========
resource "aws_alb_target_group" "app_tg" {
  name                 = "${local.identifier_short}-tg"
  port                 = 8080
  protocol             = "HTTP"
  deregistration_delay = 60
  vpc_id      				 = data.terraform_remote_state.vpc.outputs.vpc.id
	target_type          = "ip"

  stickiness {
    type            = "lb_cookie"
    cookie_duration = local.app.lb_cookie_duration
    enabled         = local.app.lb_cookie_enabled
  }

  tags = merge(
    var.tags,
    tomap( {"Name"         = format("%s-tg", local.identifier_short)} ),
    tomap( {"service-name" = format("%s-target-group", local.identifier_short)} ),
    tomap( {"service-type" = "target-group"} )
  )

  health_check {
    path                = local.app.lb_health_check_path
    unhealthy_threshold = local.app.lb_unhealthy_threshold
    healthy_threshold   = local.app.lb_healthy_threshold
    interval            = local.app.lb_interval
    timeout             = local.app.lb_timeout
  }
}

// ========  Create load balancer for app ========
resource "aws_lb" "app_lb" {
  name            = "${local.identifier_short}-lb"
  security_groups = [aws_security_group.alb.id]
  subnets         = data.terraform_remote_state.vpc.outputs.public_subnets.id
  idle_timeout    = local.app.lb_idle_timeout
  internal        = local.app.lb_scheme_internal

  access_logs {
    bucket  = local.app.lb_access_logs
		prefix  = local.identifier_short
    enabled = local.app.lb_logs_enabled
  }

  tags = merge( var.tags, tomap({ "Name" = format("%s-lb", local.identifier_short) }) )
}

// ========== Add LB to shield ==========
resource  "aws_shield_protection" "app_alb_shield"{
  name         = "${local.identifier_short}-alb-shield"
  resource_arn = aws_lb.app_lb.arn

  tags         = merge( var.tags, tomap({ "Name" = format("%s-alb-shield", local.identifier_short) }) )
}

// ========== Associate LB to WAF2 regional web ACL ==========
resource "aws_wafv2_web_acl_association" "app_alb_assoc" {
  resource_arn = aws_lb.app_lb.arn
  web_acl_arn  = data.aws_wafv2_web_acl.waf_wacl_regional.arn
}

// ======== Create ALB Listener Rules ========
resource "aws_alb_listener" "http" {
  load_balancer_arn = aws_lb.app_lb.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    target_group_arn = aws_alb_target_group.app_tg.arn
    type             = "forward"
  }
}

data "aws_acm_certificate" "current" {
  domain      = var.env.route53_zone
  types       = ["IMPORTED"]
  most_recent = true
}

resource "aws_alb_listener" "ssl" {
  load_balancer_arn = aws_lb.app_lb.arn
  port              = "443"
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS-1-2-2017-01"
  certificate_arn   = data.aws_acm_certificate.current.arn

  default_action {
    target_group_arn = aws_alb_target_group.app_tg.arn
    type             = "forward"
  }
}

/*==== s3 service policy =====*/
data "template_file" "s3_template" {
  template = file("${path.module}/policies/s3-policy.json")

  vars = {
    s3_app_bucket_name  = var.cf_s3_bucket
  }
}

resource "aws_iam_policy" "s3_policy" {
  name        = "${local.identifier_short}-s3-policy"
  description = "Allows to access to s3"
  policy      = data.template_file.s3_template.rendered
}

resource "aws_iam_role_policy_attachment" "s3_attachment" {
  role       = aws_iam_role.ecs_task_execution_role.id
  policy_arn = aws_iam_policy.s3_policy.arn
}

// ======== Create ECS Service ========
resource "aws_ecs_service" "app_service" {
  depends_on = [
    aws_alb_listener.http,
    aws_alb_listener.ssl,
  ]
  name                               = var.app.container_name
  cluster                            = var.tags.environment
  task_definition                    = aws_ecs_task_definition.app_td.arn
  desired_count                      = local.app.service_autoscaling_desired
  health_check_grace_period_seconds  = local.app.health_check_grace_period_seconds
  deployment_maximum_percent         = local.app.deployment_maximum_percent
  deployment_minimum_healthy_percent = local.app.deployment_minimum_healthy_percent
  enable_execute_command             = local.app.enable_execute_command
	propagate_tags                     = "SERVICE"

  wait_for_steady_state = false

	capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
    weight            = local.app.capacity_provider_fargatespot_weight
    base              = local.app.capacity_provider_fargatespot_base
  }
  capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = local.app.capacity_provider_fargate_weight
    base              = local.app.capacity_provider_fargate_base
  }

  network_configuration {
    security_groups = [aws_security_group.app.id]
    subnets = data.terraform_remote_state.vpc.outputs.private_subnets.id
  }

  load_balancer {
    target_group_arn = aws_alb_target_group.app_tg.arn
    container_name   = var.app.container_name
    container_port   = local.app.container_port
  }


}

// ======== Template used to create task definition ========
data "template_file" "app_tmpl" {
  template = file("${path.module}/templates/task_definition_splunk.json")

  vars = {
    environment                      = "${var.tags.environment}"
    region                           = var.env.region
    network_mode                     = local.app.network_mode
    container_name                   = "app-service"
    app_image                        = "${var.env.aws_account}.dkr.ecr.${var.env.region}.amazonaws.com/${local.app.app_repo_name}:${var.app_image_version}"
    app_cpu                          = local.app.app_cpu
    host_port                        = local.app.host_port
    container_port                   = local.app.container_port
    cw_log_stream                    = local.app.app_suffix
    app_suffix                       = "app"
	  cw_log_group                     = "/${var.tags.environment}/app"
		app_memory                       = local.app.app_memory
    add_java_opts                    = local.app.add_java_opts
    secrets_provider_image           = "${var.env.aws_account}.dkr.ecr.${var.env.region}.amazonaws.com/css/secrets-provider:${var.secrets_provider_image_version}"
    splunk_url                       = var.splunk.url
    splunk_token                     = var.splunk.token
    splunk_sourcetype                = local.app.app_suffix
    splunk_source                    = "/${var.tags.environment}/${var.app.log_group_name}"
    splunk_index                     = var.splunk.index
  }
}


// ======== Create task definition ========
// when task_cpu/task_memory not provided by the user and if ecs_launch_type=fargate defaults to 2048/6144 else get the values from the external data source above.
resource "aws_ecs_task_definition" "app_td" {
  family                = "${local.identifier_short}"
  container_definitions = data.template_file.app_tmpl.rendered
  network_mode          = local.app.network_mode
  execution_role_arn    = aws_iam_role.ecs_task_execution_role.arn
  task_role_arn         = aws_iam_role.ecs_task_execution_role.arn
	cpu                   = local.app.task_cpu
  memory                = local.app.task_memory

  tags = merge( var.tags, tomap({ "Name" = format("%s-taskdef", local.identifier_short) }) )

  requires_compatibilities = [ upper(var.ecs_launch_type) ]

  volume {
    name = "${local.identifier_short}-volume"
  }


}

	// ======== Enable ECS service Autoscaling ========
	resource "aws_appautoscaling_target" "app_autoscaling_service" {
	  max_capacity       = local.app.service_autoscaling_max
	  min_capacity       = local.app.service_autoscaling_min
	  resource_id        = "service/${var.tags.environment}/${aws_ecs_service.app_service.name}"
//	  role_arn = data.aws_iam_role.app_autoscaling_iam_role.arn
	  scalable_dimension = "ecs:service:DesiredCount"
	  service_namespace  = "ecs"
	}

	resource "aws_appautoscaling_policy" "scale_up" {
	  name                = "${local.identifier_short}-scale-up"
	  resource_id         = "service/${var.tags.environment}/${aws_ecs_service.app_service.name}"
	  scalable_dimension  = "ecs:service:DesiredCount"
	  service_namespace   = "ecs"

	  step_scaling_policy_configuration {
	    adjustment_type         = "ChangeInCapacity"
	    cooldown                = 120
	    metric_aggregation_type = "Average"

	    step_adjustment {
	      metric_interval_lower_bound = 0
	      scaling_adjustment          = 1
	    }
	  }

	  depends_on = [aws_appautoscaling_target.app_autoscaling_service]
	}

	resource "aws_appautoscaling_policy" "scale_down" {
	  name                = "${local.identifier_short}-scale-down"
	  resource_id         = "service/${var.tags.environment}/${aws_ecs_service.app_service.name}"
	  scalable_dimension  = "ecs:service:DesiredCount"
	  service_namespace   = "ecs"

	  step_scaling_policy_configuration {
	    adjustment_type         = "ChangeInCapacity"
	    cooldown                = 120
	    metric_aggregation_type = "Average"

	    step_adjustment {
	        metric_interval_upper_bound = 0
	        metric_interval_lower_bound = ""
	        scaling_adjustment          = -1
	    }
	  }

	  depends_on = [aws_appautoscaling_target.app_autoscaling_service]
	}

	// ======== Create Cloud Watch Alarms ========
	resource "aws_cloudwatch_metric_alarm" "app_cw_ma" {
	  actions_enabled     = true
	  alarm_actions       = [aws_appautoscaling_policy.scale_up.arn]
	  alarm_description   = "${var.tags.environment} App-tier scale up"
	  alarm_name          = "${local.identifier_short}-scaleup"
	  comparison_operator = "GreaterThanOrEqualToThreshold"

	  dimensions = {
	    "ClusterName" = var.tags.environment
	    "ServiceName" = aws_ecs_service.app_service.name
	  }

	  evaluation_periods = "3"
	  metric_name = "CPUUtilization"
	  namespace = "AWS/ECS"
	  period = "60"
	  statistic = "Average"
	  threshold = "80"
	}

	resource "aws_cloudwatch_metric_alarm" "app_cw_down" {
	  actions_enabled     = true
	  alarm_actions       = [aws_appautoscaling_policy.scale_down.arn]
	  alarm_description   = "${var.tags.environment} App-tier scale down"
	  alarm_name          = "${local.identifier_short}-scaledown"
	  comparison_operator = "LessThanOrEqualToThreshold"

	  dimensions = {
	    "ClusterName" = var.tags.environment
	    "ServiceName" = aws_ecs_service.app_service.name
	  }

	  evaluation_periods = "3"
	  metric_name = "CPUUtilization"
	  namespace   = "AWS/ECS"
	  period      = "60"
	  statistic   = "Average"
	  threshold   = "30"
	}

	// Role that the Amazon ECS container agent and the Docker daemon can assume
resource "aws_iam_role" "ecs_task_execution_role" {
  name               = "${local.identifier_short}-TaskExecutionRole"
  assume_role_policy = file("${path.module}/policies/ecs-task-execution-role.json")
}
resource "aws_iam_role_policy" "ecs_execution_role_policy" {
  name   = "${local.identifier_short}-ExecutionRolePolicy"
  policy = file("${path.module}/policies/ecs-execution-role-policy.json")
  role   = aws_iam_role.ecs_task_execution_role.id
}

// Iam policy provides access to dynamoDB.
data "template_file" "dynamoDB_template" {
  template = file("${path.module}/policies/dynamodb-policy.json")

  vars = {
    region      = var.env.region
		account_id  = var.env.aws_account
    environment = var.tags.environment
  }
}

resource "aws_iam_policy" "dynamoDB_policy" {
  name        = "${var.tags.environment}-dynamoDB"
  description = "Allows access to dynamoDB"
  policy      = data.template_file.dynamoDB_template.rendered
}

resource "aws_iam_role_policy_attachment" "dynamoDB_attachment" {
  role       = aws_iam_role.ecs_task_execution_role.id
  policy_arn = aws_iam_policy.dynamoDB_policy.arn
}
