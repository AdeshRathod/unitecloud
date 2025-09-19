# UniteCloud Tap-to-Transfer

This project demonstrates two approaches for sharing a small contact card between nearby devices:

1. NFC phone-to-phone using HCE (Host Card Emulation) – one device emulates a card that serves the JSON contact in chunks; the peer reads it using reader mode.
2. Nearby Connections (Bluetooth / Wi‑Fi Direct) – for auto-discovery or manual code, supporting bidirectional exchange without requiring NFC.

## Features

- Create a contact (name, phone, email) and share via NFC phone-to-phone (HCE based).
- Clean Nearby flows: auto-discover or manual 6-char code entry, with bidirectional exchange.
- Nearby Connections wrapper to advertise/discover using token-based serviceId.
- Reactive UI with logs and list of received contacts (GetX state management).
- Human-readable logs across NFC and Nearby (discover/connect/transfer/cancel).
- Per-field input validation with inline errors (Name/Phone/Email).
- Graceful handling of NFC disabled/unavailable, permission errors, and user-cancel.

## Folder Structure (Relevant Parts)

```
lib/
	app/
		data/models/contact.dart
		services/nfc_hce_service.dart
		services/bluetooth_service.dart (Nearby wrapper)
		modules/transfer/
			transfer_binding.dart
			transfer_controller.dart
			transfer_view.dart
	main.dart
```

## Dependencies

Added to `pubspec.yaml`:

- get – state management & DI
- nearby_connections – offline P2P (Bluetooth / Wi‑Fi Direct)
- permission_handler – runtime permission requests (Bluetooth & Location)

## Permissions & Platform Notes

Android (API 26+) only for full feature set.

Add / verify in `AndroidManifest.xml` (example – adjust for your min/target SDK):

```xml
<uses-permission android:name="android.permission.NFC" />
<uses-permission android:name="android.permission.BLUETOOTH" />
<uses-permission android:name="android.permission.BLUETOOTH_ADMIN" />
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
<uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION" />
```

For Android 12+ also consider adding `BLUETOOTH_CONNECT`, `BLUETOOTH_SCAN` with `usesPermissionFlags` as required by the Nearby library.

On iOS: `nearby_connections` is not supported; NFC reading/writing limited by hardware & entitlements. This demo focuses on Android; guard code paths accordingly if expanding.

## Architecture Overview

- `TransferController` orchestrates NFC HCE exchange and Nearby flows.
- Deterministic NFC roles: devices pick reader/card deterministically using ANDROID_ID parity, with a manual override fallback internally after failures.
- Native Android HCE service serves an APDU-based chunk protocol; the app runs reader mode to pull payload.
- `TransferService` abstracts Nearby advertising, discovery, and payload sending.
- A 6-character token (base32-like) identifies the temporary Nearby serviceId.
- Logs aggregated for transparency & debugging.

### Data Flow (NFC HCE)

```
Both devices tap Share by NFC -> each sets HCE payload with its contact -> a deterministic rule picks which reads first -> reader connects and pulls chunks -> JSON parsed -> Contact saved
```

### Data Flow (Nearby)

```
Auto: both tap Start -> advertise+discover -> connect -> exchange payloads.
Manual: one gets 6-char code -> other enters code -> connect -> exchange payloads.
```

## Testing Plan

1. Launch app on two Android NFC-capable devices.
2. Sender enters contact (small payload) <= 1.8 KB -> Tap: ensure receiver logs receipt & contact appears.
3. Modify code temporarily to pad JSON > 2 KB -> Tap: confirm token path: receiver first logs token, then after Nearby connection full payload arrives.
4. Turn off NFC on receiver -> attempt share -> ensure proper availability log.
5. Deny Bluetooth / Location permission -> verify graceful failure messages (Nearby sender/receiver fail cleanly, logs show the reason).
6. For NFC HCE, align backs of phones; if both try to read, the deterministic role prevents collisions.
7. Start NFC read and press Cancel -> the read stops, log shows "NFC read canceled" and UI returns to idle; Try again re-arms and retries.
8. Leave NFC off and press Share by NFC -> app prompts and logs "NFC is not enabled or not available."

## Limitations

- Nearby Connections: Android only.
- NFC HCE phone-to-phone varies by OEM; timings and chunk sizes tuned conservatively.
- No persistent storage (in-memory list only) – consider Hive/SQLite for production.
- No encryption / security handshake; suitable only for demo or non-sensitive data.
- Error handling simplified; production should handle more edge cases (timeouts, partial transfers).

## Future Enhancements

- Add persistent storage layer.
- Encrypt payloads with a shared secret derived from token.
- Add progress indicators for Nearby transfer.
- Support multiple simultaneous discovery attempts.
- iOS conditional compilation & CoreNFC wrappers.

## Running

Ensure Flutter SDK (3.x) and run:

```
flutter pub get
flutter run
```

Tap two devices together (screen on, NFC enabled). On large payload test scenario, observe token handshake logs.

Expected log examples:
- NFC active. Bring the other phone close to read.
- NFC HCE ready. Bring the other phone close to exchange.
- HCE read attempt 1/2 ... Bring phones together.
- Received 512 bytes / Contact saved: Alice
- NFC read canceled.
- Nearby: advertising started / connection initiated / payload 384 bytes sent.

## Troubleshooting

- If NFC sessions fail repeatedly, ensure no other NFC app is in foreground (e.g., Google Pay).
- If Nearby discovery fails: toggle Bluetooth & Location; ensure permissions are granted.
- Use `adb logcat` filtering `[NFC]` or `[Nearby]` for deeper diagnostics.

---

MIT-style license or internal usage only (adjust as needed).
