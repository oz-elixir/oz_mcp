# SDK client tests

These tests drive `OzMcp.E2E.SdkServer` with the official TypeScript SDK
client (`@modelcontextprotocol/sdk`), over HTTP and over stdio.

## Run

    mix test.sdk          # npm ci, then npm test
    cd test/sdk_client && npm test

## Pinned versions

| Package | Where | Why |
|---|---|---|
| `@modelcontextprotocol/sdk` | `package.json`, exact | the client under test |
| `tsx` | `package.json`, exact | the runner |
| `typescript` | `package.json`, exact | the type check |
| `@types/node` | `package.json`, exact | the types of Node |
| `@modelcontextprotocol/conformance` | `.github/workflows/ci.yml` and `README.md`, exact | the conformance tool |

No tool changes a version by itself. Update a version on purpose:

1. Read the release notes of the new version.
2. Change the exact version in `package.json` (or in `ci.yml` and the README
   for the conformance tool) and run `npm install` to update the lock file.
3. Run `mix test.sdk` (or the conformance command) on a local machine. After
   an update of the SDK, `npm test` also runs the type check.
4. Put the change in its own commit. A failure that comes from the new
   version is a finding: record it and do not change the baseline to hide it.
