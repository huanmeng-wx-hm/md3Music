import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:flutter/foundation.dart' show compute;

/// 本地歌词加载器：内嵌歌词优先，其次读取同目录同名歌词文件。
///
/// 本地音乐歌词来源（参考 Lyrico 歌词文件约定）：
/// 1. 音频内嵌歌词（ID3 USLT / SYLT、Vorbis LYRICS、MP4 ©lyr）—— 最高优先；
/// 2. 音频同目录同名歌词文件（.lrc / .ttml / .txt，按此顺序查找）。
class LocalLyricLoader {
  LocalLyricLoader._();

  /// 支持的本地歌词文件扩展名（按优先级排列）。
  static const List<String> lyricExtensions = ['.lrc', '.ttml', '.txt'];

  /// compute 超时不会取消后台 isolate；限制同时解析的本地音乐歌词任务，
  /// 防止快速切歌时多个大 ID3/FLAC 标签解析任务堆积。
  static String? _activeAsyncReadKey;
  static Future<String?>? _activeAsyncRead;

  /// 仅从音频头部读取元数据的最大字节数。
  ///
  /// FLAC 的 VORBIS_COMMENT、MP3 的 ID3v2、MP4 的 ©lyr 均位于文件起始区域，
  /// 逐块随机读取即可拿到内嵌 LRC。限制头部读取量可避免把整首高码率大文件
  /// 一次性读入内存（播放大体积内嵌歌词歌曲时可能被系统判定 OOM/无响应而崩溃）。
  /// 若头部区域内未发现歌词标签，则按"无内嵌歌词"处理，回退到同名歌词文件。
  static const int _maxEmbeddedReadBytes = 16 * 1024 * 1024;

  /// 优先使用扫描阶段缓存的歌词（如 SAF `content://`），再按普通本地路径读取。
  static Future<String?> loadForSongAsync({
    required String? localPath,
    String? cachedLyrics,
  }) async {
    if (cachedLyrics != null && cachedLyrics.isNotEmpty) return cachedLyrics;
    if (localPath == null || localPath.isEmpty) return null;
    return loadForAudioAsync(localPath);
  }

  /// 从 Song 里挑出「这次播放真正能读到的本地音频路径」。
  ///
  /// 本地歌看 [localPath]；在线歌命中缓存后 [url] 会变成 `file:///...`，
  /// 也据此放行。云盘歌无本地文件，一律返回 null。
  /// `content://` 不认（那份由扫描阶段缓存的 localLyrics 处理）。
  static String? audioPathFor({
    String? localPath,
    String? url,
    bool isCloud = false,
  }) {
    if (isCloud) return null;
    for (final candidate in <String?>[localPath, url]) {
      if (candidate == null || candidate.isEmpty) continue;
      if (candidate.startsWith('content://')) continue;
      final path = _normalizePath(candidate);
      if (path.isEmpty) continue;
      return path;
    }
    return null;
  }

  /// 只取内嵌歌词文本，不读同目录同名外挂。
  static String? readEmbeddedOnly(String filePath) {
    final path = _normalizePath(filePath);
    if (path.isEmpty) return null;
    return _readEmbeddedLyrics(path);
  }

  /// 只取同目录同名外挂（.lrc / .ttml / .txt），不读内嵌。
  static String? readSidecarOnly(String filePath) {
    final path = _normalizePath(filePath);
    if (path.isEmpty) return null;
    return _findSidecarLyric(path);
  }

  /// 播放时「临时抠出内嵌歌词」：后台 isolate + 5s 超时，不落盘。
  static Future<String?> readEmbeddedOnlyAsync(String filePath) =>
      _runRead(filePath, 'embedded', _embeddedOnlyInIsolate);

  /// 外挂兜底同样走 isolate，避免大目录遍历压住 UI。
  static Future<String?> readSidecarOnlyAsync(String filePath) =>
      _runRead(filePath, 'sidecar', _sidecarOnlyInIsolate);

  /// `file://` → 真实路径；`content://` 与空串统一返回空。
  static String _normalizePath(String raw) {
    if (raw.isEmpty) return '';
    if (raw.startsWith('file://')) {
      try {
        return Uri.parse(raw).toFilePath();
      } catch (_) {
        return '';
      }
    }
    return raw;
  }

