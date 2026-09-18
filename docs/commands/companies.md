# rd companies

Companies (accounts) in the CRM. Part of LeadDrive. Run `rd companies <verb> --help` for the exhaustive
flag list; this page covers the essentials + examples.

## `rd companies list [-j]`

List companies, newest first.

| Flag | Purpose |
|---|---|
| `--search Q` | match name or domain |
| `--industry I` | filter by industry |
| `--page N` / `--limit N` | pagination (max 100/page) |

```sh
rd companies list --search acme
rd companies list -j | jq -r '.companies[].id'
```

## `rd companies get ID [-j]`

Show one company.

## `rd companies create --name NAME [-j]`

Create a company. **Idempotent** when `--external-id` is given: re-running with the same key updates the
existing company instead of duplicating.

| Flag | Purpose |
|---|---|
| `--name` | **required** |
| `--domain` `--url` `--industry` `--phone` `--city` `--country` `--postal-code` `--employees` `--type` `--description` `--owner` | attributes |
| `--external-id` | idempotency key (`external_record_id`) |

```sh
rd companies create --name "ABCD" --domain abcd.example.com
rd companies create --name "ABCD" --external-id crm-42   # safe to re-run
```

## `rd companies update ID [-j]`

Update a company — same flags as create (all optional; provide at least one).

## Notes

- Exit `2` if `--name` is missing on create, or no fields given on update.
- Missing/other-org IDs → exit `4` (not found).

## Bulk import

To create companies from a CSV, see [`rd companies import`](imports.md).
