# The realm is managed here: created on first apply. If it already exists on
# the instance (created by hand), adopt it instead of recreating it:
#   terraform import ferriskey_realm.mestier mestier
resource "ferriskey_realm" "mestier" {
  name = var.realm_name
}

resource "ferriskey_realm_settings" "mestier" {
  realm = ferriskey_realm.mestier.name

  # MCP: AI clients (Claude, ChatGPT) register dynamically over DCR.
  # CIMD stays off: ChatGPT's Client ID Metadata Document asks for
  # private_key_jwt, which FerrisKey 0.10.1 does not support.
  dcr_enabled  = true
  cimd_enabled = false

  # Resource indicators (RFC 8707) clients may request. Required before
  # ferriskey_resource_owners can map one to a client.
  allowed_resources = [var.mcp_resource_url]
}
