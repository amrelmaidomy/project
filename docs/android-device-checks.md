# Android device acceptance checks

These are manual acceptance checks, not executed test results. A successful APK build does not verify microphone, TTS, exact alarms, reboot recovery, or manufacturer background restrictions.

Use one Android 8/API 26 device or emulator for the minimum supported version, Android 12/API 31 for exact alarm access, Android 13/API 33 for notification permission, and Android 15–16/API 35–36 for current background and edge-to-edge behavior. Set the device language to Arabic, timezone to Africa/Cairo, and install an Arabic TTS voice where available.

## First run and voice capture

- [ ] Fresh install opens in Arabic with right-to-left layout and no clipped controls at large font size.
- [ ] The microphone prompt appears after an explicit recording action; declining it leaves the app usable and explains how to grant access.
- [ ] Recording starts and stops visibly. Leaving the capture flow stops microphone use; no background microphone or wake word starts automatically.
- [ ] Granting permission records intelligible Arabic speech. A failed upload offers recovery without creating an unconfirmed reminder.
- [ ] Missing network or unavailable backend is shown clearly. Existing reminders remain available offline.
- [ ] Arabic TTS speaks a confirmation when available. A missing Arabic voice produces a clear fallback without crashing.

## Reminder confirmation and local notifications

- [ ] An Egyptian Arabic request such as «فكرني بكرة الساعة 8 الصبح آخد الدوا» shows the interpreted date, time, timezone and task before saving.
- [ ] An ambiguous request such as «فكرني يوم الجمعة» asks for missing time rather than choosing silently.
- [ ] Confirming once creates one local reminder; rapid repeated taps do not create duplicates.
- [ ] A reminder two minutes in the future fires after the app is backgrounded and after swiping it from recent apps.
- [ ] On Android 13+, declining notification permission explains the limitation; granting it enables notifications.
- [ ] On Android 12+, declining exact alarm access does not claim that precise delivery is enabled. Granting access and scheduling a new reminder produces an exact notification.
- [ ] A notification has a visible monochrome status icon, Arabic title/body, sound and the expected tap destination.
- [ ] Editing time removes the old scheduled notification; deleting a reminder prevents notification delivery.
- [ ] Dismissing a notification does not create another notification unexpectedly.

## Persistence, clock and power behavior

- [ ] Restart the app: reminders and their current statuses remain correct.
- [ ] Reboot the device before a future reminder: the boot receiver restores delivery after boot, subject to Android unlock requirements.
- [ ] Update the app with the same signing key: pending future reminders survive package replacement.
- [ ] Change the device timezone: the displayed reminder timezone stays explicit and the documented time policy is applied consistently.
- [ ] Check an Africa/Cairo daylight-saving boundary: invalid or repeated local times are resolved explicitly and never silently shifted.
- [ ] Turn on battery saver/Doze: record observed delivery behavior. Check a physical device with aggressive vendor battery restrictions separately.
- [ ] Force-stop from Android Settings: record Android's expected suspension; opening the app again reconciles future reminders. Do not promise delivery while the package is force-stopped.

## Network and release integrity

- [ ] A debug emulator reaches `http://10.0.2.2:8000`; a physical USB device with `adb reverse tcp:8000 tcp:8000` reaches `http://127.0.0.1:8000`.
- [ ] Debug HTTP requests to unrelated hosts are blocked. Profile/release HTTP is blocked; a valid HTTPS backend works.
- [ ] Invalid/expired TLS certificates fail verification.
- [ ] A production artifact uses the owner controlled signing key. Missing release keys never fall back to the debug key.
- [ ] App backup remains disabled and no server/API secrets appear in the packaged application or logs.

Record device model, Android version, build ID, app version, permission state, timezone, and observed result for each failed or environment-dependent check. Keep recordings and task text out of public test logs.

## Rafiq background voice (manual checks; not yet verified on a phone)

- [ ] Update the previous APK with the same key; existing reminders remain.
- [ ] Enable «تشغيل يا رفيق» while the app is visible. Missing notification, exact alarm or microphone permissions are resolved before listening.
- [ ] With laptop backend and USB reverse active, say «يا رفيق»: an audible Arabic reply is heard. «يا مساعد», «رفيق» alone, ordinary conversation and silence do not trigger a reply.
- [ ] Repeat with Home pressed, screen locked, and app task swiped away; record the actual Samsung/Android behavior separately.
- [ ] Give a complete reminder, hear event and reminder timestamps, say «تأكيد» or «أيوه احفظ»: one reminder is saved and appears on reopening the UI, and its exact notification fires.
- [ ] Give incomplete/ambiguous times, answer clarifying questions, correct the preview, and confirm the new preview. No old preview is saved.
- [ ] «إلغاء», «لا تحفظ», silence and generic «تمام» do not save a reminder.
- [ ] Stop during recording, upload and TTS using notification «إيقاف»: microphone indicator and audio end, and delayed callbacks never restart listening.
- [ ] Disable the backend/disconnect USB, revoke alarm access, and remove Arabic TTS: failures are visible and active-conversation failures audible; no false saved confirmation.
- [ ] Restore backend/USB reverse, retry, then force-stop or reboot: listening stays off until explicitly enabled again.
- [ ] Test silence, fan, television, short and long speech, distance, and battery drain; do not infer recognition accuracy from builds/unit tests.
