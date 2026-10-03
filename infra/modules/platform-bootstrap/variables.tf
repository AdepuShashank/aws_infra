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

variable "ssm_path_prefix" {
  description = "Parameter Store prefix, matching what 20-security grants the node role. Everything this layer writes goes under here."
  type        = string
}

variable "ssm_kms_key_arn" {
  description = <<-EOT
    KMS key the SecureString parameters are encrypted with. Must be the SSM key
    from 20-security, not the EBS one: the node role has to decrypt what the script
    writes back, and 20-security grants kms:Decrypt on the SSM key for exactly
    that reason.
  EOT
  type        = string
}

variable "control_plane_instance_id" {
  description = "Control plane instance to run the bootstrap command on. Supplied by the layer root from 30-cluster."
  type        = string
}

variable "control_plane_private_ip" {
  description = "Control plane fixed private IP. Recorded as a tag so the association is traceable from the console."
  type        = string
}

variable "cluster_name" {
  description = "Kubernetes cluster name, used for the Argo CD in-cluster domain."
  type        = string
}

variable "pod_cidr" {
  description = "Pod CIDR. Must equal the podSubnet kubeadm was initialised with; the Calico IP pool is rendered from this value."
  type        = string
}

variable "calico_version" {
  description = "Calico release tag. Manifest URLs are built from it, so this pins the CNI exactly."
  type        = string
  default     = "v3.32.2"

  validation {
    condition     = can(regex("^v\\d+\\.\\d+\\.\\d+$", var.calico_version))
    error_message = "calico_version must be a full release tag such as v3.32.2. Manifest URLs do not resolve for a branch name, so 'latest' cannot be used."
  }
}

variable "helm_version" {
  description = "Helm version installed on the control plane."
  type        = string
  default     = "3.20.0"
}

variable "helm_sha256" {
  description = <<-EOT
    Expected sha256 of the linux-arm64 helm tarball. Verified on the node against
    the published .sha256sum before the binary is installed, so the download is
    pinned to this exact artifact and not merely to a URL.
  EOT
  type        = string
  default     = "bfb14953295d5324d47ab55f3dfba6da28d46c848978c8fbf412d4271bdc29f1"
}

variable "argocd_chart_version" {
  description = "argo-cd Helm chart version. 10.9.6 ships Argo CD v3.5.3."
  type        = string
  default     = "10.9.6"

  validation {
    condition     = can(regex("^\\d+\\.\\d+\\.\\d+$", var.argocd_chart_version))
    error_message = "argocd_chart_version must be an exact chart version, not a range. A range makes the Argo CD image an unpinned input."
  }
}

variable "gitops_repo_url" {
  description = "Repository Argo CD syncs, in owner/repo form without a scheme. The script builds the https or ssh:// URL from this."
  type        = string

  validation {
    condition     = can(regex("^[^/@]+/[^/@]+$", var.gitops_repo_url))
    error_message = "gitops_repo_url must be owner/repo with no scheme, for example your-org/dpx-infra."
  }
}

variable "gitops_ssh_host" {
  description = "Host used in the ssh:// repo URL. Only read when a deploy key is present in SSM."
  type        = string
  default     = "github.com"
}

variable "gitops_repo_path" {
  description = "Path inside the repository holding the environment overlay."
  type        = string
  default     = "gitops/prod"
}

variable "gitops_target_revision" {
  description = "Git ref Argo CD tracks. A branch, because this environment is meant to be re-applied as it evolves."
  type        = string
  default     = "main"
}

variable "association_schedule" {
  description = <<-EOT
    cron/rate expression for the recurring run of the bootstrap document, e.g.
    "rate(30 minutes)".

    The platform is installed once and then left to Argo CD, so this does not need
    to be frequent. It exists so that a control plane replaced by hand - or one
    restored from an etcd snapshot - converges on its own without anyone
    remembering to re-run the bootstrap. Association runs are skipped while a
    previous run is still in progress.
  EOT
  type        = string
  default     = "rate(30 minutes)"
}

variable "bootstrap_timeout_seconds" {
  description = "How long an association run may take before SSM marks it failed. Generous: the Calico rollout alone can take several minutes on a small cluster."
  type        = number
  default     = 3600
}
