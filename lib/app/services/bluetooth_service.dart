import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:nearby_connections/nearby_connections.dart';

class TransferService {
  static const Strategy _strategy = Strategy.P2P_POINT_TO_POINT;

  final _logController = StreamController<String>.broadcast();
  Stream<String> get logs => _logController.stream;

  final Nearby _nearby = Nearby();

  bool _advertising = false;
  bool _discovering = false;

  void _log(String msg) {
    if (kDebugMode) {
      // ignore: avoid_print
      print('[Nearby] $msg');
    }
    _logController.add(msg);
  }

  Future<bool> _ensurePermissions() async {
    if (!Platform.isAndroid) {
      _log('Nearby only supported on Android.');
      return false;
    }
    // Request a comprehensive set; on older Android versions, extra ones are ignored.
    final requests =
        await [
          Permission.bluetooth, // pre-Android 12
          Permission
              .locationWhenInUse, // discovery requirement on <= Android 11
          Permission.bluetoothScan, // Android 12+
          Permission.bluetoothConnect, // Android 12+
          Permission.bluetoothAdvertise, // Android 12+
          Permission.nearbyWifiDevices, // Android 13+
        ].request();

    final allGranted = requests.values.every((s) => s.isGranted);
    if (allGranted) {
      _log('Permissions granted.');
      return true;
    }
    _log(
      'Permissions status: ${requests.map((k, v) => MapEntry(k.value, v)).values.toList()}',
    );
    return false;
  }

  Future<void> advertise(
    String endpointName,
    String token, {
    String? payloadToSend,
    Function(String payload)? onPayload,
  }) async {
    if (_advertising) {
      _log('Already advertising.');
      return;
    }
    if (!await _ensurePermissions()) return;
    _log('Starting advertising with token=$token ...');
    _advertising = await _nearby.startAdvertising(
      endpointName,
      _strategy,
      onConnectionInitiated: (id, info) {
        _log('Connection initiated from $id(${info.endpointName})');
        _nearby.acceptConnection(
          id,
          onPayLoadRecieved: (epId, payload) async {
            final bytes = payload.bytes;
            if (bytes != null) {
              final text = String.fromCharCodes(bytes);
              _log('Payload received (${bytes.length} bytes)');
              onPayload?.call(text);
            }
          },
          onPayloadTransferUpdate: (epId, update) {
            _log(
              'Transfer update status=${update.status} bytes=${update.bytesTransferred}/${update.totalBytes}',
            );
          },
        );
        // If we already have the payload (sender role), attempt to send after a short microtask.
        if (payloadToSend != null) {
          scheduleMicrotask(() async {
            try {
              final data = Uint8List.fromList(payloadToSend.codeUnits);
              _log('Sending payload automatically (${data.length} bytes) ...');
              await _nearby.sendBytesPayload(id, data);
              _log('Auto-send complete to $id');
            } catch (e) {
              _log('Auto-send failed: $e');
            }
          });
        }
      },
      onConnectionResult: (id, status) {
        _log('Connection result for $id => $status');
      },
      onDisconnected: (id) => _log('Disconnected: $id'),
      serviceId: 'unitecloud.transfer.$token',
    );
    _log('Advertising started: $_advertising');
  }

  Future<void> discover(
    String token, {
    Function(String payload)? onPayload,
  }) async {
    if (_discovering) {
      _log('Already discovering.');
      return;
    }
    if (!await _ensurePermissions()) return;
    _log('Starting discovery for token=$token ...');
    _discovering = await _nearby.startDiscovery(
      'unitecloud-discoverer',
      _strategy,
      onEndpointFound: (id, name, serviceId) {
        _log('Endpoint found id=$id name=$name serviceId=$serviceId');
        if (serviceId == 'unitecloud.transfer.$token') {
          _nearby.requestConnection(
            'receiver',
            id,
            onConnectionInitiated: (epId, info) {
              _log('Initiated with $epId(${info.endpointName})');
              _nearby.acceptConnection(
                epId,
                onPayLoadRecieved: (epId, payload) async {
                  final bytes = payload.bytes;
                  if (bytes != null) {
                    final text = String.fromCharCodes(bytes);
                    _log('Payload received (${bytes.length} bytes)');
                    onPayload?.call(text);
                  }
                },
                onPayloadTransferUpdate: (epId, update) {
                  _log(
                    'Transfer update status=${update.status} bytes=${update.bytesTransferred}/${update.totalBytes}',
                  );
                },
              );
            },
            onConnectionResult:
                (epId, status) => _log('Connection result $epId => $status'),
            onDisconnected: (epId) => _log('Disconnected $epId'),
          );
        }
      },
      onEndpointLost: (id) => _log('Endpoint lost $id'),
      serviceId: 'unitecloud.transfer.$token',
    );
    _log('Discovery started: $_discovering');
  }

  Future<void> send(String endpointId, String payload) async {
    if (!_advertising && !_discovering) {
      _log(
        'Cannot send; no active connection context (advertise/discover first).',
      );
      return;
    }
    final data = Uint8List.fromList(payload.codeUnits);
    await _nearby.sendBytesPayload(endpointId, data);
    _log('Sent payload (${data.length} bytes) to $endpointId');
  }

  Future<void> stopAll() async {
    if (_advertising) {
      await _nearby.stopAdvertising();
      _advertising = false;
      _log('Stopped advertising.');
    }
    if (_discovering) {
      await _nearby.stopDiscovery();
      _discovering = false;
      _log('Stopped discovering.');
    }
  }

  void dispose() {
    stopAll();
    _logController.close();
  }
}
