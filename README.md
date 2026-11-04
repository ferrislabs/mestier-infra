# Mestier Infra

GitOps configuration for the Mestier platform, deployed with **ArgoCD** on the `ferriskey-vps`
k3s cluster. There is a single environment, **`demo`**. **Kargo** keeps it current: every push to
`main` of the `mestier` repo builds a `sha-<commit>` image, Kargo promotes it by writing the tag
straight into this repo's `main`, and ArgoCD syncs it like any other change.

## Layout

```
mestier-infra/
├── charts/                 # Local Helm charts maintained here
│   ├── argocd/             # ArgoCD wrapper (argo-cd subchart + HTTPRoute + CNPG health check)
│   └── kargo/              # Kargo wrapper (kargo subchart + HTTPRoute + read-only ArgoCD RBAC)
├── kargo/
│   └── mestier-delivery/   # Kargo Project/Warehouse/Stage for the Mestier delivery pipeline
│                           # (platform-level, not nested in the env's app-of-apps)
├── base/                   # Env-agnostic building blocks
│   ├── ferriskey/
│   │   ├── db/             # Kustomize base for the CNPG database
│   │   └── values.yaml     # Common Ferriskey Helm values (image 0.10.2-rc1)
│   └── mestier/            # Mestier app: data layer (Kustomize bases) + common Helm values
│       ├── db/             # CNPG Postgres cluster (mestier-db)
│       ├── redis/          # Simple single-node Redis (official image, no HA)
│       ├── rustfs/         # RustFS S3-compatible object storage
│       └── values.yaml     # Common Mestier Helm values (api + webapp)
└── envs/
    └── demo/
        ├── root.yaml       # ← app-of-apps root: deploys the WHOLE env
        ├── apps/           # ArgoCD Application manifests (managed by root.yaml)
        ├── ferriskey/      # Ferriskey overlay (db) + Helm values → ns `ferriskey`
        └── mestier/        # Overlays (db, redis, rustfs) + Helm values → ns `mestier-demo`
```

**Pattern**: `envs/demo/root.yaml` is an app-of-apps. Applying it deploys everything. DRY comes
from Kustomize base + overlays (raw manifests) and layered Helm value files
(`base/.../values.yaml` + `envs/demo/.../values.yaml`).

**Naming convention** — root app-of-apps is the bare env name (`demo`); every other Application
is suffixed `-demo` (`mestier-db-demo`, `mestier-demo`, ...). `ferriskey` and `ferriskey-db` keep
their bare names: they were moved here from the old `production` env without being recreated, so
ArgoCD sees the same Applications. Application names live in one flat `argocd` namespace, so check
`argocd app list` before picking one. Namespaces: `mestier-demo` for the app, `ferriskey` for the
IAM.

**Ferriskey** — one instance, `auth.mestier.fr`, chart `0.10.1`, image `0.10.2-rc1`. Realm `mestier`.
The `ferriskey-db` CNPG cluster and its data are the ones that existed before; nothing is
recreated.

**Own RustFS** — `demo` runs its own RustFS in `mestier-demo` (bucket `mestier-files`). There is
no shared instance any more.

**One host, path-routed** — `demo.mestier.fr` serves api+webapp, split by path (`/api` → api,
everything else → webapp), the same pattern Ferriskey uses on `auth.mestier.fr`.

## Cluster prerequisites (provisioned outside this repo)

- **cert-manager** + ClusterIssuer `letsencrypt-internal` (DNS-01 via OVH webhook)
- **CloudNativePG** operator (`cnpg-system`)
- **Envoy Gateway** (class `eg`): `mestier-gateway` (`*.mestier.fr`, wildcard `mestier-tls`) and
  `internal-gateway` (`*.internal.ferriskey.rs`, for the ArgoCD and Kargo UIs)