  /// 加载本地歌曲歌词：先内嵌，无内嵌时查找同目录同名歌词文件。
  ///
  /// 兼容 file:// URI 与裸绝对路径。返回歌词文本，无则 null。
  static String? loadForAudio(String filePath) {
    final path = filePath.startsWith('file://')
        ? Uri.parse(filePath).toFilePath()
        : filePath;
    if (path.isEmpty) return null;

    final embedded = _readEmbeddedLyrics(path);
    if (embedded != null && embedded.isNotEmpty) return embedded;

    return _findSidecarLyric(path);
  }

  /// 异步版本：把内嵌歌词的元数据读取与侧车歌词文件读取整体移入后台 isolate
  /// 执行，并带超时兜底。任何耗时/异常/超时都不会阻塞主隔离区（避免在切歌/播放
  /// 瞬间拖垮 UI 甚至被判定为无响应而崩溃）；返回 null 时由调用方回退到酷狗接口。
  /// 异步版本：后台 isolate 执行，带 5s 超时与串行闸门。
  /// 返回 null 时由调用方回退到下一级歌词来源。
  static Future<String?> loadForAudioAsync(String filePath) =>
      _runRead(filePath, 'all', _loadForAudioInIsolate);

  /// 统一的 isolate 读取闸门：同一 key 复用在途任务，不同 key 串行排队。
  /// compute 超时不会取消后台 isolate，所以完成前不释放闸门。
  static Future<String?> _runRead(
    String filePath,
    String label,
    String? Function(String) work,
  ) async {
    final path = _normalizePath(filePath);
    if (path.isEmpty) return null;
    final key = '$path|$label';

    final active = _activeAsyncRead;
    if (active != null) {
      if (_activeAsyncReadKey != key) {
        try {
          await active.timeout(const Duration(seconds: 5));
        } catch (_) {
          return null;
        }
        return _runRead(path, label, work);
      }
      try {
        return await active.timeout(const Duration(seconds: 5));
      } catch (_) {
        return null;
      }
    }

    final read = Future<String?>.sync(() => compute(work, path));
    _activeAsyncReadKey = key;
    _activeAsyncRead = read;
    void clearRead() {
      if (identical(_activeAsyncRead, read)) {
        _activeAsyncReadKey = null;
        _activeAsyncRead = null;
      }
    }
    read.then<void>((_) => clearRead(), onError: (_, _) => clearRead());
    try {
      return await read.timeout(const Duration(seconds: 5));
    } catch (_) {
      return null;
    }
  }

  /// 读取音频内嵌歌词（ID3 USLT / SYLT / Vorbis LYRICS / MP4 ©lyr）。
  ///
  /// FLAC 特殊处理：audio_metadata_reader 1.4.1 的 FlacParser 用
  /// `comment.split("=")[1]` 解析 Vorbis comment，含 `=` 的歌词值
  /// （如 TTML XML 声明的 `version="1.0"`）会被截断到第一个 `=`，
  /// 因此 FLAC 内嵌歌词改为手动解析 LYRICS 标签（取第一个 `=` 后完整值）。
  static String? _readEmbeddedLyrics(String filePath) {
    final lower = filePath.toLowerCase();

    // M4A / MP4 / AAC：只走 moov→udta→meta→ilst→©lyr→data 的 atom 树，
    // 每次只读命中的那一小段，不受 _maxEmbeddedReadBytes 整文件大小限制。
    if (lower.endsWith('.m4a') || lower.endsWith('.mp4') ||
        lower.endsWith('.aac') || lower.endsWith('.m4b')) {
      final mp4 = _readMp4Lyrics(filePath);
      if (mp4 != null && mp4.isNotEmpty) return mp4;
    }

    // OGG / OGA / OPUS：逐页拼 Vorbis Comment / OpusTags packet，
    // 只扫文件头部若干 page，音频帧一字节不进内存。
    if (lower.endsWith('.ogg') || lower.endsWith('.oga') ||
        lower.endsWith('.opus')) {
      final ogg = _readOggLyrics(filePath);
      if (ogg != null && ogg.isNotEmpty) return ogg;
    }

    final isMp3 = lower.endsWith('.mp3');
    if (lower.endsWith('.flac')) {
      final flacLyrics = _readFlacLyrics(filePath);
      if (flacLyrics != null && flacLyrics.isNotEmpty) return flacLyrics;
    }
    // MP3 的 USLT 自行解析：audio_metadata_reader 1.8.1 取正文时用
    // `rest.sublist(1, ...)`，会把 LRC 首行的 `[` 一并吞掉，首行变成
    // `00:26.400]...`，被 LyricParserChain 误判为静态歌词并原样显示时间戳。
    if (isMp3) {
      final usltLyrics = _readMp3UsltLyrics(filePath);
      if (usltLyrics != null && usltLyrics.isNotEmpty) return usltLyrics;
    }
    String? metadataLyrics;
    try {
      final file = File(filePath);
      if (!file.existsSync()) return null;
      // 超大文件不做整读（避免主隔离区一次性读入大文件导致 OOM/ANR），
      // 直接视为无内嵌歌词，回退到同目录同名歌词文件。
      if (file.lengthSync() > _maxEmbeddedReadBytes) return null;
      final metadata = readMetadata(file, getImage: false);
      metadataLyrics = metadata.lyrics;
    } catch (_) {}

    // 保持现有 USLT / Vorbis / MP4 读取优先级；只有通用元数据读取不到歌词时，
    // 才补读 MP3 ID3v2 的 SYLT（同步歌词）帧。这样不会改变 AM 现有歌词路径，
    // 只会让此前读不到的本地内嵌同步歌词多一个普通时间轴文本的兜底来源。
    final existingLyrics = metadataLyrics;
    if (existingLyrics != null && existingLyrics.isNotEmpty) {
      return existingLyrics;
    }
    if (isMp3) {
      return _readMp3SyncedLyrics(filePath);
    }
    return null;
  }

