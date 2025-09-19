import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter/services.dart';
import 'package:nearby_connections/nearby_connections.dart';

class TransferService {
  static const Strategy _strategy = Strategy.P2P_POINT_TO_POINT;

  final _logController = StreamController<String>.broadcast();
  Stream<String> get logs => _logController.stream;

  final Nearby _nearby = Nearby();

  bool _advertising = false;
  bool _discovering = false;
  final Set<String> _connectingEndpoints = <String>{};
  // Track endpoints we've retried a requestConnection for to avoid infinite loops
  final Set<String> _requestRetried = <String>{};

  void _log(String msg) {
    if (kDebugMode) {
      // ignore: avoid_print
      print('[Nearby] $msg');
    }
    _logController.add(msg);
  }

  Future<Map<Permission, PermissionStatus>> _requestAllRelevant() async {
    if (!Platform.isAndroid) {
      _log('Nearby only supported on Android.');
      return {};
    }
    // Request a comprehensive set; on older Android versions, extra ones are ignored.
    final requests =
        await [
          Permission.bluetooth, // pre-Android 12
          Permission.locationWhenInUse, // fine location (Android <=11)
          Permission
              .location, // coarse location (needed on some devices for discovery)
          Permission.bluetoothScan, // Android 12+
          Permission.bluetoothConnect, // Android 12+
          Permission.bluetoothAdvertise, // Android 12+
          Permission.nearbyWifiDevices, // Android 13+
        ].request();
    _log(
      'Permissions status: ${requests.map((k, v) => MapEntry(k.value, v)).values.toList()}',
    );
    return requests;
  }

  Future<bool> _ensurePermissionsForDiscover() async {
    final req = await _requestAllRelevant();
    if (req.isEmpty && !Platform.isAndroid) return false;
    final bluetoothGranted =
        (req[Permission.bluetooth]?.isGranted ?? false) ||
        ((req[Permission.bluetoothScan]?.isGranted ?? false) &&
            (req[Permission.bluetoothConnect]?.isGranted ?? false));
    // Require either scan (Android 12+) or location (Android 11 and below).
    final scanOrLocation =
        (req[Permission.bluetoothScan]?.isGranted ?? false) ||
        (req[Permission.locationWhenInUse]?.isGranted ?? false) ||
        (req[Permission.location]?.isGranted ?? false);
    final ok = bluetoothGranted && scanOrLocation;
    _log(
      ok
          ? 'Permissions OK for discovery.'
          : 'Missing required permissions for discovery.',
    );
    return ok;
  }

  Future<bool> _ensurePermissionsForAdvertise() async {
    final req = await _requestAllRelevant();
    if (req.isEmpty && !Platform.isAndroid) return false;
    final bluetoothGranted =
        (req[Permission.bluetooth]?.isGranted ?? false) ||
        ((req[Permission.bluetoothScan]?.isGranted ?? false) &&
            (req[Permission.bluetoothConnect]?.isGranted ?? false));
    final advertiseGranted =
        (req[Permission.bluetoothAdvertise]?.isGranted ?? false) ||
        (req[Permission.bluetooth]?.isGranted ?? false);
    final ok = bluetoothGranted && advertiseGranted;
    _log(
      ok
          ? 'Permissions OK for advertising.'
          : 'Missing required permissions for advertising.',
    );
    return ok;
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
    if (!await _ensurePermissionsForAdvertise()) return;
    _log('Starting advertising with token=$token ...');
    final epName = 'uc|${token.toUpperCase()}';
    Future<bool> startAdv() async {
      return await _nearby.startAdvertising(
        epName,
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
        },
        onConnectionResult: (id, status) async {
          _log('Connection result for $id => $status');
          if (status == Status.CONNECTED) {
            // Send payload after the connection is established.
            if (payloadToSend != null) {
              try {
                final data = Uint8List.fromList(payloadToSend.codeUnits);
                _log(
                  'Sending payload automatically (${data.length} bytes) ...',
                );
                await _nearby.sendBytesPayload(id, data);
                _log('Auto-send complete to $id');
              } catch (e) {
                _log('Auto-send failed: $e');
              }
            }
            await stopAll();
          }
        },
        onDisconnected: (id) => _log('Disconnected: $id'),
        serviceId: 'unitecloud.transfer',
      );
    }

