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

  /// 自动缓存时歌名要等解析到元数据才能回填，所以可写。
  String title;
  String artist;
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
///
/// 命名：缓存与下载共用同一套 —— 「歌曲名 - 歌手[音质标记].扩展名」。
/// 标准档不标；320 → [HQ]、flac → [SQ]、high/Hi-Res → [HR]、
/// 蝰蛇母带 → [MASTER]，其余档位兜底成大写缩写。
/// 播放/打开弹窗前只扫 md3_cache + md3_downloads 两个目录，
/// 把纸条里没登记的裸文件按文件名认回来；同档两份优先播缓存那份。
/// 同目录撞名自动加 (2) 序号，绝不覆盖已有文件。
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

  /// 播放源开始时旁路记下的「id → 歌名/歌手」，自动缓存命名用。
  /// 只从已经在跑的播放链路里捡，不额外发请求、不顶掉宿主回调。
  final Map<String, Map<String, String>> _meta =
      <String, Map<String, String>>{};

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

    // 顺手记下正在播的那首歌的名字，自动缓存就能按「歌名 - 歌手」落盘。
    final prevSource = PlayerProvider.onPlaybackSourceStarted;
    PlayerProvider.onPlaybackSourceStarted = (Song song, String q, String url) {
      if (song.isOnline) {
        _meta[song.id] = <String, String>{
          't': song.title.trim().isEmpty ? song.id : song.title.trim(),
          'a': song.artist.trim(),
        };
      }
      if (prevSource != null) prevSource(song, q, url);
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
      // 按 pinned 把历史文件归到两个夹子，顺便统一改成新命名。
      await _relocateAll();
      await _save();
    } catch (_) {
      // 纸条坏了就当空表，不影响播放。
    }
    _loaded = true;
    _loadFuture = null;
    _bump();
  }

  /// 每条记录按 pinned 找到它「该在」的夹子，并按统一命名归位。
  /// 覆盖三种历史：内部文档目录、上一版全塞 md3_cache、以及手动/自动混放。
  Future<void> _relocateAll() async {
    final cacheDir = await _ensureDir(false);
    final dlDir = await _ensureDir(true);
    for (final row in _index) {
      final p = row['path'] as String?;
      if (p == null || !File(p).existsSync()) continue;
      final id = (row['id'] as String?) ?? '';
      var t = (row['title'] as String?)?.trim() ?? '';
      var a = (row['artist'] as String?)?.trim() ?? '';
      if (t.isEmpty || t == id) {
        final m = _meta[id];
        if (m != null) {
          t = m['t'] ?? t;
          a = m['a'] ?? a;
        }
      }
      if (t.isEmpty) t = id;
      final q = (row['requested'] as String?) ??
          (row['quality'] as String?) ??
          '';
      final dir = row['pinned'] == true ? dlDir : cacheDir;
      final name = _uniqueName(
        dir,
        _displayFileName(t, a, q, _extOfPath(p)),
        ownPath: p,
      );
      final dst = '${dir.path}${Platform.pathSeparator}$name';
      if (p == dst) continue;
      final f = File(p);
      try {
        try {
          f.renameSync(dst);
        } catch (_) {
          f.copySync(dst);
          f.deleteSync();
        }
        row['path'] = dst;
        row['title'] = t;
        row['artist'] = a;
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

  /// 按档位查本地：**只认同歌 + 同档**。
  /// 请求档优先 → 实际档（服务端降级时两者不同）。
  /// 同一档在缓存和下载各有一份时，**优先返回缓存目录那条**。
  Future<String?> _localFor(String id, String quality) async {
    await _load();
    String? first;
    for (final row in _index) {
      if (row['id'] != id || row['requested'] != quality) continue;
      final p = _pathOf(row);
      if (p == null) continue;
      if (_isCachePath(p)) return p;
      first ??= p;
    }
    if (first != null) return first;
    String? second;
    for (final row in _index) {
      if (row['id'] != id || row['quality'] != quality) continue;
      final p = _pathOf(row);
      if (p == null) continue;
      if (_isCachePath(p)) return p;
      second ??= p;
    }
    return second;
  }

  /// 播放钩子本体：先查纸条 → 再扫两个目录认领裸文件 → 都没有才自动缓存。
  Future<String?> ensureCached(String id, String quality) async {
    await _load();
    final hit = await _localFor(id, quality);
    if (hit != null) return hit;
    // 重启后 / 用管理器搬回来 / 纸条丢了，靠文件名把两个目录里的文件认回来。
    final meta = _metaFor(id);
    if (meta != null) {
      await _claimFiles(id: id, title: meta['t'] ?? '', artist: meta['a'] ?? '');
      final claimed = await _localFor(id, quality);
      if (claimed != null) return claimed;
    }
    return _downloadAndStore(id: id, quality: quality, pinned: false);
  }

  /// 弹窗用：只扫 md3_cache + md3_downloads，返回这首歌本地已有的档位。
  /// 顺手把裸文件绑到 song.id 认领进纸条，之后两页列表和播放钩子都能用。
  Future<Set<String>> localQualitiesFor(Song song) async {
    await _load();
    _meta[song.id] = <String, String>{
      't': song.title.trim().isEmpty ? song.id : song.title.trim(),
      'a': song.artist.trim(),
    };
    await _claimFiles(id: song.id, title: song.title, artist: song.artist);
    final out = <String>{};
    for (final row in _index) {
      if (row['id'] != song.id || _pathOf(row) == null) continue;
      final q = (row['requested'] as String?) ??
          (row['quality'] as String?) ??
          '';
      if (q.isNotEmpty) out.add(q);
    }
    return out;
  }

  /// 认领时认歌名用的线索：优先播放旁路，其次纸条里同 id 的记录。
  /// 不发网络请求，断网点歌也不会多等几秒。
  Map<String, String>? _metaFor(String id) {
    final m = _meta[id];
    if (m != null) return m;
    for (final row in _index) {
      if (row['id'] != id) continue;
      final t = (row['title'] as String?)?.trim() ?? '';
      if (t.isNotEmpty && t != id) {
        return <String, String>{
          't': t,
          'a': (row['artist'] as String?)?.trim() ?? '',
        };
      }
    }
    return null;
  }

  /// 是否落在播放缓存夹子里（同档两份时它优先）。
  bool _isCachePath(String p) => p.contains(
      '${Platform.pathSeparator}$cacheFolder${Platform.pathSeparator}');

  /// 只扫这两个目录的顶层，把文件名对得上的裸文件补进纸条。
  /// 不递归、不碰别处、不删任何文件；已在纸条里的跳过。
  Future<List<String>> _claimFiles({
    required String id,
    required String title,
    required String artist,
  }) async {
    await _load();
    // 写入时歌名/歌手为空会落成「未知歌曲 - 未知歌手」，两组都试着认。
    final t = _cleanName(title.isEmpty ? id : title);
    final a = _cleanName(artist);
    final t2 = _cleanName(title.isEmpty ? '未知歌曲' : title);
    final a2 = _cleanName(artist.isEmpty ? '未知歌手' : artist);
    final claimed = <String>[];
    for (final pinned in <bool>[false, true]) {
      final dir = await _ensureDir(pinned);
      if (!dir.existsSync()) continue;
      List<File> files;
      try {
        files = dir.listSync().whereType<File>().toList();
      } catch (_) {
        continue;
      }
      for (final f in files) {
        if (f.path.endsWith('.part')) continue;
        if (_index.any((r) => r['path'] == f.path)) continue;
        final name = f.path.split(Platform.pathSeparator).last;
        final parsed = _parseFileName(name);
        if (parsed == null) continue;
        // 超长歌名写入时被截断过，这里允许「文件名是原名前缀」也算同一首。
        final pt = parsed['t']!;
        final pa = parsed['a']!;
        bool match(String et, String ea) {
          final titleOk = pt == et || et.startsWith(pt);
          final artistOk = pa == ea || pa.isEmpty || ea.startsWith(pa);
          return titleOk && artistOk;
        }

        if (!match(t, a) && !match(t2, a2)) continue;
        final q = parsed['q']!;
        _index.add(<String, dynamic>{
          'id': id,
          'title': t,
          'artist': a,
          'requested': q,
          'quality': q,
          'path': f.path,
          'pinned': pinned,
          'size': _safeSize(f),
          'time': DateTime.now().millisecondsSinceEpoch,
        });
        claimed.add(f.path);
      }
    }
    if (claimed.isNotEmpty) {
      await _save();
      _bump();
    }
    return claimed;
  }

  static int _safeSize(File f) {
    try {
      return f.lengthSync();
    } catch (_) {
      return 0;
    }
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
          row['title'] = song.title.trim().isEmpty ? song.id : song.title.trim();
          row['artist'] = song.artist.trim();
          // 老纸条可能没记档位，补上，搬完重新查路径时才不会扑空。
          row['requested'] = quality;
          row['quality'] = (row['quality'] as String?) ?? quality;
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

    // 服务端可能降级，实际档和请求档分别记；文件名按「用户点的那档」标。
    final actualQ = play.quality.isNotEmpty ? play.quality : quality;
    final dir = await _ensureDir(pinned);
    final ext = _extFrom(play.url);

    // 手动下载自带 Song；自动缓存只有 id，先从播放旁路捡，再查详情兜底。
    var metaTitle = (title ?? '').trim();
    var metaArtist = (artist ?? '').trim();
    if (metaTitle.isEmpty) {
      final m = await _resolveMeta(id);
      if (m != null) {
        metaTitle = m['t'] ?? '';
        metaArtist = m['a'] ?? '';
      }
    }
    if (metaTitle.isEmpty) metaTitle = id;
    task.title = metaTitle;
    task.artist = metaArtist;
    _notifyTasks();

    final file = File(_allocatePath(dir, metaTitle, metaArtist, quality, ext));
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

    // 只清「同 id + 同档 + 同一夹子」的旧记录：
    // 缓存 320 和下载 320 要能同时留在纸条里，互不覆盖。
    _index.removeWhere((r) =>
        r['id'] == id &&
        r['requested'] == quality &&
        ((r['pinned'] == true) == pinned));
    _index.add(<String, dynamic>{
      'id': id,
      'title': metaTitle,
      'artist': metaArtist,
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

  /// 自动缓存拿歌名：先捡播放旁路记下的，再向本地 API 查详情兜底。
  /// 查不到就退回用 id，绝不因为缺元数据把下载卡住。
  Future<Map<String, String>?> _resolveMeta(String id) async {
    final cached = _meta[id];
    if (cached != null) return cached;
    try {
      final detail = await KugouApiClient()
          .getSongDetail(id)
          .timeout(const Duration(seconds: 4));
      if (detail != null && detail.songName.trim().isNotEmpty) {
        final m = <String, String>{
          't': detail.songName.trim(),
          'a': (detail.artistName ?? '').trim(),
        };
        _meta[id] = m;
        return m;
      }
    } catch (_) {}
    return null;
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

  // ---------------------------------------------------------------------------
  // 命名工具：缓存与手动下载共用，标准档不标，其余档位加方括号缩写。
  // ---------------------------------------------------------------------------

  /// 只改两档标签：高品质 → [HQ]、无损 → [SQ]，方括号保留。
  /// 标准档不标；Hi-Res / 母带 / 旧 [320K] 写法都照旧。
  static String _qualityTag(String q) {
    final v = q.trim().toLowerCase();
    if (v.isEmpty) return '';
    if (v == '128' || v == 'standard' || v == '标准' || v == 'normal') {
      return '';
    }
    if (v == '320' || v == 'hq' || v == '高品质') return '[HQ]';
    if (v == 'flac' || v == 'sq' || v == 'lossless' || v == '无损') {
      return '[SQ]';
    }
    // 其它纯数字档位（192 / 999 等）仍写成 [xxxK]，兼容旧文件。
    if (RegExp(r'^\d+$').hasMatch(v)) return '[${v}K]';
    switch (v) {
      case 'high': // AudioQuality.hires 的 value
      case 'hires':
      case 'hi-res':
      case 'hr':
        return '[HR]';
      case 'viper':
      case 'viper_tape':
      case 'master':
        return '[MASTER]';
      default:
        return '[${v.toUpperCase()}]';
    }
  }

  /// 文件名末尾的 [XXX] 反推档位 value；没有标记 = 标准档。
  /// 旧写法 [320K] / [FLAC] 也认，方便扫到上一版留下的文件。
  static String _qualityFromTag(String tag) {
    final v = tag.trim().toUpperCase();
    switch (v) {
      case '':
        return '128';
      case 'HQ':
        return '320';
      case 'SQ':
      case 'FLAC':
        return 'flac';
      case 'HR':
        return 'high';
      case 'MASTER':
        return 'viper_tape';
      default:
        final m = RegExp(r'^(\d+)K$').firstMatch(v);
        if (m != null) return m.group(1)!;
        return tag.trim().toLowerCase();
    }
  }

  /// 文件名非法字符处理，写入和比对共用一套，避免中英文/符号对不上。
  static String _cleanName(String s) => s
      .replaceAll(RegExp(r'[\\/:*?"<>|\r\n\t]'), '_')
      .trim()
      .replaceAll(RegExp(r'\.+$'), '');

  /// 拆「歌曲名 - 歌手 [标记].扩展名」→ 标题 / 歌手 / 档位 value。
  /// 歌名里也可能带 " - "，所以从右边切一次；撞名后缀 (2) 忽略。
  static Map<String, String>? _parseFileName(String name) {
    final dot = name.lastIndexOf('.');
    final stem = dot > 0 ? name.substring(0, dot) : name;
    var base = stem.replaceAll(RegExp(r' \(\d+\)$'), '');
    var tag = '';
    final m = RegExp(r' \[([^\]]+)\]$').firstMatch(base);
    if (m != null) {
      tag = m.group(1)!;
      base = base.substring(0, m.start);
    }
    final i = base.lastIndexOf(' - ');
    if (i <= 0) return null;
    final t = base.substring(0, i).trim();
    final a = base.substring(i + 3).trim();
    if (t.isEmpty) return null;
    return <String, String>{'t': t, 'a': a, 'q': _qualityFromTag(tag)};
  }

  static String _displayFileName(
    String title,
    String artist,
    String quality,
    String ext,
  ) {
    final t = _cleanName(title.isEmpty ? '未知歌曲' : title);
    final a = _cleanName(artist.isEmpty ? '未知歌手' : artist);
    var base = '$t - $a';
    // 按 Unicode 码点截断，避免把 emoji 切成半个代理对；中文件名也留足余量。
    if (base.runes.length > 70) {
      base = String.fromCharCodes(base.runes.take(70)).trim();
    }
    final safeExt = ext.startsWith('.') ? ext : '.$ext';
    final tag = _qualityTag(quality);
    return tag.isEmpty ? '$base$safeExt' : '$base $tag$safeExt';
  }

  static String _extOfPath(String p) {
    final n = p.split(Platform.pathSeparator).last;
    final d = n.lastIndexOf('.');
    if (d > 0 && n.length - d <= 6) return n.substring(d).toLowerCase();
    return '.mp3';
  }

  /// 同目录里不覆盖：被占了就加 (2)、(3)……；ownPath 是自己的旧路径时不算占用。
  String _uniqueName(Directory dir, String name, {String? ownPath}) {
    String candidate(String n) =>
        '${dir.path}${Platform.pathSeparator}$n';
    if (!File(candidate(name)).existsSync() || candidate(name) == ownPath) {
      return name;
    }
    final dot = name.lastIndexOf('.');
    final stem = dot > 0 ? name.substring(0, dot) : name;
    final ext = dot > 0 ? name.substring(dot) : '';
    var i = 2;
    while (true) {
      final alt = '$stem ($i)$ext';
      if (!File(candidate(alt)).existsSync() || candidate(alt) == ownPath) {
        return alt;
      }
      i++;
    }
  }

  String _allocatePath(
    Directory dir,
    String title,
    String artist,
    String quality,
    String ext, {
    String? ownPath,
  }) {
    final name = _uniqueName(
      dir,
      _displayFileName(title, artist, quality, ext),
      ownPath: ownPath,
    );
    return '${dir.path}${Platform.pathSeparator}$name';
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
