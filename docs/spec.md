# Sheket - election spam blocker: design

Date: 2026-10-04. Working name "Sheket" (quiet); the store name is the owner's call.

## 1. Purpose

Israelis receive a flood of campaign SMS and recorded calls before an election.
Section 30A of the Communications Law does not cover election propaganda, so
nothing stops it at the source. Sheket stops it on the phone: an iOS app and an
Android app that block election calls and (on iOS) junk election SMS, fed by a
shared blocklist that users build by reporting what they receive.

**Deadline: the Knesset election is Tuesday 2026-10-27, 23 days after this
spec.** The product is worth little after that date, so every scope decision
below is made against the calendar, not against completeness.

Success for this election:

- iOS app live on the App Store by 2026-10-16, filtering SMS and blocking calls.
- Android app in testers' hands (closed test and direct APK) by 2026-10-09.
- A blocklist that updates from user reports within 15 minutes, with no way for
  a single actor to add a number to it.
- No legitimate message class (Elections Committee, banks, health funds, 2FA)
  is filtered.

## 2. What the owner said, and what is assumed

Said: Android and iOS apps plus an AWS backend; target this election with cut
scope; backend goes in the existing AWS account as a new stack.

Assumed (correct these if wrong):

- The owner has an Apple Developer Program membership and no Google Play
  account yet.
- The app is free, with no accounts and no sign-in.
- Hebrew is the UI language, with English as fallback. Arabic and Russian
  appear in filter keywords, not in the UI.
- The owner is the single operator who curates overrides and applies Terraform.

## 3. Scope

In scope (v1):

| Piece | What it does |
|---|---|
| Backend | Serves the blocklist as a static file; accepts reports; aggregates reports into the blocklist every 15 minutes. |
| iOS app | Message Filter extension (SMS to Junk), Call Directory extension (block numbers), in-app report form, list refresh. |
| Android app | `CallScreeningService` (reject calls on the list before they ring), one-tap report from the screened-call log, list refresh. |

Cut from v1, deliberately:

- **Android SMS filtering.** Needs default-SMS-app status or notification
  access, plus a manual Play permissions review. Not shippable in the window.
- **The no-install opt-out bot** (answering robocalls, pressing the removal
  key). A separate telephony product.
- **Carrier white-label.** A sales process, not a build.
- **Device attestation** (App Attest, Play Integrity). First item for v1.1; its
  absence is the main known weakness (section 8).
- **iOS Unwanted Communication Reporting extension.** v1.1; v1 reports by
  pasting a number or sender into the app.
- Accounts, analytics, push notifications, settings beyond on/off.

## 4. Platform facts the design rests on

These are constraints of the operating systems, not choices.

iOS:

- The Message Filter extension sees only SMS/MMS from senders not in the
  user's contacts. It has **no network access and cannot write to the shared
  container**; it can read the app group container. So the app downloads the
  rules and the extension reads them.
- The filter moves messages to the Junk tab. It does not delete them.
- The Call Directory extension blocks **exact numbers only**, supplied as
  integers in ascending order. No prefixes, no real-time decision. The app asks
  iOS to reload the extension after each list refresh.
- The app can refresh in the background only when iOS grants a background
  refresh; a foreground open always refreshes.

Android:

- `CallScreeningService` (API 29+, role `ROLE_CALL_SCREENING`) decides per
  call, before it rings, and must answer within about 5 seconds. So the
  decision is made against the local copy of the list, never over the network.
- Without `READ_CONTACTS`, Android invokes the service only for callers not in
  the user's contacts. That is the behaviour wanted; the permission is not
  requested.
- A new personal Play account must run a closed test with 12 testers for 14
  continuous days before production access. Started 2026-10-09, that completes
  2026-10-23, and production review follows. **Play production before election
  day is not planned on.** The closed test track and a signed APK on the
  website are the Android channels for this election.

## 5. Architecture

Three independent units, joined by one contract (section 6).

```
  iOS app ─┐                              ┌─ S3 (blocklist.json) ◄─┐
           ├─ GET  blocklist ─ CloudFront ┘                        │
  Android ─┤                                              aggregate Lambda
           └─ POST report ── Function URL ─ report Lambda ─► DynamoDB ─┘
                                                         (every 15 min, EventBridge)
```

Backend approach considered:

1. **Static list on S3/CloudFront, reports to a Function URL Lambda, scheduled
   aggregation (chosen).** Reads, which are nearly all the traffic, never touch
   Lambda. Uses Function URLs, Python Lambdas and DynamoDB on-demand.
2. API Gateway to SQS to a batch Lambda. Better throttling, more parts. The
   reason to want it was the account's Lambda concurrency cap of 10, which is
   no longer true.
3. Server-side classification of each message. Best accuracy, but it sends
   users' message text to a server and puts a network call in a path the OS
   does not allow one in. Rejected.

Backend components (new Terraform root module `infra/` in this repo,
`us-east-1`):

- **S3 bucket** holding `v1/blocklist.json`. Private; read through CloudFront
  with origin access control. Cache TTL 5 minutes, no invalidations.
- **Report Lambda** behind a Function URL (`authorization_type = "NONE"`).
  Validates the body, rate-limits per install and per source IP, writes one
  item to DynamoDB. Reserved concurrency 10, so abuse cannot run up cost or
  take concurrency from other workloads in the account.
- **DynamoDB table** `reports`, on-demand, TTL 30 days. A second item type in
  the same table holds operator overrides (`force_block`, `never_block`).
- **Aggregate Lambda**, run by an EventBridge schedule every 15 minutes. Reads
  reports and overrides, applies the publication rule, merges the curated
  rules file, writes `v1/blocklist.json`. Reserved concurrency 1.
- **Curated rules file** `contract/curated.json` in the repo: SMS keywords, SMS
  sender IDs, the allowlist, seed numbers. Deployed with the aggregate Lambda:
  the Terraform packaging copies `contract/curated.json` and
  `contract/blocklist.schema.json` into the Lambda package. Changing it is a
  commit and an apply.
- **Alarms**: report Lambda errors and throttles, aggregate Lambda errors,
  blocklist older than 45 minutes, report read capped during a flood.

Backend requirements: Terraform with providers pinned exactly and the lock
file committed; local, gitignored state; Lambdas in Python 3.13 on arm64;
DynamoDB on-demand; IAM roles with inline policies only; no secrets in source.

Apps:

- **iOS**: Swift, SwiftUI, iOS 16+. One app target and two extension targets
  sharing an app group. Filtering logic lives in a Swift package with no UIKit
  or extension dependencies so it is unit-testable.
- **Android**: Kotlin, min SDK 29. One module. Matching logic is plain Kotlin,
  unit-testable on the JVM.
- No cross-platform framework: the extensions must be native and the UI is
  three screens (status, report, about).

## 6. The contract

### 6.1 Blocklist: `GET https://<cloudfront-domain>/v1/blocklist.json`

```json
{
  "schema": 1,
  "version": 1791201600,
  "generated_at": "2026-10-05T12:00:00Z",
  "call_numbers": ["+972501234567"],
  "call_prefixes": ["+97255988"],
  "sms_senders": ["+972521234567", "ExampleParty"],
  "sms_keywords": [
    {"text": "הודעת בחירות", "strength": "strong"},
    {"text": "קלפי", "strength": "weak"}
  ],
  "sms_allow_senders": ["Bechirot"]
}
```

- `version` is the generation time in Unix seconds and only increases. A
  client ignores a list whose `version` is not greater than the one it holds.
- A client that sees `schema` greater than 1 keeps its current list.
- Numbers are E.164. Sender IDs are compared case-insensitively.
- `call_prefixes`: Android blocks any caller whose E.164 number starts with
  one. iOS expands a prefix only when it leaves at most 4 free digits (10,000
  numbers), and stops at 500,000 Call Directory entries in total, taking
  `call_numbers` first.
- SMS rule, evaluated in order: sender in `sms_allow_senders` -> allow; sender
  in `sms_senders` -> junk; text contains at least one `strong` keyword or at
  least two distinct `weak` keywords -> junk; otherwise allow.
- Keyword matching is substring matching after normalisation (Unicode NFKC,
  Hebrew niqqud removed, lowercased). No regular expressions.
- Clients send `If-None-Match` and treat 304 as "no change".

### 6.2 Report: `POST <function-url>/v1/reports`

```json
{
  "install_id": "3f0e4c1e-6a0b-4f5e-9d0a-2f6c1b7a9e11",
  "platform": "ios",
  "kind": "call",
  "sender": "+972501234567",
  "text": "optional, SMS only, at most 1000 characters",
  "app_version": "1.0.0"
}
```

