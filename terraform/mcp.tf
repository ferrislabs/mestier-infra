# Token exchange policy: the gateway swaps incoming AI-client tokens for
# api-demo tokens, with delegation allowed.
resource "ferriskey_client_token_exchange_policy" "mcp_gateway_to_api" {
  realm           = ferriskey_realm.mestier.name
  client_id       = ferriskey_client.mcp_gateway.client_uuid
  target_audience = ferriskey_client.api_demo.client_id

  allow_delegation = true
  allowed_scopes   = concat(["openid"], local.mcp_scopes)
}

# The protected resource is owned by the gateway client. allowed_resources
# must be set first, hence the depends_on.
resource "ferriskey_resource_owners" "mestier" {
  realm = ferriskey_realm.mestier.name

  owners = [
    {
      uri       = var.mcp_resource_url
      client_id = ferriskey_client.mcp_gateway.client_uuid
    },
  ]

  depends_on = [ferriskey_realm_settings.mestier]
}
