# ==============================================================================
# GLOBALS & LOCALS
# ==============================================================================
# Safely extracts IPs and strips the "sensitive" flag so the terminal isn't muted.
locals {
  amp_secrets = {
    oidc_client_id     = local.secrets.amp.oidc_client_id
    oidc_client_secret = local.secrets.amp.oidc_client_secret
  }

  master_ip = nonsensitive([for name, ip in local.secrets.virtual_machines.k3s_cluster : ip if can(regex("master", name))][0])

  # Moving AMP to primary compute VLAN permanently until DMZ is fixed
  amp_ip = "10.0.50.40"

  # Concatenates both K3s, Docker, and AMP IPs so we can clear SSH keys for everything!
  all_ips = nonsensitive(join(" ", concat(
    values(local.secrets.virtual_machines.k3s_cluster),
    values(local.secrets.virtual_machines.docker_hosts),
    [local.amp_ip]
  )))
}

# ==============================================================================
# SECTION 1: K3S KUBERNETES CLUSTER (THE COMPUTE LAYER)
# ==============================================================================
resource "proxmox_virtual_environment_vm" "k3s_nodes" {
  for_each = nonsensitive(local.secrets.virtual_machines.k3s_cluster)

  name      = each.key
  node_name = "pve"

  clone {
    vm_id = 8000
    full  = true
  }

  cpu {
    type  = "host"
    cores = 8
  }
  memory {
    dedicated = 3072
  }

  vga {
    type = "std"
  }

  network_device {
    bridge  = "vmbr0"
    vlan_id = 50
  }

  stop_on_destroy = true

  initialization {
    ip_config {
      ipv4 {
        address = "${each.value}/24"
        gateway = local.secrets.virtual_machines.gw_ip
      }
    }

    user_account {
      username = local.secrets.ansible.user
      password = local.secrets.ansible.password
      keys     = [local.secrets.ansible.public_key]
    }
  }
}

# ==============================================================================
# SECTION 2: DOCKER HOSTS (THE STANDALONE APP LAYER)
# ==============================================================================
resource "proxmox_virtual_environment_vm" "docker_nodes" {
  for_each = nonsensitive(local.secrets.virtual_machines.docker_hosts)

  name      = each.key
  node_name = "pve"

  clone {
    vm_id = 8000
    full  = true
  }

  cpu {
    type  = "host"
    cores = 4
  }
  memory {
    dedicated = 4096
  }

  vga {
    type = "std"
  }

  network_device {
    bridge  = "vmbr0"
    vlan_id = 50
  }

  stop_on_destroy = true

  disk {
    datastore_id = "local-lvm"
    interface    = "scsi0"
    size         = 100
  }

  initialization {
    ip_config {
      ipv4 {
        address = "${each.value}/24"
        gateway = local.secrets.virtual_machines.gw_ip
      }
    }
    user_account {
      username = local.secrets.ansible.user
      password = local.secrets.ansible.password
      keys     = [local.secrets.ansible.public_key]
    }
  }
}

# ==============================================================================
# SECTION 2.5: AMP MANAGEMENT PANEL (GAME SERVER LAYER)
# ==============================================================================
resource "proxmox_virtual_environment_vm" "amp_node" {
  name      = "amp-core-01"
  node_name = "pve"

  clone {
    vm_id = 8000
    full  = true
  }

  cpu {
    type  = "host"
    cores = 4
  }
  memory {
    dedicated = 11264
  }

  vga {
    type = "std"
  }

  network_device {
    bridge  = "vmbr0"
    vlan_id = 50
  }

  stop_on_destroy = true

  disk {
    datastore_id = "local-lvm"
    interface    = "scsi0"
    size         = 150 # Larger disk for game instances
  }

  initialization {
    ip_config {
      ipv4 {
        address = "${local.amp_ip}/24"
        gateway = local.secrets.virtual_machines.gw_ip
      }
    }
    user_account {
      username = local.secrets.ansible.user
      password = local.secrets.ansible.password
      keys     = [local.secrets.ansible.public_key]
    }
  }
}

