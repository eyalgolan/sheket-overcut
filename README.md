# Sheket

An election spam blocker for Israel: an iOS app and an Android app that block
election calls and (on iOS) junk election SMS, fed by a shared blocklist that
users build by reporting what they receive, served by an AWS backend.

| Path | What it is |
|---|---|
| `docs/spec.md` | The product spec. Binding. |
| `contract/` | The blocklist schema, curated rules and shared test corpus. The acceptance tests for every track. |
| `AGENTS.md` | Rules for anyone, human or agent, changing this repository. |
| `backend/` | Python 3.13 Lambda code and its tests (not yet written). |
| `infra/` | Terraform root module. Its packaging copies `contract/curated.json` and `contract/blocklist.schema.json` into the Lambda package (not yet written). |
| `android/` | Kotlin app, min SDK 29 (not yet written). |
| `ios/` | Swift app and extensions, with matching logic in `ios/SheketCore` (not yet written). |

CI runs one workflow per track in `.github/workflows/`: `backend` (for
`backend/` and `infra/`), `android` and `ios`. Each is red until its track's
code exists. A change to `contract/` runs all three.
