# gitops

Argo CD watches `cluster/apps` (see `2-root-app.yaml`).

## api-next (mhav)

`cluster/apps/mhav/templates/api-next` runs the new API next to the old
`mhav-api`, which stays as it is until launch day. It has its own Redis and
uses `mhav-pg`, which the old API never used, so the two never touch each
other's data:

| | old | api-next |
| --- | --- | --- |
| API, worker, scheduler | `mhav-api`, `mhav-api-worker`, `mhav-api-scheduler` | `mhav-api-next`, `mhav-api-next-worker`, `mhav-api-next-scheduler` |
| Image tag | `image.tag` (prod CI) | `next.image.tag` (bumped by hand) |
| Redis | `redis.redis` (shared with dev) | `mhav-next-redis` (in `mhav`) |
| Postgres | — | `mhav-pg`, migrated by `mhav-api-next-migrate` |
| Forecast trainer | — | `mhav-api-next-forecast-trainer` (weekly) |
| Host | `megisholavonat.info/api` | `api.megisholavonat.info` |

The old and new code use some of the same Redis key names, hence the separate
Redis. Set `next.image.tag` to a commit the dev pipeline has already built (its
`mhav-api` and `mhav-api-trainer` images); `mhav-dev/values.yaml` holds the
latest one.

While both run, MÁV is polled twice as often: each worker refreshes every
minute (a fixed cron in `api/tasks/data.py`, there is no setting for it).

### DNS

There is no external-dns or cert-manager here: hosts sit behind Cloudflare,
which reaches Traefik's `websecureproxy` entrypoint. Add `api.megisholavonat.info`
in Cloudflare exactly like `dev.megisholavonat.info` (same record type and
target, proxied); if the proxy in front of Traefik keeps a list of hosts, add
it there too. Cloudflare's edge certificate already covers first-level
subdomains.

### Launch day

1. Point `megisholavonat.info/api` at `mhav-api-next` (the `/api` path in
   `templates/ingress.yaml`) and the web's `API_URL` at
   `http://mhav-api-next.mhav.svc:80`.
2. Deploy the new web (`image.tag`).
3. Keep `api.megisholavonat.info` on `mhav-api-next` for good; the app uses it.
4. Retire the old `mhav-api`, `mhav-api-worker` and `mhav-api-scheduler`.

## APNs key (mhav, mhav-dev)

`mhav-api-next` and its worker in `mhav`, and `mhav-dev-api` and its worker in
`mhav-dev`, send iOS Live Activity updates through APNs. `APNS_BUNDLE_ID` and
`APNS_USE_SANDBOX` (false: TestFlight and App Store builds use production APNs)
are set in each chart's `values.yaml`; the key comes from an `apns-secret` in
each namespace. The deployments reference it as optional, so pods start
without it and Live Activities stay off until it exists. Seal one per
namespace from the `.p8` downloaded from Apple (Key ID and Team ID are on the
key's page in the developer account):

```bash
for ns in mhav mhav-dev; do
  kubectl create secret generic apns-secret -n "$ns" --dry-run=client -o yaml \
    --from-literal=APNS_KEY_ID='<key id>' \
    --from-literal=APNS_TEAM_ID='<team id>' \
    --from-file=APNS_PRIVATE_KEY=AuthKey_<key id>.p8 \
    > "apns-secret-$ns.unsealed.yaml"
  kubeseal --cert kubeseal.pem -o yaml \
    < "apns-secret-$ns.unsealed.yaml" \
    > "cluster/apps/$ns/templates/apns-secret.yaml"
done
rm apns-secret-*.unsealed.yaml
```

Only if the Expo project enforces access tokens, seal one for `mhav` the same
way: `kubectl create secret generic expo-secret -n mhav ...
--from-literal=EXPO_ACCESS_TOKEN='<token>'` into
`cluster/apps/mhav/templates/expo-secret.yaml`.

Pods read secrets only at start, so restart the API and worker deployments
after Argo CD has synced a new one.

## Postgres (mhav, mhav-dev)

- The CloudNativePG operator is installed by `cluster/apps/cnpg.yaml`.
- Each environment has its own `Cluster` in `templates/postgres/cluster.yaml`
  (`mhav-pg` in `mhav`, `mhav-dev-pg` in `mhav-dev`). Size and instance count are
  set in the chart's `values.yaml`.
- The operator generates the credentials and stores them in the `<cluster>-app`
  secret. The API and worker read `DATABASE_URL` from its `uri` key, so the
  database password never lives in git and nothing has to be sealed for it.
- `templates/api/migrate-job.yaml` runs `alembic upgrade head` with the new image
  as an Argo CD Sync hook in wave -1, after the database (wave -2) and before the
  deployments (wave 0) roll. It is not a PreSync hook because PreSync runs
  before the `Cluster` exists on the very first sync.
- Roll this out only once the deployed `mhav-api` image contains `alembic`
  (the API's `feat/api-postgres` branch); older images fail the migration job.

### Sealing secrets

Secrets go in as `SealedSecret`s encrypted with the cluster's public key,
`kubeseal.pem`. Write the plain secret to a `*.unsealed.yaml` file (ignored by
git), seal it, and commit only the sealed output. For example, credentials for
Postgres backups to object storage (see the commented `backup` block in the
`Cluster`):

```bash
kubectl create secret generic mhav-pg-backup -n mhav --dry-run=client -o yaml \
  --from-literal=ACCESS_KEY_ID='<access key id>' \
  --from-literal=SECRET_ACCESS_KEY='<secret access key>' \
  > mhav-pg-backup.unsealed.yaml
kubeseal --cert kubeseal.pem -o yaml \
  < mhav-pg-backup.unsealed.yaml \
  > cluster/apps/mhav/templates/postgres/backup-secret.yaml
```

Use `-n mhav-dev` and the `mhav-dev` chart for the dev environment; a sealed
secret only decrypts in the namespace it was sealed for.
