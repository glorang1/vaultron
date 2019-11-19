# =======================================================================
# Black Lion
# Vault servers
#   - Standard OSS distribution
#   - Custom binary (allows for custom builds, Enterprise, etc.)
# ========================================================================

terraform {
  required_version = ">= 0.12"
}

# -----------------------------------------------------------------------
# Vault variables
# -----------------------------------------------------------------------

variable "datacenter_name" {
}

variable "vault_version" {
}

variable "use_vault_oss" {
}

variable "vault_ent_id" {
}

variable "vault_path" {
}

variable "vault_cluster_name" {
}

variable "disable_clustering" {
}

variable "vault_server_log_format" {
}

variable "vault_server_log_level" {
}

variable "consul_server_ips" {
  type = list(string)
}

variable "consul_client_ips" {
  type = list(string)
}

variable "vault_oss_instance_count" {
}

variable "vault_custom_instance_count" {
}

variable "vault_custom_config_template" {
}

variable "statsd_ip" {
}

variable "vaultron_telemetry_count" {
}

# This is the official Vault Docker image that Vaultron uses by default.
# See also: https://hub.docker.com/_/vault/
resource "docker_image" "vault" {
  name         = "vault:${var.vault_version}"
  keep_locally = true
}

# -----------------------------------------------------------------------
# Vault OSS server configuration
# -----------------------------------------------------------------------

data "template_file" "vault_config" {
  count = var.vault_oss_instance_count
  template = file(
    "${path.module}/templates/oss/vault_config_${var.vault_version}.hcl",
  )

  vars = {
    address            = "0.0.0.0:8200"
    api_addr           = "https://${format("10.10.42.20%d", count.index)}:8200"
    cluster_addr       = "https://${format("10.10.42.20%d", count.index)}:8201"
    cluster_address    = "${format("10.10.42.20%d", count.index)}:8201"
    consul_address     = element(var.consul_client_ips, count.index)
    datacenter         = var.datacenter_name
    log_level          = var.vault_server_log_level
    vault_path         = var.vault_path
    cluster_name       = var.vault_cluster_name
    disable_clustering = var.disable_clustering
    service_tags       = "vaultron"
  }
}

# -----------------------------------------------------------------------
# TLS configuration
# -----------------------------------------------------------------------

data "template_file" "ca_bundle" {
  template = file("${path.module}/tls/ca.pem")
}

data "template_file" "vault_tls_cert" {
  count = var.vault_oss_instance_count
  template = file(
    "${path.module}/tls/${format("vault-server-%d.crt", count.index)}",
  )
}

data "template_file" "vault_tls_key" {
  count = var.vault_oss_instance_count
  template = file(
    "${path.module}/tls/${format("vault-server-%d.key", count.index)}",
  )
}

# -----------------------------------------------------------------------
# Vault telemetry configuration
# -----------------------------------------------------------------------

data "template_file" "telemetry_config" {
  template = file("${path.module}/templates/extras/vault_telemetry.hcl")

  vars = {
    statsd_ip = var.statsd_ip
  }
}

# -----------------------------------------------------------------------
# Vault OSS servers
# -----------------------------------------------------------------------

resource "docker_container" "vault_oss_server" {
  count = var.vault_oss_instance_count
  name  = "vaultron-${format("vault%d", count.index)}"
  image = docker_image.vault.latest

  env = ["SKIP_CHOWN", "VAULT_REDIRECT_ADDR=https://${format("10.10.42.20%d", count.index)}:8200", "VAULT_LOG_FORMAT=${var.vault_server_log_format}"]

  command    = ["vault", "server", "-log-level=${var.vault_server_log_level}", "-config=/vault/config"]
  hostname   = format("vaults%d", count.index)
  domainname = "consul"
  dns        = var.consul_server_ips
  dns_search = ["consul"]

  labels = {
    robot = "vaultron"
  }

  must_run = true

  capabilities {
    add = ["IPC_LOCK", "NET_ADMIN", "SYS_ADMIN", "SYS_PTRACE", "SYSLOG", "SYS_RAWIO"]
  }

  healthcheck {
    test         = ["CMD", "vault", "status"]
    interval     = "10s"
    timeout      = "2s"
    start_period = "10s"
    retries      = 2
  }

  networks_advanced {
    name         = "vaultron-network"
    ipv4_address = "format("10.10.42.20%d", count.index)"
  }

  volumes {
    host_path      = "${path.cwd}/vault/vault${count.index}/audit_log"
    container_path = "/vault/logs"
  }

  volumes {
    host_path      = "${path.cwd}/vault/vault${count.index}/config"
    container_path = "/vault/config"
  }

  volumes {
    host_path      = "${path.cwd}/vault/plugins"
    container_path = "/vault/plugins"
  }

  upload {
    content = element(data.template_file.vault_config.*.rendered, count.index)
    file    = "/vault/config/main.hcl"
  }

  upload {
    content = data.template_file.telemetry_config.rendered
    file    = var.vaultron_telemetry_count ? "/vault/config/telemetry.hcl" : "/tmp/telemetry.hcl"
  }

  upload {
    content = data.template_file.ca_bundle.rendered
    file    = "/etc/ssl/certs/ca.pem"
  }

  upload {
    content = element(data.template_file.vault_tls_cert.*.rendered, count.index)
    file    = "/etc/ssl/certs/vault-server.crt"
  }

  upload {
    content = element(data.template_file.vault_tls_key.*.rendered, count.index)
    file    = "/etc/ssl/vault-server.key"
  }

  ports {
    internal = "8200"
    external = format("82%d0", count.index)
    protocol = "tcp"
  }
}

