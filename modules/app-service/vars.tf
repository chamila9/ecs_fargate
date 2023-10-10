variable env {
  type = map(string)
}

variable tags {
  type = map(string)
}

variable confd {
  type = map(string)
  default = {
    confd_repo_name = "confd"
    confd_image_version = "latest"
  }
}

variable role {
  type    = string
  default = "app-service"
}

variable app_image_version { default = "" }

variable secrets_provider_image_version { default = ""}

variable ecs_launch_type { default = "fargate" }

variable app {
  type    = map(string)
  default = {}
}

variable splunk {
  type = map(string)
  default = {
    token = "6909f85d-9319-40f2-acbb-21976263b698"
    index = "app_clinicalscoring"
    url   = "https://http-inputs-pearsonedu.splunkcloud.com:443/services/collector/event"
  }
}

locals {
  defaults = {
    app_suffix                           = ""
    app_repo_name                        = ""
    host_port                            = 0
    app_cpu                              = 924
    app_memory                           = 1948
    task_memory                          = 2048
    task_cpu                             = 1024
    network_mode                         = "awsvpc" // if ecs_launch_type is ec2 defaults to bridge else if fargate defaults to awsvpc.
    service_autoscaling_desired          = 1
    service_autoscaling_min              = 1
    service_autoscaling_max              = 1
    retention_in_days                    = 30
    lb_health_check_path                 = "/"
    lb_idle_timeout                      = 60
    lb_cookie_duration                   = 28800
    lb_cookie_enabled                    = true
    lb_unhealthy_threshold               = 4  // The number of consecutive health check failures required before considering a target unhealthy (2-10).
    lb_healthy_threshold                 = 2  // The number of consecutive health checks successes required before considering an unhealthy target healthy (2-10).
    lb_interval                          = 50 // The approximate amount of time between health checks of an individual target (5-300 seconds).
    lb_timeout                           = 5  // The amount of time, in seconds, during which no response means a failed health check (2-120 seconds)
    health_check_grace_period_seconds    = 120
    deployment_maximum_percent           = 200
    deployment_minimum_healthy_percent   = 100
    log_group_name                       = {}
    capacity_provider_fargatespot_weight = 0
    capacity_provider_fargatespot_base   = 0
    capacity_provider_fargate_weight     = 1
    capacity_provider_fargate_base       = 1
    container_port                       = 8080
    internal_access                      = "false"
    add_java_opts                        = "-XX:InitialRAMPercentage=75.0 -XX:MaxRAMPercentage=75.0"
    enable_execute_command               = "true"
  }
  app = merge(
    local.defaults,
    var.app
  )
}

variable internal_ingress_cidr {
  type    = list(string)
  default = []
}

variable cf_s3_bucket {
  type    = string
  default = ""
}

variable s3_tf_vpc_bucket {
  type    = string
  default = ""
}

variable shared_rds_sg {
  type    = string
  default = ""
}