- StorageClass `local-path` (default)
- DNS, all → `51.91.53.117`: `auth.mestier.fr`, `demo.mestier.fr`,
  `argocd.internal.ferriskey.rs`, `kargo.internal.ferriskey.rs`. Both `*.mestier.fr` records are
  covered by the existing wildcard cert; only the DNS records need adding.

## Bootstrap (run once)

> **Ordering matters.** The Mestier Application pins `targetRevision: "0.4.0"` for
> `oci://ghcr.io/ferrislabs/charts/mestier`. Confirm the version is pullable
> (`helm show chart oci://ghcr.io/ferrislabs/charts/mestier --version 0.4.0`) *then* apply the
> root. Applying out of order leaves the Application in a `ComparisonError` until the chart shows
> up — self-healing, but confusing to debug.

```bash
# 1. Install ArgoCD (wrapper chart: HTTPRoute + CNPG health customization)
helm dependency build charts/argocd
helm upgrade --install argocd charts/argocd -n argocd --create-namespace
kubectl -n argocd rollout status deploy/argocd-server

# 2. Install Kargo (wrapper chart: HTTPRoute + read-only Argo CD RBAC)
helm dependency build charts/kargo
helm upgrade --install kargo charts/kargo -n kargo --create-namespace \
  --set kargo.api.adminAccount.passwordHash=$(htpasswd -bnBC 10 "" "$KARGO_ADMIN_PASSWORD" | tr -d ':\n' | sed 's/^[^$]*//') \
  --set kargo.api.adminAccount.tokenSigningKey=$(openssl rand -base64 29 | tr -d "=+/")
kubectl -n kargo rollout status deploy/kargo-api

# 3. Deploy the whole demo environment via its root
kubectl apply -f envs/demo/root.yaml

# 4. Deploy the Kargo delivery pipeline for Mestier (Project/Warehouse/Stage)
kubectl apply -f kargo/mestier-delivery/application.yaml
```

ArgoCD then reconciles the environment automatically:
- **wave 0** — `ferriskey-db`: CNPG `Cluster` (DB `ferriskey`, secret `ferriskey-db-app`)
- **wave 1** — `ferriskey`: Helm chart (PreSync migration job, then API + webapp + HTTPRoute)
- **wave 0** — `mestier-db-demo` / `mestier-redis-demo` / `mestier-rustfs-demo`: data layer in
  namespace `mestier-demo`
- **wave 1** — `mestier-demo`: API + webapp, from the OCI chart

> **RustFS prerequisite** — the Mestier app references a secret holding its RustFS S3 credentials,
> which is intentionally **not** in git. Create it once before `mestier-rustfs-demo` syncs (the pod
> stays `Pending`/`CreateContainerConfigError` until it exists):
>
> ```bash
> kubectl create namespace mestier-demo --dry-run=client -o yaml | kubectl apply -f -
> kubectl -n mestier-demo create secret generic mestier-rustfs-credentials \
>   --from-literal=accessKey="$(openssl rand -hex 16)" \
>   --from-literal=secretKey="$(openssl rand -base64 32)"
> ```
>
> Retrieve them later with:
> `kubectl -n mestier-demo get secret mestier-rustfs-credentials -o jsonpath='{.data.accessKey}' | base64 -d`

> **Ferriskey OIDC clients** — the Mestier chart omits `AUTH_CLIENT_SECRET` entirely until you
> provide one, but the API refuses to authenticate without it. In realm `mestier` of Ferriskey,
> register `api-demo` (confidential) and `webapp-demo` (public, PKCE, redirect URI
> `https://demo.mestier.fr/`), then create the secret the API reads:
>
> ```bash
> kubectl -n mestier-demo create secret generic mestier-oidc-client \
>   --from-literal=clientSecret="<the secret Ferriskey generated for api-demo>"
> ```

