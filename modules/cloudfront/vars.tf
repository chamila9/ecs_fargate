variable env {
  type = map(string)
}

variable tags {
  type = map(string)
}

variable role {
  default = "cloudfront"
}

variable cf_s3_bucket {
  type = string
}

variable internal_ingress_cidr {
  type = list(string)
}
