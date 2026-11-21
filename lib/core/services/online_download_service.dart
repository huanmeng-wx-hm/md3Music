import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

import '../../data/models/song.dart';
import '../../providers/player_provider.dart';
import '../../services/kugou_api/kugou_api_client.dart';
import '../../services/kugou_server.dart';

/// 在线歌曲「先下载到缓存目录，再播本地文件」。
///
/// 接线只用作者留好的一个空钩子：
///   [PlayerProvider.resolveLocalAudioPath] : Future<String?> Function(id, quality)
/// 三个播放入口都会 `await` 它（player_provider.dart 4208 / 4472 / 5715），
/// 拿到非 null 就直接 `Uri.file(path)` 播本地，**根本不会去解析在线播放地址**。
/// 所以这里是「整首下完才出声」，不是边播边存，也不是先播流再补缓存。
///
/// 音质天然对齐：钩子收到的 quality 就是当前 _audioQuality.value。
///   - 同音质再播 → 纸条命中 → 直接播本地，零流量
///   - 换了音质   → (id, requested) 键不同 → 另下一份
///   - 服务端把 Hi-Res 降级成 320 → 纸条同时记「请求档」和「实际档」，
///     下次同一个请求仍能命中，不会反复重下
///
/// 存文件沿用仓库 RemoteDownloadCache 的写法：先写 `.part` → 确认非空 →
/// 才 rename 成正式名，半成品绝不会被当成完整歌曲播放。
class OnlineDownloadService {
  OnlineDownloadService._();

  static final OnlineDownloadService instance = OnlineDownloadService._();

  /// 小于这个体积不收：源码里判断试听片段的口径就是「<200KB 且 3~5 分钟」。
  static const int _minBytes = 200 * 1024;

  /// 自动缓存总量上限（1GB）。显式预下载（pinned）不参与清理。
  static const int _maxBytes = 1024 * 1024 * 1024;

  bool _installed = false;
  bool _loaded = false;
  Directory? _dir;
  final List<Map<String, dynamic>> _index = <Map<String, dynamic>>[];

  /// 快切歌 / 重复点击时，同一 (id, 档位) 只下一次。
  final Set<String> _inFlight = <String>{};

  /// 幂等。**必须在 App 启动时调用一次**（见 main.dart 的 runBootstrap），
  /// 不能等到用户点音质弹窗才装 —— 因为现在「播放」本身就要触发下载。
  void install() {
    if (_installed) return;
    _installed = true;

    final prevResolver = PlayerProvider.resolveLocalAudioPath;
    PlayerProvider.resolveLocalAudioPath = (id, quality) async {
      final mine = await ensureCached(id, quality);
      if (mine != null) return mine;
      // 不顶掉别的宿主已注入的解析器。
      if (prevResolver != null) return prevResolver(id, quality);
      return null;
    };

    // 预热纸条，不阻塞启动。
    unawaited(_load());
  }

  Future<Directory> _ensureDir() async {
    final cached = _dir;
    if (cached != null) return cached;
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/md3_downloads');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    _dir = dir;
    return dir;
  }

  Future<File> _indexFile() async =>
      File('${(await _ensureDir()).path}/index.json');

