# UniteCloud Tap-to-Transfer

Share a contact card quickly between nearby Android devices using NFC (Host Card Emulation), Nearby Connections (Bluetooth/Wi‑Fi), or QR codes. The app uses deterministic NFC roles for faster pairing, clean logs, and a simple UI.

## Table of Contents

- Overview
- Quick Start
- Features
- Architecture
  - Services
  - Platform Channels
  - Data Flows
- Folder Structure
- Permissions & Platform Notes
- Troubleshooting
- FAQ
- Limitations
- License

## Overview

Three ways to exchange a small contact payload:

1. NFC phone-to-phone (HCE): one phone emulates a card, the other reads it via IsoDep.
2. Nearby Connections: auto-discovery or 6‑character code; bidirectional over Bluetooth/Wi‑Fi.
3. QR codes: show your contact or scan someone else’s.

## Quick Start

1. Install Flutter SDK and Android toolchain.
2. Connect two Android NFC-capable devices (screen on, NFC enabled).
3. In one terminal, run in this repo:
   - flutter pub get
   - flutter run
4. Repeat on the second device.

## Features

- NFC HCE share with a robust reader loop (retries, reselect, short timeouts).
- Deterministic NFC roles (ANDROID_ID parity) with manual override.
- Nearby auto and manual (code) flows with retries and concise logs.
- QR bottom sheet consolidating Show QR and Scan QR.
- Inline validation for Name/Phone/Email; graceful handling for NFC off, permissions denied, and user-cancel.

## Architecture

The `TransferController` orchestrates all flows (NFC, Nearby, QR), manages state and logs, and keeps logic context-free for easier testing.

### Services

- NFC HCE service – `lib/app/services/nfc_hce_service.dart`
  - Sets/clears payload (serve-once), disables reader, checks payload presence, and exposes a one-shot read.
- Nearby service – `lib/app/services/bluetooth_service.dart`
  - Advertise/discover, connect, send/receive payloads; handles permissions/retries and emits logs.
- NFC capability/platform – `lib/app/services/nfc_utils.dart`
  - Checks hardware/enabled state and opens system settings via a platform channel.
- QR share service – `lib/app/services/qr_share_service.dart`
  - Generates and scans QR content for the contact payload.

### Platform Channels

MethodChannel (Android) exports:

- hasNfcHardware(): bool
- isNfcEnabled(): bool
- openNfcSettings(): void
- getAndroidId(): String
- hceSetPayload(bytes): void
- hceClear(): void
- hceDisableReader(): void
- hceHasPayload(): bool
- hceReadOnce(timeoutMs): String? (JSON)

Flutter wrappers:

- `NfcHceService` for HCE controls
- `NfcUtils` for capability/settings
- Reader loop lives in `TransferController`

### Data Flows

- NFC (HCE): Both tap Share → both set payload → parity decides reader/card → reader pulls chunks → JSON parsed → saved.
- Nearby: Auto (advertise+discover) or Manual (code) → connect → exchange payloads.
- QR: Open sheet → Show QR or Scan QR → preview and save.

## Folder Structure

```
lib/
  app/
    data/
      models/
        contact.dart
    modules/
      transfer/
        transfer_binding.dart
        transfer_controller.dart
        transfer_view.dart
    services/
      bluetooth_service.dart
      nfc_hce_service.dart
      nfc_utils.dart
      qr_share_service.dart
main.dart
```

## Permissions & Platform Notes

Android (API 26+) recommended. Add/verify in AndroidManifest as needed:

```
android.permission.NFC
android.permission.BLUETOOTH
android.permission.BLUETOOTH_ADMIN
android.permission.ACCESS_FINE_LOCATION
android.permission.ACCESS_COARSE_LOCATION
android.permission.BLUETOOTH_CONNECT   # Android 12+
android.permission.BLUETOOTH_SCAN      # Android 12+
android.permission.NEARBY_WIFI_DEVICES # Android 13+
```

iOS: Nearby Connections is not supported. NFC is limited by CoreNFC/entitlements. This app targets Android.

## Troubleshooting

- NFC off or missing: The app prompts to enable NFC. You can also open system NFC settings from the UI.
- Tag was lost / unstable taps: Re-align the backs of the phones. Ensure no wallet app is active in the foreground.
- Collisions (both trying to read): Deterministic roles reduce this; use the manual role toggle if needed.
- Nearby not connecting: Re-grant Bluetooth/Location permissions. Toggle Bluetooth and Location services. Try manual code mode.
- QR not scanning: Ensure camera permission is granted and the QR is fully visible.

## FAQ

- Why native HCE instead of a general NFC plugin? Phone-to-phone requires one device to emulate a tag. A HostApduService gives reliable control (serve‑once, chunking, retries) and a robust reader over IsoDep.
- Services vs utils—where should `NfcUtils` live? It uses a platform channel and opens settings, so it belongs in `services/`. Split any pure helpers into `utils/` if needed.
- Is the exchange bidirectional? Nearby is bidirectional. NFC serves one payload per tap by design; you can re-arm to reciprocate.

## Limitations

- Android only for Nearby; NFC HCE timing can vary across OEMs.
- No persistence layer (contacts held in-memory). Consider Hive/SQLite.
- No encryption/handshake; suitable for non-sensitive data.