# -----------------------------------------------------------------------
# Vault Custom binary (for Enterprise / source builds / etc.)
# -----------------------------------------------------------------------

# -----------------------------------------------------------------------
# TLS configuration
# -----------------------------------------------------------------------

data "template_file" "vault_custom_tls_cert" {
  count = var.vault_custom_instance_count
  template = file(
    "${path.module}/tls/${format("vault-server-%d.crt", count.index)}",
  )
}

data "template_file" "vault_custom_tls_key" {
  count = var.vault_custom_instance_count
  template = file(
    "${path.module}/tls/${format("vault-server-%d.key", count.index)}",
  )
}

# -----------------------------------------------------------------------
# Vault Custom binary configuration
# -----------------------------------------------------------------------

data "template_file" "vault_custom_config" {
  count = var.vault_custom_instance_count
  template = file(
    "${path.module}/templates/custom/${var.vault_custom_config_template}",
  )

  vars = {
    address            = "0.0.0.0:8200"
    api_addr           = "https://${format("10.10.42.20%d", count.index)}:8200"
    alt_address        = "0.0.0.0:443"
    cluster_addr       = "https://${format("10.10.42.20%d", count.index)}:8201"
    cluster_address    = "${format("10.10.42.20%d", count.index)}:8201"
    consul_address     = element(var.consul_client_ips, count.index)
    datacenter         = var.datacenter_name
    log_level          = var.vault_server_log_level
    node_id            = uuid()
    vault_path         = var.vault_path
    cluster_name       = var.vault_cluster_name
    disable_clustering = var.disable_clustering
    statsd_ip          = var.statsd_ip
    tls_cert           = "/vault/config/vault-server.crt"
    tls_key            = "/vault/config/vault-server.key"
    service_tags       = "vaultron"
    ui                 = true
  }
}

# -----------------------------------------------------------------------
# Vault Custom binary servers
# -----------------------------------------------------------------------

resource "docker_container" "vault_custom_server" {
  count = var.vault_custom_instance_count
  name  = "vaultron-${format("vault%d", count.index)}"
  image = docker_image.vault.latest

  env = ["SKIP_CHOWN", "VAULT_REDIRECT_ADDR=https://${format("10.10.42.20%d", count.index)}:8200", "VAULT_LOG_FORMAT=${var.vault_server_log_format}"]

  command    = ["/vault/custom/vault", "server", "-log-level=${var.vault_server_log_level}", "-config=/vault/config"]
  hostname   = format("vaults%d", count.index)
  domainname = "consul"
  dns        = var.consul_server_ips
  dns_search = ["consul"]

  labels = {
    robot = "vaultron"
  }

  must_run = true

  capabilities {
    add = ["IPC_LOCK", "NET_ADMIN", "SYS_ADMIN", "SYS_PTRACE", "SYSLOG"]
  }

  healthcheck {
    test         = ["CMD", "vault", "status"]
    interval     = "10s"
    timeout      = "2s"
    start_period = "10s"
    retries      = 2
  }

  networks_advanced {
    name         = "vaultron-network"
    ipv4_address = "format("10.10.42.20%d", count.index)"
  }

  volumes {
    host_path      = "${path.cwd}/custom/"
    container_path = "/vault/custom"
  }

  volumes {
    host_path      = "${path.cwd}/vault/vault${count.index}/audit_log"
    container_path = "/vault/logs"
  }

  volumes {
    host_path      = "${path.cwd}/vault/vault${count.index}/config"
    container_path = "/vault/config"
  }

  volumes {
    host_path      = "${path.cwd}/vault/vault${count.index}/data"
    container_path = "/vault/data"
  }

  volumes {
    host_path      = "${path.cwd}/vault/plugins"
    container_path = "/vault/plugins"
  }

  upload {
    content = element(
      data.template_file.vault_custom_config.*.rendered,
      count.index,
    )
    file = "/vault/config/main.hcl"
  }

  upload {
    content = data.template_file.telemetry_config.rendered
    file    = var.vaultron_telemetry_count ? "/vault/config/telemetry.hcl" : "/tmp/telemetry.hcl"
  }

  upload {
    content = data.template_file.ca_bundle.rendered
    file    = "/etc/ssl/certs/ca.pem"
  }

  upload {
    content = element(
      data.template_file.vault_custom_tls_cert.*.rendered,
      count.index,
    )
    file = "/etc/ssl/certs/vault-server.crt"
  }

  upload {
    content = element(
      data.template_file.vault_custom_tls_key.*.rendered,
      count.index,
    )
    file = "/etc/ssl/vault-server.key"
  }

  ports {
    internal = "8200"
    external = format("82%d0", count.index)
    protocol = "tcp"
  }
}

