# Android: manual test for call screening

Spec section 11 requires a manual test on real devices for the screening
service. This script covers the five AC-6 cases of #22:

- (a) a call from a listed number does not ring;
- (b) a call from a contact always rings;
- (c) a withheld call rings;
- (d) an outgoing call is unaffected;
- (e) a blocked call appears in the system call log with no missed-call
  notification.

Run it on a real device if you can. An emulator covers every case except (c).
Record each run with the template at the end.

The bundled seed list has no call entries (spec section 8, risk 2), so with the
seed alone the service blocks nothing. The script loads
`contract/test-blocklist.json` as the stored list instead. That file only
contains fictitious numbers in or next to the `+97255500xxxx` test range. It is
copied to the device and never edited, and no real phone number appears in
this script.

All commands run from the repository root on a host with `adb`.

## 1. Prerequisites

1. A device or emulator with API 29 or higher (`minSdk = 29`), and nothing
   installed under `app.sheket`.
   - **Emulator:** any phone system image. Incoming calls are simulated with
     the emulator console (`adb emu gsm call`).
   - **Real device:** a SIM, and a second phone that can call it. To run (a)
     on a real device, the caller's number must be on the list, so use the
     emulator for (a) unless you control a line in the test range.
2. A debug build installed **without** `-Psheket.blocklistUrl`:

   ```
   cd android && ./gradlew :app:installDebug && cd ..
   ```

   The default endpoint is the fake `https://blocklist.example.invalid/...`.
   The background refresh therefore always fails and keeps the stored list.
   With a real endpoint, a refresh could replace the test list in the middle
   of a run. The debug build is also what makes `run-as` and the
   `Sheket` debug log work.

## 2. Grant the call screening role

The app has no role request UI yet (#23), so grant the role over adb:

```
adb shell cmd role add-role-holder android.app.role.CALL_SCREENING app.sheket
adb shell dumpsys role | grep -A 4 'android.app.role.CALL_SCREENING'
```

Expected: the `dumpsys` output lists `app.sheket` as a holder of
`android.app.role.CALL_SCREENING`. If it does not, stop here: Android refused
the role, and every later step would pass for the wrong reason.

## 3. Load the test list

1. Stop the app so that the next process start reads the stored file:

   ```
   adb shell am force-stop app.sheket
   ```

2. Copy the test list into the app's files directory as `blocklist.json`.
   The file is piped through the shell's `cat`, because `run-as` may not be
   able to read `/data/local/tmp` directly on newer SELinux policies.

   ```
   adb push contract/test-blocklist.json /data/local/tmp/sheket-test-blocklist.json
   adb shell run-as app.sheket mkdir -p files
   adb shell "cat /data/local/tmp/sheket-test-blocklist.json | run-as app.sheket sh -c 'cat > files/blocklist.json'"
   adb shell run-as app.sheket ls -l files/blocklist.json
   ```

   Expected: `files/blocklist.json` exists and is the same size as
   `contract/test-blocklist.json`.

3. Clear the log, so that step 4 (a) can check which list was loaded:

   ```
   adb logcat -c
   ```

`BlocklistRepository.load()` uses the stored list when its `version` is at
least the seed's. The test list has `1791201600` and the seed has
`1791149668`, so the stored list wins. The app has no launcher activity, so its
process first starts when Telecom binds the screening service for the first
call in step 4 (a). The list is loaded then.

The test list contains:

| Entry | Value | Dial on the emulator as |
|---|---|---|
| `call_numbers` | `+972555001234` | `0555001234` |
| `call_numbers` | `+972555009876` | `0555009876` |
| `call_prefixes` | `+97255501`, `+9725552` | not used by this script |

## 4. Test cases

Before each case, wait until the previous call has ended.

### (a) A call from a listed number does not ring

1. Make an incoming call from a listed number:

   ```
   adb emu gsm call 0555001234
   ```

2. Expected:
   - the phone does not ring;
   - no incoming-call screen appears;
   - the call ends by itself.

   If the call is still shown, end it with `adb emu gsm cancel 0555001234` and
   record a **fail**.

3. Check that the test list, not the seed, made the decision:

   ```
   adb logcat -d -s Sheket
   ```

   Expected: one line containing `blocklist loaded:`, and
   `callNumbers=2, callPrefixes=2, source=STORED`.
   - `source=SEED` means the copy in step 3 did not take effect.
   - `callNumbers=0` means the seed's `version` has caught up with the test
     list's.

   Either way the run is invalid. Fix the cause and start again from step 3.

4. Check the app's own screened-call log:

   ```
   adb shell run-as app.sheket cat files/screened-calls.json
   ```

   Expected: the newest entry has `"number":"+972555001234"` and
   `"blocked":true`.

### (b) A call from a contact always rings

1. In the Contacts app, save a contact named `Sheket test` with the number
   `0555009876`. That number is on the list as `+972555009876`.
2. Make an incoming call from it:

   ```
   adb emu gsm call 0555009876
   ```

3. Expected: the phone rings and shows `Sheket test`. Android asks the service
   only about callers who are not contacts, because the app never holds
   `READ_CONTACTS` (spec section 4).
4. End the call:

   ```
   adb emu gsm cancel 0555009876
   ```

5. Run `adb shell run-as app.sheket cat files/screened-calls.json`. Expected:
   no entry for `+972555009876`, because the service was not consulted.

### (c) A withheld call rings (real device only)

The emulator console cannot place a call with a withheld number, so mark this
case `not run` on an emulator.

1. On the second phone, hide the caller ID. Use the phone's setting (in Call
   settings, set Show my caller ID to off), or dial `#31#` before the number.
