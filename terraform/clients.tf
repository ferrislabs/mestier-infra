# Confidential client of the Mestier API. Its secret feeds the
# mestier-oidc-client Kubernetes secret (AUTH_CLIENT_SECRET) — see outputs.tf.
resource "ferriskey_client" "api_demo" {
  realm       = ferriskey_realm.mestier.name
  client_id   = "api-demo"
  name        = "Mestier API (demo)"
  client_type = "confidential"
}

# Public PKCE client for the browser sign-in flow.
resource "ferriskey_client" "webapp_demo" {
  realm                        = ferriskey_realm.mestier.name
  client_id                    = "webapp-demo"
  name                         = "Mestier Webapp (demo)"
  client_type                  = "public"
  public_client                = true
  require_pkce                 = true
  direct_access_grants_enabled = false
  redirect_uris                = [var.demo_app_url]
}

# Confidential client of the MCP gateway: it performs the RFC 8693 token
# exchange on behalf of dynamically registered AI clients. Its secret feeds
# the mestier-mcp-gateway Kubernetes secret — see outputs.tf.
resource "ferriskey_client" "mcp_gateway" {
  realm                  = ferriskey_realm.mestier.name
  client_id              = "mestier-mcp-gateway"
  name                   = "Mestier MCP Gateway"
  client_type            = "confidential"
  token_exchange_enabled = true
}
