variable tags {
  type = map(string)
}

variable env {
  type = map(string)
}

variable role {
  type = string
}

variable container_insights { default = "disabled"}

//The capacity provider strategy to use by default for the cluster
variable ecs {
  type = map(string)
  default = {
    capacity_provider = "FARGATE" // The short name of the capacity provider.
    weight = 100 // The relative percentage of the total number of launched tasks that should use the specified capacity provider.
    base = 1 // The number of tasks, at a minimum, to run on the specified capacity provider. Only one capacity provider in a capacity provider strategy can have a base defined.
    retention_in_days = 30
    kms_key_deletion_window_in_days = 30
    kms_key_enable_key_rotation = true
  }
}