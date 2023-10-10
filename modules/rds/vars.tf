variable "rds_cluster_identifier" {
  default = ""
}
variable "tags" {
  type = map(string)
}

# variable "subnet_ids" { type = "list" }
variable "env" {
  type = map(string)
}

variable "rds" {
  type = map(string)
}

locals {
  defaults = {
    cluster_name                 = ""
    port                         = 3306
    db_instance_count            = 1
    rds_engine                   = "aurora-mysql"
    engine_version               = "5.7.mysql_aurora.2.11.2"
    snapshot_identifier          = ""
    instance_class               = ""
    db_master_username           = "clinicalscorUser"
    cluster_param_group_name     = "default.aurora-mysql5.7"
    param_group_name             = "default.aurora-mysql5.7"
    backup_window                = "06:45-07:15"
    maintenance_window           = "sun:06:00-sun:06:30"
    backup_retention             = 30
    deletion_protection          = true
    apply_immediately            = true
    performance_insights_enabled = false
    storage_encryption_enabled   = true
    skip_final_snapshot          = true
  }
  rds = merge(
    local.defaults,
    var.rds
  )
}

variable "db_master_password" {
  default     = ""
}

variable "role" {
  default = "rds"
}

variable "dns_name" {
  default = ""
}

variable "rds_zone_id" {
  default = ""
}

variable "route53_zone_id_front" {
  default = ""
}

variable "route53_zone_id_back" {
  default = ""
}

variable "internal_ingress_cidr" {
  default = ""
}


variable "override_remote_state" {
  default = ""
}

variable "bastion_host_name" {
  default = ""
}

# variable "cluster_size" {
#   default = "1"
# }
