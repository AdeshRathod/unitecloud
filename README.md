# UniteCloud Tap-to-Transfer

This project demonstrates two approaches for sharing a small contact card between nearby devices:

1. NFC-only for small payloads (<= ~1.8 KB) – write/read JSON contact directly to the NFC tag / device.
2. Hybrid (NFC handshake + Nearby / Bluetooth / Wi-Fi Direct) – NFC transfers only a short 6-char token, then the full JSON payload is sent over a higher-bandwidth offline channel using `nearby_connections`.

## Features

- Create a contact (name, phone, email) and share via NFC tap.
- Automatically decide if payload fits direct NFC, otherwise fall back to token handshake.
- Listen mode to receive incoming NFC payloads or handshake tokens.
- Nearby Connections wrapper to advertise/discover using token-based serviceId.
- Reactive UI with logs and list of received contacts (GetX state management).

## Folder Structure (Relevant Parts)

```
lib/
	app/
		data/models/contact.dart
		services/nfc_service.dart
		services/transfer_service.dart
		modules/transfer/
			transfer_binding.dart
			transfer_controller.dart
			transfer_view.dart
	main.dart
```

## Dependencies

Added to `pubspec.yaml`:

- get – state management & DI
- nfc_manager – low-level NFC session control
- ndef – constructing & parsing NDEF records
- nearby_connections – offline P2P (Bluetooth / Wi‑Fi Direct) for larger payloads
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

- `TransferController` decides sharing strategy based on payload size.
- `NfcService` abstracts session lifecycle (startReading / startWriting / stopSession) & logs.
- `TransferService` abstracts Nearby advertising, discovery, and payload sending.
- A 6-character token (base32-like) identifies the temporary Nearby serviceId: `unitecloud.transfer.<TOKEN>`.
- Logs aggregated for transparency & simple debugging.

### Data Flow (Direct NFC)

```
User taps Share -> Controller builds JSON -> NFC write session -> Receiver read session -> JSON parsed -> Contact saved
```

### Data Flow (Hybrid Handshake)

```
Share: build JSON (too large) -> generate token -> start Nearby advertising -> write token via NFC -> Receiver reads token -> discovery -> connects -> receives full JSON -> parsed -> saved
```

In the implementation, when the controller chooses the hybrid path it calls `advertise(..., payloadToSend: fullJson)`. The `TransferService` stores this and, upon `onConnectionInitiated`, automatically sends the full JSON bytes over the established Nearby connection—no extra UI action required. The receiver, once discovery connects, accepts the connection and any received payload is forwarded to the controller for parsing and persistence.

## Testing Plan

1. Launch app on two Android NFC-capable devices.
2. Sender enters contact (small payload) <= 1.8 KB -> Tap: ensure receiver logs receipt & contact appears.
3. Modify code temporarily to pad JSON > 2 KB -> Tap: confirm token path: receiver first logs token, then after Nearby connection full payload arrives.
4. Turn off NFC on receiver -> attempt share -> ensure proper availability log.
5. Deny Bluetooth / Location permission -> verify graceful failure messages.

## Limitations

- Nearby Connections: Android only.
- NFC tag size & phone-to-phone capabilities vary by hardware.
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

## Troubleshooting

- If NFC sessions fail repeatedly, ensure no other NFC app is in foreground (e.g., Google Pay).
- If Nearby discovery fails: toggle Bluetooth & Location; ensure permissions are granted.
- Use `adb logcat` filtering `[NFC]` or `[Nearby]` for deeper diagnostics.

---

MIT-style license or internal usage only (adjust as needed).
