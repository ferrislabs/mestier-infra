# Mestier Infra

GitOps configuration for the Mestier platform, deployed with **ArgoCD** on the `ferriskey-vps`
k3s cluster. One ArgoCD instance manages every environment; environments are isolated by namespace
on the same cluster. **Kargo** drives image promotion across environments (dev → staging →
production) by writing the promoted tag straight into this repo's `main` — ArgoCD then syncs it
like any other change.

## Layout

```
mestier-infra/
├── charts/                 # Local Helm charts maintained here
│   ├── argocd/             # ArgoCD wrapper (argo-cd subchart + HTTPRoute + CNPG health check)
│   └── kargo/              # Kargo wrapper (kargo subchart + HTTPRoute + read-only ArgoCD RBAC)
├── kargo/
│   └── mestier-delivery/   # Kargo Project/Warehouse/Stages for the Mestier delivery pipeline
│                           # (platform-level, not nested in any env's app-of-apps)
├── base/                   # Env-agnostic building blocks (shared by all envs)
│   ├── ferriskey/
│   │   ├── db/             # Kustomize base for the CNPG database
│   │   └── values.yaml     # Common Ferriskey Helm values (production only, see below)
│   └── mestier/            # Mestier app: data layer (Kustomize bases) + common Helm values
│       ├── db/             # CNPG Postgres cluster (mestier-db)
│       ├── redis/          # Simple single-node Redis (official image, no HA)
│       ├── rustfs/         # RustFS S3-compatible object storage
│       └── values.yaml     # Common Mestier Helm values (api + webapp, all environments)
└── envs/
    ├── production/
    │   ├── root.yaml       # ← app-of-apps root: deploys the WHOLE env
    │   ├── apps/           # ArgoCD Application manifests (managed by root.yaml)
    │   ├── ferriskey/      # Per-env Kustomize overlay (db) + Helm values
    │   └── mestier/        # Per-env overlays (db, redis, rustfs) + Helm values → ns `mestier`
    ├── staging/            # Same shape, minus ferriskey/ (see "Shared Ferriskey" below) → ns `mestier-staging`
    └── dev/                # Same shape as staging → ns `mestier-dev`
```

**Pattern**: each env has one `root.yaml` (app-of-apps). Applying it deploys everything for that env.
DRY is achieved with Kustomize base + overlays (raw manifests) and layered Helm value files
(`base/.../values.yaml` + `envs/<env>/.../values.yaml`).

