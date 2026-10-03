variable "project" {
  description = "Project identifier used in resource names and tags."
  type        = string
}

variable "env" {
  description = "Deployment environment (prod or qa)."
  type        = string

  validation {
    condition     = contains(["prod", "qa"], var.env)
    error_message = "env must be one of: prod, qa."
  }
}

variable "layer" {
  description = "This Terraform layer."
  type        = string
  default     = "50-platform"
}

variable "owner" {
  description = "Accountable owner tag value."
  type        = string
}

variable "cost_center" {
  description = "Cost allocation tag value."
  type        = string
}

variable "aws_region" {
  description = "AWS region."
  type        = string
  default     = "ap-south-1"
}

variable "extra_tags" {
  description = "Additional tags merged on top of the standard tag set."
  type        = map(string)
  default     = {}
}

variable "alb_allowed_cidrs" {
  description = "CIDR blocks allowed to reach the public ALB on 80/443. Declared in every layer because every layer root calls modules/foundation; only 40-edge consumes it."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "domain_name" {
  description = "Optional DNS name. null disables all Route 53 / ACM resources. Declared in every layer because every layer root calls modules/foundation; only 40-edge consumes it."
  type        = string
  default     = null
}

# ------------------------------------------------------- 30-cluster state ---
# 50-platform reads 30-cluster's outputs through the same S3 bucket its own state
# lives in. Passing the bucket name in rather than hardcoding it keeps the layer
# from being pinned to one account's bucket naming.
variable "state_bucket" {
  description = "S3 bucket holding every layer's remote state for this environment."
  type        = string
}

# -------------------------------------------------- platform add-on pins ---
# Calico. Manifest URLs are built from this tag, so it must be a full release -
# a branch name does not resolve. docs/versions.md records why v3.32 and not the
# newer release: Calico tests against a specific set of Kubernetes minors.
variable "calico_version" {
  description = "Calico release tag, used to build the CRD, operator and Installation manifest URLs."
  type        = string
  default     = "v3.32.2"
}

# Helm is installed by the bootstrap script, checksum-verified, because Phase 6 is
# the first thing that needs it and Phase 4 has no reason to carry the download.
variable "helm_version" {
  description = "Helm version installed on the control plane."
  type        = string
  default     = "3.20.0"
}

variable "helm_sha256" {
  description = "Expected sha256 of the linux-arm64 helm tarball, verified on the node against the published checksum."
  type        = string
  default     = "bfb14953295d5324d47ab55f3dfba6da28d46c848978c8fbf412d4271bdc29f1"
}

variable "argocd_chart_version" {
  description = "argo-cd Helm chart version. 10.9.6 ships Argo CD v3.5.3."
  type        = string
  default     = "10.9.6"
}

# ---------------------------------------------------------------- GitOps ---
# The repository the root Application syncs. owner/repo with no scheme - the
# script builds either the https or the ssh:// URL depending on whether a deploy
# key is present in SSM.
variable "gitops_repo_url" {
  description = "Repository Argo CD syncs, in owner/repo form without a scheme."
  type        = string
  default     = "REPLACE_ME/dpx-infra"
}

variable "gitops_ssh_host" {
  description = "Host used in the ssh:// repo URL. Only read when a deploy key is present."
  type        = string
  default     = "github.com"
}

variable "gitops_repo_path" {
  description = "Path inside the repository holding this environment's overlay."
  type        = string
  default     = "gitops/prod"
}

variable "gitops_target_revision" {
  description = "Git ref Argo CD tracks."
  type        = string
  default     = "main"
}

variable "association_schedule" {
  description = "How often the bootstrap document runs on the control plane. Frequent enough that a hand-rebuilt control plane converges on its own, rare enough that it is not doing work all day."
  type        = string
  default     = "rate(30 minutes)"
}
