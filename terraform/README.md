# Terraform — realm `mestier` de FerrisKey

Configure de façon déclarative le realm `mestier` de l'instance FerrisKey
(`auth.mestier.fr`) : settings DCR/CIMD, clients OIDC de la démo et du MCP,
scopes MCP, token exchange et resource owners. Provider
[`ferriskey/ferriskey`](https://registry.terraform.io/providers/ferriskey/ferriskey)
`~> 0.2.0`.

Le realm `mestier` est **créé par le premier apply** (`ferriskey_realm`).
S'il existe déjà sur l'instance (créé à la main), adopte-le d'abord :
`terraform import ferriskey_realm.mestier mestier`.

## Bootstrap (une fois)

Le provider s'authentifie contre le token endpoint d'un realm. Deux phases :

1. **Password grant** (bootstrap) avec un client public et un admin :

   ```bash
   # NB: FerrisKey sert son API sous le préfixe /api — l'URL doit le contenir.
   export FERRISKEY_URL=https://auth.mestier.fr/api
   export FERRISKEY_REALM=master
   export FERRISKEY_CLIENT_ID=admin-cli
   export FERRISKEY_USERNAME=<admin>
   export FERRISKEY_PASSWORD=<admin password>
   ```

2. Crée ensuite un client confidentiel `terraform-runner` avec les droits
   admin (via l'admin API), puis passe en **client credentials** :

   ```bash
   export FERRISKEY_CLIENT_ID=terraform-runner
   export FERRISKEY_CLIENT_SECRET=<son secret>
   unset FERRISKEY_USERNAME FERRISKEY_PASSWORD
   ```

Toutes les variables ont un équivalent `FERRISKEY_*` ; aucun secret dans les
`.tf` ni dans le state en clair (les outputs de secrets sont `sensitive`).

## Apply

```bash
cd terraform
terraform init
terraform plan
terraform apply
```

## Pousser les secrets dans Kubernetes

Les deux clients confidentiels génèrent un secret serveur, exposé en output
`sensitive` :

```bash
kubectl -n mestier-demo create secret generic mestier-oidc-client \
  --from-literal=clientSecret="$(terraform output -raw api_demo_client_secret)"

kubectl -n mestier-demo create secret generic mestier-mcp-gateway \
  --from-literal=MCP_GATEWAY_EXCHANGE_CLIENT_SECRET="$(terraform output -raw mcp_gateway_client_secret)"
```

(Recréer avec `kubectl create secret ... --dry-run=client -o yaml | kubectl
apply -f -` pour mettre à jour sans écraser les autres clés.)

## Ce que ça configure

| Ressource Terraform | Effet |
|---|---|
| `ferriskey_realm_settings.mestier` | DCR on, CIMD off, `allowed_resources = [https://demo.mestier.fr/mcp]` |
| `ferriskey_client.api_demo` | client confidentiel `api-demo` |
| `ferriskey_client.webapp_demo` | client public PKCE `webapp-demo`, redirect `https://demo.mestier.fr/` |
| `ferriskey_client.mcp_gateway` | client confidentiel `mestier-mcp-gateway`, token exchange on |
| `ferriskey_client_scope.mcp` | scopes `mestier.read`, `mestier.doe.write`, `mestier.maintenance.write`, ouverts aux clients dynamiques |
| `ferriskey_client_token_exchange_policy.mcp_gateway_to_api` | échange vers audience `api-demo`, `allow_delegation = true` |
| `ferriskey_resource_owners.mestier` | resource `https://demo.mestier.fr/mcp` possédée par `mestier-mcp-gateway` |
