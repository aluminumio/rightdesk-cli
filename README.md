# rd

CLI for the [RightDesk](https://app.rightdesk.com) API. The command is `rd`. Crystal binary, distributed via Homebrew and GitHub Releases.

## Install

    brew install aluminumio/tap/rightdesk

The Homebrew package is `rightdesk`; the installed command is `rd`. Or download a binary
from [Releases](https://github.com/aluminumio/rightdesk-cli/releases).

> **If `rd` doesn't run RightDesk**, a shell alias or another tool is shadowing the name
> (check with `type rd`). Run it as `command rd`, or remove the alias by adding
> `unalias rd` to your shell profile (`~/.zshrc` / `~/.bashrc`) below anything that defines it.

## Grammar

    rd <noun> <verb> [target] [flags]

Nouns are plural, verb second, target positional, flags named — e.g. `rd deals get 42`,
`rd deals list --status open`. The colon form (`rd deals:get 42`) also works.

`rd <noun>` with no verb lists that noun's commands. At the terminal:

- `rd list` — every registered command.
- `rd <noun> <verb> --help` — exhaustive flags for one command.
- `rd skills` — condensed guide for LLMs/agents.

## Quick start

```sh
rd login                 # paste an API token (Organization Settings → API)
rd whoami                # confirm user + org
rd companies list
rd deals list --status open -j | jq -r '.deals[].id'
```

## Commands

Full reference, one page per noun, under [`docs/`](docs/README.md):

| Noun | Commands | Docs |
|---|---|---|
| auth & session | login, logout, whoami, skills | [auth](docs/commands/auth.md) |
| contacts | list, get, search, create, update, merge | [contacts](docs/commands/contacts.md) |
| companies | list, get, create, update | [companies](docs/commands/companies.md) |
| deals | list, get, create, update, move, won, lost, reopen, convert, merge, notes, note-add, note-edit, note-delete, checklist-templates, checklists, checklist-add, checklist-remove, checklist-check, checklist-uncheck, events, event-add | [deals](docs/commands/deals.md) |
| activities | list, get, create, update, delete, done, reopen, add-blocker, remove-blocker, subtask-add, subtask-toggle, subtask-remove, start-timer, stop-timer, log-time, edit-time, remove-time, comment, comments, history | [activities](docs/commands/activities.md) |
| pipelines | list, get, create, update, delete | [pipelines](docs/commands/pipelines.md) |
| stages | list, create, update, reorder, delete | [stages](docs/commands/stages.md) |
| products | list, get, create, update, activate, deactivate, delete | [products](docs/commands/products.md) |
| customers | list, get, create, update, timeline | [customers](docs/commands/customers.md) |
| partners | list, get, create, update, timeline | [partners](docs/commands/partners.md) |
| leads | list, get, create, update, delete, move, qualify, disqualify, convert | [leads](docs/commands/leads.md) |

Destructive verbs (`delete`, `contacts merge`) and outward ones (`leads convert`) require `--yes`.

## Output contract

- **Data on stdout, diagnostics on stderr.** Errors never touch stdout.
- **`-j`/`--json`** emits the raw JSON payload; under `--json`, errors are structured
  (`{"error","code","hint"}`) on stderr.
- **Exit codes:** `0` success · `1` general · `2` usage · `3` auth · `4` not found · `5` insufficient scope.

## Authentication

RightDesk uses static API tokens (no OAuth device flow). Create one in the web UI under
**Organization Settings → API**, then run `rd login` and paste it. Tokens are **organization-scoped** —
to switch orgs, mint a token in the other org and `login` again (this overwrites the local entry).
`logout` clears only the local copy; revoke server-side in the web UI.

## Configuration

| Flag / Variable | Default | Purpose |
|---|---|---|
| `--host <host>` / `RIGHTDESK_URL` | `https://app.rightdesk.com` | API host (override for self-hosted or dev) |
| `--token <t>` / `RIGHTDESK_TOKEN` | (from `~/.netrc`) | API token override (prefer the env var; never pass secrets in argv) |

Tokens are persisted in `~/.netrc`.

## Build from source

    shards install
    shards build --release
    ./bin/rd --help
