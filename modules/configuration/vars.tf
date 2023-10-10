variable env {
  type = map(string)
}

variable tags{
  type = map(string)
}

variable configuration {
  type = map(string)
  default = {
  }
}

locals {
  defaults = {
    kms_key_deletion_window_in_days = 30
    billing_mode                    = "PAY_PER_REQUEST"
    kms_key_enable_key_rotation     = "true"
  }
  configuration = merge(
    local.defaults,
    var.configuration
  )
}
