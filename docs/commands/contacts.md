# rd contacts

People in the CRM. Part of LeadDrive. Run `rd contacts <verb> --help` for exhaustive flags.

## `rd contacts list [-j]`

List contacts, newest first. `--page N` / `--limit N` (max 100/page).

## `rd contacts search QUERY [-j]`

Search by name, email, or phone (the term is matched across first/last name + email).

| Flag | Purpose |
|---|---|
| `--company ID` | restrict to a company |

```sh
rd contacts search rolly
rd contacts search acme --company 15244 -j | jq -r '.contacts[].email'
```

## `rd contacts get ID [-j]`

Show one contact.

## `rd contacts create --email EMAIL [-j]`

Create a contact. **Idempotent by email** — re-running with the same email updates the existing contact.

| Flag | Purpose |
|---|---|
| `--email` | **required** |
| `--first-name` `--last-name` `--phone` `--note` `--company-id` | core attributes |
| `--line-id` `--line-user-id` `--whatsapp-number` `--linkedin-profile` `--alternative-emails` | channels |

```sh
rd contacts create --first-name Rolly --email rolly@example.com --company-id 15244
```

## `rd contacts update ID [-j]`

Update a contact — same flags as create (provide at least one).

## `rd contacts merge PRIMARY_ID --duplicate DUP_ID --yes`

**Destructive.** Merge `DUP_ID` into `PRIMARY_ID`: the primary survives, the duplicate is soft-deleted, and
its CRM relationships (deals, leads, notes, activities, …) move to the primary. Requires `--yes`.

| Flag | Purpose |
|---|---|
| `--duplicate ID` | **required** — the contact to absorb |
| `--yes` | **required** — confirm the merge |

```sh
rd contacts merge 157891 --duplicate 157892 --yes
```

## Notes

- Exit `2` if `--email` missing on create, no fields on update, or `--duplicate`/`--yes` missing on merge.
- Merge validates same-org and rejects self-merge (→ exit `1`, server message on stderr).

## Bulk import

To create contacts from a CSV — with duplicate detection against every person already in the CRM —
see [`rd contacts import`](imports.md).
