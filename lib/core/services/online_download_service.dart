import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../../data/models/song.dart';
import '../../providers/player_provider.dart';
import '../../services/kugou_api/kugou_api_client.dart';
import '../../services/kugou_api/kugou_models.dart';
import '../../services/kugou_server.dart';

/// 一条下载/缓存任务的状态（「已下载」页顶部用）。
enum DownloadStatus { downloading, done, failed }

/// 服务层只存数据，UI 监听 [OnlineDownloadService.tasks] 自己刷新。
class DownloadTask {
  DownloadTask({
    required this.id,
    required this.title,
    required this.artist,
    required this.quality,
    required this.pinned,
  });

  final String id;
  final String title;
  final String artist;
  final String quality;

  /// true = 菜单里手动点的「下载」；false = 播放时自动缓存。
  final bool pinned;

  double progress = 0;
  DownloadStatus status = DownloadStatus.downloading;
  String message = '';
}

/// 在线歌曲「先下载到缓存目录，再播本地文件」。
///
/// 接线只用作者留好的空钩子：
/// [PlayerProvider.resolveLocalAudioPath] : Future<String?> Function(id, quality)
/// 三个播放入口都会 await 它，拿到非 null 就直接 Uri.file(path) 播本地。
///
/// 两个文件夹，都在 /storage/emulated/0/Android/data/<包名>/files/ 下：
///   md3_cache      → 播放缓存（点歌自动整首存，超 1GB 清最旧）
///   md3_downloads  → 已下载（菜单手动点「下载」选音质存的，永不自动清）
/// 纸条 index.json 放在 files/ 根，每条记 path + pinned，UI 按 pinned 分两页。
class OnlineDownloadService {
  OnlineDownloadService._();

  static final OnlineDownloadService instance = OnlineDownloadService._();

  /// 播放缓存夹子名。
  static const String cacheFolder = 'md3_cache';

  /// 手动下载夹子名。
  static const String downloadFolder = 'md3_downloads';

  /// 旧版目录名（在内部文档目录里），首次用到时一次性归位。
  static const String _legacyFolderName = 'md3_downloads';

  /// 「没存成」递一句中文原因给 UI 弹窗；不设就静默回落到在线播放。
  static void Function(String reason)? onDownloadFailed;

  /// 缓存页监听这两个刷新，不轮询。
  static final ValueNotifier<List<DownloadTask>> tasks =
      ValueNotifier<List<DownloadTask>>(<DownloadTask>[]);
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  static const int _minBytes = 200 * 1024;
  static const int _maxBytes = 1024 * 1024 * 1024;

  bool _installed = false;
  bool _loaded = false;
  Future<void>? _loadFuture;
  Directory? _baseDir;
  final Map<bool, Directory> _dirs = <bool, Directory>{};
  final List<Map<String, dynamic>> _index = <Map<String, dynamic>>[];
  final Set<String> _inFlight = <String>{};

  void _bump() => revision.value = revision.value + 1;

  void _notifyTasks() => tasks.value = List<DownloadTask>.of(tasks.value);

  void _putTask(DownloadTask t) {
    final list = List<DownloadTask>.of(tasks.value)
      ..removeWhere((e) => e.id == t.id && e.quality == t.quality);
    list.insert(0, t);
    if (list.length > 60) list.removeRange(60, list.length);
    tasks.value = list;
  }