2. Call the device under test.
3. Expected:
   - the phone rings;
   - the caller is shown as private or unknown;
   - the call is put through.

### (d) An outgoing call is unaffected

1. In the Phone app on the device under test, dial `+972555001234`, which is
   on the list.
2. Expected: the call is placed as normal. On an emulator the simulated call
   connects, and on a real device it rings out. The service only blocks calls
   with `DIRECTION_INCOMING`.
3. Hang up.
4. Run `adb shell run-as app.sheket cat files/screened-calls.json`. Expected:
   no new entry, because outgoing calls are not logged.

### (e) A blocked call is in the call log, with no missed-call notification

Use the call from case (a).

1. Open the notification shade. Expected: no missed-call notification for
   `0555001234`, because the block response sets `setSkipNotification(true)`.
2. In the Phone app, open the call history. Expected: an entry for
   `0555001234` at the time of case (a), because the block response sets
   `setSkipCallLog(false)`. Some dialers mark it as a blocked call; record
   how it is shown.

The `adb` shell cannot read the call log (it does not hold `READ_CALL_LOG`),
so this case is checked in the Phone app.

## 5. Clean up

```
adb shell run-as app.sheket rm -f files/blocklist.json files/screened-calls.json
adb shell rm /data/local/tmp/sheket-test-blocklist.json
adb shell am force-stop app.sheket
adb shell cmd role remove-role-holder android.app.role.CALL_SCREENING app.sheket
```

Also delete the `Sheket test` contact, and the test calls from the call
history.

After cleanup the app falls back to the bundled seed on its next start. The
seed blocks no calls.

## 6. Run record

Copy this block into the pull request description and fill it in:

```
Manual test: android/docs/manual-test.md
Date:
Tester:
Device / emulator:            (model or system image)
Android version / API level:
Build: debug, commit          (git rev-parse --short HEAD)
Step 2 role granted:          yes / no
Step 4(a) list loaded:        (paste the "blocklist loaded:" line)

| Case | Result (pass / fail / not run) | Notes |
|---|---|---|
| (a) listed number does not ring | | |
| (b) contact always rings | | |
| (c) withheld call rings | | |
| (d) outgoing call unaffected | | |
| (e) in call log, no missed-call notification | | |
```
