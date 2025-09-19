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
			# UniteCloud Tap-to-Transfer

			Share contact cards quickly between Android devices using three paths:

			1) NFC phone-to-phone (HCE) – one device emulates a card, the other reads it.  
			2) Nearby Connections (Bluetooth / Wi‑Fi Direct) – auto-discovery or manual code.  
			3) QR – show your contact as a QR, or scan a QR to receive.

			The app provides a clean UI, fast auto-mode, deterministic roles for NFC, and simple, human-readable logs.

			## Features

			- NFC phone-to-phone via Host Card Emulation (HCE) with reader mode.
			- Nearby Connections: Auto mode or 6-character manual code, bidirectional exchange.
			- QR: Unified bottom sheet to Show QR and Scan QR.
			- Deterministic NFC role selection (ANDOID_ID parity) with manual override.
			- Human-friendly logs and graceful error handling (NFC disabled, permissions, cancel).
			- Inline validation for Name/Phone/Email.

			## Project structure (relevant)

			```
			lib/
				app/
					data/models/contact.dart
					modules/transfer/
						transfer_binding.dart
						transfer_controller.dart
						transfer_view.dart
					services/
						bluetooth_service.dart      # Nearby wrapper (advertise/discover/send)
						nfc_hce_service.dart        # Flutter API for native HCE/reader controls
						nfc_utils.dart              # NFC availability/settings helpers (platform channel)
						qr_share_service.dart       # QR generator and scanner widgets
			main.dart
			```

			Notes on naming: `nfc_utils.dart` is a thin platform-channel gateway (open settings, check hardware/enabled). It behaves like a service. If you prefer strict separation, rename to `nfc_platform_service.dart` or move “utils” to a dedicated `utils/` folder and keep services focused on external integrations.

			## Services overview

			- NFC HCE (native-backed)
				- File: `lib/app/services/nfc_hce_service.dart`
				- What it does: Sets/clears HCE payload, disables reader, checks payload state (serve-once), and exposes a one-shot reader call. Thin Dart API over a native Android service.

			- Nearby (Bluetooth/Wi‑Fi)
				- File: `lib/app/services/bluetooth_service.dart` (class `TransferService`)
				- What it does: Advertise/discover, connect, auto-send payloads, handle permissions and retries, log human-readable events.

			- QR
				- File: `lib/app/services/qr_share_service.dart`
				- What it does: Generate QR from contact JSON; scanner widget that returns scanned data.

			## Native Android (HCE) service

			Why native: NFC phone-to-phone requires one phone to emulate a tag. We implement a HostApduService that:

			- Responds to SELECT AID and serves the contact JSON in chunks via a simple APDU protocol.
			- Clears (serve-once) payload after the last chunk or EOF, keeping HCE safely idle.
			- Works with a reader built on IsoDep that supports:
				- Reconnect and reselect on errors (e.g., 6A82) and “Tag was lost”.
				- Tuned timeouts and small backoffs to improve reliability.
				- Deterministic roles with optional override to reduce collisions.

			Platform channel (MethodChannel: `nfc_utils`) methods exposed to Flutter:

			- hasNfcHardware(): bool
			- isNfcEnabled(): bool
			- openNfcSettings(): void
			- getAndroidId(): String
			- hceSetPayload({bytes}): void
			- hceClear(): void
			- hceDisableReader(): void
			- hceHasPayload(): bool
			- hceReadOnce({timeoutMs}): String? (JSON)

			Flutter-side wrappers:

			- `NfcHceService` – wraps set/clear/disable/hasPayload.
			- `TransferController._readFromPhoneViaHceInternal` – calls `hceReadOnce` and handles retries/backoff.
			- `NfcUtils` – guard rails for NFC hardware/enabled and opening settings.

			## Architecture

			- `TransferController` orchestrates NFC HCE and Nearby flows, manages UI state, validates inputs, and aggregates user-friendly logs.
			- Deterministic role selection: ANDROID_ID parity decides reader/card; manual override available in UI.
			- Auto mode optimized with short windows and backoffs to reduce collisions.
			- Logs: Technical details remain in debug logs; the UI shows short, readable messages.

			### Data flows

			NFC (HCE):

			```
			Both devices tap Share by NFC → both set HCE payload → deterministic rule selects who reads first → reader pulls chunks via IsoDep → JSON parsed → preview & save
			```

			Nearby:

			```
			Auto: both tap Start → advertise + discover → connect → exchange payloads.
			Manual: one taps Get code → other enters code → connect → exchange payloads.
			```

			QR:

			```
			Open QR bottom sheet → Show QR (share) or Scan QR (receive) → preview & save.
			```

			## Services vs Utils (best practice)

			- Services: Integrate with platforms/frameworks (NFC, Nearby, camera). They may have side effects, permissions, and lifecycle handling.
			- Utils: Pure functions/helpers without side effects (formatting, parsing). No platform state or permissions.

			Where should `NfcUtils` live? It talks to a platform channel and opens system settings; that’s service-like behavior. It is acceptable in `services/`. If you want stricter boundaries:

			- Option A: Rename to `nfc_platform_service.dart` and keep in `services/`.
			- Option B: Split pure helpers (if any) to `utils/`, and keep platform calls in a service file.

			Also consider keeping Bluetooth/Location permission checks in the Nearby service (not the NFC utility) to avoid mixing concerns.

			## Permissions & Platform Notes

			Android (API 26+) for full feature set.

			AndroidManifest (adjust to your min/target):

			```xml
			<uses-permission android:name="android.permission.NFC" />
			<uses-permission android:name="android.permission.BLUETOOTH" />
			<uses-permission android:name="android.permission.BLUETOOTH_ADMIN" />
			<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
			<uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION" />
			<!-- Android 12+ -->
			<uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
			<uses-permission android:name="android.permission.BLUETOOTH_SCAN" />
			<!-- Android 13+ -->
			<uses-permission android:name="android.permission.NEARBY_WIFI_DEVICES" />
			```

			iOS: `nearby_connections` is not supported. NFC is limited by CoreNFC and entitlements; this demo targets Android.

			## Testing

			1) Two Android NFC-capable devices, screen on, NFC enabled.  
			2) Enter contact, Share by NFC → other device should receive contact.  
			3) Auto Nearby: both tap Start → confirm connection and exchange.  
			4) Manual Nearby: one gets a code, the other enters it → exchange.  
			5) QR: open QR sheet → Show QR on one, Scan QR on the other → preview & save.  
			6) Disable NFC and try Share by NFC → app prompts to enable and logs a simple message.  
			7) Deny Bluetooth/Location permissions and try Nearby → graceful failure with concise logs.

			## Limitations

			- Nearby Connections is Android-only.
			- NFC HCE behavior/timings vary by OEM; chunk and timeout tuning is conservative.
			- Contacts stored in-memory only (no persistence). Consider Hive/SQLite.
			- No crypto/handshake; use only for non-sensitive payloads or extend with encryption.

			## Run

			```
			flutter pub get
			flutter run
			```

			Tips: If NFC sessions fail repeatedly, ensure no wallet app is in foreground. For Nearby, toggle Bluetooth/Location or re-grant permissions if needed. Use `adb logcat` and filter `[NFC]` / `[Nearby]` for deep diagnostics.

			---

			MIT-style license or internal usage only (adjust as needed).