**Naming convention** — this is the one that actually shipped, follow it for any future environment:
- Root app-of-apps: bare env name (`mestier-production` is the one historical exception —
  production predates this convention; a new env's root is just `<env>`, e.g. `staging`, `dev`).
- Every other Application in that env is suffixed `-<env>` (`mestier-db-staging`,
  `mestier-staging`, ...) except in production, which keeps bare names (`mestier-db`, `mestier`,
  ...) for the same historical reason. Application names live in one flat `argocd` namespace
  across every environment, so they must all be globally unique — check `argocd app list` before
  picking one.
- Namespace: `mestier` for production (historical), `mestier-<env>` for anything added since.

**Shared Ferriskey** — there is one Ferriskey (IAM) instance, `auth.mestier.fr`, used by every
environment. `staging`/`dev` deploy only the Mestier data layer + app, no `ferriskey`/`ferriskey-db`
of their own. Each environment still registers its **own OIDC client** in that shared instance
(`AUTH_CLIENT_ID`: `mestier` / `mestier-staging` / `mestier-dev`) so a token issued for one
environment is never accepted by another — see "Ferriskey OIDC client per environment" below.

## Cluster prerequisites (provisioned outside this repo)

- **cert-manager** + ClusterIssuer `letsencrypt-internal` (DNS-01 via OVH webhook)
- **CloudNativePG** operator (`cnpg-system`)
- **Envoy Gateway** (class `eg`): `mestier-gateway` (`*.mestier.fr`, wildcard `mestier-tls`) and
  `internal-gateway` (`*.internal.ferriskey.rs`, for the ArgoCD and Kargo UIs)
- StorageClass `local-path` (default)
- DNS, all → `51.91.53.117`:
  `auth.mestier.fr`, `argocd.internal.ferriskey.rs`, `kargo.internal.ferriskey.rs`,
  `app.mestier.fr`, `api.mestier.fr`, `staging.mestier.fr`, `staging-api.mestier.fr`,
  `dev.mestier.fr`, `dev-api.mestier.fr` — the `*.mestier.fr` entries are covered by the existing
  wildcard cert, only the DNS records themselves need adding.

## Bootstrap (run once)

> **Ordering matters.** The Mestier Applications below pin `targetRevision: "0.2.0"` for
> `oci://ghcr.io/ferrislabs/charts/mestier`. That chart version is published by the `mestier` repo's
> `helm-chart-release` workflow on push to `main` — merge and land that first, confirm the
> version is pullable (`helm show chart oci://ghcr.io/ferrislabs/charts/mestier --version 0.2.0`),
> *then* apply the roots below. Applying out of order just leaves the Applications in a
> `ComparisonError` until the chart shows up — self-healing, not destructive, but confusing to
> debug if you don't know why.

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

# 3. Deploy the whole production environment via its root
kubectl apply -f envs/production/root.yaml

# 4. Deploy staging and dev the same way
kubectl apply -f envs/staging/root.yaml
kubectl apply -f envs/dev/root.yaml

# 5. Deploy the Kargo delivery pipeline for Mestier (Project/Warehouse/Stages)
kubectl apply -f kargo/mestier-delivery/application.yaml
```

ArgoCD then reconciles each environment automatically. Production also carries Ferriskey:
- **wave 0** — `ferriskey-db`: CNPG `Cluster` (creates DB `ferriskey` + secret `ferriskey-db-app`)
- **wave 1** — `ferriskey`: Helm chart (PreSync migration job, then API + webapp + HTTPRoute)
- **wave 0** — `mestier-db` / `mestier-redis` / `mestier-rustfs` (per env): data layer in
  namespace `mestier` / `mestier-staging` / `mestier-dev`
- **wave 1** — `mestier` (per env): API + webapp, from the OCI chart

> **RustFS prerequisite, per environment** — each environment's Mestier app references a secret
> holding its RustFS S3 credentials, which is intentionally **not** in git. Create it once before
> that environment's `mestier-rustfs` app syncs (the pod stays `Pending`/`CreateContainerConfigError`
> until it exists). Repeat for `mestier`, `mestier-staging`, `mestier-dev`:
>
> ```bash
> ns=mestier   # or mestier-staging / mestier-dev
> kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
> kubectl -n "$ns" create secret generic mestier-rustfs-credentials \
>   --from-literal=accessKey="$(openssl rand -hex 16)" \
>   --from-literal=secretKey="$(openssl rand -base64 32)"
> ```
>
> Retrieve them later with:
> `kubectl -n "$ns" get secret mestier-rustfs-credentials -o jsonpath='{.data.accessKey}' | base64 -d`

> **Ferriskey OIDC client per environment** — the Mestier chart omits `AUTH_CLIENT_SECRET`
> entirely (no env var, no crash) until you provide one, but the API refuses to authenticate
> without it. For each environment, register an OIDC client in the shared Ferriskey
> (`AUTH_CLIENT_ID`: `mestier` / `mestier-staging` / `mestier-dev`, redirect URI matching that
> env's webapp host), then create the secret it's read from:
>
> ```bash
> ns=mestier   # or mestier-staging / mestier-dev
> kubectl -n "$ns" create secret generic mestier-oidc-client \
>   --from-literal=clientSecret="<the secret Ferriskey generated for this client>"
> ```

> **Kargo git write-back credential** — the delivery pipeline pushes promoted image tags
> straight to this repo's `main`. Create a Secret labeled `kargo.akuity.io/cred-type: git` in
> namespace `mestier-delivery` (created by the `Project` in step 5 above — wait for it to exist
> first) holding push credentials scoped to *this repo only* (a deploy key or a fine-grained PAT,
> not a broad personal token — this credential can write to whatever `main` auto-syncs, i.e. all
> of production):
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

## Adding another environment

`staging` and `dev` are the reference implementations of this — copy whichever is closer to what
you need rather than starting from production (production alone still carries the historical
bare-name exception, see "Naming convention" above, and it's the only one with its own Ferriskey).

1. `cp -r envs/staging envs/<name>` (or `envs/dev`).
2. Rename every `-staging`/`-dev` suffix in `envs/<name>/apps/*.yaml` (`metadata.name`,
   `spec.destination.namespace`) to `-<name>`, and in `envs/<name>/mestier/*/kustomization.yaml`
   (`namespace:`).
3. `envs/<name>/root.yaml` → `metadata.name: <name>`, `spec.source.path: envs/<name>/apps`.
4. `envs/<name>/mestier/values.yaml` → update `ALLOWED_ORIGINS`, `AUTH_CLIENT_ID`, `API_URL`,
   `ISSUER_URL`, `gatewayApi.*.hostnames` for the new environment's hosts.
5. Before first sync: create `mestier-rustfs-credentials` and `mestier-oidc-client` in the new
   namespace (see "Bootstrap" above), and register the new `AUTH_CLIENT_ID` in Ferriskey.
6. `kubectl apply -f envs/<name>/root.yaml`
7. If this environment should also receive promoted images: add a `Stage` in
   `kargo/mestier-delivery/stages/`, writing to `envs/<name>/mestier/values.yaml`, and wire its
   `requestedFreight.sources` to whichever upstream Stage should feed it.

The `base/` building blocks are reused as-is — this is the whole point of keeping them env-agnostic.

## Verify (after apply)

```bash
# Ferriskey (production only)
kubectl get cluster.postgresql.cnpg.io -n ferriskey      # → Cluster in healthy state
kubectl get job -n ferriskey ferriskey-database-migrations # → Complete
kubectl get pods -n ferriskey                             # → api + webapp Running
kubectl get httproute -n ferriskey ferriskey             # → host auth.mestier.fr, parent mestier-gateway
curl -fsS https://auth.mestier.fr/api/health/ready        # → 200

# Mestier, per environment (swap the namespace/host)
kubectl get cluster.postgresql.cnpg.io -n mestier mestier-db   # → healthy
kubectl get pods -n mestier                                     # → api + webapp + redis + rustfs Running
kubectl get httproute -n mestier                                # → hosts app.mestier.fr / api.mestier.fr
curl -fsS https://api.mestier.fr/api/health/ready               # → 200

# Everything ArgoCD knows about
argocd app list
# → mestier-production, ferriskey-db, ferriskey, mestier-db, mestier-redis, mestier-rustfs, mestier,
#   staging, mestier-db-staging, ..., mestier-staging,
#   dev, mestier-db-dev, ..., mestier-dev,
#   kargo-mestier-delivery
```

## Mestier data layer (per environment)

In-cluster endpoints for the Mestier API + webapp — identical names in every namespace, only the
namespace itself changes (`mestier` / `mestier-staging` / `mestier-dev`):

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

## Kargo delivery pipeline (dev → staging → production)

Kargo watches `ghcr.io/ferrislabs/mestier-api` and `ghcr.io/ferrislabs/mestier-webapp` for new
`sha-*` images (the `mestier` repo's CI pushes one on every merge to `main`) and bundles the pair
into a single Freight. `dev` and `staging` auto-promote as soon as the upstream Stage is healthy;
`production` never does.

```bash
# Promoting to production is the one manual step in this pipeline:
kargo promote --project mestier-delivery --stage production --freight <freight-id>
# or: Kargo UI → Project "mestier-delivery" → Stage "production" → Promote
```

Each promotion writes `api.image.tag` / `webapp.image.tag` straight into
`envs/<env>/mestier/values.yaml` on `main`; ArgoCD (already watching `main` for that path) syncs
it like any other commit. See `kargo/mestier-delivery/` for the `Project`/`Warehouse`/`Stage`
definitions, and the "Kargo git write-back credential" bootstrap note above for the one secret
this needs that isn't in git.

**Accepted residual risk, by design of the environment/promotion policy already chosen for this
pipeline**: dev and staging share Ferriskey's issuer with production (mitigated by each having
its own OIDC client, not full isolation), and dev/staging auto-promote any image someone manages
to push to those GHCR repos (mitigated by requiring GHCR push access, but not by any additional
review or verification step before promotion). Both are consequences of "one shared Ferriskey" +
"dev/staging auto-promote" as decided for this environment topology, not oversights — revisit if
that trade-off ever needs tightening.

## Next steps (not in this repo yet)

- CNPG backups to the RustFS S3 bucket
- A verification step (health/smoke check) between Stages, beyond "the last promotion succeeded" —
  today's Stages carry no `verification` block
