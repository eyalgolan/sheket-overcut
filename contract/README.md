# contract/

The only thing the backend, the Android app and the iOS app share. The binding
definition is spec section 6
(`docs/spec.md`); these
files make it executable. Every track reads them from here. Nobody keeps a copy.

| File | What it is | Who consumes it |
|---|---|---|
| `blocklist.schema.json` | JSON Schema (draft 2020-12) for `GET /v1/blocklist.json`, spec 6.1. | Aggregate Lambda (validates before writing), both apps (same rules in their parsers), tests. |
| `curated.json` | Hand-curated rules: SMS keywords, SMS senders, SMS allowlist, seed call numbers and prefixes, and `never_block`. | Aggregate Lambda (packaged beside it), the seed build that writes `seed-blocklist.json`. |
| `test-blocklist.json` | A valid blocklist with fictitious data, for tests only. Never shipped. | Backend, Android and iOS unit tests. |
| `corpus.json` | Shared test cases: sender normalisation, SMS classification, call blocking. | Backend, Android and iOS unit tests, so the three implementations cannot drift apart. |
| `seed-blocklist.json` | The blocklist built from `curated.json` alone, committed here and bundled into both apps. It is only ever regenerated from `curated.json`, never edited by hand. | Both apps (first launch, offline), tests. |

## The rule for changing these files

Any change to `curated.json`, `corpus.json`, `test-blocklist.json` or
`blocklist.schema.json` goes in its own pull request, titled `contract: ...`,
that touches only `contract/` and is approved by the owner. A change to
`curated.json` comes in that pull request with the `corpus.json` cases that
prove it (a new keyword comes with at least one campaign message it catches
and one legitimate message it must not catch) and with `seed-blocklist.json`
regenerated from it. The corpus runs against the seed list in every track's
tests, so a keyword that catches a legitimate message fails the build.

A code pull request may change `seed-blocklist.json` only as a pure
regeneration from `curated.json`, and only with a test that proves the
committed file matches a fresh build.

## Schema notes

- `schema` is the constant `1`. A document with any other value fails the
  schema, so a client keeps its current list (spec 6.1).
- `version` is an integer (Unix seconds). The schema cannot express "greater
  than the list I hold"; each client checks that itself.
- `generated_at` uses `"format": "date-time"`. In draft 2020-12 `format` is an
  annotation unless the validator asserts formats, so the validation command
  below turns format checking on. Python's `jsonschema` needs the
  `rfc3339-validator` package installed to check `date-time`; without it the
  check is silently skipped.
- `call_numbers`: `^\+[1-9][0-9]{6,14}$`. `call_prefixes`: `^\+[1-9][0-9]{3,13}$`.
- `sms_senders` and `sms_allow_senders` are non-empty strings: an E.164 number
  or a sender ID. Sender IDs may be in any case (spec 6.1 shows
  `ExampleParty`); clients normalise both sides before comparing.
- No additional properties at the top level or inside a keyword object.

Validation command:

```
python -m venv .venv && .venv/bin/pip install jsonschema rfc3339-validator
.venv/bin/python -c 'import json, jsonschema; from jsonschema import Draft202012Validator, FormatChecker; s = json.load(open("contract/blocklist.schema.json")); Draft202012Validator.check_schema(s); Draft202012Validator(s, format_checker=FormatChecker()).validate(json.load(open("contract/test-blocklist.json"))); print("valid")'
```

## `curated.json`

Every value is stored in the form the clients compare against, so no consumer
depends on another's normalisation:

- Keyword texts are already normalised (NFKC, no niqqud, lowercase).
- Senders in `sms_senders`, `sms_allow_senders` and `never_block` are already
  normalised: E.164 numbers, or trimmed, case-folded sender IDs. Short service
  numbers such as `100` or `*2700` are not phone numbers, so they stay as
  written (see the `normalize` cases in `corpus.json`).
- `sms_senders`, `call_numbers` and `call_prefixes` are empty. No sender or
  number is published without evidence; the owner adds seed entries from real
  messages, each with corpus cases.

### Keywords: one rule for every list

Neutrality (spec section 8, risk 5) means every list gets the same treatment.
The Hebrew keywords for each list come from one rule:

1. **Weak:** each distinctive name in the list's official ballot name: the
   list name, and the people the ballot name mentions. A word that is also
   ordinary Hebrew, or sits inside an ordinary word or place name, is left out
   (`ביחד`, `ישר!`, `זהות`, the bare `גולן`, the bare `הנדל` which is inside
   `הנדל"ן`, the bare `בנט` which is inside `בנטפליקס` and `בנטילת`, the bare
   `בן גביר` which is inside the street name `אבן גבירול`), and the person's
   full name or another name in the ballot is used instead.
