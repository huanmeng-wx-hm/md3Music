import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../core/services/online_download_service.dart';
import '../../core/utils/app_toast.dart';

/// 「我的 → 已下载」：左右划两页 —— 已下载 / 播放缓存。
///
/// 两页物理上对应两个文件夹，都在 Android/data/<包名>/files/ 下：
///   已下载   → md3_downloads
///   播放缓存 → md3_cache
/// 纸条按 pinned 分组显示，不轮询，只监听服务的两个 ValueNotifier。
class DownloadLibraryPage extends StatefulWidget {
  const DownloadLibraryPage({super.key});

  @override
  State<DownloadLibraryPage> createState() => _DownloadLibraryPageState();
}

class _DownloadLibraryPageState extends State<DownloadLibraryPage> {
  final PageController _page = PageController();
  int _tab = 0;
  List<Map<String, dynamic>> _rows = <Map<String, dynamic>>[];

  static const Map<String, String> _qualityLabels = <String, String>{
    '128': '标准',
    '320': '高音质',
    'flac': '无损',
    'high': 'Hi-Res',
    'viper_tape': '蝰蛇母带',
  };

  @override
  void initState() {
    super.initState();
    OnlineDownloadService.revision.addListener(_onRevision);
    OnlineDownloadService.tasks.addListener(_onTasks);
    _onRevision();
  }

  @override
  void dispose() {
    OnlineDownloadService.revision.removeListener(_onRevision);
    OnlineDownloadService.tasks.removeListener(_onTasks);
    _page.dispose();
    super.dispose();
  }

  void _onTasks() {
    if (mounted) setState(() {});
  }

  /// ValueNotifier 的回调是 void，用 unawaited 明确丢掉 Future。
  void _onRevision() => unawaited(_refresh());

  Future<void> _refresh() async {
    final rows = await OnlineDownloadService.instance.rows();
    if (!mounted) return;
    setState(() => _rows = rows);
  }

  String _q(String? v) =>
      _qualityLabels[v] ?? (v == null || v.isEmpty ? '—' : v);

  String _size(dynamic bytes) {
    final n = bytes is int ? bytes : (int.tryParse('$bytes') ?? 0);
    if (n <= 0) return '—';
    if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(0)} KB';
    return '${(n / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  List<Map<String, dynamic>> _of(bool pinned) => _rows
      .where((r) => (r['pinned'] == true) == pinned)
      .toList(growable: false);

