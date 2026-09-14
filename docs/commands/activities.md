# rd activities

Activities (calls, meetings, tasks, emails, deadlines) attached to CRM records — the sales team's daily
task surface. Full read/write parity with the web activity detail page: core fields, subtasks, blockers,
time tracking, comments, and history. Run `rd activities <verb> --help` for exhaustive flags.

## Reads

### `rd activities list [-j]`

List activities, ordered by due date. Each line shows `id  ✓|○ subject (type)  → linked-record`.

| Flag | Purpose |
|---|---|
| `--done true\|false` | filter by completion (omit → all) |
| `--type T` | activity type (call/meeting/email/task/deadline or org-custom) |
| `--assigned-to ID` | filter by assignee user |
| `--deal` `--lead` `--contact` `--company` `--customer` `--partner` | filter by an associated record id |
| `--due-before` `--due-after` | ISO date bounds |
| `--page N` / `--limit N` | pagination (max 100/page) |

```sh
rd activities list --done false --assigned-to 1
rd activities list --deal 52375
```

### `rd activities get ID [-j]`

Show one activity — subject, type, done, due date, duration + logged minutes, assignee, and the linked
record. Under `-j` the payload also carries `checklist_items`, `blockers`, recurrence fields,
`running_timer`, `time_entries`, and `comments_count`.

## Core writes

### `rd activities create [-j]`

Create an activity. `--subject` and `--type` are required.

| Flag | Purpose |
|---|---|
| `--subject` (required) | subject line |
| `--type` (required) | call/meeting/email/task/deadline or an org-custom type |
| `--description` | notes body |
| `--location` | location or link |
| `--due-date` | `YYYY-MM-DD` or ISO8601 |
| `--has-time` | treat `--due-date` as carrying a time-of-day |
| `--duration` | planned duration in minutes |
| `--chargeable-status` | standard / chargeable / charged |
| `--assigned-to ID` | assignee user (defaults to you) |
| `--deal` `--lead` `--contact` `--company` `--customer` `--partner` | the primary link (contact/company are derived server-side) |
| `--recurring` + `--pattern` + `--interval` + `--recurrence-end` | recurrence (needs `--pattern` and `--due-date`) |
| `--external-id` | idempotency key — re-creating with the same id upserts, never duplicates |

```sh
rd activities create --subject "Call ACME" --type call --deal 52375 --due-date 2026-10-01
rd activities create --subject "Weekly sync" --type meeting --recurring --pattern weekly --interval 1 --due-date 2026-10-01
```

### `rd activities update ID [-j]` — same flags as create (all optional; provide at least one).

### `rd activities delete ID --yes` — **destructive**, requires `--yes`.

### `rd activities done ID` / `rd activities reopen ID`
Mark complete / reopen. Completing a recurring activity spawns its next occurrence server-side.

## Subtasks (checklist)

```sh
rd activities subtask-add 43240 --text "Draft agenda"
rd activities subtask-toggle 43240 --index 0     # flip done state
rd activities subtask-remove 43240 --index 0
```

## Blockers

```sh
rd activities add-blocker 43240 --note "waiting on legal"
rd activities remove-blocker 43240 --index 0
```

## Time tracking

Timers are **server-side** — `start-timer` stamps a start time and returns immediately (nothing counts in your
terminal); `stop-timer` computes the elapsed minutes whenever you run it, from any machine. Check elapsed time
any time with `rd activities get`.

```sh
rd activities start-timer 43240 --note "prep"
rd activities stop-timer 43240
rd activities log-time 43240 --minutes 30 --note "call" [--credited-user ID] [--worked-on 2026-09-14]
rd activities edit-time 43240 --entry 99 --minutes 45 --note "revised"
rd activities remove-time 43240 --entry 99
```

## Comments & history

```sh
rd activities comment 43240 --body "Left a voicemail, will retry tomorrow"
rd activities comments 43240              # oldest-first; @mentions notify those users
rd activities history 43240               # audit trail: at  event_type  actor  summary
```

## Notes

- The subject record is resolved server-side (`primary_link_type`/`primary_link_name`) — one of
  deal/lead/customer/partner/contact; `contact`/`company` are derived from the chosen primary link.
- `total_logged_minutes` aggregates time entries; `duration_minutes` is the planned duration.
- Only one exclusive primary link (deal/lead/customer/partner) may be set at a time.