  /// 读取 MP3 ID3v2 USLT（Unsychronised lyric/text）帧的完整歌词正文。
  ///
  /// 格式：编码(1) + 语言(3) + 内容描述符 + 终止符 + 歌词正文。
  /// 第三方库在该帧上会吞掉正文首字符，所以这里按规范自行截取。
  static String? _readMp3UsltLyrics(String filePath) =>
      _readMp3TagFrame(filePath, 'USLT', _parseUsltPayload);

  /// 解析 USLT 帧载荷，返回完整歌词正文（不做任何截断）。
  static String? _parseUsltPayload(List<int> payload) {
    if (payload.length < 5) return null;
    final encoding = payload[0];
    if (encoding > 3) return null;
    // 跳过编码字节与 3 字节语言码后，先读到内容描述符的终止符。
    final descriptionEnd = _findId3Terminator(payload, 4, encoding);
    if (descriptionEnd < 0) return null;
    final textStart = descriptionEnd + _id3TerminatorLength(encoding);
    if (textStart >= payload.length) return null;
    final text = _decodeId3Text(payload, textStart, payload.length, encoding)
        .trim();
    return text.isEmpty ? null : text;
  }

  /// 读取 MP3 ID3v2 SYLT（Synchronized lyric/text）帧。
  ///
  /// SYLT 的每条文本都带一个毫秒时间戳，但不同写入器可能按整行或按词写入。
  /// 这里把每条记录转换成普通 LRC 行，目标是保证 MD3/AM 至少能正常显示歌词文本；
  /// 不在本地读取层改变现有 AppleLyricsView 的逐字渲染逻辑。
  static String? _readMp3SyncedLyrics(String filePath) =>
      _readMp3TagFrame(filePath, 'SYLT', _parseSyltPayload);

  static String? _parseSyltPayload(List<int> payload) {
    final entries = _parseSylt(payload);
    final lyrics = _formatSyltAsLrc(entries);
    return lyrics != null && lyrics.isNotEmpty ? lyrics : null;
  }

