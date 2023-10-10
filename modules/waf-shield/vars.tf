variable role {
  default = "shield"
}

variable env {
  description = "A map of environment variables"
  type        = map
}

variable tags {
  description = "A map of tags to add to all resources"
  type        = map
}

variable drt_policy {
  default = "AWSShieldDRTAccessPolicy"
}

variable managed_rules {
  type = list(object({
    name            = string
    priority        = number
    override_action = string
    excluded_rules  = list(string)
  }))
  description = "List of Managed WAF rules."
  default = [
    {
      name            = "AWSManagedRulesKnownBadInputsRuleSet",
      priority        = 0
      override_action = "none"
      excluded_rules = [
        "Host_localhost_HEADER",
        "PROPFIND_METHOD",
        "ExploitablePaths_URIPATH"
      ]
    }
  ]
}

variable group_rules {
  type = list(object({
    name            = string
    #arn_cf          = string
    arn_regional    = string
    priority        = number
    override_action = string
    excluded_rules  = list(string)
  }))
  description = "List of WAFv2 Rule Groups."
  default     = []
}

variable default_action {
  type        = string
  description = "The action to perform if none of the rules contained in the WebACL match."
  default     = "allow"
}

variable ip-limit { default = 1000 }