# ==============================================================================
# SECTION 3: MANIFEST GENERATORS (THE BRIDGE)
# ==============================================================================
resource "local_file" "ansible_inventory" {
  content = <<-EOT
    [master]
    %{for name, ip in local.secrets.virtual_machines.k3s_cluster~}
    %{if can(regex("master", name))~}
    ${name} ansible_host=${ip}
    %{endif~}
    %{endfor~}

    [workers]
    %{for name, ip in local.secrets.virtual_machines.k3s_cluster~}
    %{if can(regex("worker", name))~}
    ${name} ansible_host=${ip}
    %{endif~}
    %{endfor~}
    %{for name, ip in try(local.secrets.bare_metal.pi_cluster, {})~}
    ${name} ansible_host=${ip} ansible_user=${local.secrets.bare_metal.user} ansible_ssh_private_key_file=~/.ssh/id_ed25519
    %{endfor~}

    [docker]
    %{for name, ip in local.secrets.virtual_machines.docker_hosts~}
    ${name} ansible_host=${ip}
    %{endfor~}

    [amp]
    amp-core-01 ansible_host=${local.amp_ip}

    [all:vars]
    ansible_user=${local.secrets.ansible.user}
    ansible_ssh_private_key_file=${local.secrets.ansible.private_key_file}
    ansible_become_pass=${local.secrets.ansible.password}
    ansible_ssh_common_args='-o StrictHostKeyChecking=no'
    nfs_server=${local.secrets.storage.nfs_server}
    nfs_path=${local.secrets.storage.nfs_path}
    tailscale_client_id=${local.secrets.tailscale.client_id}
    tailscale_client_secret=${local.secrets.tailscale.client_secret}
    amp_oidc_client_id=${local.amp_secrets.oidc_client_id}
    amp_oidc_client_secret=${local.amp_secrets.oidc_client_secret}

  EOT

  filename = "${path.module}/../ansible/hosts.ini"
}

resource "local_file" "magic_frame_compose" {
  content  = <<EOT
services:
  app:
    image: jeremiaa/magic-frame:latest
    build:
      context: https://github.com/jeremiaa/magic-frame.git#main
    restart: unless-stopped
    ports:
      - "3080:3000"
    environment:
      - DATABASE_URL=postgresql://postgres:postgres@db:5432/magicdashboard?schema=public # pragma: allowlist secret
      - NODE_ENV=production
      - SESSION_SECRET=${local.secrets.magic_frame.session_secret}
      - APP_BASE_URL=http://10.0.50.30:3080
    volumes:
      - /var/lib/docker-data/magic-frame/data:/opt/data
    labels:
      kuma.magic-frame-app.http.name: "Magic Frame Dashboard"
      kuma.magic-frame-app.http.url: "http://10.0.50.30:3080"
      kuma.magic-frame-app.http.parent_name: "mediastack"
    depends_on:
      - db

  db:
    image: postgres:15-alpine
    restart: unless-stopped
    environment:
      - POSTGRES_DB=magicdashboard
      - POSTGRES_USER=postgres
      - POSTGRES_PASSWORD=postgres
    volumes:
      - /var/lib/docker-data/magic-frame/db:/var/lib/postgresql/data

EOT
  filename = "${path.module}/../docker/magic-frame/docker-compose.yml"
}


resource "local_file" "mealie_manifest" {
  content = templatefile("${path.module}/../kubernetes/apps/mealie.yaml.tftpl", {
    nfs_server         = local.secrets.storage.nfs_server
    nfs_path           = local.secrets.storage.nfs_path
    oidc_client_id     = local.secrets.mealie.oidc_client_id
    oidc_client_secret = local.secrets.mealie.oidc_client_secret
  })
  filename = "${path.module}/../kubernetes/apps/mealie.yaml"
}

resource "local_file" "authentik_manifest" {
  content = templatefile("${path.module}/../kubernetes/apps/authentik.yaml.tftpl", {
    nfs_server        = local.secrets.storage.nfs_server
    nfs_path          = local.secrets.storage.nfs_path
    secret_key        = local.secrets.authentik.secret_key
    postgres_name     = local.secrets.authentik.postgres_name
    postgres_user     = local.secrets.authentik.postgres_user
    postgres_password = local.secrets.authentik.postgres_password
  })
  filename = "${path.module}/../kubernetes/apps/authentik.yaml"
}

resource "local_file" "kuma_ingress_watcher_manifest" {
  content = templatefile("${path.module}/../kubernetes/apps/kuma-ingress-watcher.yaml.tftpl", {
    kuma_username   = local.secrets.uptime_kuma.username
    kuma_password   = local.secrets.uptime_kuma.password
    controller_code = file("${path.module}/../kubernetes/apps/controller.py")
  })
  filename = "${path.module}/../kubernetes/apps/kuma-ingress-watcher.yaml"
}

