# Every variable is optional: when null, the provider falls back to its
# FERRISKEY_* environment variable (FERRISKEY_URL, FERRISKEY_REALM,
# FERRISKEY_CLIENT_ID, FERRISKEY_CLIENT_SECRET, FERRISKEY_USERNAME,
# FERRISKEY_PASSWORD).

variable "ferriskey_url" {
  description = "Base URL of the FerrisKey instance, e.g. https://auth.mestier.fr."
  type        = string
  default     = null
}

variable "admin_realm" {
  description = "Realm whose token endpoint authenticates the provider."
  type        = string
  default     = "master"
}

variable "client_id" {
  description = "Provider client: confidential admin client in steady state, public client (e.g. admin-cli) for the password-grant bootstrap."
  type        = string
  default     = null
}

variable "client_secret" {
  description = "Secret of the provider client (client-credentials grant)."
  type        = string
  default     = null
  sensitive   = true
}

variable "username" {
  description = "Admin username, password-grant bootstrap only."
  type        = string
  default     = null
}

variable "password" {
  description = "Admin password, password-grant bootstrap only."
  type        = string
  default     = null
  sensitive   = true
}

variable "realm_name" {
  description = "FerrisKey realm managed by this configuration (created on first apply; import it if it already exists)."
  type        = string
  default     = "mestier"
}

variable "mcp_resource_url" {
  description = "Protected resource indicator (RFC 8707) served by the MCP gateway."
  type        = string
  default     = "https://demo.mestier.fr/mcp"
}

variable "demo_app_url" {
  description = "Public URL of the demo app; redirect URI of the webapp-demo client."
  type        = string
  default     = "https://demo.mestier.fr/"
}
