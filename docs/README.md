# rd — documentation

Command reference for the RightDesk CLI, one page per noun (mirrors the code layout under
`src/rightdesk/commands/`). Start at the [top-level README](../README.md) for install, grammar, the output
contract, and auth.

Three ways to get help at the terminal, always authoritative:
- `rd list` — every registered command.
- `rd <noun> <verb> --help` — exhaustive flags for one command.
- `rd skills` — condensed guide for LLMs/agents (the embedded [`skill.md`](../src/rightdesk/skill.md)).

## Command reference

| Noun | Commands | Page |
|---|---|---|
| auth & session | login, logout, whoami, skills | [auth.md](commands/auth.md) |
| contacts | list, get, search, create, update, merge | [contacts.md](commands/contacts.md) |
| companies | list, get, create, update | [companies.md](commands/companies.md) |
| deals | list, get, create, update, move, won, lost, reopen, convert, merge | [deals.md](commands/deals.md) |
| activities | list, get, create, update, delete, done, reopen, add-blocker, remove-blocker, subtask-add, subtask-toggle, subtask-remove, start-timer, stop-timer, log-time, edit-time, remove-time, comment, comments, history | [activities.md](commands/activities.md) |
| pipelines | list, get, create, update, delete | [pipelines.md](commands/pipelines.md) |
| stages | list, create, update, reorder, delete | [stages.md](commands/stages.md) |
| products | list, get, create, update, activate, deactivate, delete | [products.md](commands/products.md) |
| customers | list, get, create, update, timeline | [customers.md](commands/customers.md) |
| partners | list, get, create, update, timeline | [partners.md](commands/partners.md) |
| leads | list, get, create, update, delete, move, qualify, disqualify, convert | [leads.md](commands/leads.md) |

## Conventions

- **Destructive** verbs (`delete`, `contacts merge`) and **outward** ones (`leads convert`) require `--yes`.
- Writes are **idempotent** where an `--external-id` flag exists (companies, products, customers, partners,
  leads; contacts dedupe by email).
- See [`docs/leaddrive-cli-plan.md`](leaddrive-cli-plan.md) for the noun roadmap and the recipe to add a new
  one (which includes adding its doc page here).
