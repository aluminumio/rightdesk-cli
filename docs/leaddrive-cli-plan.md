# RightDesk CLI — LeadDrive Implementation Plan

The living plan for bringing **LeadDrive** (the sales CRM) to the `rd` CLI, one noun at a time.
Scope of this doc is **LeadDrive only** — other drives (ZenDrive, DocuDrive, MailDrive, SignDrive,
Agents) are tracked in the backlog and out of scope here.

Each noun is a **vertical slice** across two repos:
- **rightdesk** (Rails) — a `/api/v1/<noun>` endpoint.
- **rightdesk-cli** (this repo) — an `rd <noun> <verb>` command that calls it.

They land as separate PRs (Rails endpoint first, CLI command after).

---

## Architecture & conventions

### Grammar
`rd <noun> <verb> [target] [flags]` — e.g. `rd companies get 42`, `rd companies list --search acme`.
An ARGV pre-processor rewrites the space form to the colon name athena resolves (`companies:get`); the
colon form works too. `rd <noun>` with no verb prints that namespace's commands.

### Output contract (makes the CLI usable by scripts and LLMs)
- **Data → stdout, diagnostics/errors → stderr** (never mixed).
- `-j`/`--json` emits the raw JSON payload; under `--json`, errors are structured `{error,code,hint}`.
- **Exit codes:** `0` ok · `1` general · `2` usage · `3` auth · `4` not found · `5` insufficient scope.

### Auth
Static `ApiToken` minted in the web UI, stored in `~/.netrc` (org-scoped). Overrides: `--host` /
`RIGHTDESK_URL`, `--token` / `RIGHTDESK_TOKEN`. No OAuth/device flow.

### Rails endpoint pattern
- Inherit `Api::V1::BaseController` (token auth + org scoping + error rescues).
- Scope everything through `current_organization.<assoc>`.
- List envelope `{ <plural>: [...], meta: pagination_meta }`, `per_page` capped at 100.
- `create` is **idempotent via `external_record_id`** for models that have it (`find_or_initialize_by`);
  config-type models without that column are not idempotent.

### CLI command pattern
- One class per verb: `@[ACONA::AsCommand("noun:verb")]`, `include JSONOption` for `-j`.
- Add the command name to `RightDesk::CLI::COMMAND_NAMES` (the rewriter validates against it).
- Errors go through `RightDesk.fail(label, resp, json?)` → stderr + mapped exit code.
- Add a `Client` verb (`get`/`post`/`patch`) if missing.

### Safety classes
`read` (no gate) · `write` (no gate) · `destructive` (delete/merge — `--yes`) · `outward` (reaches people
outside the org — `--yes` + `--dry-run`). **LeadDrive has no `outward` verbs;** destructive = deletes and
merges.

---

## Noun roadmap (dependency order)

Build small → large; leads/deals/activities are the heavy ones and come after their dependencies.

| # | Noun | Rails endpoint | CLI command | Effort | Deps | Status |
|---|------|----------------|-------------|--------|------|--------|
| 1 | companies | new (list/get/create/update) | list/get/create/update | Low | — | Merged — Rails #626, CLI #32 |
| 2 | pipelines | **extend** read → +create/update/destroy | list/get/create/update/delete | Low | — | CLI merged #33; Rails #627 open |
| 3 | stages | new (list/create/update/reorder/delete) | list/create/update/reorder/delete¹ | Low | pipelines | PRs open — Rails #627, CLI #34 |
| 4 | products | new (CRUD + activate) | list/get/create/update/activate/deactivate/delete² | Low | — | PRs open — Rails #627, CLI #34 |
| 5 | contacts | **extend** (add create/update, merge) | +create/update/merge² (list/get/search exist) | Low | — | todo |
| 6 | customers | new (CRUD) | list/get/create/update/timeline | Medium | — | todo |
| 7 | partners | new (CRUD) | list/get/create/update/timeline | Medium | customers | todo |
| 8 | leads | new (CRUD + move/qualify/convert) | list/get/create/update/delete/move/qualify/disqualify/convert | Med-high | companies, pipelines, stages | todo |
| 9 | activities | new (full: CRUD + done/blockers/subtasks/time/comments/history) | list/get/create/update/delete/done/reopen/add-blocker/remove-blocker/subtask-add/subtask-toggle/subtask-remove/start-timer/stop-timer/log-time/edit-time/remove-time/comment/comments/history | High | — | Done — full write surface (Rails `feature/api-v1-activities-full`, CLI `feature/activities-full`) |
| 10 | deals | **extend** (add the rest) | +update/move/won/lost/convert/merge/… (list/get/create exist) | High | contacts, pipelines, stages, products | todo |

¹ `stages delete` is destructive (`--yes`); if the stage still holds active deals/leads it 409s unless `--transfer-to STAGE_ID` is given, which moves them first (mirrors the web `transfer_and_destroy`; never orphan deals).
² `*:delete` / `contacts merge` are **destructive** → require `--yes`.

**"customers" note:** John uses "customers" loosely for any CRM record; the `customers` noun above is
specifically our `Customer` model (post-conversion records). No special handling.

---

## Recipe to add a noun (the `companies` template)

1. **Rails endpoint PR** (rightdesk, branch `feature/api-v1-<noun>`)
   - New/extended `Api::V1::<Noun>Controller` (index/show/create/update[/destroy]) under
     `Api::V1::BaseController`; enrich the `*_json` serializer as needed.
   - Add the route in the `api/v1` block of `config/routes.rb`.
   - Request spec (`spec/requests/api/v1/<noun>_spec.rb`, plain `Model.create!`): CRUD, org-scoping (404
     cross-org), pagination, idempotency (if applicable), 401.
   - Verify: `bundle exec rspec …` + `curl`. Commit (single subject), draft PR to `master`.
2. **CLI command PR** (this repo, branch `feature/<noun>-command`)
   - Add `src/rightdesk/commands/<noun>.cr` (command classes + that noun's `*_body`/`configure_*`/`print_*`
     helpers, reopening `module RightDesk`); `require` it from `cli.cr`; register in `CLI.run`; add names to
     `COMMAND_NAMES`.
   - Add a `Client` verb if needed. **Docs:** write `docs/commands/<noun>.md`, add its row to
     `docs/README.md` + the README command table, and update `src/rightdesk/skill.md` (agent guide). Add
     rewriter spec cases.
   - Verify: `crystal build … --no-codegen --error-on-warnings`, `crystal spec`, smoke (namespace list,
     usage exit 2, unauth exit 3), and **end-to-end** against a local rightdesk + token (incl.
     idempotency where relevant). Commit, draft PR to `main`.
3. Link the CLI backlog issue for the noun; update this doc's status row.

---

## Links
- CLI backlog epic: `#3` (this repo) and its per-noun child issues.
- Full command-surface design doc (all drives): the product's `CLI_COMMAND_SURFACE` reference.