  /// 在 ID3v2 标签中查找 [frameId] 帧，命中后交给 [parse] 解析载荷。
  ///
  /// 返回首个非空的解析结果；无匹配帧或解析失败返回 null。
  static String? _readMp3TagFrame(
    String filePath,
    String frameId,
    String? Function(List<int> payload) parse,
  ) {
    RandomAccessFile? rf;
    try {
      final file = File(filePath);
      if (!file.existsSync()) return null;
      rf = file.openSync();
      final fileLength = rf.lengthSync();
      if (fileLength < 10) return null;

      final header = rf.readSync(10);
      if (header.length < 10 ||
          header[0] != 0x49 ||
          header[1] != 0x44 ||
          header[2] != 0x33) {
        return null;
      }

      final version = header[3];
      if (version != 3 && version != 4) return null;
      final tagSize = _readSynchsafeInt(header, 6);
      if (tagSize <= 0 || tagSize > _maxEmbeddedReadBytes) return null;

      final available = fileLength - 10;
      final readLength = tagSize < available ? tagSize : available;
      if (readLength <= 0) return null;
      final List<int> tagBytes = rf.readSync(readLength);
      var tag = tagBytes;

      // ID3 unsynchronisation is applied to the tag payload, so remove it before
      // reading frame sizes and frame contents.
      if ((header[5] & 0x80) != 0) {
        tag = _removeId3Unsynchronization(tag);
      }

      var offset = 0;
      if ((header[5] & 0x40) != 0) {
        final skipped = _skipId3ExtendedHeader(tag, version);
        if (skipped < 0 || skipped > tag.length) return null;
        offset = skipped;
      }

      while (offset + 10 <= tag.length) {
        final currentId = String.fromCharCodes(tag.sublist(offset, offset + 4));
        if (currentId.codeUnits.every((c) => c == 0)) break;

        final frameSize = version == 4
            ? _readSynchsafeInt(tag, offset + 4)
            : _readUint32Be(tag, offset + 4);
        final frameStart = offset + 10;
        final frameEnd = frameStart + frameSize;
        if (frameSize <= 0 || frameEnd > tag.length) break;

        if (currentId == frameId) {
          final value = parse(tag.sublist(frameStart, frameEnd));
          if (value != null && value.isNotEmpty) return value;
        }
        offset = frameEnd;
      }
    } catch (_) {
      return null;
    } finally {
      rf?.closeSync();
    }
    return null;
  }

  static int _readSynchsafeInt(List<int> bytes, int offset) {
    if (offset < 0 || offset + 4 > bytes.length) return 0;
    return ((bytes[offset] & 0x7F) << 21) |
        ((bytes[offset + 1] & 0x7F) << 14) |
        ((bytes[offset + 2] & 0x7F) << 7) |
        (bytes[offset + 3] & 0x7F);
  }

  static int _readUint32Be(List<int> bytes, int offset) {
    if (offset < 0 || offset + 4 > bytes.length) return 0;
    return (bytes[offset] << 24) |
        (bytes[offset + 1] << 16) |
        (bytes[offset + 2] << 8) |
        bytes[offset + 3];
  }

  static int _skipId3ExtendedHeader(List<int> bytes, int version) {
    if (bytes.length < 4) return -1;
    final size = version == 4
        ? _readSynchsafeInt(bytes, 0)
        : _readUint32Be(bytes, 0);
    final total = version == 3 ? size + 4 : size;
    return total > 0 && total <= bytes.length ? total : -1;
  }

  static List<int> _removeId3Unsynchronization(List<int> bytes) {
    final result = <int>[];
    for (var i = 0; i < bytes.length; i++) {
      result.add(bytes[i]);
      if (bytes[i] == 0xFF && i + 1 < bytes.length && bytes[i + 1] == 0x00) {
        i++;
      }
    }
    return result;
  }

  static List<_SyltEntry> _parseSylt(List<int> payload) {
    if (payload.length < 7) return const [];
    final encoding = payload[0];
    if (encoding > 3) return const [];
    // SYLT timestamp format 2 is milliseconds. MPEG-frame timestamps cannot be
    // converted without the audio stream's frame rate, so leave them untouched.
    if (payload[4] != 2) return const [];

    var offset = 1 + 3 + 1 + 1;
    final descriptionEnd = _findId3Terminator(payload, offset, encoding);
    if (descriptionEnd < 0) return const [];
    offset = descriptionEnd + _id3TerminatorLength(encoding);

    final entries = <_SyltEntry>[];
    while (offset < payload.length) {
      final textEnd = _findId3Terminator(payload, offset, encoding);
      if (textEnd < 0 ||
          textEnd + _id3TerminatorLength(encoding) + 4 > payload.length) {
        break;
      }
      final text = _decodeId3Text(payload, offset, textEnd, encoding).trim();
      offset = textEnd + _id3TerminatorLength(encoding);
      final timestamp = _readUint32Be(payload, offset);
      offset += 4;
      if (text.isNotEmpty) entries.add(_SyltEntry(text, timestamp));
    }
    return entries;
  }

  static int _id3TerminatorLength(int encoding) =>
      encoding == 1 || encoding == 2 ? 2 : 1;

