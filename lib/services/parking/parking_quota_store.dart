import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/io_client.dart';
import 'package:path_provider/path_provider.dart';

import 'parking_api.dart';
import 'parking_quota.dart';

const _storage = FlutterSecureStorage();
final parkingGate = ParkingRequestGate(
  read: () => _storage.read(key: 'opview_parking_gate_v3'),
  write: (v) => _storage.write(key: 'opview_parking_gate_v3', value: v),
);
Future<File> _cacheFile(String key) async {
  if (!RegExp(r'^parking_static_v3_[A-Za-z]+$').hasMatch(key))
    throw const FormatException('cache key');
  final root = await getApplicationSupportDirectory();
  final folder = Directory('${root.path}/parking');
  await folder.create(recursive: true);
  return File('${folder.path}/$key.json');
}

final parkingApi = ParkingApi(
  gate: parkingGate,
  readCache: (key) async {
    final file = await _cacheFile(key);
    return await file.exists() ? file.readAsString() : null;
  },
  writeCache: (key, value) async {
    final file = await _cacheFile(key);
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(value, flush: true);
    await temp.rename(file.path);
  },
  readSecret: (key) => _storage.read(key: key),
  writeSecret: (key, value) => _storage.write(key: key, value: value),
  clientFactory: () => IOClient(HttpClient()..autoUncompress = true),
);
