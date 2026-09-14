# RightDesk CLI — Skill

Drive the RightDesk API from the shell. The command is `rd`, grammar `rd <noun> <verb> [target] [flags]`
(the colon form `rd deals:get 42` also works). All data commands accept `-j`/`--json` for
machine-readable output — prefer this when piping or parsing.

## Authentication

RightDesk uses static API tokens (no browser/OAuth flow). Mint a token in the web UI under
**Organization Settings → API**, then:

```sh
rd login            # paste the token (prompted, hidden); stored in ~/.netrc
rd whoami -j        # confirms the current user + organization
rd logout           # clears the local token copy
```

The token is **organization-scoped**: to act in another org, mint a token there and `login` again
(this overwrites the local entry). `logout` only clears the local copy — the token stays valid
server-side until revoked in the web UI.

Non-interactive: `rd login <token>`, or set `RIGHTDESK_TOKEN` (overrides `~/.netrc`).

## Output contract (important for agents)

- **Data on stdout, diagnostics on stderr** — parse stdout only.
- **`-j`/`--json`** emits the raw JSON payload; under `--json`, errors are structured
  `{"error","code","hint"}` on stderr.
- **Exit codes:** `0` ok · `1` general · `2` usage · `3` auth · `4` not found · `5` insufficient scope.
  Branch on these; e.g. exit `3` means run `rd login` and retry.

## Configuration

| Flag / Variable | Default | Purpose |
|---|---|---|
| `--host` / `RIGHTDESK_URL` | `https://app.rightdesk.com` | API host (override for self-hosted or dev) |
| `--token` / `RIGHTDESK_TOKEN` | (from `~/.netrc`) | API token override |

## Command reference