> **Kargo git write-back credential** — the delivery pipeline pushes promoted image tags straight
> to this repo's `main`. Create a Secret labeled `kargo.akuity.io/cred-type: git` in namespace
> `mestier-delivery` (created by the `Project` in step 4 — wait for it to exist first), holding
> push credentials scoped to *this repo only* (a deploy key or a fine-grained PAT). This credential
> can write to whatever `main` auto-syncs, i.e. the whole demo environment:
>
> ```bash
> kubectl -n mestier-delivery create secret generic mestier-infra-git-push \
>   --from-literal=username="<git username or bot>" \
>   --from-literal=password="<token with write access to ferrislabs/mestier-infra only>"
> kubectl -n mestier-delivery label secret mestier-infra-git-push kargo.akuity.io/cred-type=git
> ```

### Passwords

```bash
# ArgoCD admin
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
# Ferriskey admin
kubectl get secret -n ferriskey ferriskey-api-admin -o jsonpath='{.data.password}' | base64 -d
# Kargo admin: whatever KARGO_ADMIN_PASSWORD was set to at install (see bootstrap step 2) —
# Kargo does not generate or store one for you the way ArgoCD does.
```

## Moving from dev / staging / production to demo (one-off, human)

The previous `dev`, `staging` and `production` environments, and the PR previews, were removed
from git. Removing them from git does **not** remove them from the cluster: their roots were
applied by hand, so nothing prunes them. Order matters because `ferriskey` and `ferriskey-db` move
from the production root to the demo root, and `kubectl delete` cascades through the Application
finalizer.

1. Merge the PR, then bootstrap `demo` as above, but apply `envs/demo/root.yaml` **first**, so the
   `ferriskey` / `ferriskey-db` Applications are adopted by the new parent. Check
   `argocd app get ferriskey` shows `Synced` and the 0.10.2-rc1 image rolled out.
2. Delete the old roots **without cascading to their children**, otherwise `ferriskey` goes with
   `mestier-production`:
   ```bash
   kubectl -n argocd delete application mestier-production --cascade=orphan
   kubectl -n argocd delete application dev staging --cascade=orphan
   kubectl -n argocd delete applicationset mestier-preview
   ```
3. Delete what is left of the old environments (children of `dev`, `staging`, `production`,
   and the generated `mestier-pr-*` previews), then their namespaces `mestier`, `mestier-staging`
   and `mestier-dev`. **This destroys the old production database and files**: confirm backups
   first. The `ferriskey` namespace must stay.
4. In Ferriskey (realm `mestier`), drop the clients `api`, `webapp`, `api-staging`, `webapp-staging`,
   `api-dev`, `webapp-dev`, `api-preview`, `webapp-preview` once nothing uses them, and delete the
   `mestier-staging` realm.
5. Kargo: the `staging` and `production` Stages disappear on their own once
   `kargo-mestier-delivery` syncs (`prune: true`). The `discord-webhook` Secret in
   `mestier-delivery` is no longer used. Delete it, and the notifications config left in the
   `argocd` release by running `helm upgrade --install argocd charts/argocd -n argocd`
   (and the `argocd-notifications-secret` token).
6. DNS: `app.mestier.fr`, `api.mestier.fr`, `staging.mestier.fr`, `dev.mestier.fr` and
   `pr-*.mestier.fr` no longer point at anything. Remove them if they have their own records.

## Mestier data layer

In-cluster endpoints for the Mestier API + webapp, in namespace `mestier-demo`:

| Service   | Host / endpoint           | Notes                                            |
|-----------|---------------------------|--------------------------------------------------|
| Postgres  | `mestier-db-rw:5432`      | DB `app`, user `app`, secret `mestier-db-app`    |
| Redis     | `mestier-redis:6379`      | No auth (in-cluster only), AOF persistence       |
| RustFS S3 | `mestier-rustfs:9000`     | Credentials in `mestier-rustfs-credentials`      |
| RustFS UI | `mestier-rustfs:9001`     | Web console (`RUSTFS_CONSOLE_ENABLE=true`)       |

