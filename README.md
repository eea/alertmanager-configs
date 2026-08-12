# alertmanager-configs

Source of truth for Alertmanager **routing** (`AlertmanagerConfig` objects) — which
alerts go to Matrix and which are ignored. The webhook URL's secrets (API key +
Matrix room id) are **never committed**; they live in per-cluster Kubernetes
Secrets built from gitignored `.env` files.

Three scripts, all **dry-run by default** — add `--apply` to make real changes:

- **`apply.sh`** — push routing (the `configs/*.yaml`).
- **`sync-secrets.sh`** — create/update the `matrix-webhook-url` Secret. Only when a secret is new or changes.
- **`export.sh`** — one-time import of existing live configs into this repo.

Requires `kubectl` and `envsubst`. `export.sh` also needs `yq` and GNU grep.

---

## Edit or ignore an alert (the common case)

No secrets involved. Edit the routing and apply that namespace:

```bash
$EDITOR configs/graylog.yaml
./apply.sh <kubeconfig> graylog             # preview
./apply.sh <kubeconfig> graylog --apply     # apply
```

**To ignore an alert**, route it to the `'null'` receiver. Routes are evaluated
top-to-bottom and all use `continue: false`, so the ignore rule must sit **above**
any route that would otherwise match it (e.g. above the `warning` route for a
warning-severity alert). Worked example in `configs/graylog.yaml`:

```yaml
- continue: false
  matchers:
    - name: alertname
      value: KubePersistentVolumeFillingUp
  receiver: 'null'
```

The alert still fires and stays visible in the Alertmanager UI — only the Matrix
message is suppressed. Narrow it with more matchers (e.g. `namespace`).

**Applying scope** — `apply.sh` needs exactly one:

```bash
./apply.sh <kubeconfig> graylog sentry      # named namespaces
./apply.sh <kubeconfig> -f namespaces.prod   # namespaces listed in a file
./apply.sh <kubeconfig> --all               # every configs/*.yaml
```

---

## Add a new namespace

Needs a secret (new) **and** a config. Create both, secret first:

```bash
# 1. secret value (KEY + ROOM_ID come from your password manager / vault)
cp secrets/example.env secrets/prod/newns.env && $EDITOR secrets/prod/newns.env
./sync-secrets.sh <kubeconfig> --cluster prod newns --apply

# 2. routing (copy an existing config as a starting point)
cp configs/graylog.yaml configs/newns.yaml && $EDITOR configs/newns.yaml
./apply.sh <kubeconfig> newns --apply
```

`configs/<ns>.yaml` and `secrets/<cluster>/<ns>.env` are tied by the `<ns>` name.
Keep the config's `urlSecret` block and `managed-by` label as in the others.

---

## Change a secret (rotate key / change room)

```bash
$EDITOR secrets/prod/graylog.env
./sync-secrets.sh <kubeconfig> --cluster prod graylog --apply   # one namespace
./sync-secrets.sh <kubeconfig> --cluster prod --all --apply     # all on that cluster
```

Push is one-way (`.env` → cluster): an existing Secret is **overwritten** to match
the local file. `--cluster` is the value written into the URL (shown in the Matrix
alert title) — not cluster targeting; the kubeconfig picks the cluster.

---

## Another cluster

Same configs, different kubeconfig + `--cluster`, and per-cluster `.env` files under
`secrets/<cluster>/`:

```bash
./sync-secrets.sh <kubeconfig-dev> --cluster dev --all --apply
./apply.sh <kubeconfig-dev> --all --apply
```

---

## First-time import (once per repo)

`export.sh` pulls live configs in, strips server fields, moves `key`/`room_id` into
`secrets/<cluster>/<ns>.env`, and rewrites `url` → `urlSecret`:

```bash
./export.sh <kubeconfig> graylog sentry   # or: -f namespaces.prod
```

Namespaces come from CLI args, `-f <file>`, or cluster discovery (needs cluster-scope
access). After it runs, confirm `url.template` matches the live URL's non-secret
parts, and re-add any ignore routes.

---

## Things to know

- **Secret values are not in git** (`.env` is gitignored). The repo is the source of
  truth for *routing*; for *secret values* it's your vault / the live cluster. Read a
  live one with:
  `kubectl --kubeconfig=<kc> get secret matrix-webhook-url -n <ns> -o jsonpath='{.data.url}' | base64 -d`
- **Order:** for a new namespace, `sync-secrets.sh` before `apply.sh` — the config
  references a Secret that must already exist (apply.sh warns if it doesn't).
- **No deletes:** `apply.sh` never prunes. Removing a `configs/<ns>.yaml` leaves the
  live object in place.
- **`url.template`** defines the URL shape for every namespace; `sync-secrets.sh`
  fills in `${KEY}`/`${ROOM_ID}` (from `.env`) and `${CLUSTER}` (from `--cluster`).
