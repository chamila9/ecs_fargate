variable tags {
  type = map(string)
}

variable "env" {
  description = "A map of environment variables"
  type        = map
}

variable role {
  default = "vpc"
}

variable vpc_identifier {
  default = ""
}

variable aws_account {
  default = ""
}

variable region {
  default = ""
}

variable vpc {
  type        = map(string)
  description = "Map of options used to configure VPC attributes"
  default     = {}
}

# Configured public subnets on the "front" half of the vpc cidr block
variable public_cidrs {
  type        = list(string)
  description = "List of IPv4 CIDR blocks used for public subnets"
  default     = []
}

# Configured private subnets on the "back" half of the vpc cidr block
variable private_cidrs {
  type        = list(string)
  description = "List of IPv4 CIDR blocks used for private subnets"
  default     = []
}