## Kargo delivery pipeline (Warehouse → demo)

Kargo watches `ghcr.io/ferrislabs/mestier-api` and `ghcr.io/ferrislabs/mestier-webapp` for new
`sha-*` images (the `mestier` repo's CI pushes one on every merge to `main`) and bundles the pair
into a single Freight. The `demo` Stage auto-promotes every new Freight (`ProjectConfig`), so
the environment follows `main` with the Warehouse's 5 minute polling delay.

Each promotion writes `api.image.tag` / `webapp.image.tag` straight into
`envs/demo/mestier/values.yaml` on `main`; ArgoCD (already watching `main` for that path) syncs it
like any other commit. See `kargo/mestier-delivery/` for the `Project`/`Warehouse`/`Stage`
definitions.

**A promotion is not "done" at `git-push`.** The Stage's last step is `argocd-update` on
`mestier-demo`, so the promotion only succeeds once ArgoCD reports the Application `Synced` **and**
`Healthy`, i.e. pods actually came up on the new tag. This requires the Application to carry
`kargo.akuity.io/authorized-stage: mestier-delivery:demo` (already set in
`envs/demo/apps/mestier.yaml`); Kargo silently refuses to touch an Application without it.

**What does not follow `main`** — the Helm chart. `mestier-demo` pins chart `0.4.0`: a change to
the chart in the `mestier` repo needs its version published by `helm-chart-release` and the pin
bumped here.

## MCP

`mestier-demo` also runs the MCP entry point for AI clients: `mcp-gateway`,
`mcp-server` and Cerbos (chart 0.6.0). Clients reach it at
`https://demo.mestier.fr/mcp`; only the gateway is routed publicly.

Two things live outside git:

1. **Realm `mestier` in Ferriskey** (admin API): DCR on and CIMD off (ChatGPT's
   CIMD document asks for `private_key_jwt`, which Ferriskey 0.10.1 does not
   do), `allowed_resources: [https://demo.mestier.fr/mcp]`, the scopes
   `mestier.read`, `mestier.doe.write` and `mestier.maintenance.write` open to
   dynamic clients, a confidential client `mestier-mcp-gateway` with token
   exchange enabled and a policy `target_audience: api-demo`
   (`allow_delegation: true`), and a resource owner mapping the resource to that
   client. See `docs/chantiers/mcp.md` in the mestier repo.
2. **Secret** holding that client's secret:

```bash
kubectl -n mestier-demo create secret generic mestier-mcp-gateway \
  --from-literal=MCP_GATEWAY_EXCHANGE_CLIENT_SECRET="<client secret of mestier-mcp-gateway>"
```

An organization only answers MCP calls once `mcp_enabled` is set on it.

## Verify (after apply)

```bash
# Ferriskey
kubectl get cluster.postgresql.cnpg.io -n ferriskey          # → Cluster in healthy state
kubectl get job -n ferriskey ferriskey-database-migrations   # → Complete
kubectl get pods -n ferriskey                                # → api + webapp Running, image 0.10.2-rc1
curl -fsS https://auth.mestier.fr/api/health/ready           # → 200

# Mestier
kubectl get cluster.postgresql.cnpg.io -n mestier-demo mestier-db   # → healthy
kubectl get pods -n mestier-demo                                    # → api + webapp + redis + rustfs Running
kubectl get httproute -n mestier-demo                               # → host demo.mestier.fr
curl -s -o /dev/null -w '%{http_code}\n' https://demo.mestier.fr/api/v1/users/@me/organizations   # → 401 without a token

# Kargo
kargo get stages --project mestier-delivery                         # → demo, Healthy

# Everything ArgoCD knows about
argocd app list
# → demo, ferriskey-db, ferriskey, mestier-db-demo, mestier-redis-demo, mestier-rustfs-demo,
#   mestier-demo, kargo-mestier-delivery
```
