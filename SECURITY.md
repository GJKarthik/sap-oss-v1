# Security

## Credentials and secrets

- **Never commit** `.env` files or any file containing passwords, API keys, or tokens. Use `.env.example` as a template and keep real values in `.env`, which is ignored by Git.
- If credentials were previously committed (e.g. in `sap_openai_server/.env` or `tests/btp-integration/.env`), **rotate them immediately** in BTP Cockpit (AI Core, HANA Cloud, Object Store) and invalidate any exposed tokens.
- Prefer environment variables or a secret manager (e.g. BTP secrets, vault) over local `.env` in production.

## Reporting vulnerabilities

Please report security issues privately to the maintainers; do not open public issues for vulnerabilities.
