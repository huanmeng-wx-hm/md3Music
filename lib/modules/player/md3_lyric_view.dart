import 'package:flutter/foundation.dart' show ValueListenable, ValueChanged;
import 'package:flutter/widgets.dart';

import '../../providers/player_provider.dart';
import '../../widgets/apple_lyrics/apple_lyrics_view.dart';
import 'package:md3music/widgets/apple_lyrics/models/lyric_line.dart';
import 'lyrics_view.dart';

/// MD3 播放器用的歌词槽：仍待在 MD3 壳里（不引入 AM 那层模糊封面背景），
/// 只有歌词本身带字级时间戳（KRC / 字级 LRC / 增强型 LRC）时，
/// 才借 AppleLyricsView 开逐字动画；普通 LRC / 纯文本继续走原来的
/// LyricsView，滚动、换行、双击跳转与浅色主题观感全部不变。
///
/// 外层的 RepaintBoundary 由调用方保留，用来隔离逐字渲染每帧重绘。
class Md3LyricView extends StatelessWidget {
  const Md3LyricView({
    super.key,
    required this.lyrics,
    required this.parsedLyrics,
    required this.playerProvider,
    required this.positionListenable,
    required this.adaptPosition,
    required this.onSeek,
    this.position = Duration.zero,
    this.doubleTapToJump = false,
    this.songBpm,
  });

  final String lyrics;
  final List<LyricLine>? parsedLyrics;
  final PlayerProvider playerProvider;
  final ValueListenable<Duration>? positionListenable;
  final Duration Function(Duration)? adaptPosition;
  final ValueChanged<Duration> onSeek;
  final Duration position;
  final bool doubleTapToJump;
  final int? songBpm;

  @override
  Widget build(BuildContext context) {
    final lines = parsedLyrics ?? const <LyricLine>[];
    final hasWordTiming = lines.any((line) => line.hasWordTiming);

    if (!hasWordTiming) {
      return LyricsView(
        lyrics: lyrics,
        parsedLyrics: parsedLyrics,
        position: position,
        positionListenable: positionListenable,
        adaptPosition: adaptPosition,
        doubleTapToJump: doubleTapToJump,
        onSeek: onSeek,
      );
    }

    // AppleLyricsView 内部用 Ticker 跑每帧重绘，isPlaying / playbackNotReady
    // 必须随 PlayerProvider 刷新，否则暂停后 Ticker 不收敛、白烧 120fps。
    return ListenableBuilder(
      listenable: playerProvider,
      builder: (context, _) => AppleLyricsView(
        lines: lines,
        currentTimeMs: 0,
        positionListenable: positionListenable,
        adaptTimeMs: adaptPosition == null
            ? null
            : (p) => adaptPosition!(p).inMilliseconds,
        isPlaying: playerProvider.isPlaying,
        playbackNotReady: playerProvider.isPlaybackNotReady,
        // MD3 背景跟随主题（浅色用黑字），不要 AM 的强制深色白字。
        forceDarkBackground: false,
        enableInterludeDots: true,
        doubleTapToJump: doubleTapToJump,
        songBpm: songBpm,
        onSeek: (timeMs) => onSeek(Duration(milliseconds: timeMs)),
      ),
    );
  }
}
