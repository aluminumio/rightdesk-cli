# rd imports

Bulk CSV import of **contacts** and **companies**. The server does the work: an upload becomes a
background job that streams the file row by row, so a 25 MB export does not need the terminal to stay
open. These commands upload, show what the server detected, and watch the result.

Two halves:

- `rd contacts import` / `rd companies import` — the one-shot: upload, review, import.
- `rd imports list|get|start|skipped` — inspect what happened.

## `rd contacts import -f FILE` / `rd companies import -f FILE`

Upload a CSV and import it.

| Flag | Purpose |
|---|---|
| `-f`, `--file FILE` | **required** — the CSV to upload |
| `--yes` | accept the detected mapping and actually import |
| `--no-wait` | return as soon as the import starts, instead of watching it |
| `-j` | emit the raw JSON payload |

**Without `--yes` nothing is imported.** The column mapping is auto-detected from the header row, and
auto-detection is a heuristic — so a bare run uploads the file, prints what each column became, and stops:

```sh
$ rd contacts import -f leads.csv
mapping detected for leads.csv (18.4 KB)
  Email         ->  email
  First Name    ->  first_name
  Internal ID   ->  (not imported)
  1 column(s) will not be imported
import 8821 created — nothing imported yet; re-run with --yes, or: rd imports start 8821
```

A column shown as `(not imported)` is usually a mis-detected header — checking that line is the reason
this step exists. Nothing is lost either way: the upload is already stored, so `rd imports start 8821`
runs it without re-uploading.

With `--yes` it imports and watches to the end, progress on **stderr** and the summary on stdout:

```sh
$ rd contacts import -f leads.csv --yes
  ...same mapping...
 ████████████░░░░  74%  298 imported · 12 duplicate
412 rows · 396 imported · 14 duplicate · 2 invalid
16 rows skipped — see: rd imports skipped 8821
```

### Duplicate handling

Contact rows are matched against **every person already in the CRM** — contacts, leads, customers and
partners — by email *and* by phone. A match is reported as a duplicate with the record it collided with,
never written as a second person. Company rows match on domain. Duplicates are not an error: the import
finishes, exits `0`, and lists them under `rd imports skipped`.

### Encoding

The file is uploaded byte-for-byte and the server sniffs the encoding, so a CP932 or Latin-1 export from
Excel imports as-is. Japanese headers (`姓`, `名`, `メールアドレス`, …) auto-map.

## `rd imports list [-j]`

Imports, newest first: `id  state  item_type  filename  counts`. Only contact/company imports appear.

| Flag | Purpose |
|---|---|
| `--state S` | `uploaded` \| `processing` \| `finished` \| `failed` |
| `--page N` / `--limit N` | pagination (max 100/page) |

## `rd imports get ID [--wait] [-j]`

Show one import — state, progress, mapping and counts. With `--wait`, watch it to completion; this is
also how you resume watching after a Ctrl-C.

## `rd imports start ID [--wait] [-j]`

Start an import that was uploaded but never run (a `--yes`-less upload). Exit `1` if it has already been
started, or if its mapping is missing or maps two columns to the same field.

## `rd imports skipped ID [-j]`

The rows the import did not write, one per line:
`row_number  outcome  identity  matched_by  existing`.

| Flag | Purpose |
|---|---|
| `--reason R` | `duplicate` \| `invalid` \| `blank` |
| `--page N` / `--limit N` | pagination (max 100/page) |

```sh
rd imports skipped 8821 --reason duplicate
rd imports skipped 8821 -j | jq -r '.skipped_rows[] | [.row_number, .matched_by, .existing.id] | @tsv'
```

A very messy file can produce more skipped rows than the server records; when that cap is hit, both the
summary and this command say so.

## Notes

- Exit `2` if `--file` is missing or does not point at a file.
- Exit `4` for an unknown or other-org import id.
- **Exit `130` on Ctrl-C during a wait.** The import keeps running server-side — Ctrl-C stops the
  *watching*, not the import — so a script can tell "I stopped looking" from "the import failed" (`1`).
- Watching gives up after 15 minutes and exits `1`, telling you to check with `rd imports get`.
- Progress is suppressed under `-j`, when stderr is not a terminal, and under `RD_NO_PROGRESS=1`.
- Files are capped at 25 MB by the server, which rejects a larger one with a localized error.
