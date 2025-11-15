variable "region" {
  type    = string
  default = "us-west-2"
}

variable "cluster_name" {
  type    = string
  default = "auto-mode-lab"
}

variable "repository_name" {
  type    = string
  default = "secure-demo"
}

variable "signing_profile_name" {
  type    = string
  default = "ekssecureworkloads"
}
