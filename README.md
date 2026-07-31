# Focus Tracker

Focus Tracker is a native Apple Silicon focus ledger with a public Next.js landing page. The repository is a pnpm workspace orchestrated by Turborepo.

## Workspace

- `apps/desktop` — Native SDK macOS application, local SQLite persistence, packaging, and DMG verification.
- `apps/web` — English product landing page deployed on Vercel.

## Requirements

- Node.js 22
- pnpm 10.33.0
- Zig 0.16.0 and the macOS toolchain for desktop work

## Commands

```sh
pnpm install --frozen-lockfile
pnpm dev
pnpm build
pnpm lint
pnpm typecheck
pnpm test
pnpm check
pnpm package:desktop
```

Run a single application with a workspace filter:

```sh
pnpm --filter @focus-tracker/web dev
pnpm --filter @focus-tracker/desktop check
```

Desktop-specific architecture, validation, and packaging notes live in [`apps/desktop/README.md`](apps/desktop/README.md).

## Vercel

The Vercel project deploys this monorepo with `apps/web` as its Root Directory,
Node.js 22, and `main` as the production branch. Vercel detects the root
`pnpm-lock.yaml`, `packageManager` field, and Turborepo workspace automatically.

## Releases

Merges to `main` that change the desktop product create a verified Apple Silicon DMG in [GitHub Releases](https://github.com/TommyBez/focus-tracker/releases). The current beta is ad-hoc signed and is not Developer ID signed or notarized; the landing page explains the corresponding macOS Gatekeeper step.