- `install_id` is a random UUID created on first launch. It is not tied to a
  person, phone number or advertising ID.
- `text` is sent only when the user ticks "include the message text".
- Responses: `202` accepted; `400` malformed, with `{"error": "<field>"}`;
  `429` rate limited. The client shows success on 202, a retry hint on 429 or
  network failure, and never blocks the UI on the result.
- Limits: 20 reports per install per day; 60 per source IP per hour.
- Stored per report: install ID, platform, kind, normalised sender, optional
  text, app version, received time, and a salted hash of the source IP's /24.
  The raw IP is not stored. Everything expires after 30 days.

### 6.3 Publication rule

A reported sender enters the blocklist when, within the last 7 days, it was
reported by **at least 3 distinct installs from at least 2 distinct /24
networks**, and it is not `never_block`. `force_block` adds a sender
regardless; `never_block` removes one regardless. Both thresholds are
Terraform variables.

`never_block` ships pre-filled with emergency and short service numbers, the
Central Elections Committee, the banks, the health funds, and the common
2FA sender IDs. The owner reviews that list before launch.

## 7. Failure behaviour

| Condition | Behaviour |
|---|---|
| Blocklist download fails | Client keeps its last list. No error unless the list is more than 24 hours old, then a quiet "last updated" line. |
| First launch, offline | Apps ship with a bundled copy of the curated rules, so the iOS SMS filter works before any download. |
| Malformed or wrong-schema list | Rejected whole; previous list kept. |
| Aggregate Lambda fails | The previous `blocklist.json` stays in place. Alarm after 45 minutes stale. |
| Report endpoint down or throttled | The report is dropped after one retry; the user is told it was not sent. Reports are not queued on device. |
| iOS Call Directory reload fails | Previous entries stay active; the app shows the error state from `CXCallDirectoryManager` and the path to enable the extension in Settings. |
| User has not enabled an extension or granted the role | The status screen says exactly which switch is off and links to it. |
| A legitimate number is blocked | Operator adds `never_block`; clients drop it on their next refresh (at most 15 minutes plus the 5 minute cache). |

## 8. Risks, stated plainly

1. **List poisoning.** `install_id` is free to forge, so a determined actor
   with several networks can get a number onto the list. v1 mitigations: the
   two-network rule, rate limits, `never_block`, operator override, and a
   public list anyone can audit. Attestation is the real fix and is v1.1.
2. **Cold start.** With no users there are no reports and the call blocklist
   is empty. The iOS SMS keyword filter works from day one; call blocking is
   only as good as the seed numbers the owner collects before launch.
3. **App Review.** A rejection or a slow review can consume the remaining
   window. Mitigation: submit by 2026-10-11, request expedited review, keep the
   first build minimal, have the privacy policy and support pages live first.
4. **False positives.** Keyword filtering has caught legitimate messages
   before. Mitigation: the strong/weak rule, the allowlist evaluated first, a
   test corpus of real election and non-election messages that must classify
   correctly before any rules change ships.
5. **Neutrality.** The curated keywords must cover every list running, with
   the same rule for each. The curated file is public in the repo.
6. **Legal.** Blocking on the user's own device at their request is the low-risk
   core. Two things need an Israeli lawyer's eye before launch: the privacy
   notice for report text under the Privacy Protection Law, and publishing a
   list of numbers labelled as election spam. Not resolved by this spec.
7. **AWS account lifetime.** The account is a free-plan account that closes
   itself about six months after 2026-07-24 or when credits run out. That is
   after the election; a product that outlives this cycle must move.

## 11. Testing

- Backend: pytest for the report handler and the aggregation rule, with moto
  for DynamoDB condition behaviour, no AWS credentials. `terraform validate`
  and `terraform plan` clean before any apply. One smoke test after apply:
  post three reports from two networks, confirm the number appears in the
  served list.
- Matching logic on both platforms: unit tests driven by one shared corpus
  file of real messages and numbers with expected outcomes, so iOS and Android
  cannot drift apart.
- Extensions and the screening service: manual test script on real devices
  (an SMS from an unknown sender with a strong keyword lands in Junk; a call
  from a listed number does not ring; a call from a contact always rings).
