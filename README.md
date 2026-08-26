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
of their own. Production has its own realm (`mestier`); `staging` and `dev` **share** a second
realm (`mestier-staging`) — but each still registers its **own OIDC clients** within whichever
realm it uses (`api`/`webapp` for production, `api-staging`/`webapp-staging` for staging,
`api-dev`/`webapp-dev` for dev), so a token issued for one environment is never accepted by
another even when the realm is shared — see "Ferriskey OIDC client per environment" below.

**Shared RustFS** — similarly, there is one RustFS instance (production's, namespace `mestier`).
`staging`/`dev` don't deploy their own — they point `FILE_STORAGE_ENDPOINT` at production's
Service across namespaces and use their own bucket (`mestier-files-staging`, `mestier-files-dev`)
so environments never share files. The RustFS **credentials** are the same Secret, copied into
each namespace (see "RustFS prerequisite" below) — not regenerated per environment, since it's
the same instance underneath.

**One host, path-routed** — `staging`/`dev` each serve api+webapp from a single hostname
(`staging.mestier.fr`, `dev.mestier.fr`), split by path (`/api` → api, everything else → webapp) —
the same pattern Ferriskey itself uses on `auth.mestier.fr`. Production predates this convention
and still uses two hosts (`api.mestier.fr` + `app.mestier.fr`); nothing forces a new environment
to pick one pattern over the other, but one-host-per-env is one fewer DNS record and one fewer
`ALLOWED_ORIGINS` entry to keep in sync.

## Cluster prerequisites (provisioned outside this repo)

- **cert-manager** + ClusterIssuer `letsencrypt-internal` (DNS-01 via OVH webhook)
- **CloudNativePG** operator (`cnpg-system`)
- **Envoy Gateway** (class `eg`): `mestier-gateway` (`*.mestier.fr`, wildcard `mestier-tls`) and
  `internal-gateway` (`*.internal.ferriskey.rs`, for the ArgoCD and Kargo UIs)
- StorageClass `local-path` (default)
- DNS, all → `51.91.53.117`:
  `auth.mestier.fr`, `argocd.internal.ferriskey.rs`, `kargo.internal.ferriskey.rs`,
  `app.mestier.fr`, `api.mestier.fr`, `staging.mestier.fr`, `dev.mestier.fr` — the `*.mestier.fr`
  entries are covered by the existing wildcard cert, only the DNS records themselves need adding.
  `staging`/`dev` need only one record each (see "One host, path-routed" above).

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
- **wave 0** — `mestier-db` / `mestier-redis` (per env): data layer in namespace `mestier` /
  `mestier-staging` / `mestier-dev` — `mestier-rustfs` exists in `mestier` only, shared by every env
- **wave 1** — `mestier` (per env): API + webapp, from the OCI chart

> **RustFS prerequisite** — production's Mestier app references a secret holding its RustFS S3
> credentials, which is intentionally **not** in git. Create it once before `mestier-rustfs`
> syncs (the pod stays `Pending`/`CreateContainerConfigError` until it exists):
>
> ```bash
> kubectl create namespace mestier --dry-run=client -o yaml | kubectl apply -f -
> kubectl -n mestier create secret generic mestier-rustfs-credentials \
>   --from-literal=accessKey="$(openssl rand -hex 16)" \
>   --from-literal=secretKey="$(openssl rand -base64 32)"
> ```
>
> `staging`/`dev` share this same RustFS instance (see "Shared RustFS" above) — copy the same
> Secret into their namespaces instead of generating new credentials:
>
> ```bash
> for ns in mestier-staging mestier-dev; do
>   kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
>   kubectl -n mestier get secret mestier-rustfs-credentials -o json \
>     | jq --arg ns "$ns" '.metadata = {name: .metadata.name, namespace: $ns}' \
>     | kubectl apply -f -
> done
> ```
>
> Retrieve the credentials later with:
> `kubectl -n mestier get secret mestier-rustfs-credentials -o jsonpath='{.data.accessKey}' | base64 -d`

> **Ferriskey OIDC clients** — the Mestier chart omits `AUTH_CLIENT_SECRET` entirely (no env var,
> no crash) until you provide one, but the API refuses to authenticate without it. Register each
> environment's OIDC clients in the appropriate Ferriskey realm — `api`/`webapp` in realm `mestier`
> for production, `api-staging`/`webapp-staging` in realm `mestier-staging` for staging,
> `api-dev`/`webapp-dev` in that same shared `mestier-staging` realm for dev — redirect URI
> matching that env's webapp host, then create the secret the API client's secret is read from:
>
> ```bash
> ns=mestier   # or mestier-staging / mestier-dev
> kubectl -n "$ns" create secret generic mestier-oidc-client \
>   --from-literal=clientSecret="<the secret Ferriskey generated for that env's api-* client>"
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

> **Kargo Discord notification credential** — the `staging`/`production` Stages' `http` step
> posts to a Discord webhook using `${{ secret('discord-webhook').url }}`. Create it as a generic
> credential (not `git`) in the same namespace:
>
> ```bash
> kubectl -n mestier-delivery create secret generic discord-webhook \
>   --from-literal=url="<the Discord channel's webhook URL>"
> kubectl -n mestier-delivery label secret discord-webhook kargo.akuity.io/cred-type=generic
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
5. Before first sync: copy `mestier-rustfs-credentials` into the new namespace and create
   `mestier-oidc-client` there (see "Bootstrap" above), and register the new environment's OIDC
   clients in Ferriskey — either its own realm or an existing shared one.
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

**Verification — a promotion is not "done" at `git-push`.** Every Stage's `promotionTemplate`
ends its write-back with an `argocd-update` step referencing that env's Application
(`mestier-dev` / `mestier-staging` / `mestier`). This activates Kargo's [Implicit ArgoCD
Verification](https://docs.kargo.io/user-guide/how-to-guides/verification): the step — and so the
whole promotion — only succeeds once ArgoCD reports the Application `Synced` **and** `Healthy`,
i.e. pods actually came up on the new tag, not merely "the commit landed". `staging` and
`production` only ever auto-promote/accept Freight that a Stage has itself verified this way. No
Argo Rollouts `AnalysisTemplate` is involved — that path needs Argo Rollouts CRDs, which this
cluster doesn't run — this is Kargo's own health check, and it requires the Application to carry
`kargo.akuity.io/authorized-stage: mestier-delivery:<stage>` (already set on all three
`envs/*/apps/mestier*.yaml`; Kargo silently refuses to touch an Application missing it).

**Git tag on every verified production promotion.** Once `production`'s `argocd-update` step
confirms `mestier` is `Healthy`, the Stage tags this repo — `production-sha-<shortsha>` — and
pushes the tag. Because the tag step runs *after* verification, its existence is itself the audit
trail: `git tag -l 'production-*'` lists every production deploy that actually came up healthy,
distinct from every production deploy merely *attempted*. This tags `mestier-infra`, not the
`mestier` app repo, and needs no credential beyond the existing git write-back one.

**Discord notification on `staging`/`production`.** Same ordering guarantee: the `http` step
posting to Discord (see "Kargo Discord notification credential" above) is the last step, so a
message only ever arrives once the environment is confirmed healthy — a broken rollout stops at
`argocd-update` and nothing gets reported as promoted. `dev` stays silent (too frequent, and
nothing downstream depends on a human noticing). Native Kargo `send-message` notifications exist
but are an [Akuity-Platform-only](https://docs.kargo.io/) feature; the generic `http` step is the
open-source-compatible substitute and works the same with any webhook-based receiver.

**Known gap**: this only notifies on a *successful* verified promotion. A promotion that fails
verification (Application goes `Degraded`/never reaches `Healthy`) currently reports nowhere but
`kargo get promotions -n mestier-delivery` / the Kargo UI — there is no OSS-native "on failure"
hook analogous to `argocd-update`'s health gating. Check the pipeline after a promotion you expect
to have gone out; don't assume silence means success.

**Accepted residual risk, by design of the environment/promotion policy already chosen for this
pipeline**: dev and staging share Ferriskey's issuer with production (mitigated by each having
its own OIDC client, not full isolation), and dev/staging auto-promote any image someone manages
to push to those GHCR repos (mitigated by requiring GHCR push access, but not by any additional
review or verification step before promotion). Both are consequences of "one shared Ferriskey" +
"dev/staging auto-promote" as decided for this environment topology, not oversights — revisit if
that trade-off ever needs tightening.

## Rollback

The mechanism is the same for every environment — **re-promote the last known-good Freight** —
because that's a normal promotion Kargo already verifies (see "Verification" above); it is not a
special code path. `production`'s manual-only policy makes this safe by default. `dev`/`staging`
auto-promote, which needs one extra step (below) so your rollback doesn't get immediately
overwritten by the next Warehouse discovery.

### 1. Find the last known-good Freight

```bash
# What production is running now, and its promotion history:
kargo get stage production -n mestier-delivery -o yaml
kargo get freight -n mestier-delivery
```

Or use the audit trail directly, when you know a specific past release worked (production only —
these tags only exist for promotions that passed `argocd-update`'s health check, see "Git tag on
every verified production promotion" above):

```bash
git -C mestier-infra tag -l 'production-*' --sort=-creatordate | sed -n '2,5p'
# → production-sha-<shortsha> of the last few verified deploys, newest first;
#   the one you want is usually the *second* entry, i.e. the one before the bad one.
```

The tag name embeds the `mestier-api` image tag (`sha-<shortsha>`). Match that against
`kargo get freight -n mestier-delivery` to find the Freight ID that produced it — that ID is what
`kargo promote` takes.

### 2. Production — just re-promote it

```bash
kargo promote --project mestier-delivery --stage production --freight <good-freight-id>
```

Runs the exact same pipeline as any promotion: writes the old tags into
`envs/production/mestier/values.yaml`, waits for `mestier` to be `Healthy` again, tags
`mestier-infra`, notifies Discord. If the bad Freight only just went out and staging/dev haven't
moved on yet, no further action is needed.

### 3. `dev` / `staging` — pause auto-promotion first

Left alone, the Warehouse's next discovery cycle can auto-promote a newer Freight right back over
your rollback (that's the point of auto-promotion — it always wants the newest verified image).
Hold the Stage still before rolling it back:

```bash
kubectl -n mestier-delivery patch projectconfig mestier-delivery --type merge -p '
spec:
  promotionPolicies:
  - stageSelector: {name: dev}
    autoPromotionEnabled: false
  - stageSelector: {name: staging}
    autoPromotionEnabled: false
  - stageSelector: {name: production}
    autoPromotionEnabled: false
'
```

Then re-promote the good Freight to that Stage (`kargo promote --stage dev|staging --freight ...`,
same as step 2). Once you're ready to resume the normal flow, flip `dev`/`staging` back to `true`
— **not** by re-applying the live-patched object, but by re-syncing
`kargo/mestier-delivery/project-config.yaml` from git (`argocd app sync kargo-mestier-delivery` or
just wait for its next auto-sync), so the patch above doesn't quietly become permanent drift.

### Emergency alternative: bypass Kargo entirely

If Kargo itself is unavailable (down, misconfigured) and an environment needs to come back
*right now*, hand-edit the tag and push directly:

```bash
# e.g. envs/production/mestier/values.yaml
sed -i 's/tag: sha-.*/tag: sha-<known-good-shortsha>/' envs/production/mestier/values.yaml
git commit -am "fix: emergency rollback of mestier to sha-<known-good-shortsha>"
git push origin main
```

ArgoCD picks it up on its own (already watching `main`), no Kargo involvement needed. The
trade-off: this skips the `argocd-update` health gate entirely (you're asserting it's good, not
verifying it), and it leaves Kargo's own bookkeeping (`Stage.status.currentFreight`) pointing at
the Freight it still believes is deployed. Treat this as a stop-the-bleeding move only — follow up
with a real `kargo promote` of that same good Freight once Kargo is healthy again, so its state
matches reality and auto-promotion doesn't fight you on the next discovery cycle.

## Next steps (not in this repo yet)

- CNPG backups to the RustFS S3 bucket
- Notification on a *failed* verification (see "Known gap" above) — today, Discord only hears
  about promotions that succeeded; a `Degraded` Application currently reports nowhere but
  `kargo get promotions` / the Kargo UI.
