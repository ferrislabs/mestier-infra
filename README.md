# Mestier Infra

GitOps configuration for the Mestier platform, deployed with **ArgoCD** on the `ferriskey-vps`
k3s cluster. One ArgoCD instance manages every environment; environments are isolated by namespace
on the same cluster.

## Layout

```
mestier-infra/
├── charts/                 # Local Helm charts maintained here
│   └── argocd/             # ArgoCD wrapper (argo-cd subchart + HTTPRoute + CNPG health check)
├── base/                   # Env-agnostic building blocks (shared by all envs)
│   ├── ferriskey/
│   │   ├── db/             # Kustomize base for the CNPG database
│   │   └── values.yaml     # Common Ferriskey Helm values
│   └── mestier/            # Mestier app data layer (Kustomize bases)
│       ├── db/             # CNPG Postgres cluster (mestier-db)
│       ├── redis/          # Simple single-node Redis (official image, no HA)
│       └── rustfs/         # RustFS S3-compatible object storage
└── envs/
    └── production/
        ├── root.yaml       # ← app-of-apps root: deploys the WHOLE env
        ├── apps/           # ArgoCD Application manifests (managed by root.yaml)
        ├── ferriskey/      # Per-env Kustomize overlay (db) + Helm values
        └── mestier/        # Per-env overlays (db, redis, rustfs) → ns `mestier`
```

**Pattern**: each env has one `root.yaml` (app-of-apps). Applying it deploys everything for that env.
DRY is achieved with Kustomize base + overlays (raw manifests) and layered Helm value files
(`base/.../values.yaml` + `envs/<env>/.../values.yaml`).

## Cluster prerequisites (provisioned outside this repo)

- **cert-manager** + ClusterIssuer `letsencrypt-internal` (DNS-01 via OVH webhook)
- **CloudNativePG** operator (`cnpg-system`)
- **Envoy Gateway** (class `eg`): `mestier-gateway` (`*.mestier.fr`, wildcard `mestier-tls`) and
  `internal-gateway` (`*.internal.ferriskey.rs`, for the ArgoCD UI)
- StorageClass `local-path` (default)
- DNS: `auth.mestier.fr` and `argocd.internal.ferriskey.rs` → `51.91.53.117`

## Bootstrap (run once)

```bash
# 1. Install ArgoCD (wrapper chart: HTTPRoute + CNPG health customization)
helm dependency build charts/argocd
helm upgrade --install argocd charts/argocd -n argocd --create-namespace
kubectl -n argocd rollout status deploy/argocd-server

# 2. Deploy the whole production environment via its root
kubectl apply -f envs/production/root.yaml
```

ArgoCD then reconciles production automatically:
- **wave 0** — `ferriskey-db`: CNPG `Cluster` (creates DB `ferriskey` + secret `ferriskey-db-app`)
- **wave 1** — `ferriskey`: Helm chart (PreSync migration job, then API + webapp + HTTPRoute)
- **wave 0** — `mestier-db` / `mestier-redis` / `mestier-rustfs`: Mestier data layer in
  namespace `mestier` (Postgres via CNPG, Redis, RustFS S3 storage)

> **RustFS prerequisite** — the deployment references a secret holding its S3
> credentials, which is intentionally **not** in git. Create it once before the
> `mestier-rustfs` app syncs (the pod stays `Pending`/`CreateContainerConfigError`
> until it exists):
>
> ```bash
> kubectl create namespace mestier --dry-run=client -o yaml | kubectl apply -f -
> kubectl -n mestier create secret generic mestier-rustfs-credentials \
>   --from-literal=accessKey="$(openssl rand -hex 16)" \
>   --from-literal=secretKey="$(openssl rand -base64 32)"
> ```
>
> Retrieve them later with:
> `kubectl -n mestier get secret mestier-rustfs-credentials -o jsonpath='{.data.accessKey}' | base64 -d`

### Passwords

```bash
# ArgoCD admin
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
# Ferriskey admin
kubectl get secret -n ferriskey ferriskey-api-admin -o jsonpath='{.data.password}' | base64 -d
```

## Adding an environment (e.g. staging)

1. `cp -r envs/production envs/staging`
2. In `envs/staging/ferriskey/db/kustomization.yaml` → set `namespace: ferriskey-staging`.
3. In `envs/staging/ferriskey/values.yaml` → set `publicHost`, `allowedOrigins`, `parentRefs`.
4. In `envs/staging/apps/*.yaml` and `root.yaml` → repoint `path:` to `envs/staging/...`, set
   `destination.namespace: ferriskey-staging`, rename the root to `mestier-staging`.
5. `kubectl apply -f envs/staging/root.yaml`

The `base/` building blocks are reused as-is.

## Verify (after apply)

```bash
kubectl get cluster.postgresql.cnpg.io -n ferriskey      # → Cluster in healthy state
kubectl get job -n ferriskey ferriskey-database-migrations # → Complete
kubectl get pods -n ferriskey                             # → api + webapp Running
kubectl get httproute -n ferriskey ferriskey             # → host auth.mestier.fr, parent mestier-gateway
curl -fsS https://auth.mestier.fr/api/health/ready        # → 200
argocd app list                                          # → mestier-production, ferriskey-db, ferriskey
```

## Mestier data layer (namespace `mestier`)

In-cluster endpoints for the Mestier API + webapp (deployed later, same pattern):

| Service   | Host / endpoint           | Notes                                            |
|-----------|---------------------------|--------------------------------------------------|
| Postgres  | `mestier-db-rw:5432`      | DB `app`, user `app`, secret `mestier-db-app`    |
| Redis     | `mestier-redis:6379`      | No auth (in-cluster only), AOF persistence       |
| RustFS S3 | `mestier-rustfs:9000`     | Credentials in `mestier-rustfs-credentials`      |
| RustFS UI | `mestier-rustfs:9001`     | Web console (`RUSTFS_CONSOLE_ENABLE=true`)       |

Verify:

```bash
kubectl get cluster.postgresql.cnpg.io -n mestier mestier-db   # → healthy
kubectl get pods -n mestier                                     # → redis + rustfs Running
kubectl -n mestier exec deploy/mestier-redis -- redis-cli ping  # → PONG
```

## Next steps (not in this repo yet)

- Provision the `mestier` realm + `api` client in Ferriskey
  (`AUTH_ISSUER=https://auth.mestier.fr/realms/mestier`)
- Mestier API + webapp wired to the data layer above (same base/overlay pattern)
- CNPG backups to the RustFS S3 bucket