  int _total(List<Map<String, dynamic>> list) =>
      list.fold<int>(0, (s, r) => s + ((r['size'] as int?) ?? 0));

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('已下载'),
        actions: <Widget>[
          IconButton(
            tooltip: '目录位置',
            onPressed: () => _showDirs(context),
            icon: const Icon(Icons.info_outline),
          ),
          IconButton(
            tooltip: '刷新',
            onPressed: _onRevision,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          // 两条下划线 tab：像 Material TabBar，但不依赖 TabController。
          Row(
            children: <Widget>[
              Expanded(child: _tabCell(0, '已下载', cs)),
              Expanded(child: _tabCell(1, '播放缓存', cs)),
            ],
          ),
          const Divider(height: 1),
          Expanded(
            child: PageView(
              controller: _page,
              onPageChanged: (i) => setState(() => _tab = i),
              children: <Widget>[
                _pinnedPage(cs),
                _cachePage(cs),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _tabCell(int i, String label, ColorScheme cs) {
    final on = _tab == i;
    return InkWell(
      onTap: () => _page.animateToPage(
        i,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          SizedBox(
            height: 48,
            child: Center(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: on ? FontWeight.w600 : FontWeight.w400,
                  color: on ? cs.primary : cs.onSurfaceVariant,
                ),
              ),
            ),
          ),
          Container(
            height: 2,
            color: on ? cs.primary : Colors.transparent,
          ),
        ],
      ),
    );
  }

  Widget _summary(ColorScheme cs, List<Map<String, dynamic>> list, String clearLabel,
      VoidCallback onClear) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: <Widget>[
          Text(
            '${list.length} 首 · ${_size(_total(list))}',
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
          ),
          const Spacer(),
          TextButton.icon(
            onPressed: list.isEmpty ? null : onClear,
            icon: const Icon(Icons.delete_sweep, size: 18),
            label: Text(clearLabel),
          ),
        ],
      ),
    );
  }

  /// 第一页：已下载（含进行中的任务条 + 手动存好的文件）。
  Widget _pinnedPage(ColorScheme cs) {
    final list = _of(true);
    final running = OnlineDownloadService.tasks.value
        .where((t) => t.status == DownloadStatus.downloading)
        .toList(growable: false);
    if (list.isEmpty && running.isEmpty) {
      return _empty(
        cs,
        Icons.download_done,
        '还没有已下载歌曲',
        '下载歌曲后可离线播放',
      );
    }
    return Column(
      children: <Widget>[
        _summary(cs, list, '清空已下载', () => _confirmClear(context, true)),
        const Divider(height: 1),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _refresh,
            child: ListView.builder(
              padding: const EdgeInsets.only(bottom: 24),
              itemCount: running.length + list.length,
              itemBuilder: (context, i) {
                if (i < running.length) return _taskTile(cs, running[i]);
                return _rowTile(cs, list[i - running.length], true);
              },
            ),
          ),
        ),
      ],
    );
  }

  /// 第二页：播放缓存（自动存的）。
  Widget _cachePage(ColorScheme cs) {
    final list = _of(false);
    if (list.isEmpty) {
      return _empty(
        cs,
        Icons.cached,
        '还没有播放缓存',
        '点播在线歌曲会自动整首存进来',
      );
    }
    return Column(
      children: <Widget>[
        _summary(cs, list, '清空播放缓存', () => _confirmClear(context, false)),
        const Divider(height: 1),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _refresh,
            child: ListView.builder(
              padding: const EdgeInsets.only(bottom: 24),
              itemCount: list.length,
              itemBuilder: (context, i) => _rowTile(cs, list[i], false),
            ),
          ),
        ),
      ],
    );
  }

  Widget _empty(ColorScheme cs, IconData icon, String title, String sub) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 72, color: cs.onSurfaceVariant.withValues(alpha: 0.3)),
            const SizedBox(height: 20),
            Text(
              title,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: cs.onSurface,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              sub,
              style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  Widget _taskTile(ColorScheme cs, DownloadTask t) {
    final pct = (t.progress * 100).toInt();
    return ListTile(
      leading: Icon(Icons.download, color: cs.onSurfaceVariant),
      title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            '${_q(t.quality)} · ${pct > 0 ? '下载中 $pct%' : '下载中'}',
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 6),
          LinearProgressIndicator(
            value: t.progress > 0 ? t.progress : null,
            minHeight: 3,
          ),
        ],
      ),
    );
  }

  Widget _rowTile(ColorScheme cs, Map<String, dynamic> r, bool pinned) {
    final name = '${r['title'] ?? r['id'] ?? ''}';
    final artist = '${r['artist'] ?? ''}';
    return ListTile(
      leading: Icon(
        pinned ? Icons.download_done : Icons.music_note,
        color: cs.onSurfaceVariant,
      ),
      title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '$artist · ${_q(r['requested']?.toString())} · ${_size(r['size'])}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
      ),
      trailing: IconButton(
        tooltip: '删除',
        icon: const Icon(Icons.delete_outline),
        onPressed: () => _delete(context, r),
      ),
    );
  }

  Future<void> _delete(BuildContext context, Map<String, dynamic> r) async {
    final id = '${r['id'] ?? ''}';
    if (id.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('删掉这一首？'),
        content: Text('${r['title'] ?? id} 的所有音质文件都会删除。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(d, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await OnlineDownloadService.instance.remove(id);
    await _refresh();
  }

  Future<void> _confirmClear(BuildContext context, bool pinned) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(pinned ? '清空已下载？' : '清空播放缓存？'),
        content: Text(
          pinned
              ? '只删手动下载的，播放缓存会留下。'
              : '只删播放时自动存的，手动下载的会留下。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(d, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final n = pinned
        ? await OnlineDownloadService.instance.clearPinned()
        : await OnlineDownloadService.instance.clearAuto();
    await _refresh();
    showToast('清掉 $n 首');
  }

  Future<void> _showDirs(BuildContext context) async {
    String cache;
    String dl;
    try {
      cache = await OnlineDownloadService.cacheDirPath();
      dl = await OnlineDownloadService.downloadDirPath();
    } catch (_) {
      cache = '读取失败';
      dl = '读取失败';
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('两个文件夹'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text('已下载', style: TextStyle(fontWeight: FontWeight.w600)),
            Text(dl, style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 12),
            const Text('播放缓存', style: TextStyle(fontWeight: FontWeight.w600)),
            Text(cache, style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 12),
            const Text(
              '都在 App 私有外部目录里，卸载会一起清掉；'
              '两个包名（精简版 / 兼容版）各有一套，互不共享。',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(d),
            child: const Text('好'),
          ),
        ],
      ),
    );
  }
}