  static int _findId3Terminator(List<int> bytes, int start, int encoding) {
    final length = _id3TerminatorLength(encoding);
    if (length == 1) {
      for (var i = start; i < bytes.length; i++) {
        if (bytes[i] == 0) return i;
      }
      return -1;
    }
    for (var i = start; i + 1 < bytes.length; i += 2) {
      if (bytes[i] == 0 && bytes[i + 1] == 0) return i;
    }
    return -1;
  }

  static String _decodeId3Text(
    List<int> bytes,
    int start,
    int end,
    int encoding,
  ) {
    final value = bytes.sublist(start, end);
    switch (encoding) {
      case 0:
        return latin1.decode(value);
      case 3:
        return utf8.decode(value, allowMalformed: true);
      case 1:
      case 2:
        return _decodeUtf16(value, littleEndian: encoding == 1);
      default:
        return '';
    }
  }

  static String _decodeUtf16(List<int> bytes, {required bool littleEndian}) {
    var start = 0;
    var little = littleEndian;
    if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
      little = true;
      start = 2;
    } else if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
      little = false;
      start = 2;
    }
    final codeUnits = <int>[];
    for (var i = start; i + 1 < bytes.length; i += 2) {
      codeUnits.add(
        little
            ? bytes[i] | (bytes[i + 1] << 8)
            : (bytes[i] << 8) | bytes[i + 1],
      );
    }
    return String.fromCharCodes(codeUnits);
  }

  static String? _formatSyltAsLrc(List<_SyltEntry> entries) {
    if (entries.isEmpty) return null;
    entries.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    final buffer = StringBuffer();
    for (final entry in entries) {
      final minutes = entry.timestamp ~/ 60000;
      final seconds = (entry.timestamp % 60000) ~/ 1000;
      final milliseconds = entry.timestamp % 1000;
      final text = entry.text.replaceAll(RegExp(r'\r?\n'), ' ').trim();
      if (text.isEmpty) continue;
      buffer
        ..write('[')
        ..write(minutes.toString().padLeft(2, '0'))
        ..write(':')
        ..write(seconds.toString().padLeft(2, '0'))
        ..write('.')
        ..write(milliseconds.toString().padLeft(3, '0'))
        ..write(']')
        ..writeln(text);
    }
    final result = buffer.toString().trimRight();
    return result.isEmpty ? null : result;
  }

  /// 手动解析 FLAC 的 Vorbis comment，读取 LYRICS 标签完整值。
  ///
  /// FLAC metadata block：1 字节头（last 标志 + block type）+ 3 字节大端长度；
  /// block type 4 = VORBIS_COMMENT，内部为小端长度 + UTF-8 字符串的序列。
  static String? _readFlacLyrics(String filePath) {
    RandomAccessFile? rf;
    try {
      final file = File(filePath);
      if (!file.existsSync()) return null;
      // 只读起始 metadata 区域，避免一次性读入整首大文件（FLAC metadata block
      // 总在音频帧之前），播放大体积内嵌歌词歌曲时不会触发 OOM/ANR。
      rf = file.openSync();
      final fileLen = rf.lengthSync();
      final bytes = rf.readSync(
        fileLen > _maxEmbeddedReadBytes ? _maxEmbeddedReadBytes : fileLen,
      );
      final data = ByteData.sublistView(bytes);
      if (bytes.length < 4 ||
          String.fromCharCodes(bytes.sublist(0, 4)) != 'fLaC') {
        return null;
      }

      var offset = 4;
      while (offset + 4 <= bytes.length) {
        final header = data.getUint8(offset);
        final isLast = (header & 0x80) != 0;
        final type = header & 0x7F;
        final blockLen = (data.getUint8(offset + 1) << 16) |
            (data.getUint8(offset + 2) << 8) |
            data.getUint8(offset + 3);
        offset += 4;

        if (type == 4) {
          // VORBIS_COMMENT：vendor length + vendor + comment count + comments
          if (offset + 4 > bytes.length) return null;
          final vendorLen = data.getUint32(offset, Endian.little);
          var p = offset + 4 + vendorLen;
          if (p + 4 > bytes.length) return null;
          final count = data.getUint32(p, Endian.little);
          p += 4;
          for (var i = 0; i < count; i++) {
            if (p + 4 > bytes.length) return null;
            final clen = data.getUint32(p, Endian.little);
            p += 4;
            if (p + clen > bytes.length) return null;
            final comment = utf8.decode(bytes.sublist(p, p + clen));
            p += clen;
            // 取第一个 `=` 之后的所有内容作为值（与 OGG 解析器一致）
            final eq = comment.indexOf('=');
            if (eq > 0 && comment.substring(0, eq).toUpperCase() == 'LYRICS') {
              return comment.substring(eq + 1);
            }
          }
          return null;
        }

        offset += blockLen;
        if (isLast) break;
      }
    } catch (_) {}
    finally {
      rf?.closeSync();
    }
    return null;
  }

  /// 查找音频同目录下的同名歌词文件（.lrc / .ttml / .txt 优先级）。
  static String? _findSidecarLyric(String audioPath) {
    try {
      final audio = File(audioPath);
      if (!audio.existsSync()) return null;
      final dir = audio.parent;
      final baseName = audioPath.split(Platform.pathSeparator).last;
      final dot = baseName.lastIndexOf('.');
      final stem = dot > 0 ? baseName.substring(0, dot) : baseName;

      for (final ext in lyricExtensions) {
        final candidate =
            File('${dir.path}${Platform.pathSeparator}$stem$ext');
        if (candidate.existsSync()) {
          return candidate.readAsStringSync();
        }
      }
    } catch (_) {}
    return null;
  }

  // ===== M4A / MP4 ©lyr：按 atom 树随机读取，不整读文件 =====

  /// 在 [start, end) 的 MP4 atom 列表里找 [type]（4 字节），
  /// 返回 (内容起, 内容止)；已跳过 atom 自身 8/16 字节头。
  static (int, int)? _findAtom(
    RandomAccessFile rf,
    int start,
    int end,
    List<int> type,
  ) {
    var pos = start;
    var guard = 0;
    while (pos + 8 <= end && guard < 4096) {
      guard++;
      rf.setPositionSync(pos);
      final header = rf.readSync(8);
      if (header.length < 8) return null;
      var size = _mp4Be32(header, 0);
      var headerSize = 8;
      if (size == 1) {
        final ext = rf.readSync(8);
        if (ext.length < 8) return null;
        size = (_mp4Be32(ext, 0) << 32) | _mp4Be32(ext, 4);
        headerSize = 16;
      } else if (size == 0) {
        size = end - pos;
      }
      if (size < headerSize || pos + size > end) return null;
      if (header[4] == type[0] &&
          header[5] == type[1] &&
          header[6] == type[2] &&
          header[7] == type[3]) {
        return (pos + headerSize, pos + size);
      }
      pos += size;
    }
    return null;
  }

  static int _mp4Be32(List<int> b, int o) =>
      (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];

  static int _mp4Le32(List<int> b, int o) =>
      b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);

  static List<int> _atom(String s) => s.codeUnits;

  /// 读取 MP4 内嵌歌词（©lyr）。moov 常被工具挪到文件尾，
  /// 这里按 atom 头逐层跳转，不把整首音频读进内存。
  static String? _readMp4Lyrics(String filePath) {
    RandomAccessFile? rf;
    try {
      final file = File(filePath);
      if (!file.existsSync()) return null;
      rf = file.openSync();
      final fileLen = rf.lengthSync();

      final moov = _findAtom(rf, 0, fileLen, _atom('moov'));
      if (moov == null) return null;
      final udta = _findAtom(rf, moov.$1, moov.$2, _atom('udta'));
      if (udta == null) return null;
      final meta = _findAtom(rf, udta.$1, udta.$2, _atom('meta'));
      if (meta == null) return null;
      // meta 内容开头 4 字节是 version/flags，子 atom 从 +4 起。
      final ilst = _findAtom(rf, meta.$1 + 4, meta.$2, _atom('ilst'));
      if (ilst == null) return null;
      // ©lyr 的 atom 类型是 Latin-1 的 0xA9 + "lyr"。
      final lyr = _findAtom(
        rf,
        ilst.$1,
        ilst.$2,
        <int>[0xA9, 0x6C, 0x79, 0x72],
      );
      if (lyr == null) return null;
      final data = _findAtom(rf, lyr.$1, lyr.$2, _atom('data'));
      if (data == null) return null;

      final len = data.$2 - data.$1;
      if (len < 8 || len > 8 * 1024 * 1024) return null;
      rf.setPositionSync(data.$1);
      final bytes = rf.readSync(len);

      // data 内容：version/flags(4) + type indicator(4) + [locale(4)] + 文本
      var offset = 4;
      for (var i = 0; i < 2 && offset + 4 <= bytes.length; i++) {
        final word = _mp4Be32(bytes, offset);
        if (word == 0 || word == 1) {
          offset += 4;
        } else {
          break;
        }
      }
      if (offset >= bytes.length) return null;
      final text =
          utf8.decode(bytes.sublist(offset), allowMalformed: true).trim();
      return text.isEmpty ? null : text;
    } catch (_) {
      return null;
    } finally {
      rf?.closeSync();
    }
  }

  // ===== OGG / OGA / OPUS：拼 Vorbis Comment / OpusTags packet =====

  /// 只扫文件头部若干 Ogg page，按 lacing table 拼出完整 packet，
  /// 命中 LYRICS= 立刻返回。
  static String? _readOggLyrics(String filePath) {
    RandomAccessFile? rf;
    try {
      final file = File(filePath);
      if (!file.existsSync()) return null;
      rf = file.openSync();
      final fileLen = rf.lengthSync();
      final maxScan =
          fileLen < 4 * 1024 * 1024 ? fileLen : 4 * 1024 * 1024;

      var pos = 0;
      var pages = 0;
      final pending = <int>[];
      while (pos + 27 <= maxScan && pages < 1024) {
        rf.setPositionSync(pos);
        final header = rf.readSync(27);
        if (header.length < 27 ||
            String.fromCharCodes(header.sublist(0, 4)) != 'OggS') {
          break;
        }
        final segCount = header[26];
        if (pos + 27 + segCount > maxScan) break;
        final table = rf.readSync(segCount);
        var payloadLen = 0;
        for (final s in table) {
          payloadLen += s;
        }
        if (pos + 27 + segCount + payloadLen > maxScan) break;
        final payload =
            payloadLen > 0 ? rf.readSync(payloadLen) : <int>[];

        var p = 0;
        for (final s in table) {
          if (s > 0) {
            final stop = p + s;
            if (stop > payload.length) break;
            pending.addAll(payload.sublist(p, stop));
            p = stop;
          }
          if (s < 255) {
            final lyrics = _parseCommentPacket(pending);
            if (lyrics != null) return lyrics;
            pending.clear();
          }
        }
        pos += 27 + segCount + payloadLen;
        pages++;
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      rf?.closeSync();
    }
  }

  /// Vorbis comment header（\x03vorbis）与 OpusTags 共用
  /// vendor + comment count + [len][KEY=value] 结构。
  static String? _parseCommentPacket(List<int> packet) {
    if (packet.length < 8) return null;
    final isVorbis = packet[0] == 0x03 &&
        String.fromCharCodes(packet.sublist(1, 7)) == 'vorbis';
    final isOpus =
        String.fromCharCodes(packet.sublist(0, 8)) == 'OpusTags';
    if (!isVorbis && !isOpus) return null;

    var off = isVorbis ? 7 : 8;
    if (off + 4 > packet.length) return null;
    final vendorLen = _mp4Le32(packet, off);
    off += 4;
    if (vendorLen < 0 || off + vendorLen + 4 > packet.length) return null;
    off += vendorLen;
    final count = _mp4Le32(packet, off);
    off += 4;
    if (count < 0 || count > 4096) return null;

    for (var i = 0; i < count; i++) {
      if (off + 4 > packet.length) return null;
      final len = _mp4Le32(packet, off);
      off += 4;
      if (len < 0 || off + len > packet.length) return null;
      final comment =
          utf8.decode(packet.sublist(off, off + len), allowMalformed: true);
      off += len;
      final eq = comment.indexOf('=');
      if (eq > 0 && comment.substring(0, eq).toUpperCase() == 'LYRICS') {
        final value = comment.substring(eq + 1);
        return value.isEmpty ? null : value;
      }
    }
    return null;
  }
}

/// compute isolate 的工作函数：在后台 isolate 中同步执行完整歌词加载。
String? _loadForAudioInIsolate(String path) => LocalLyricLoader.loadForAudio(path);

String? _embeddedOnlyInIsolate(String path) =>
    LocalLyricLoader.readEmbeddedOnly(path);

String? _sidecarOnlyInIsolate(String path) =>
    LocalLyricLoader.readSidecarOnly(path);

class _SyltEntry {
  final String text;
  final int timestamp;

  const _SyltEntry(this.text, this.timestamp);
}