| Command | Purpose | Key options |
|---|---|---|
| `rd login [token]` | Store an API token | — |
| `rd logout` | Clear the local token | — |
| `rd whoami` | Show current user/org | `-j` |
| `rd deals list` | List deals (newest first) | `--status open\|won\|lost`, `--page N`, `--limit N`, `-j` |
| `rd deals get ID` | Show one deal | `-j` |
| `rd deals create` | Create a deal | `--title` (required), `--pipeline-id`, `--stage-id`, `--contact-id`, `--company-id`, `--owner-id`, `--value`, `--currency`, `--expected-close-date`, `--source`, `--visible-to`, `--probability`, `--referral-partner-id`, `-j` |
| `rd deals update ID` | Update a deal | same flags as create, `-j` |
| `rd deals move ID` | Move to a stage (same pipeline) | `--stage STAGE_ID` (required), `-j` |
| `rd deals won ID` | Mark won | `-j` |
| `rd deals lost ID` | Mark lost | `--reason TEXT`, `-j` |
| `rd deals reopen ID` | Reopen a closed deal | `-j` |
| `rd deals convert ID` | Convert to customer/partner (**outward**) | `--to customer\|partner` (required), `--yes` (required) |
| `rd deals merge PRIMARY_ID` | Merge a duplicate deal (**destructive**) | `--duplicate DUP_ID` (required), `--yes` (required) |
| `rd activities list` | List activities (by due date) | `--done true\|false`, `--type`, `--assigned-to ID`, `--deal`, `--lead`, `--contact`, `--company`, `--customer`, `--partner`, `--due-before`, `--due-after`, `--page N`, `--limit N`, `-j` |
| `rd activities get ID` | Show one activity (incl. subtasks, blockers, time, running timer) | `-j` |
| `rd activities create` | Create an activity | `--subject` (required), `--type` (required), `--description`, `--location`, `--due-date`, `--has-time`, `--duration`, `--chargeable-status`, `--assigned-to`, one of `--deal\|--lead\|--contact\|--customer\|--partner` (company is derived), `--recurring` `--pattern` `--interval` `--recurrence-end`, `--external-id`, `-j` |
| `rd activities update ID` | Update an activity | same flags as create (`--external-id` ignored); empty value clears a field, `--no-has-time`/`--no-recurring` unset the booleans, `-j` |
| `rd activities delete ID` | Delete an activity (**destructive**) | `--yes` (required) |
| `rd activities done ID` / `reopen ID` | Mark complete / reopen | `-j` |
| `rd activities add-blocker ID` | Add a blocker | `--note` (required), `-j` |
| `rd activities remove-blocker ID` | Remove a blocker by index | `--index` (required), `-j` |
| `rd activities subtask-add ID` | Add a subtask (checklist item) | `--text` (required), `-j` |
| `rd activities subtask-toggle ID` / `subtask-remove ID` | Toggle/remove a subtask by index | `--index` (required), `-j` |
| `rd activities start-timer ID` / `stop-timer ID` | Start/stop a server-side timer | `--note` (start only), `-j` |
| `rd activities log-time ID` | Log time manually | `--minutes` (required), `--note`, `--credited-user`, `--worked-on`, `-j` |
| `rd activities edit-time ID` / `remove-time ID` | Edit/remove a time entry | `--entry` (required), (edit: `--minutes`, `--note`, `--credited-user`, `--worked-on`), `-j` |
| `rd activities comment ID` | Add a comment (@mentions notify) | `--body` (required), `-j` |
| `rd activities comments ID` / `history ID` | List comments / show history | `--page N`, `--limit N`, `-j` |
| `rd contacts list` | List contacts | `--page N`, `--limit N`, `-j` |
| `rd contacts search QUERY` | Search contacts (name/email/phone) | `--company ID`, `-j` |
| `rd contacts get ID` | Show one contact | `-j` |
| `rd contacts create` | Create a contact | `--email` (required), `--first-name`, `--last-name`, `--phone`, `--note`, `--company-id`, `--line-id`, `--line-user-id`, `--whatsapp-number`, `--linkedin-profile`, `--alternative-emails`, `-j` |
| `rd contacts update ID` | Update a contact | same flags as create, `-j` |
| `rd contacts merge PRIMARY_ID` | Merge a duplicate into the primary (**destructive**) | `--duplicate DUP_ID` (required), `--yes` (required) |
| `rd customers list` | List customers | `--status`, `--owner ID`, `--search Q`, `--page N`, `--limit N`, `-j` |
| `rd customers get ID` | Show one customer | `-j` |
| `rd customers create` | Create a customer | `--title` (required), `--contact-id`, `--company-id`, `--owner-id`, `--value`, `--currency`, `--became-date`, `--source`, `--visible-to`, `--status`, `--description`, `--external-id`, `-j` |
| `rd customers update ID` | Update a customer | same flags as create, `-j` |
| `rd customers timeline ID` | Show a customer's history | `-j` |
| `rd partners list` | List partners | `--status`, `--owner ID`, `--partner-type T`, `--search Q`, `--page N`, `--limit N`, `-j` |
| `rd partners get ID` | Show one partner | `-j` |
| `rd partners create` | Create a partner | `--title` (required), `--partner-type`, plus the same flags as customers, `-j` |
| `rd partners update ID` | Update a partner | same flags as create, `-j` |
| `rd partners timeline ID` | Show a partner's history | `-j` |
| `rd leads list` | List leads | `--status`, `--owner ID`, `--source S`, `--pipeline ID`, `--stage ID`, `--page N`, `--limit N`, `-j` |
| `rd leads get ID` | Show one lead | `-j` |
| `rd leads create` | Create a lead | `--title` (required); optional `--contact-id`, `--company-id`, `--owner-id`, `--referral-partner-id`, `--value`, `--currency`, `--expected-close-date`, `--source`, `--visible-to`, `--status`, `--description`, `--pipeline-id`, `--stage-id`, `--external-id`, `-j`. Defaults to the org's default lead pipeline/stage if none given. |
| `rd leads update ID` | Update a lead | same flags as create, `-j` |
| `rd leads delete ID` | Delete a lead (**destructive**) | `--yes` (required) |
| `rd leads move ID` | Move to a stage | `--stage STAGE_ID` or `--unassigned` |
| `rd leads qualify ID` | Mark qualified | `-j` |
| `rd leads disqualify ID` | Mark disqualified | `--reason TEXT`, `-j` |
| `rd leads convert ID` | Convert to deal/customer/partner (**outward**) | `--to deal\|customer\|partner` (required), `--pipeline ID` (for deal), `--yes` (required) |
| `rd companies list` | List companies | `--search Q`, `--industry I`, `--page N`, `--limit N`, `-j` |
| `rd companies get ID` | Show one company | `-j` |
| `rd companies create` | Create a company | `--name` (required), `--domain`, `--url`, `--industry`, `--phone`, `--city`, `--country`, `--postal-code`, `--employees`, `--type`, `--description`, `--owner`, `--external-id`, `-j` |
| `rd companies update ID` | Update a company | same flags as create, `-j` |
| `rd pipelines list` | List pipelines | `-j` |
| `rd pipelines get ID` | Show a pipeline + stages | `-j` |
| `rd pipelines create` | Create a pipeline | `--name` (required), `--entity deal\|lead`, `--description`, `--default`, `--position N`, `-j` |
| `rd pipelines update ID` | Update a pipeline | `--name`, `--description`, `--default`, `--active`, `--inactive`, `--position`, `-j` |
| `rd pipelines delete ID` | Delete a pipeline (**destructive**) | `--yes` (required) |
| `rd stages list` | List a pipeline's stages (by position) | `--pipeline ID` (required), `-j` |
| `rd stages create` | Create a stage | `--pipeline ID` (required), `--name` (required), `--stage-type open\|won\|lost`, `--probability N`, `--rotting-days N`, `--position N`, `--color HEX`, `-j` |
| `rd stages update ID` | Update a stage | `--pipeline ID` (required), same flags as create, `-j` |
| `rd stages reorder` | Set stage order | `--pipeline ID` (required), `--order ID,ID,ID` (required) |
| `rd stages delete ID` | Delete a stage (**destructive**) | `--pipeline ID` (required), `--yes` (required), `--transfer-to STAGE_ID` (needed if the stage holds active deals/leads) |
| `rd products list` | List products | `--active`, `--inactive`, `--category C`, `--search Q`, `--page N`, `--limit N`, `-j` |
| `rd products get ID` | Show one product | `-j` |
| `rd products create` | Create a product | `--name` (required), `--code`, `--category`, `--description`, `--price`, `--currency`, `--tax`, `--unit`, `--billing-frequency`, `--billing-cycles`, `--visible-to`, `--owner-id`, `--external-id`, `--active\|--inactive`, `-j` |
| `rd products update ID` | Update a product | same flags as create, `-j` |
| `rd products activate ID` | Activate a product | `-j` |
| `rd products deactivate ID` | Deactivate a product | `-j` |
| `rd products delete ID` | Delete a product (**destructive**) | `--yes` (required) |
| `rd skills` | Print this guide | — |

## Tips for agentic use

- **Always pass `-j`** when parsing; the human format is unstable.
- **Capture IDs immediately** with `jq -r` (e.g. `rd deals list --status open -j | jq -r '.deals[].id'`).
- **Branch on exit codes**, not on message text. Exit `3` → `rd login` and retry.