2. **Strong:** for each weak name `N` (with a leading `ה` dropped), the phrases
   `צביע ל<N>` and `צביעו ל<N>`. These fragments match every common
   "vote for" form by substring: `להצביע לליכוד`, `הצביע לליכוד`,
   `מצביע לליכוד`, `הצביעו לליכוד`, `תצביעו לליכוד`. A bare surname that
   rule 1 left out of the weak names (`בנט`, `גולן`, `בן גביר`, `בן-גביר`,
   `הנדל`) also gets both phrases, as written (a leading `ה` is part of the
   name and stays): after `צביע ל` it is unambiguous, and `הצביעו לבנט` is how
   campaigns write it.

Ballot letters (`מחל`, `ג`, `שס` ...) are not keywords. Most are one or two
letters, which substring matching would find inside ordinary words (`פתק מחל`
is inside `פתק מחלה`, a sick note). Treating some lists' letters as keywords and
not others would break neutrality, so none are used. `corpus.json` records the
miss this causes.

Arabic and Russian keywords are generic election phrases only (no list
names), for the same reason: the rule above produces Hebrew names, and giving
some lists Arabic or Russian names and others none would treat them
differently. Arabic harakat are not removed by the normalisation in spec 6.1,
so a strong Arabic phrase appears both with and without the shadda.

Generic keywords, used for all lists alike:

- Strong: `הודעת בחירות`, `תעמולת בחירות`, `מטה הבחירות`, `دعاية انتخابية`,
  `صوتوا للقائمة` / `صوتوا لقائمة` (with and without shadda),
  `голосуйте за`, `предвыборная агитация`.
- Weak: `בחירות`, `קלפי`, `הצבעה`, `انتخابات`, `الكنيست`, `الاقتراع`,
  `выборы`, `кнессет`, `голосование`.

One word in a message must never count as two distinct weak keywords:

- No weak keyword is a substring of another weak keyword.
- Each word has one weak keyword, never two of its forms. A vote that has
  nothing to do with the Knesset (a tenant committee, a works council) uses
  `הצבעה` and `להצביע`, or `выборы` and `о выборах`, side by side; with both
  forms as keywords it would be junked. `הצבעה` is kept rather than `להצביע`
  because `להצביע על` also means "to point out". `выборы` is kept rather than
  a stem such as `выбор`, which is the ordinary word for "choice".
- No weak keyword sits inside a common word or place name with another
  meaning. The list was checked against `בנטפליקס`, `בנטילת`, `בנטו`,
  `בנטייה`, `בנטל`, `בנטרול`, `הנדל"ן`, `הנדל״ן`, `רמת הגולן`, `גולני`,
  `בגולן`, `אבן גבירול`, `אבן-גבירול`, `נתניה`, `קלפים`. The one exception
  is `קלפי` inside `קלפים` (playing cards): spec 6.1 names `קלפי` as a weak
  keyword, and the corpus proves a single hit stays in the inbox.

### Lists covered, and the source

