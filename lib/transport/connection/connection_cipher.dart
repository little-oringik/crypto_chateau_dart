import 'dart:math';
import 'dart:typed_data';

import 'package:crypto_chateau_dart/extensions.dart';
import 'package:crypto_chateau_dart/transport/connection/connection_pipe.dart';
import 'package:crypto_chateau_dart/transport/connection/encryption.dart';
import 'package:crypto_chateau_dart/transport/connection/error.dart';
import 'package:crypto_chateau_dart/transport/utils.dart';
import 'package:x25519/x25519.dart';
import 'package:crypto_chateau_dart/transport/connection/connection_base.dart';
import 'bytes_writer.dart';
import 'bytes_reader.dart';

class ConnectionCipher extends ConnectionBase {
  final Encryption _encryption;
  late _State _state;

  ConnectionCipher(super._connection, this._encryption) {
    _state = _encryption.key.when(
      isNull: () => _StateNone(this),
      isNotNull: (_) => _StateIdle(this),
    );
  }

  @override
  Stream<BytesReader> get read => super.read.asyncExpand((buffer) => _state.read(buffer));

  @override
  void write(BytesWriter buffer) => _state.write(buffer);

  void Function(BytesWriter buffer) get _write => super.write;
}

abstract class _State {
  Stream<BytesReader> read(BytesReader event);

  void write(BytesWriter buffer);
}

/// Состояние до начала работы
/// При поступлении запроса начинает процесс рукопожатия
class _StateNone implements _State {
  final ConnectionCipher _context;

  _StateNone(this._context);

  @override
  Stream<BytesReader> read(BytesReader event) => Stream.empty();

  @override
  void write(BytesWriter buffer) => _context._state = _StateInit(_context)..write(buffer);
}

/// Оборачивает шаги рукапожатия в Pipe
/// Кеширует все запросы клиента в буффер до завершения рукопожатия
class _StateInit implements _State {
  final ConnectionCipher _context;
  late _StateInitState _state;
  final _buffer = List<BytesWriter>.empty(growable: true);
  final _pipe = Pipe();

  _StateInit(this._context) {
    _state = _StateInitStateFirstRequest(this);
  }

  /// Преобразует байты через Pipe, затем оборачивает StreamSink
  /// в _RedirectSink, чтоб перенаправить вызов чтения Pipe в [_state]
  @override
  Stream<BytesReader> read(BytesReader buffer) => _pipe.read(buffer).asyncExpand((buffer) => _state.read(buffer));

  @override
  void write(BytesWriter buffer) => _buffer.add(buffer);

  /// Метод отправки данных для состояний (обёрнут в Pipe)
  void _write(BytesWriter buffer) {
    _pipe.write(buffer);
    _context._write(buffer);
  }

  void _toIdle(Uint8List encryptionKey) {
    _context._encryption.key = encryptionKey;
    final newState = _context._state = _StateIdle(_context);
    _buffer.forEach(newState.write);
    _buffer.clear();
  }
}

class _StateIdle implements _State {
  final ConnectionCipher _context;

  _StateIdle(this._context);

  @override
  Stream<BytesReader> read(BytesReader buffer) => Stream.value(_decrypt(buffer));

  @override
  void write(BytesWriter buffer) => _context._write(_encrypt(buffer));

  Encryption get _encryption => _context._encryption;

  BytesReader _decrypt(BytesReader buffer) => _encryption.key.when(
        isNull: () => buffer,
        isNotNull: (sharedKey) => buffer.decrypt(sharedKey),
      );

  BytesWriter _encrypt(BytesWriter buffer) => _encryption.key.when(
        isNull: () => buffer,
        isNotNull: (sharedKey) => buffer..encrypt(sharedKey),
      );
}

abstract class _StateInitState {
  Stream<BytesReader> read(BytesReader buffer);
}

/// При создании отправляет на сервер первый ключ для рукопожатия
/// Ждёт в ответ публичный ключ
class _StateInitStateFirstRequest implements _StateInitState {
  final _StateInit _context;

  _StateInitStateFirstRequest(this._context) {
    final key = Uint8List.fromList([104, 97, 110, 100, 115, 104, 97, 107, 101]);
    _context._write(BytesWriter()..writeData(key));
  }

  @override
  Stream<BytesReader> read(BytesReader buffer) async* {
    final publicKey = buffer.bytes;
    final privateKey = _createPrivateKey();
    _context._state = _StateInitStateSecondRequest(_context, privateKey, publicKey);
  }

  Uint8List _createPrivateKey() {
    var privateKey = Uint8List(32);
    var secureRandom = Random.secure();

    for (var i = 0; i < privateKey.length; i++) {
      privateKey[i] = secureRandom.nextInt(256);
    }

    privateKey[0] &= 248;
    privateKey[31] &= 63;
    privateKey[31] |= 64;

    return privateKey;
  }
}

/// При создании отправляет на сервер второй ключ для рукопожатия
/// Ждёт в ответ сообщение с подтверждением рукопожатия
class _StateInitStateSecondRequest implements _StateInitState {
  final _StateInit _context;
  final Uint8List _publicKey;
  final Uint8List _privateKey;

  _StateInitStateSecondRequest(this._context, this._privateKey, this._publicKey) {
    _context._write(BytesWriter()..writeData(X25519(_privateKey, basePoint)));
  }

  @override
  Stream<BytesReader> read(BytesReader buffer) async* {
    if (buffer.bytes.first != 49) {
      throw ConnectionHandshakeError(buffer.bytes);
    }

    final encryptionKey = Uint8List.fromList(getSha256FromBytes(X25519(_privateKey, _publicKey)));
    _context._toIdle(encryptionKey);
  }
}