resource "local_file" "media_compose" {
  content  = <<EOT
services:
  gluetun:
    image: qmcgaw/gluetun:latest
    container_name: gluetun
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    environment:
      - VPN_SERVICE_PROVIDER=protonvpn
      - VPN_TYPE=${try(local.secrets.vpn.type, "wireguard")}
      - WIREGUARD_PRIVATE_KEY=${try(local.secrets.vpn.wireguard_private_key, "")}
      - OPENVPN_USER=${try(local.secrets.vpn.username, "")}
      - OPENVPN_PASSWORD=${try(local.secrets.vpn.password, "")}
      - VPN_PORT_FORWARDING=on
      - VPN_PORT_FORWARDING_PROVIDER=protonvpn
      - VPN_PORT_FORWARDING_STATUS_FILE=/gluetun/forwarded_port
    volumes:
      - /var/lib/docker-data/gluetun:/gluetun
    ports:
      - "8080:8080" # qBittorrent Web UI
      - "6881:6881" # torrent TCP
      - "6881:6881/udp" # torrent UDP
    restart: unless-stopped

  qbittorrent:
    image: lscr.io/linuxserver/qbittorrent:latest
    container_name: qbittorrent
    network_mode: service:gluetun
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=America/New_York
      - WEBUI_PORT=8080
    volumes:
      - /var/lib/docker-data/qbittorrent/config:/config
      - /mnt/HDDs/media:/data
    labels:
      kuma.qbittorrent.http.name: "qBittorrent"
      kuma.qbittorrent.http.url: "http://10.0.50.30:8080"
      kuma.qbittorrent.http.parent_name: "mediastack"
    restart: unless-stopped
    depends_on:
      - gluetun

  qbportweaver:
    image: snoringdragon/gluetun-qbittorrent-port-manager:latest
    container_name: qbportweaver
    network_mode: service:gluetun
    environment:
      - QBITTORRENT_SERVER=localhost
      - QBITTORRENT_PORT=8080
      - QBITTORRENT_USER=admin
      - QBITTORRENT_PASS=adminadmin
      - PORT_FORWARDED=/tmp/gluetun/forwarded_port
    volumes:
      - /var/lib/docker-data/gluetun:/tmp/gluetun:ro
    restart: unless-stopped
    depends_on:
      - qbittorrent

  prowlarr:
    image: lscr.io/linuxserver/prowlarr:latest
    container_name: prowlarr
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=America/New_York
    volumes:
      - /var/lib/docker-data/prowlarr:/config
    ports:
      - "9696:9696"
    labels:
      kuma.prowlarr.http.name: "Prowlarr"
      kuma.prowlarr.http.url: "http://10.0.50.30:9696"
      kuma.prowlarr.http.parent_name: "mediastack"
    restart: unless-stopped

  flaresolverr:
    image: ghcr.io/flaresolverr/flaresolverr:latest
    container_name: flaresolverr
    environment:
      - LOG_LEVEL=info
      - TZ=America/New_York
    ports:
      - "8191:8191"
    restart: unless-stopped

  sonarr:
    image: lscr.io/linuxserver/sonarr:latest
    container_name: sonarr
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=America/New_York
    volumes:
      - /var/lib/docker-data/sonarr:/config
      - /mnt/HDDs/media:/data
    ports:
      - "8989:8989"
    labels:
      kuma.sonarr.http.name: "Sonarr"
      kuma.sonarr.http.url: "http://10.0.50.30:8989"
      kuma.sonarr.http.parent_name: "mediastack"
    restart: unless-stopped

  radarr:
    image: lscr.io/linuxserver/radarr:latest
    container_name: radarr
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=America/New_York
    volumes:
      - /var/lib/docker-data/radarr:/config
      - /mnt/HDDs/media:/data
    ports:
      - "7878:7878"
    labels:
      kuma.radarr.http.name: "Radarr"
      kuma.radarr.http.url: "http://10.0.50.30:7878"
      kuma.radarr.http.parent_name: "mediastack"
    restart: unless-stopped

  seanime:
    image: umagistr/seanime:latest
    container_name: seanime
    command: ["/app/seanime", "--host", "0.0.0.0"]
    environment:
      - PUID=1000
      - PGID=1000
    volumes:
      - /var/lib/docker-data/seanime:/root/.config/Seanime
      - /mnt/HDDs/media:/data
    ports:
      - "43211:43211"
    labels:
      kuma.seanime.http.name: "Seanime"
      kuma.seanime.http.url: "http://10.0.50.30:43211"
      kuma.seanime.http.parent_name: "mediastack"
    restart: unless-stopped

  bazarr:
    image: lscr.io/linuxserver/bazarr:latest
    container_name: bazarr
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=America/New_York
    volumes:
      - /var/lib/docker-data/bazarr:/config
      - /mnt/HDDs/media:/data
    ports:
      - "6767:6767"
    labels:
      kuma.bazarr.http.name: "Bazarr"
      kuma.bazarr.http.url: "http://10.0.50.30:6767"
      kuma.bazarr.http.parent_name: "mediastack"
    restart: unless-stopped

  recyclarr:
    image: ghcr.io/recyclarr/recyclarr:latest
    container_name: recyclarr
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=America/New_York
    volumes:
      - /var/lib/docker-data/recyclarr:/config
    restart: unless-stopped

  plex:
    image: lscr.io/linuxserver/plex:latest
    container_name: plex
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=America/New_York
      - VERSION=docker
      - PLEX_CLAIM=${try(local.secrets.plex.claim_token, "")}
    volumes:
      - /var/lib/docker-data/plex:/config
      - /mnt/HDDs/media/library:/data
    devices:
      - /dev/dri:/dev/dri
    ports:
      - "32400:32400"
    labels:
      kuma.plex.http.name: "Plex"
      kuma.plex.http.url: "http://10.0.50.30:32400/web/index.html"
      kuma.plex.http.parent_name: "mediastack"
    restart: unless-stopped

  seerr:
    image: ghcr.io/seerr-team/seerr:latest
    container_name: seerr
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=America/New_York
      - LOG_LEVEL=info
    volumes:
      - /var/lib/docker-data/seerr:/app/config
    ports:
      - "5055:5055"
    labels:
      kuma.seerr.http.name: "Seerr"
      kuma.seerr.http.url: "http://10.0.50.30:5055"
      kuma.seerr.http.parent_name: "mediastack"
    restart: unless-stopped

  tautulli:
    image: lscr.io/linuxserver/tautulli:latest
    container_name: tautulli
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=America/New_York
    volumes:
      - /var/lib/docker-data/tautulli:/config
    ports:
      - "8181:8181"
    labels:
      kuma.tautulli.http.name: "Tautulli"
      kuma.tautulli.http.url: "http://10.0.50.30:8181"
      kuma.tautulli.http.parent_name: "mediastack"
    restart: unless-stopped

  sabnzbd:
    image: lscr.io/linuxserver/sabnzbd:latest
    container_name: sabnzbd
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=America/New_York
    volumes:
      - /var/lib/docker-data/sabnzbd:/config
      - /mnt/HDDs/media:/data
    ports:
      - "8085:8080"
    labels:
      kuma.sabnzbd.http.name: "SABnzbd"
      kuma.sabnzbd.http.url: "http://10.0.50.30:8085"
      kuma.sabnzbd.http.parent_name: "mediastack"
    restart: unless-stopped

  autokuma:
    image: ghcr.io/bigboot/autokuma:uptime-kuma-v1-latest
    container_name: autokuma
    restart: unless-stopped
    environment:
      AUTOKUMA__KUMA__URL: "https://uptime.netnook.cloud"
      AUTOKUMA__KUMA__USERNAME: "${local.secrets.uptime_kuma.username}"
      AUTOKUMA__KUMA__PASSWORD: "${local.secrets.uptime_kuma.password}"
      AUTOKUMA__TAG_NAME: "Docker Auto-Discovered"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    labels:
      kuma.mediastack.group.name: "Media Stack"

  n8n:
    image: docker.n8n.io/n8nio/n8n:latest
    container_name: n8n
    restart: unless-stopped
    ports:
      - "5678:5678"
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=America/New_York
      - GENERIC_TIMEZONE=America/New_York
      - N8N_PORT=5678
      - WEBHOOK_URL=https://n8n.netnook.cloud/
      - NODES_EXCLUDE=[]
    volumes:
      - /var/lib/docker-data/n8n:/home/node/.n8n
    labels:
      kuma.n8n.http.name: "n8n"
      kuma.n8n.http.url: "http://10.0.50.30:5678"
      kuma.n8n.http.parent_name: "mediastack"

  watchtower:
    image: ghcr.io/nicholas-fedor/watchtower:latest
    container_name: watchtower
    restart: unless-stopped
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    environment:
      - WATCHTOWER_CLEANUP=true
      - WATCHTOWER_POLL_INTERVAL=86400
EOT
  filename = "${path.module}/../docker/media/docker-compose.yml"
}

