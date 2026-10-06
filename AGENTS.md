# Rules for agents working in this repository

## Standing rules

These apply at every single step, not just at the end:

1. Verify everything. No assumptions - read the actual code before changing it, run commands and cite their output. Don't trust any file:line reference in a spec, plan or message without confirming it yourself first - the codebase may have moved since it was written.
2. Rank every decision 1-10 and only proceed on a 10. If a step isn't a 10, stop and close the gap before moving to the next step. Don't carry a known gap forward.
3. Devil's advocate before acting. For each change, explicitly write down what could break, then address it before you make the change - not after.
4. Review every change as a staff engineer would. No sloppy patches, no unrequested abstractions, no scope creep.

## Hard limits

- Never run `terraform apply`. Applying infrastructure is a human action.
- No AWS credentials in the repository or in CI.
- No secrets in source.
- Endpoints (the blocklist URL and the report URL) are build-time configuration with fake defaults. No real endpoint is committed.
- Each pull request must keep CI green for its track (`backend`, `android`, `ios`). The first pull request of a track must turn that track's workflow green. A pull request that touches `contract/` triggers all three workflows.
- The files in `contract/` are the acceptance tests. A code pull request may not edit them, with one exception: it may regenerate `contract/seed-blocklist.json`, only as a pure regeneration from `contract/curated.json` and only with a test that proves the committed file matches a fresh build.
- Any change to `contract/curated.json`, `contract/corpus.json`, `contract/test-blocklist.json` or `contract/blocklist.schema.json` goes in a separate pull request titled `contract: ...` that touches only `contract/` and is approved by the owner.