Lists in the poll of polls at <https://israelvote.meforum.org/>, updated
2026-10-04 20:43 UTC, read 2026-10-05; the twelve above the threshold and the
two below it that the poll still tracks. Ballot letters and official ballot
names from the Central Elections Committee's approved list as reported by ynet
on 2026-09-27 (<https://www.ynet.co.il/news/article/s1ibdii5fe>), cross-checked
with kore.co.il the same day (<https://www.kore.co.il/viewArticle/221855>).

| List | Letters | Weak names |
|---|---|---|
| Likud | מחל | ליכוד, נתניהו |
| Yashar (Gadi Eisenkot) | דרך | איזנקוט |
| Together (Naftali Bennett) | רק | נפתלי בנט |
| The Democrats | אמת | דמוקרטים, יאיר גולן |
| Yisrael Beytenu | ל | ישראל ביתנו, ליברמן |
| Joint List | ודם | הרשימה המשותפת |
| Otzma Yehudit | ב | עוצמה יהודית, איתמר בן גביר, איתמר בן-גביר |
| United Torah Judaism | ג | יהדות התורה, דגל התורה, אגודת ישראל |
| Shas | שס | ש"ס, ש״ס, עובדיה יוסף |
| Religious Zionism and Zehut | ט | הציונות הדתית, סמוטריץ, פייגלין |
| Ra'am | עם | רע"ם, רע״ם, הרשימה הערבית המאוחדת |
| Amcha Yisrael | ך | עמך ישראל, עופר וינטר |
| Blue and White | כן | כחול לבן, גנץ |
| Reservists and Economic list | די | המילואימניקים, יועז הנדל, זליכה |

Ra'am and the Joint List were approved conditionally, pending a Supreme Court
ruling. They are covered either way. Names with a quotation mark appear in
both the ASCII (`"`) and the Hebrew gershayim (`״`) form, because NFKC does not
unify them. `סמוטריץ` is stored without the final geresh so both spellings of
`סמוטריץ'` match.

### `sms_allow_senders` and `never_block`

**The owner reviews both lists before launch (spec 6.3).** The sender IDs are
the names these organisations commonly use; they were not confirmed against
messages actually received. An extra entry costs nothing; a missing one lets a
legitimate message reach the keyword rule, so the owner should add every
sender ID seen on real bank, health-fund, Elections Committee and 2FA
messages, each with a corpus case.

- `sms_allow_senders`: the Central Elections Committee (`bechirot`, the sender
  in spec 6.1), the banks and credit-card companies, the four health funds
  (`clalit`, `maccabi`, `meuhedet`, `leumit`), and common 2FA senders.
- `never_block`: everything in `sms_allow_senders`, plus emergency and short
  service numbers: 100 police, 101 Magen David Adom, 102 fire, 103 electricity,
  104 Home Front Command, 105 online child protection, 106 municipal hotline,
  110 police information, 112 emergency, 1201 ERAN; the Elections Committee
  hotline `*3857`; bank hotlines `*2403`, `*2407`, `*2009`, `*8860`, `*3009`;
  health fund hotlines `*2700`, `*3555`, `*3833`, `*507`.

Sources for the short numbers, all from web searches on 2026-10-05 and all to
be confirmed by the owner:

- `*3857`: search results quoting the Elections Committee's contact page
  (`bechirot24.bechirot.gov.il`, which now redirects to gov.il; gov.il refused
  the direct fetch with HTTP 403). Not confirmed as current for the 26th
  Knesset.
- Bank hotlines: search results listing Israeli bank call centres (among them
  moadim.co.il). The results were inconsistent on whether `*2403` belongs to
  Leumi or to a Hapoalim line; it is never-blocked either way.
- Health fund hotlines: search results listing the funds' call centres (among
  them tasmc.org.il, "מוקדי קופות חולים").
- Emergency and public-service short codes: the standard Israeli numbers, from
  general knowledge, not re-checked against a source in this session.

Lists not in that poll of polls (for example Noam, and the other minor lists
among the 38 approved) are not covered. Adding one means applying the same rule
and adding its corpus cases.

## `test-blocklist.json`

Fictitious data only, never shipped.

- `call_numbers`: `+972555001234`, `+972555009876` (the `+97255500xxxx` test
  range).
- `call_prefixes`: `+97255501` leaves 4 free digits for a 12-digit Israeli
  mobile number, so iOS expands it to exactly 10,000 entries; `+9725552` leaves
  5, so iOS skips it while Android still blocks by prefix. A 4-free-digit
  prefix cannot sit inside `+97255500xxxx` without covering that whole range,
  so both prefixes sit next to it.
- `sms_senders`: two sender IDs in mixed case (`ExampleList`, `ExampleParty`)
  to prove case-insensitive comparison, and one number.
- Keywords: two strong (Hebrew and Russian), three weak; one allow sender.

## `corpus.json`

- `normalize`: `{"in", "out"}`. `out` is the E.164 number, the trimmed and
  case-folded sender ID (1 to 20 characters), or `null`. Covers the many
  spellings of one number (`055-500-1234`, `0555001234`, `972555001234`,
  `+972 55 500 1234`, `+972-55-500-1234`, `(055) 500-1234`, with surrounding
  spaces), which must count as one sender everywhere: reports, blocklist and
  both apps. Also covers sender IDs, short service numbers, and input that is
  not a sender at all.
- `sms`: `{"blocklist", "sender", "text", "expect", "why"}`. `blocklist` is
  `seed` (the list built from `curated.json`, i.e. `seed-blocklist.json`) or
  `test` (`test-blocklist.json`). The sender is classified after
  normalisation, so the cases also exercise those spellings.
- `calls`: `{"number", "expect", "why"}`, all run against
  `test-blocklist.json` after normalising `number`. Every prefix hit is on the
  4-free-digit prefix, so the expected result is the same on Android (prefix
  match) and iOS (expanded entries). Calls from numbers in the user's contacts
  have no case: neither OS asks the app about them (spec section 4).

No real phone number of a private person appears in these files. Numbers are
in the `+97255500xxxx` test range, next to it in the two test prefixes,
or the North American fictional range `555-01xx`.
