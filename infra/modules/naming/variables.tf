variable "name" {
  description = "Short logical resource name, e.g. \"vpc\" or \"cp-instance\". Combined with project/env to form the physical name."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{0,30}$", var.name))
    error_message = "name must be lowercase alphanumeric/hyphen, max 31 chars."
  }
}

variable "project" {
  description = "Project identifier."
  type        = string
}

variable "env" {
  description = "Environment identifier."
  type        = string
}

variable "layer" {
  description = "Layer this resource belongs to."
  type        = string
}

variable "owner" {
  description = "Accountable owner."
  type        = string
}

variable "cost_center" {
  description = "Cost allocation value."
  type        = string
}

variable "component" {
  description = "Optional component label (vpc, alb, cluster, edge...). Omitted from tags when empty."
  type        = string
  default     = ""
}

variable "suffix" {
  description = "Optional suffix appended to the generated name (e.g. \"a\" for per-AZ resources)."
  type        = string
  default     = ""
}

variable "extra_tags" {
  description = "Additional tags merged on top of the standard tag set."
  type        = map(string)
  default     = {}
}