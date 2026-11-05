output "api_demo_client_secret" {
  description = "Secret of api-demo. Push it as the clientSecret key of the mestier-oidc-client secret in namespace mestier-demo."
  value       = ferriskey_client.api_demo.secret
  sensitive   = true
}

output "mcp_gateway_client_secret" {
  description = "Secret of mestier-mcp-gateway. Push it as MCP_GATEWAY_EXCHANGE_CLIENT_SECRET of the mestier-mcp-gateway secret in namespace mestier-demo."
  value       = ferriskey_client.mcp_gateway.secret
  sensitive   = true
}
