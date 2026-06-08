variable "proxmox_api_token" {
  type      = string
  sensitive = true 
}

variable "proxmox_url" {
  type = string
}

variable "proxmox_username" {
  type = string
}

packer {
  required_plugins {
    proxmox = {
      version = ">= 1.1.3"
      source  = "github.com/hashicorp/proxmox"
    }
  }
}

source "proxmox-iso" "debian" {
  # Proxmox API Connection
  proxmox_url = var.proxmox_url
  username    = var.proxmox_username
  token       = var.proxmox_api_token
  node        = "pve"
  insecure_skip_tls_verify = true

  boot_iso {
    type     = "ide"
    iso_file = "local:iso/debian-12.5.0-amd64-netinst.iso"
  }
  
  iso_download_pve = false

  # Virtual Machine Hardware
  vm_id   = 8000
  vm_name = "debian-12-packer-template"
  memory  = 2048
  cores   = 2

  network_adapters {
    model  = "virtio"
    bridge = "vmbr0"
  }

  disks {
    disk_size    = "10G"
    format       = "raw"
    storage_pool = "local-lvm"
    type         = "scsi"
  }
  scsi_controller = "virtio-scsi-pci"

  # Cloud-Init Drive Configuration
  cloud_init              = true
  cloud_init_storage_pool = "local-lvm"

  # The Boot Command (Types automatically via VNC)
  boot_wait = "5s"
  boot_command = [
    "<esc><wait>",
    "auto <wait>",
    "url=http://{{ .HTTPIP }}:{{ .HTTPPort }}/preseed.cfg <wait>",
    "<enter>"
  ]
  http_directory = "http"

  # SSH Connection (Packer waits for this to know the install is done)
  ssh_username = "debian"
  ssh_password = "packer"
  ssh_timeout  = "20m"
}

build {
  sources = ["source.proxmox-iso.debian"]
}