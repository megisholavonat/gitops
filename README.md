# gitops

Argo CD watches `cluster/apps` (see `2-root-app.yaml`).

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

### APNs key (mhav, mhav-dev)

The API and the worker send iOS Live Activity updates through APNs.
`APNS_BUNDLE_ID` and `APNS_USE_SANDBOX` are set in each chart's `values.yaml`;
the key itself comes from an `apns-secret` in each namespace. The deployments
reference it as optional, so pods start without it and Live Activities stay off
until it exists. Seal one per namespace from the `.p8` downloaded from Apple
(Key ID and Team ID are on the key's page in the developer account):

```bash
for ns in mhav mhav-dev; do
  kubectl create secret generic apns-secret -n "$ns" --dry-run=client -o yaml \
    --from-literal=APNS_KEY_ID='<key id>' \
    --from-literal=APNS_TEAM_ID='<team id>' \
    --from-file=APNS_PRIVATE_KEY=AuthKey_<key id>.p8 \
    > "apns-secret-$ns.unsealed.yaml"
  kubeseal --cert kubeseal.pem -o yaml \
    < "apns-secret-$ns.unsealed.yaml" \
    > "cluster/apps/$ns/templates/api/apns-secret.yaml"
done
rm apns-secret-*.unsealed.yaml
```

Pods read the secret only at start, so restart `mhav-api`/`mhav-api-worker`
(and the `mhav-dev-` ones) after Argo CD has synced it.