  Future<void> _load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final file = await _indexFile();
      if (!file.existsSync()) return;
      final raw = jsonDecode(await file.readAsString());
      if (raw is List) {
        _index
          ..clear()
          ..addAll(raw
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e)));
      }
    } catch (_) {
      // 纸条坏了就当空表，不影响播放。
    }
  }

  Future<void> _save() async {
    try {
      await (await _indexFile()).writeAsString(jsonEncode(_index));
    } catch (_) {}
  }

  String? _pathOf(Map<String, dynamic> row) {
    final path = row['path'] as String?;
    if (path == null || !File(path).existsSync()) return null;
    return path;
  }

  /// 按档位查本地：请求档优先 → 实际档 → 该歌任意一档（降级兜底）。
  Future<String?> _localFor(String id, String quality) async {
    await _load();
    for (final row in _index) {
      if (row['id'] == id && row['requested'] == quality) {
        final path = _pathOf(row);
        if (path != null) return path;
      }
    }
    for (final row in _index) {
      if (row['id'] == id && row['quality'] == quality) {
        final path = _pathOf(row);
        if (path != null) return path;
      }
    }
    for (final row in _index) {
      if (row['id'] == id) {
        final path = _pathOf(row);
        if (path != null) return path;
      }
    }
    return null;
  }

  /// 播放钩子的本体：有就播本地，没有就**整首下完**再给路径。
  /// 返回 null 时，作者原逻辑会回落到在线播放（安全兜底）。
  Future<String?> ensureCached(String id, String quality) async {
    final hit = await _localFor(id, quality);
    if (hit != null) return hit;
    return _downloadAndStore(id: id, quality: quality, pinned: false);
  }

  /// 弹窗里「⬇ 下载到本地（选音质）」用：提前预下载一档。
  /// 该档已存在就直接复用，不挪文件、不重下。
  Future<String?> downloadSong(Song song, String quality) async {
    install();
    if (!song.isOnline) return null;
    await _load();
    final hit = await _localFor(song.id, quality);
    if (hit != null) {
      for (final row in _index) {
        if (row['id'] == song.id && _pathOf(row) == hit) {
          row['pinned'] = true;
        }
      }
      await _save();
      return hit;
    }
    return _downloadAndStore(
      id: song.id,
      quality: quality,
      pinned: true,
      title: song.title,
      artist: song.artist,
    );
  }

  Future<String?> _downloadAndStore({
    required String id,
    required String quality,
    required bool pinned,
    String? title,
    String? artist,
  }) async {
    final key = '$id|$quality';
    if (_inFlight.contains(key)) return null;
    _inFlight.add(key);
    try {
      return await _storeInner(
        id: id,
        quality: quality,
        pinned: pinned,
        title: title,
        artist: artist,
      );
    } finally {
      _inFlight.remove(key);
    }
  }

  Future<String?> _storeInner({
    required String id,
    required String quality,
    required bool pinned,
    String? title,
    String? artist,
  }) async {
    // 取播放地址走 App 自带的本地 API 服务；冷启动可能还没起来。
    try {
      if (KugouApiServer.currentPort <= 0) {
        await KugouApiServer.start();
      }
    } catch (_) {}

    final KugouPlayUrl? play;
    try {
      play = await KugouApiClient().getSongUrlWithFallback(
        id,
        quality: quality,
      );
    } catch (_) {
      return null;
    }
    // isTrial = 试听片段（如 30 秒），绝不能当完整歌曲存下来。
    if (play == null || play.url.isEmpty || play.isTrial) return null;

    // 服务端可能降级，实际档和请求档分别记。
    final actualQ = play.quality.isNotEmpty ? play.quality : quality;
    final dir = await _ensureDir();
    final safeId = id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final safeQ = actualQ.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final ext = _extFrom(play.url);
    final file = File('${dir.path}/${safeId}_$safeQ$ext');
    final part = File('${file.path}.part');
    if (part.existsSync()) part.deleteSync();

    try {
      await Dio().download(
        play.url,
        part.path,
        options: Options(
          headers: <String, String>{'User-Agent': 'MD3Music/1.0'},
          receiveTimeout: const Duration(minutes: 5),
        ),
      );
      if (!part.existsSync() || part.lengthSync() < _minBytes) {
        if (part.existsSync()) part.deleteSync();
        return null;
      }
      if (file.existsSync()) file.deleteSync();
      part.renameSync(file.path);
    } catch (_) {
      // CDN 地址过期 / 断网 / 被掐断：静默放弃，交回作者原逻辑兜底。
      if (part.existsSync()) part.deleteSync();
      return null;
    }

    _index.removeWhere(
      (r) => r['id'] == id && r['requested'] == quality,
    );
    _index.add(<String, dynamic>{
      'id': id,
      'title': title ?? id,
      'artist': artist ?? '',
      'requested': quality,
      'quality': actualQ,
      'path': file.path,
      'pinned': pinned,
      'size': file.lengthSync(),
      'time': DateTime.now().millisecondsSinceEpoch,
    });
    await _save();
    if (!pinned) await _pruneIfNeeded();
    return file.path;
  }

  /// 已缓存 / 已预下载多少首（给弹窗显示用）。
  Future<int> count() async {
    await _load();
    _index.removeWhere((r) => _pathOf(r) == null);
    return _index.length;
  }

  bool isDownloaded(String id) {
    for (final row in _index) {
      if (row['id'] == id && _pathOf(row) != null) return true;
    }
    return false;
  }

  /// 超 1GB 时按时间清最旧的自动缓存；显式预下载（pinned）保留。
  Future<void> _pruneIfNeeded() async {
    try {
      final dir = await _ensureDir();
      int total = 0;
      for (final f in dir.listSync(recursive: true).whereType<File>()) {
        if (f.path.endsWith('index.json') || f.path.endsWith('.part')) continue;
        total += f.lengthSync();
      }
      if (total <= _maxBytes) return;

      final removable = <Map<String, dynamic>>[];
      for (final row in _index) {
        if (row['pinned'] == true) continue;
        if (_pathOf(row) == null) continue;
        removable.add(row);
      }
      removable.sort((a, b) =>
          (a['time'] as int? ?? 0).compareTo(b['time'] as int? ?? 0));
      for (final row in removable) {
        if (total <= _maxBytes) break;
        final path = _pathOf(row);
        if (path == null) continue;
        final size = (row['size'] as int?) ?? File(path).lengthSync();
        try {
          File(path).deleteSync();
          total -= size;
          _index.remove(row);
        } catch (_) {}
      }
      await _save();
    } catch (_) {}
  }

  /// 删掉某首（同时删文件和纸条）。
  Future<void> remove(String id) async {
    await _load();
    for (final row in List<Map<String, dynamic>>.from(_index)) {
      if (row['id'] != id) continue;
      final path = row['path'] as String?;
      if (path != null) {
        try {
          File(path).deleteSync();
        } catch (_) {}
      }
      _index.remove(row);
    }
    await _save();
  }

  static String _extFrom(String url) {
    final path = Uri.tryParse(url)?.path ?? url;
    final dot = path.lastIndexOf('.');
    if (dot >= 0) {
      final ext = path.substring(dot).toLowerCase();
      // 只认短后缀，避免把 ?token=xxx 之类整段当扩展名。
      if (RegExp(r'^\.[a-z0-9]{2,5}$').hasMatch(ext)) return ext;
    }
    return '.mp3';
  }
}
