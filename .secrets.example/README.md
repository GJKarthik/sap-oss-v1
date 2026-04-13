Copy this directory to `.secrets/` and replace each file with the real value only.

Or run from the repo root:

```bash
bash scripts/operationalize/bootstrap-local-env.sh
```

Expected files:
- `hana_user`
- `hana_password`
- `aicore_client_id`
- `aicore_client_secret`

See [docs/runbooks/operationalize-apps.md](../docs/runbooks/operationalize-apps.md) for the full operational checklist.
