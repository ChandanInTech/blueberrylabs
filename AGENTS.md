# Agent instructions

Please follow [ARCHITECTURE.md](./ARCHITECTURE.md) for this project.

Keep [ARCHITECTURE.md](./ARCHITECTURE.md) updated with any changes to the agent
implementations, and treat it as a living document. In particular, keep
**section 27 (Implementation status)** current: milestone status, deviations,
module layouts, behavioural contracts, and external gaps.

## Ground rules

- `backend/` and `frontend/` are independent git repositories tracked here as
  submodules. Never move application code into the parent repository, and never
  commit a submodule pointer to an unpushed commit.
- Never import across the submodule boundary with relative paths. The shared
  contracts channel is `backend/contracts`, packed into `frontend/vendor/` by
  `scripts/sync-contracts.sh`.
- Run `npm run verify` before reporting a change as done. Do not claim a feature
  works until it has been run.
- Presets, error codes, and enums are authoritative in
  `backend/contracts/src/`. The API validates every request against them.