resource "local_file" "backup_compose" {
  content  = <<EOT
services:
  kopia:
    image: kopia/kopia:latest
    container_name: kopia
    command:
      - server
      - start
      - --insecure
      - --address=http://0.0.0.0:5200
      - --server-username=debian
      - --server-password=${local.secrets.kopia.repository_password}
    restart: unless-stopped
    ports:
      - "5200:5200"
    environment:
      - KOPIA_PASSWORD=${local.secrets.kopia.repository_password}
    volumes:
      - /var/lib/docker-data:/app/data:ro
      - /mnt/HDDs/backups:/app/backup-target
      - /var/lib/kopia/config:/app/config
      - /var/lib/kopia/cache:/app/cache
EOT
  filename = "${path.module}/../docker/backup/docker-compose.yml"
}


resource "null_resource" "deploy_media_compose" {
  depends_on = [local_file.media_compose, local_file.backup_compose, null_resource.ansible_provision]

  triggers = {
    compose_hash = local_file.media_compose.content_sha256
    backup_hash  = local_file.backup_compose.content_sha256
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    environment = {
      SSH_USER  = local.secrets.ansible.user
      SSH_KEY   = local.secrets.ansible.private_key_file
      DOCKER_IP = local.secrets.virtual_machines.docker_hosts["docker-core-01"]
      SUDO_PASS = local.secrets.ansible.password
    }

    command = <<-EOT
      echo "🚀 Copying Media and Backup Compose stacks to Docker host..."
      scp -i "$SSH_KEY" -o StrictHostKeyChecking=no ${local_file.media_compose.filename} "$SSH_USER"@"$DOCKER_IP":/tmp/docker-compose-media.yml
      scp -i "$SSH_KEY" -o StrictHostKeyChecking=no ${local_file.backup_compose.filename} "$SSH_USER"@"$DOCKER_IP":/tmp/docker-compose-backup.yml

      echo "📦 Moving to final location and starting containers..."
      ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SSH_USER"@"$DOCKER_IP" "
        echo '$SUDO_PASS' | sudo -S mkdir -p /var/lib/docker-data &&
        echo '$SUDO_PASS' | sudo -S chown -R debian:debian /var/lib/docker-data &&
        if [ -d /mnt/HDDs/docker-data ] && [ ! -d /var/lib/docker-data/plex ]; then
          echo '📂 Migrating existing configurations from NFS to local storage...' &&
          echo '$SUDO_PASS' | sudo -S cp -rp /mnt/HDDs/docker-data/. /var/lib/docker-data/ &&
          echo '$SUDO_PASS' | sudo -S chown -R debian:debian /var/lib/docker-data;
        fi &&
        echo '$SUDO_PASS' | sudo -S mkdir -p /var/lib/docker-data/n8n &&
        echo '$SUDO_PASS' | sudo -S chown -R debian:debian /var/lib/docker-data/n8n &&
        echo '$SUDO_PASS' | sudo -S mkdir -p /var/lib/docker-data/media &&
        echo '$SUDO_PASS' | sudo -S cp /tmp/docker-compose-media.yml /var/lib/docker-data/media/docker-compose.yml &&
        echo '$SUDO_PASS' | sudo -S docker compose -f /var/lib/docker-data/media/docker-compose.yml down || true &&
        echo '$SUDO_PASS' | sudo -S docker compose -f /var/lib/docker-data/media/docker-compose.yml up -d --remove-orphans &&

        echo '💾 Deploying Kopia Backup stack...' &&
        echo '$SUDO_PASS' | sudo -S mkdir -p /var/lib/kopia &&
        echo '$SUDO_PASS' | sudo -S chown -R debian:debian /var/lib/kopia &&
        echo '$SUDO_PASS' | sudo -S mkdir -p /var/lib/docker-data/backup &&
        echo '$SUDO_PASS' | sudo -S cp /tmp/docker-compose-backup.yml /var/lib/docker-data/backup/docker-compose.yml &&
        echo '$SUDO_PASS' | sudo -S docker compose -f /var/lib/docker-data/backup/docker-compose.yml down || true &&
        echo '$SUDO_PASS' | sudo -S docker compose -f /var/lib/docker-data/backup/docker-compose.yml up -d --remove-orphans
      "
    EOT
  }
}