  /// 只挂播放前钩子：**启动期零磁盘 IO**。
  /// 纸条与目录等第一次真正用到（播放 / 打开已下载页 / 点下载）才懒加载。
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
  }

  /// 给「已下载」页的 ⓘ 显示用。
  static Future<String> cacheDirPath() async =>
      (await instance._ensureDir(false)).path;

  static Future<String> downloadDirPath() async =>
      (await instance._ensureDir(true)).path;

  /// getExternalStorageDirectory() 在 Android 上就是
  /// /storage/emulated/0/Android/data/<applicationId>/files
  Future<Directory> _ensureBase() async {
    final cached = _baseDir;
    if (cached != null) return cached;
    Directory base;
    try {
      final ext = await getExternalStorageDirectory();
      base = ext ?? await getApplicationDocumentsDirectory();
    } catch (_) {
      base = await getApplicationDocumentsDirectory();
    }
    _baseDir = base;
    return base;
  }

  /// pinned=true 进「已下载」夹子，false 进「播放缓存」夹子。
  Future<Directory> _ensureDir(bool pinned) async {
    final cached = _dirs[pinned];
    if (cached != null) return cached;
    final base = await _ensureBase();
    final dir =
        Directory('${base.path}/${pinned ? downloadFolder : cacheFolder}');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    _dirs[pinned] = dir;
    return dir;
  }

  Future<File> _indexFile() async =>
      File('${(await _ensureBase()).path}/index.json');

  /// 并发安全：多个入口同时 await 只跑一次，且一定等读完才返回。
  Future<void> _load() {
    final pending = _loadFuture;
    if (pending != null) return pending;
    if (_loaded) return Future<void>.value();
    final f = _loadInner();
    _loadFuture = f;
    return f;
  }

  Future<void> _loadInner() async {
    try {
      final file = await _indexFile();
      var source = file;
      if (!source.existsSync()) {
        // 上一版把纸条和文件都放在内部文档目录 md3_downloads 里。
        final legacyBase = await getApplicationDocumentsDirectory();
        final legacy = File(
          '${legacyBase.path}/$_legacyFolderName/index.json',
        );
        if (legacy.existsSync()) source = legacy;
      }
      if (source.existsSync()) {
        final raw = jsonDecode(await source.readAsString());
        if (raw is List) {
          _index
            ..clear()
            ..addAll(raw
                .whereType<Map>()
                .map((e) => Map<String, dynamic>.from(e)));
        }
      }
      // 按 pinned 把历史文件归到两个夹子，并把纸条统一写回新位置。
      await _relocateAll();
      await _save();
    } catch (_) {
      // 纸条坏了就当空表，不影响播放。
    }
    _loaded = true;
    _loadFuture = null;
    _bump();
  }

  /// 每条记录按 pinned 找到它「该在」的夹子，不对就搬过去。
  /// 覆盖三种历史：内部文档目录、上一版全塞 md3_cache、以及手动/自动混放。
  Future<void> _relocateAll() async {
    final cacheDir = await _ensureDir(false);
    final dlDir = await _ensureDir(true);
    for (final row in _index) {
      final p = row['path'] as String?;
      if (p == null || !File(p).existsSync()) continue;
      final expected =
          (row['pinned'] == true ? dlDir : cacheDir).path;
      if (p.startsWith('$expected${Platform.pathSeparator}')) continue;
      final f = File(p);
      final name = p.split(Platform.pathSeparator).last;
      final dst = '$expected${Platform.pathSeparator}$name';
      try {
        if (File(dst).existsSync()) {
          f.deleteSync();
        } else {
          try {
            f.renameSync(dst);
          } catch (_) {
            f.copySync(dst);
            f.deleteSync();
          }
        }
        row['path'] = dst;
      } catch (_) {}
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
        final p = _pathOf(row);
        if (p != null) return p;
      }
    }
    for (final row in _index) {
      if (row['id'] == id && row['quality'] == quality) {
        final p = _pathOf(row);
        if (p != null) return p;
      }
    }
    for (final row in _index) {
      if (row['id'] == id) {
        final p = _pathOf(row);
        if (p != null) return p;
      }
    }
    return null;
  }

  /// 播放钩子本体：命中就播本地，没命中就整首下完再给路径。
  Future<String?> ensureCached(String id, String quality) async {
    final hit = await _localFor(id, quality);
    if (hit != null) return hit;
    return _downloadAndStore(id: id, quality: quality, pinned: false);
  }

  /// 菜单「下载」用：该档已存在就复用（翻 pinned + 归到下载夹子），否则整首下。
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
      await _relocateAll();
      await _save();
      // _relocateAll 可能把文件从播放缓存搬进「已下载」夹子并改写 path，
      // 所以复用路径要重新查一次，别把搬走前的旧地址递回给调用方。
      final pinnedPath = await _localFor(song.id, quality) ?? hit;
      _putTask(DownloadTask(
        id: song.id,
        title: song.title,
        artist: song.artist,
        quality: quality,
        pinned: true,
      )
        ..status = DownloadStatus.done
        ..progress = 1
        ..message = '本地已有这一档，直接复用');
      _bump();
      return pinnedPath;
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
    final task = DownloadTask(
      id: id,
      title: title ?? id,
      artist: artist ?? '',
      quality: quality,
      pinned: pinned,
    );
    _putTask(task);
    try {
      final path = await _storeInner(
        id: id,
        quality: quality,
        pinned: pinned,
        title: title,
        artist: artist,
        task: task,
      );
      if (task.status == DownloadStatus.downloading) {
        task.status =
            path == null ? DownloadStatus.failed : DownloadStatus.done;
        if (path != null) task.progress = 1;
        _notifyTasks();
      }
      return path;
    } finally {
      _inFlight.remove(key);
    }
  }

  String? _fail(String reason, [DownloadTask? task]) {
    if (task != null) {
      task.status = DownloadStatus.failed;
      task.message = reason;
      _notifyTasks();
    }
    final cb = onDownloadFailed;
    if (cb != null) {
      try {
        cb(reason);
      } catch (_) {}
    }
    return null;
  }

  Future<String?> _storeInner({
    required String id,
    required String quality,
    required bool pinned,
    required DownloadTask task,
    String? title,
    String? artist,
  }) async {
    // 本地 API 服务冷启动可能还没起来：最多等 4 秒，别把点播拖死。
    try {
      if (KugouApiServer.currentPort <= 0) {
        await KugouApiServer.start().timeout(const Duration(seconds: 4));
      }
    } catch (_) {}

    final KugouPlayUrl? play;
    try {
      play = await KugouApiClient().getSongUrlWithFallback(
        id,
        quality: quality,
      );
    } catch (_) {
      return _fail(
          '拿不到播放地址：可能没登录、该音质需要会员，或网络不通。', task);
    }
    // isTrial = 试听片段（如 30 秒），绝不能当完整歌曲存下来。
    if (play == null || play.url.isEmpty) {
      return _fail('服务端没给这一档的完整音频地址。', task);
    }
    if (play.isTrial) {
      return _fail('这一档只给了试听片段（约 30 秒），不缓存；换一档再试。', task);
    }

    // 服务端可能降级，实际档和请求档分别记。
    final actualQ = play.quality.isNotEmpty ? play.quality : quality;
    final dir = await _ensureDir(pinned);
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
        onReceiveProgress: (received, total) {
          if (total > 0) {
            task.progress = (received / total).clamp(0.0, 1.0);
            _notifyTasks();
          }
        },
        options: Options(
          headers: <String, String>{'User-Agent': 'MD3Music/1.0'},
          receiveTimeout: const Duration(minutes: 5),
        ),
      );
      if (!part.existsSync() || part.lengthSync() < _minBytes) {
        if (part.existsSync()) part.deleteSync();
        return _fail(
            '只下到半截（或试听片段），已丢弃，不完整的文件不会播。', task);
      }
      if (file.existsSync()) file.deleteSync();
      part.renameSync(file.path);
    } catch (_) {
      // CDN 地址过期 / 断网 / 被掐断 / 写不进手机
      if (part.existsSync()) part.deleteSync();
      return _fail('下载中断或写不进手机：可能断网、地址过期或存储不足。', task);
    }

    _index.removeWhere(
        (r) => r['id'] == id && r['requested'] == quality);
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
    _bump();
    return file.path;
  }

  /// 「已下载」页列表（按时间倒序）。pinned 由 UI 自己分两页。
  Future<List<Map<String, dynamic>>> rows() async {
    await _load();
    _index.removeWhere((r) => _pathOf(r) == null);
    return _index
        .map((r) => Map<String, dynamic>.from(r))
        .toList()
      ..sort((a, b) =>
          (b['time'] as int? ?? 0).compareTo(a['time'] as int? ?? 0));
  }

  Future<int> count() async => (await rows()).length;

  bool isDownloaded(String id) {
    for (final row in _index) {
      if (row['id'] == id && _pathOf(row) != null) return true;
    }
    return false;
  }

  /// 删掉某首（所有档位：同时删文件和纸条）。
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
    _bump();
  }

  /// 清「播放缓存」（自动存的），保留「已下载」。
  Future<int> clearAuto() => _clearWhere(pinned: false);

  /// 清「已下载」（手动下的），保留播放缓存。
  Future<int> clearPinned() => _clearWhere(pinned: true);

  Future<int> _clearWhere({required bool pinned}) async {
    await _load();
    var n = 0;
    for (final row in List<Map<String, dynamic>>.from(_index)) {
      // pinned=false 时只清自动缓存，pinned=true 时只清手动下载。
      if ((row['pinned'] == true) != pinned) continue;
      final p = _pathOf(row);
      if (p != null) {
        try {
          File(p).deleteSync();
        } catch (_) {}
      }
      _index.remove(row);
      n++;
    }
    await _save();
    _bump();
    return n;
  }

  /// 超 1GB 时按时间清最旧的**播放缓存**；「已下载」永不自动清。
  Future<void> _pruneIfNeeded() async {
    try {
      final dir = await _ensureDir(false);
      var total = 0;
      for (final f in dir.listSync(recursive: true).whereType<File>()) {
        if (f.path.endsWith('.part')) continue;
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
      _bump();
    } catch (_) {}
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
