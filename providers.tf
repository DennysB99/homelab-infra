terraform {
  required_version = ">= 1.5.0"

  required_providers {
    # The modern, highly reliable Proxmox provider
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.50.0"
    }
    # The plugin that decrypts SOPS files in RAM
    sops = {
      source  = "carlpett/sops"
      version = "~> 1.0.0"
    }
  }
}

# 1. Tell Terraform where the encrypted file is
data "sops_file" "secrets" {
  source_file = "secrets.yaml"
}

# 2. Decode the YAML structure into a usable Terraform variable
locals {
  secrets = yamldecode(data.sops_file.secrets.raw)
}

# 3. Connect to Proxmox using the decrypted secrets
provider "proxmox" {
  endpoint  = local.secrets.proxmox.api_url
  api_token = "${local.secrets.proxmox.username}=${local.secrets.proxmox.api_token}"
  insecure  = true

  ssh {
    agent = true
  }
}