# ==============================================================================
# SECTION 4: THE ORCHESTRATOR (MODULAR STAGES)
# ==============================================================================

# STAGE 1: Wait for SSH and Clean Fingerprints
resource "null_resource" "wait_for_ssh" {
  triggers = {
    cluster_instance_ids = join(",", concat(
      [for vm in proxmox_virtual_environment_vm.k3s_nodes : vm.id],
      [for vm in proxmox_virtual_environment_vm.docker_nodes : vm.id],
      [proxmox_virtual_environment_vm.amp_node.id]
    ))
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    environment = {
      SSH_USER = local.secrets.ansible.user
      SSH_KEY  = local.secrets.ansible.private_key_file
      ALL_IPS  = local.all_ips
    }

    command = <<-EOT
      echo "⏳ Waiting for ALL VMs to boot (Verbose Check)..."
      for ip in $ALL_IPS; do
        (
          # Clear stale fingerprints
          ssh-keygen -R $ip >/dev/null 2>&1 || true

          echo "   🔍 Checking $ip..."
          while true; do
            ssh -i "$SSH_KEY" -o ConnectTimeout=2 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$SSH_USER"@$ip 'echo "ready"' >/dev/null 2>&1
            if [ $? -eq 0 ]; then
              echo "✅ $ip is online!"
              break
            fi
            # Optional: echo "   ... $ip still waiting"
            sleep 5
          done
        ) &
      done

      wait
      echo "☕ Settle delay: Waiting 10 seconds..."
      sleep 10
      echo "✅ All VMs are online and stable!"
    EOT
  }
}

