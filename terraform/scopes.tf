locals {
  mcp_scopes = ["mestier.read", "mestier.doe.write", "mestier.maintenance.write"]
}

# Scopes open to dynamically registered clients (DCR).
resource "ferriskey_client_scope" "mcp" {
  for_each = toset(local.mcp_scopes)

  realm                        = ferriskey_realm.mestier.name
  name                         = each.value
  description                  = "MCP access: ${each.value}"
  dynamic_registration_allowed = true
}

# Optional scopes of the API — the audience MCP tokens are exchanged for.
resource "ferriskey_client_scope_assignment" "api_demo" {
  for_each = toset(local.mcp_scopes)

  realm     = ferriskey_realm.mestier.name
  client_id = ferriskey_client.api_demo.client_uuid
  scope_id  = ferriskey_client_scope.mcp[each.value].scope_id
  type      = "optional"
}

# Optional scopes of the gateway client.
resource "ferriskey_client_scope_assignment" "mcp_gateway" {
  for_each = toset(local.mcp_scopes)

  realm     = ferriskey_realm.mestier.name
  client_id = ferriskey_client.mcp_gateway.client_uuid
  scope_id  = ferriskey_client_scope.mcp[each.value].scope_id
  type      = "optional"
}