    try {
      _advertising = await startAdv();
    } on PlatformException catch (e) {
      final msg = e.message ?? '';
      if (msg.contains('STATUS_ALREADY_ADVERTISING')) {
        _log(
          'Already advertising at platform level. Forcing stop and retry...',
        );
        await _nearby.stopAdvertising();
        await Future.delayed(const Duration(milliseconds: 150));
        _advertising = await startAdv();
        _log('Advertising restarted: $_advertising');
        return;
      }
      _log('Advertising failed with PlatformException: $e');
      return;
    }
    _log('Advertising started: $_advertising');
  }

  Future<void> discover(
    String token, {
    Function(String payload)? onPayload,
    String? payloadToSend,
  }) async {
    if (_discovering) {
      _log('Already discovering.');
      return;
    }
    if (!await _ensurePermissionsForDiscover()) return;
    _log('Starting discovery for token=$token ...');
    final tokenUp = token.toUpperCase();
    Future<bool> start() async {
      return await _nearby.startDiscovery(
        'unitecloud-discoverer',
        _strategy,
        onEndpointFound: (id, name, serviceId) async {
          _log('Endpoint found id=$id name=$name serviceId=$serviceId');
          // Match on constant serviceId and token in endpoint name (format: uc|TOKEN)
          if (serviceId == 'unitecloud.transfer' &&
              name.toUpperCase().contains('UC|$tokenUp')) {
            if (_connectingEndpoints.contains(id)) {
              _log(
                'Already initiating connection to $id; skipping duplicate request.',
              );
              return;
            }
            _connectingEndpoints.add(id);
            // Small debounce to avoid race after recovery restarts
            await Future.delayed(const Duration(milliseconds: 100));
            try {
              await _nearby.requestConnection(
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
                onConnectionResult: (epId, status) async {
                  _log('Connection result $epId => $status');
                  _connectingEndpoints.remove(epId);
                  if (status == Status.CONNECTED) {
                    if (payloadToSend != null) {
                      try {
                        final data = Uint8List.fromList(
                          payloadToSend.codeUnits,
                        );
                        _log(
                          'Sending payload automatically (${data.length} bytes) ...',
                        );
                        await _nearby.sendBytesPayload(epId, data);
                        _log('Auto-send complete to $epId');
                      } catch (e) {
                        _log('Auto-send failed: $e');
                      }
                    }
                    await stopAll();
                  }
                },
                onDisconnected: (epId) {
                  _connectingEndpoints.remove(epId);
                  _log('Disconnected $epId');
                },
              );
            } on PlatformException catch (e) {
              _connectingEndpoints.remove(id);
              final msg = e.message ?? '';
              if (msg.contains('STATUS_ALREADY_CONNECTING')) {
                _log('RequestConnection ignored (already connecting): $e');
              } else if (msg.contains('STATUS_ALREADY_CONNECTED_TO_ENDPOINT')) {
                _log(
                  'Already connected to endpoint $id; attempting immediate payload send.',
                );
                _requestRetried.remove(id);
                if (payloadToSend != null) {
                  try {
                    final data = Uint8List.fromList(payloadToSend.codeUnits);
                    await _nearby.sendBytesPayload(id, data);
                    _log('Immediate send complete to $id');
                  } catch (e2) {
                    _log(
                      'Immediate send failed on already-connected endpoint: $e2',
                    );
                  }
                } else {
                  _log('No payload to send for already-connected endpoint.');
                }
                await stopAll();
              } else if (msg.contains('STATUS_OUT_OF_ORDER_API_CALL')) {
                if (!_requestRetried.contains(id)) {
                  _requestRetried.add(id);
                  _log(
                    'Out-of-order API call. Stopping discovery and retrying connection once...',
                  );
                  try {
                    await _nearby.stopDiscovery();
                  } catch (_) {}
                  await Future.delayed(const Duration(milliseconds: 350));
                  try {
                    _connectingEndpoints.add(id);
                    await _nearby.requestConnection(
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
                      onConnectionResult: (epId, status) async {
                        _log('Connection result $epId => $status');
                        _connectingEndpoints.remove(epId);
                        _requestRetried.remove(id);
                        _requestRetried.remove(epId);
                        if (status == Status.CONNECTED) {
                          if (payloadToSend != null) {
                            try {
                              final data = Uint8List.fromList(
                                payloadToSend.codeUnits,
                              );
                              _log(
                                'Sending payload automatically (${data.length} bytes) ...',
                              );
                              await _nearby.sendBytesPayload(epId, data);
                              _log('Auto-send complete to $epId');
                            } catch (e) {
                              _log('Auto-send failed: $e');
                            }
                          }
                          await stopAll();
                        }
                      },
                      onDisconnected: (epId) {
                        _connectingEndpoints.remove(epId);
                        _requestRetried.remove(id);
                        _requestRetried.remove(epId);
                        _log('Disconnected $epId');
                      },
                    );
                  } on PlatformException catch (e2) {
                    _connectingEndpoints.remove(id);
                    final rmsg = e2.message ?? '';
                    if (rmsg.contains('STATUS_ALREADY_CONNECTED_TO_ENDPOINT')) {
                      _log(
                        'Already connected (on retry) to endpoint $id; attempting immediate payload send.',
                      );
                      _requestRetried.remove(id);
                      if (payloadToSend != null) {
                        try {
                          final data = Uint8List.fromList(
                            payloadToSend.codeUnits,
                          );
                          await _nearby.sendBytesPayload(id, data);
                          _log('Immediate send complete to $id');
                        } catch (e3) {
                          _log(
                            'Immediate send failed on already-connected endpoint (retry): $e3',
                          );
                        }
                      } else {
                        _log(
                          'No payload to send for already-connected endpoint (retry).',
                        );
                      }
                      await stopAll();
                    } else {
                      _log('Retry requestConnection failed: $e2');
                    }
                  }
                } else {
                  _log(
                    'RequestConnection ignored (out-of-order, already retried): $e',
                  );
                }
              } else {
                _log('RequestConnection failed: $e');
              }
            }
          }
        },
        onEndpointLost: (id) => _log('Endpoint lost $id'),
        serviceId: 'unitecloud.transfer',
      );
    }

    try {
      _discovering = await start();
    } on PlatformException catch (e) {
      final msg = e.message ?? '';
      if (msg.contains('MISSING_PERMISSION_ACCESS_COARSE_LOCATION')) {
        _log(
          'Discovery failed: missing location. Requesting location permission and retrying...',
        );
        final locFine = await Permission.locationWhenInUse.request();
        final locCoarse = await Permission.location.request();
        if (locFine.isGranted || locCoarse.isGranted) {
          _discovering = await start();
        } else {
          _log('Location permission not granted. Cannot discover.');
          return;
        }
      } else if (msg.contains('STATUS_ALREADY_DISCOVERING')) {
        _log('Discovery already active. Forcing stop and retry...');
        await _nearby.stopDiscovery();
        await Future.delayed(const Duration(milliseconds: 150));
        _discovering = await start();
        _log('Discovery restarted: $_discovering');
        return;
      } else {
        _log('Discovery failed with PlatformException: $e');
        return;
      }
    }
    _log('Discovery started: $_discovering');
  }

  // Open advertise without a token, useful for "just find peers" mode.
  Future<void> advertiseOpen(
    String endpointName, {
    String? payloadToSend,
    Function(String payload)? onPayload,
  }) async {
    if (_advertising) {
      _log('Already advertising.');
      return;
    }
    if (!await _ensurePermissionsForAdvertise()) return;
    _log('Starting open advertising ...');
    Future<bool> startAdvOpen() async {
      return await _nearby.startAdvertising(
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
        },
        onConnectionResult: (id, status) async {
          _log('Connection result for $id => $status');
          if (status == Status.CONNECTED) {
            if (payloadToSend != null) {
              try {
                final data = Uint8List.fromList(payloadToSend.codeUnits);
                _log(
                  'Sending payload automatically (${data.length} bytes) ...',
                );
                await _nearby.sendBytesPayload(id, data);
                _log('Auto-send complete to $id');
              } catch (e) {
                _log('Auto-send failed: $e');
              }
            }
            await stopAll();
          }
        },
        onDisconnected: (id) => _log('Disconnected: $id'),
        serviceId: 'unitecloud.transfer',
      );
    }

    try {
      _advertising = await startAdvOpen();
    } on PlatformException catch (e) {
      final msg = e.message ?? '';
      if (msg.contains('STATUS_ALREADY_ADVERTISING')) {
        _log(
          'Already advertising at platform level. Forcing stop and retry...',
        );
        await _nearby.stopAdvertising();
        await Future.delayed(const Duration(milliseconds: 150));
        _advertising = await startAdvOpen();
        _log('Open advertising restarted: $_advertising');
        return;
      }
      _log('Open advertising failed with PlatformException: $e');
      return;
    }
    _log('Open advertising started: $_advertising');
  }

  // Open discovery without a token; connects to the first matching endpoint and optionally sends payload.
  Future<void> discoverOpen({
    String discovererName = 'unitecloud-auto',
    String? payloadToSend,
    Function(String payload)? onPayload,
  }) async {
    if (_discovering) {
      _log('Already discovering.');
      return;
    }
    if (!await _ensurePermissionsForDiscover()) return;
    _log('Starting open discovery ...');
    Future<bool> start() async {
      return await _nearby.startDiscovery(
        discovererName,
        _strategy,
        onEndpointFound: (id, name, serviceId) async {
          _log('Endpoint found id=$id name=$name serviceId=$serviceId');
          if (serviceId == 'unitecloud.transfer') {
            if (_connectingEndpoints.contains(id)) {
              _log(
                'Already initiating connection to $id; skipping duplicate request.',
              );
              return;
            }
            _connectingEndpoints.add(id);
            await Future.delayed(const Duration(milliseconds: 100));
            try {
              await _nearby.requestConnection(
                discovererName,
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
                onConnectionResult: (epId, status) async {
                  _log('Connection result $epId => $status');
                  _connectingEndpoints.remove(epId);
                  if (status == Status.CONNECTED) {
                    if (payloadToSend != null) {
                      try {
                        final data = Uint8List.fromList(
                          payloadToSend.codeUnits,
                        );
                        _log(
                          'Sending payload automatically (${data.length} bytes) ...',
                        );
                        await _nearby.sendBytesPayload(epId, data);
                        _log('Auto-send complete to $epId');
                      } catch (e) {
                        _log('Auto-send failed: $e');
                      }
                    }
                    await stopAll();
                  }
                },
                onDisconnected: (epId) {
                  _connectingEndpoints.remove(epId);
                  _log('Disconnected $epId');
                },
              );
            } on PlatformException catch (e) {
              _connectingEndpoints.remove(id);
              final msg = e.message ?? '';
              if (msg.contains('STATUS_ALREADY_CONNECTING')) {
                _log('RequestConnection ignored (already connecting): $e');
              } else if (msg.contains('STATUS_ALREADY_CONNECTED_TO_ENDPOINT')) {
                _log(
                  'Already connected to endpoint $id; attempting immediate payload send.',
                );
                _requestRetried.remove(id);
                if (payloadToSend != null) {
                  try {
                    final data = Uint8List.fromList(payloadToSend.codeUnits);
                    await _nearby.sendBytesPayload(id, data);
                    _log('Immediate send complete to $id');
                  } catch (e2) {
                    _log(
                      'Immediate send failed on already-connected endpoint: $e2',
                    );
                  }
                } else {
                  _log('No payload to send for already-connected endpoint.');
                }
                await stopAll();
              } else if (msg.contains('STATUS_OUT_OF_ORDER_API_CALL')) {
                if (!_requestRetried.contains(id)) {
                  _requestRetried.add(id);
                  _log(
                    'Out-of-order API call. Stopping discovery and retrying connection once...',
                  );
                  try {
                    await _nearby.stopDiscovery();
                  } catch (_) {}
                  await Future.delayed(const Duration(milliseconds: 350));
                  try {
                    _connectingEndpoints.add(id);
                    await _nearby.requestConnection(
                      discovererName,
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
                      onConnectionResult: (epId, status) async {
                        _log('Connection result $epId => $status');
                        _connectingEndpoints.remove(epId);
                        _requestRetried.remove(id);
                        _requestRetried.remove(epId);
                        if (status == Status.CONNECTED) {
                          if (payloadToSend != null) {
                            try {
                              final data = Uint8List.fromList(
                                payloadToSend.codeUnits,
                              );
                              _log(
                                'Sending payload automatically (${data.length} bytes) ...',
                              );
                              await _nearby.sendBytesPayload(epId, data);
                              _log('Auto-send complete to $epId');
                            } catch (e) {
                              _log('Auto-send failed: $e');
                            }
                          }
                          await stopAll();
                        }
                      },
                      onDisconnected: (epId) {
                        _connectingEndpoints.remove(epId);
                        _requestRetried.remove(id);
                        _requestRetried.remove(epId);
                        _log('Disconnected $epId');
                      },
                    );
                  } on PlatformException catch (e2) {
                    _connectingEndpoints.remove(id);
                    final rmsg = e2.message ?? '';
                    if (rmsg.contains('STATUS_ALREADY_CONNECTED_TO_ENDPOINT')) {
                      _log(
                        'Already connected (on retry) to endpoint $id; attempting immediate payload send.',
                      );
                      _requestRetried.remove(id);
                      if (payloadToSend != null) {
                        try {
                          final data = Uint8List.fromList(
                            payloadToSend.codeUnits,
                          );
                          await _nearby.sendBytesPayload(id, data);
                          _log('Immediate send complete to $id');
                        } catch (e3) {
                          _log(
                            'Immediate send failed on already-connected endpoint (retry): $e3',
                          );
                        }
                      } else {
                        _log(
                          'No payload to send for already-connected endpoint (retry).',
                        );
                      }
                      await stopAll();
                    } else {
                      _log('Retry requestConnection failed: $e2');
                    }
                  }
                } else {
                  _log(
                    'RequestConnection ignored (out-of-order, already retried): $e',
                  );
                }
              } else {
                _log('RequestConnection failed: $e');
              }
            }
          }
        },
        onEndpointLost: (id) => _log('Endpoint lost $id'),
        serviceId: 'unitecloud.transfer',
      );
    }

    try {
      _discovering = await start();
    } on PlatformException catch (e) {
      final msg = e.message ?? '';
      if (msg.contains('MISSING_PERMISSION_ACCESS_COARSE_LOCATION')) {
        _log(
          'Open discovery failed: missing location. Requesting location permission and retrying...',
        );
        final locFine = await Permission.locationWhenInUse.request();
        final locCoarse = await Permission.location.request();
        if (locFine.isGranted || locCoarse.isGranted) {
          _discovering = await start();
        } else {
          _log('Location permission not granted. Cannot discover.');
          return;
        }
      } else if (msg.contains('STATUS_ALREADY_DISCOVERING')) {
        _log('Open discovery already active. Forcing stop and retry...');
        await _nearby.stopDiscovery();
        await Future.delayed(const Duration(milliseconds: 150));
        _discovering = await start();
        _log('Open discovery restarted: $_discovering');
        return;
      } else {
        _log('Open discovery failed with PlatformException: $e');
        return;
      }
    }
    _log('Open discovery started: $_discovering');
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
    _connectingEndpoints.clear();
    _requestRetried.clear();
  }

  void dispose() {
    stopAll();
    _logController.close();
  }
}
