provider "ferriskey" {
  url           = var.ferriskey_url
  realm         = var.admin_realm
  client_id     = var.client_id
  client_secret = var.client_secret
  username      = var.username
  password      = var.password
}
