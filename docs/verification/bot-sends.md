# One-way bot sends

These fixtures prove `send_to_bot` without touching a live workspace.

## Server lifecycle

```sh
pnpm vitest run \
  server/delegations.test.ts \
  server/direct-coordination.e2e.test.ts \
  server/room-coordination.e2e.test.ts \
  --maxWorkers=2
```

The direct fixture covers a fresh recipient thread, exact retry identity,
no sender resume, and onward sending. The room fixture covers the canonical
room source link, no room callback, and approval denial. The delegation store
fixture covers restart-safe queued work, stable delivery identity, source
failure, and recipient execution at a fresh coordination depth.

## Renderer links

```sh
OMB_UI_E2E=1 pnpm vitest run \
  scripts/testing/direct-coordination-ui.e2e.test.ts \
  -t "opens both sides of a one-way send" \
  --maxWorkers=1
```

The isolated browser opens the recipient from the source receipt, then opens
the original conversation from the recipient's canonical source link. It
writes source and recipient screenshots plus a JSON thread-ID record beside
the fixture log path printed at completion.

## Existing delegation

```sh
pnpm vitest run \
  server/direct-coordination.e2e.test.ts \
  server/room-coordination.e2e.test.ts \
  -t "coordinates" \
  --maxWorkers=2
```

These unchanged callback tests prove `coordinate_bots` still returns results
and resumes its source conversation.