# STAGE 2: Run Ansible Playbook
resource "null_resource" "ansible_provision" {
  depends_on = [null_resource.wait_for_ssh, local_file.ansible_inventory]

  triggers = {
    inventory_hash = local_file.ansible_inventory.content_sha256
    playbook_hash  = filesha256("${path.module}/../ansible/site.yml")
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = "cd ${path.module}/../ansible && ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook -i hosts.ini site.yml"
  }
}

# STAGE 3: Kubernetes Setup & App Deployment
resource "null_resource" "kubernetes_setup" {
  depends_on = [
    null_resource.ansible_provision,
    local_file.mealie_manifest,
    local_file.authentik_manifest,
    local_file.kuma_ingress_watcher_manifest
  ]

  triggers = {
    manifest_hash = sha256(join("", [
      local_file.mealie_manifest.content,
      local_file.authentik_manifest.content,
      local_file.kuma_ingress_watcher_manifest.content,
      filesha256("${path.module}/../kubernetes/apps/uptime-kuma.yaml"),
      filesha256("${path.module}/../kubernetes/system/traefik-dashboard-ingress.yaml"),
      filesha256("${path.module}/../kubernetes/system/cloudflared.yaml"),
      filesha256("${path.module}/../kubernetes/system/external-bridge.yaml")
    ]))
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    environment = {
      SSH_USER  = local.secrets.ansible.user
      SSH_KEY   = local.secrets.ansible.private_key_file
      SUDO_PASS = local.secrets.ansible.password
      MASTER_IP = local.master_ip
    }

    command = <<-EOT
      echo "🔑 Fetching Kubeconfig..."
      while ! ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$SSH_USER"@$MASTER_IP "echo \"$SUDO_PASS\" | sudo -S test -s /etc/rancher/k3s/k3s.yaml" >/dev/null 2>&1; do
        sleep 5
      done

      ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$SSH_USER"@$MASTER_IP "echo \"$SUDO_PASS\" | sudo -S cat /etc/rancher/k3s/k3s.yaml" | sed "s/127.0.0.1/$MASTER_IP/g" > ~/.kube/config

      echo "🚦 Configuring Traefik..."
      kubectl apply -f ${path.module}/../kubernetes/system/traefik-config.yaml
      kubectl apply -f ${path.module}/../kubernetes/system/traefik-dashboard-ingress.yaml
      kubectl apply -f ${path.module}/../kubernetes/system/external-bridge.yaml

      echo \"🚀 Deploying Apps...\"
      kubectl apply -f ${path.module}/../kubernetes/apps/authentik.yaml
      kubectl apply -f ${path.module}/../kubernetes/apps/mealie.yaml
      kubectl apply -f ${path.module}/../kubernetes/apps/uptime-kuma.yaml
      kubectl apply -f ${path.module}/../kubernetes/apps/kuma-ingress-watcher.yaml
      kubectl apply -f ${path.module}/../kubernetes/system/minecraft-route.yaml
      kubectl apply -f ${path.module}/../kubernetes/system/cloudflared.yaml
      echo \"✅ REBUILD COMPLETE!\"

    EOT
  }
}
