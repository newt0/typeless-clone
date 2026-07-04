# CLAUDE.md

Think in English; respond to the user in Japanese.

## GitHub Guidelines

### Commit Messages (Conventional Commits, English)

Claude Code commits at appropriate levels of granularity.
Write concisely in English. 1 to 2 lines are sufficient.

### Branches

- Branch from `main` and name them using the format `<type>/<kebab-slug>` (type: `feat` / `fix` / `chore` / `docs` / `refactor`). The base is always `main`.
- Claude Code may create branches at appropriate granularities and is also authorized to merge them.

### PR / Merging

- Create PRs using the `gh` CLI, with `main` as the base.
- Use merge commits instead of squash merging (to keep the commit history within the branch).
- Ensure that `pnpm typecheck`, `pnpm lint`, and `pnpm build` pass locally before submitting a PR.

## Security

- Creating or editing `.env` / `.env.local` is permitted (provided that sensitive values are managed appropriately in production). `.env*` files are already included in `.gitignore`.
- If necessary, you may also handle private keys, `id_rsa`, `.pem`, `.key`, `wallet.json`, keystores, etc.
- For services like Supabase or Stripe, Claude Code should perform operations via the CLI as a proxy whenever possible. Claude Code should also handle the acquisition and configuration of API keys as much as possible.
