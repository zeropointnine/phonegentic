import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:sip_ua/sip_ua.dart';

import '../agent_service.dart';
import '../call_history_service.dart';
import '../demo_mode_service.dart';
import '../messaging/phone_numbers.dart';
import '../tear_sheet_service.dart';
import '../theme_provider.dart';

class CallHistoryPanel extends StatefulWidget {
  const CallHistoryPanel({Key? key}) : super(key: key);

  @override
  State<CallHistoryPanel> createState() => _CallHistoryPanelState();
}

class _CallHistoryPanelState extends State<CallHistoryPanel> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    final service = context.read<CallHistoryService>();
    _searchController.text = service.searchQuery;
    _searchController.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    final service = context.read<CallHistoryService>();
    service.setSearchQuery(_searchController.text);
    if (_searchController.text.trim().isEmpty) {
      service.loadRecentCalls();
    }
  }

  void _runSearch() {
    final query = _searchController.text.trim();
    final service = context.read<CallHistoryService>();
    if (query.isEmpty) {
      service.loadRecentCalls();
    } else {
      service.naturalSearch(query);
    }
  }

  void _askAgent() {
    final query = _searchController.text.trim();
    if (query.isEmpty) return;
    final agent = context.read<AgentService>();
    agent.sendUserMessage('Search my call history: $query');
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<CallHistoryService>(
      builder: (context, service, _) {
        if (service.searchQuery != _searchController.text) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _searchController.text = service.searchQuery;
            _searchController.selection = TextSelection.fromPosition(
              TextPosition(offset: _searchController.text.length),
            );
          });
        }

        return Container(
          color: AppColors.bg,
          child: SafeArea(
            child: Column(
              children: [
                _buildHeader(service),
                _buildSearchBar(),
                Expanded(child: _buildResultsList(service)),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildHeader(CallHistoryService service) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 28, 8, 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border:
            Border(bottom: BorderSide(color: AppColors.border, width: 0.5)),
      ),
      child: Row(
        children: [
          Icon(Icons.history_rounded, size: 18, color: AppColors.accent),
          const SizedBox(width: 10),
          Text(
            'Call History',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
              letterSpacing: -0.3,
            ),
          ),
          const Spacer(),
          if (service.isLoading)
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 1.5,
                color: AppColors.accent,
              ),
            ),
          if (service.searchResults.isNotEmpty) ...[
            const SizedBox(width: 6),
            GestureDetector(
              onTap: () {
                final tearSheet =
                    context.read<TearSheetService>();
                tearSheet.createFromSearchResults(
                  service.searchResults,
                  name: service.searchQuery.isNotEmpty
                      ? service.searchQuery
                      : 'From History',
                );
                service.closeHistory();
              },
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 8, vertical: 5),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  color: AppColors.accent.withOpacity(0.12),
                  border: Border.all(
                      color: AppColors.accent.withOpacity(0.3),
                      width: 0.5),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.receipt_long_rounded,
                        size: 12, color: AppColors.accent),
                    const SizedBox(width: 4),
                    Text(
                      'Tear Sheet',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: AppColors.accent,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(width: 8),
          GestureDetector(
            onTap: service.closeHistory,
            child: Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                color: AppColors.card,
                border: Border.all(
                    color: AppColors.border.withOpacity(0.5), width: 0.5),
              ),
              child: Icon(Icons.close_rounded,
                  size: 16, color: AppColors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border:
            Border(bottom: BorderSide(color: AppColors.border, width: 0.5)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: AppColors.card,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                    color: AppColors.border.withOpacity(0.5), width: 0.5),
              ),
              child: TextField(
                controller: _searchController,
                focusNode: _searchFocus,
                style: TextStyle(fontSize: 13, color: AppColors.textPrimary),
                decoration: InputDecoration(
                  hintText: 'e.g. "585" "missed today" "to Fred over 2 min"',
                  hintStyle:
                      TextStyle(color: AppColors.textTertiary, fontSize: 13),
                  prefixIcon: Icon(Icons.search_rounded,
                      size: 18, color: AppColors.textTertiary),
                  border: InputBorder.none,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                ),
                onSubmitted: (_) => _runSearch(),
              ),
            ),
          ),
          const SizedBox(width: 6),
          GestureDetector(
            onTap: _runSearch,
            child: Tooltip(
              message: 'Search locally',
              child: Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  color: AppColors.accent,
                ),
                child: const Icon(Icons.search_rounded,
                    size: 16, color: AppColors.crtBlack),
              ),
            ),
          ),
          const SizedBox(width: 4),
          GestureDetector(
            onTap: _askAgent,
            child: Tooltip(
              message: 'Ask AI agent',
              child: Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  color: AppColors.card,
                  border: Border.all(
                      color: AppColors.accent.withOpacity(0.4), width: 0.5),
                ),
                child: Icon(Icons.auto_awesome,
                    size: 16, color: AppColors.accent),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResultsList(CallHistoryService service) {
    if (service.searchResults.isEmpty && !service.isLoading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.phone_missed_rounded,
                size: 36, color: AppColors.textTertiary.withOpacity(0.4)),
            const SizedBox(height: 12),
            Text(
              'No calls found',
              style: TextStyle(
                  fontSize: 14, color: AppColors.textTertiary, height: 1.4),
            ),
            const SizedBox(height: 4),
            Text(
              'Try a different search or ask the AI agent',
              style: TextStyle(
                  fontSize: 12,
                  color: AppColors.textTertiary.withOpacity(0.7)),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 6),
      itemCount: service.searchResults.length,
      itemBuilder: (context, index) {
        final record = service.searchResults[index];
        final callId = record['id'] as int;
        final isExpanded = service.expandedCallId == callId;
        return _CallRecordTile(
          record: record,
          isExpanded: isExpanded,
          onTap: () => service.toggleExpanded(callId),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Call record tile
// ---------------------------------------------------------------------------

class _CallRecordTile extends StatefulWidget {
  final Map<String, dynamic> record;
  final bool isExpanded;
  final VoidCallback onTap;

  const _CallRecordTile({
    required this.record,
    required this.isExpanded,
    required this.onTap,
  });

  @override
  State<_CallRecordTile> createState() => _CallRecordTileState();
}

class _CallRecordTileState extends State<_CallRecordTile> {
  List<Map<String, dynamic>>? _transcripts;
  bool _loadingTranscripts = false;

  @override
  void didUpdateWidget(_CallRecordTile old) {
    super.didUpdateWidget(old);
    if (widget.isExpanded && !old.isExpanded) {
      _loadTranscripts();
    }
  }

  Future<void> _loadTranscripts() async {
    if (_transcripts != null) return;
    setState(() => _loadingTranscripts = true);
    final service = context.read<CallHistoryService>();
    final results =
        await service.getTranscripts(widget.record['id'] as int);
    if (mounted) {
      setState(() {
        _transcripts = results;
        _loadingTranscripts = false;
      });
    }
  }

  String _name(DemoModeService demo) {
    final rawName =
        (widget.record['remote_display_name'] as String?)?.isNotEmpty == true
            ? widget.record['remote_display_name'] as String
            : widget.record['remote_identity'] as String? ?? 'Unknown';
    if ((widget.record['remote_display_name'] as String?)?.isNotEmpty == true) {
      return demo.maskDisplayName(rawName);
    }
    return demo.maskPhone(rawName);
  }

  String _initial(DemoModeService demo) {
    final n = _name(demo);
    final cleaned = n.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '');
    return cleaned.isEmpty ? '?' : cleaned.substring(0, 1).toUpperCase();
  }

  bool get _isOutbound => widget.record['direction'] == 'outbound';

  bool get _hasRecording {
    final path = widget.record['recording_path'];
    return path != null && (path as String).isNotEmpty;
  }

  Color get _statusColor {
    switch (widget.record['status']) {
      case 'completed':
        return AppColors.green;
      case 'missed':
        return AppColors.burntAmber;
      case 'failed':
      case 'rejected':
        return AppColors.red;
      default:
        return AppColors.textTertiary;
    }
  }

  String get _durationLabel {
    final dur = (widget.record['duration_seconds'] ?? 0) as int;
    final m = dur ~/ 60;
    final s = dur % 60;
    if (m > 0) return '${m}m ${s}s';
    return '${s}s';
  }

  String get _timeLabel {
    final raw = widget.record['started_at'] as String? ?? '';
    try {
      final dt = DateTime.parse(raw).toLocal();
      final now = DateTime.now();
      final isToday = dt.year == now.year &&
          dt.month == now.month &&
          dt.day == now.day;
      final h =
          dt.hour > 12 ? dt.hour - 12 : (dt.hour == 0 ? 12 : dt.hour);
      final ampm = dt.hour >= 12 ? 'PM' : 'AM';
      final time = '$h:${dt.minute.toString().padLeft(2, '0')} $ampm';
      if (isToday) return 'Today $time';
      return '${dt.month}/${dt.day} $time';
    } catch (_) {
      return raw;
    }
  }

  void _redial(BuildContext context) async {
    final number = widget.record['remote_identity'] as String?;
    if (number == null || number.isEmpty) return;
    try {
      final helper = Provider.of<SIPUAHelper>(context, listen: false);
      final mediaConstraints = <String, dynamic>{
        'audio': true,
        'video': false,
      };
      final stream =
          await navigator.mediaDevices.getUserMedia(mediaConstraints);
      helper.call(ensureE164(number), voiceOnly: true, mediaStream: stream);
    } catch (e) {
      debugPrint('[CallHistory] Redial failed: $e');
    }
  }

  Widget _buildExpandedHeader(BuildContext context) {
    final rawNumber = widget.record['remote_identity'] as String? ?? '';
    final number = context.read<DemoModeService>().maskPhone(rawNumber);
    final direction = _isOutbound ? 'Outbound' : 'Inbound';
    final status = widget.record['status'] as String? ?? '';

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.bg,
        borderRadius: BorderRadius.circular(8),
        border:
            Border.all(color: AppColors.border.withOpacity(0.3), width: 0.5),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  number,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                    letterSpacing: -0.2,
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Text(
                      '$direction · $status · $_durationLabel',
                      style: TextStyle(
                          fontSize: 10, color: AppColors.textTertiary),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  _timeLabel,
                  style:
                      TextStyle(fontSize: 10, color: AppColors.textTertiary),
                ),
              ],
            ),
          ),
          GestureDetector(
            onTap: () => _redial(context),
            child: Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.accent.withOpacity(0.12),
                border: Border.all(
                    color: AppColors.accent.withOpacity(0.3), width: 0.5),
              ),
              child:
                  Icon(Icons.phone_rounded, size: 16, color: AppColors.accent),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRecordingSection() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.bg,
        borderRadius: BorderRadius.circular(8),
        border:
            Border.all(color: AppColors.border.withOpacity(0.3), width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.fiber_manual_record,
                size: 8,
                color: _hasRecording ? AppColors.red : AppColors.textTertiary,
              ),
              const SizedBox(width: 6),
              Text(
                'Recording',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textTertiary,
                  letterSpacing: 0.5,
                ),
              ),
              const Spacer(),
              if (!_hasRecording)
                Text(
                  'Not Recorded',
                  style: TextStyle(
                    fontSize: 10,
                    color: AppColors.textTertiary,
                    fontStyle: FontStyle.italic,
                  ),
                ),
            ],
          ),
          if (_hasRecording) ...[
            const SizedBox(height: 8),
            _RecordingPlayer(
                filePath: widget.record['recording_path'] as String),
          ] else ...[
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: 0,
                minHeight: 3,
                backgroundColor: AppColors.border.withOpacity(0.15),
                valueColor: AlwaysStoppedAnimation<Color>(
                    AppColors.textTertiary.withOpacity(0.2)),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildTranscriptSection() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.bg,
        borderRadius: BorderRadius.circular(8),
        border:
            Border.all(color: AppColors.border.withOpacity(0.3), width: 0.5),
      ),
      child: _loadingTranscripts
          ? Center(
              child: Padding(
              padding: const EdgeInsets.all(12),
              child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 1.5,
                  color: AppColors.accent,
                ),
              ),
            ))
          : (_transcripts == null || _transcripts!.isEmpty)
              ? Text(
                  'No transcript recorded',
                  style: TextStyle(
                    fontSize: 11,
                    color: AppColors.textTertiary,
                    fontStyle: FontStyle.italic,
                  ),
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Transcript',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textTertiary,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 6),
                    ..._transcripts!
                        .map((t) => _TranscriptLine(transcript: t)),
                  ],
                ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final _demo = context.watch<DemoModeService>();
    return GestureDetector(
      onTap: widget.onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: widget.isExpanded
              ? AppColors.surface
              : AppColors.card,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: widget.isExpanded
                ? AppColors.accent.withOpacity(0.3)
                : AppColors.border.withOpacity(0.4),
            width: 0.5,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                // Avatar
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(9),
                    color: _statusColor.withOpacity(0.12),
                    border: Border.all(
                        color: _statusColor.withOpacity(0.25), width: 0.5),
                  ),
                  child: Center(
                    child: Text(
                      _initial(_demo),
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: _statusColor,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                // Details
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            _isOutbound
                                ? Icons.call_made_rounded
                                : Icons.call_received_rounded,
                            size: 11,
                            color: AppColors.textTertiary,
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              _name(_demo),
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: AppColors.textPrimary,
                                letterSpacing: -0.2,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Row(
                        children: [
                          Container(
                            width: 5,
                            height: 5,
                            decoration: BoxDecoration(
                                shape: BoxShape.circle, color: _statusColor),
                          ),
                          const SizedBox(width: 5),
                          Text(
                            widget.record['status'] as String? ?? '',
                            style: TextStyle(
                              fontSize: 10,
                              color: _statusColor,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Text(
                            _durationLabel,
                            style: TextStyle(
                                fontSize: 10, color: AppColors.textTertiary),
                          ),
                          if (_hasRecording) ...[
                            const SizedBox(width: 8),
                            Icon(Icons.fiber_manual_record,
                                size: 6, color: AppColors.red),
                            const SizedBox(width: 3),
                            Text(
                              'Recorded',
                              style: TextStyle(
                                  fontSize: 10,
                                  color: AppColors.red,
                                  fontWeight: FontWeight.w500),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
                // Redial + Timestamp
                GestureDetector(
                  onTap: () => _redial(context),
                  child: Container(
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppColors.accent.withOpacity(0.12),
                      border: Border.all(
                          color: AppColors.accent.withOpacity(0.3), width: 0.5),
                    ),
                    child: Icon(Icons.phone_rounded,
                        size: 13, color: AppColors.accent),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  _timeLabel,
                  style: TextStyle(
                    fontSize: 10,
                    color: AppColors.textTertiary.withOpacity(0.8),
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  widget.isExpanded
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                  size: 16,
                  color: AppColors.textTertiary,
                ),
              ],
            ),
            if (widget.isExpanded) ...[
              const SizedBox(height: 12),
              // Expanded header: call details + redial
              _buildExpandedHeader(context),
              const SizedBox(height: 10),
              // Recording section (always shown)
              _buildRecordingSection(),
              const SizedBox(height: 10),
              // Transcript section
              _buildTranscriptSection(),
            ],
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Audio playback player for call recordings
// ---------------------------------------------------------------------------

class _RecordingPlayer extends StatefulWidget {
  final String filePath;
  const _RecordingPlayer({required this.filePath});

  @override
  State<_RecordingPlayer> createState() => _RecordingPlayerState();
}

class _RecordingPlayerState extends State<_RecordingPlayer> {
  late AudioPlayer _player;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _playing = false;

  @override
  void initState() {
    super.initState();
    _player = AudioPlayer();
    _initPlayer();
  }

  Future<void> _initPlayer() async {
    try {
      final file = File(widget.filePath);
      if (await file.exists()) {
        await _player.setFilePath(widget.filePath);
      }
    } catch (e) {
      debugPrint('[RecordingPlayer] Failed to load: $e');
    }

    _player.positionStream.listen((pos) {
      if (mounted) setState(() => _position = pos);
    });
    _player.durationStream.listen((dur) {
      if (mounted && dur != null) setState(() => _duration = dur);
    });
    _player.playerStateStream.listen((state) {
      if (!mounted) return;
      setState(() => _playing = state.playing);
      if (state.processingState == ProcessingState.completed) {
        _player.seek(Duration.zero);
        _player.pause();
      }
    });
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  String _formatDuration(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final progress =
        _duration.inMilliseconds > 0
            ? _position.inMilliseconds / _duration.inMilliseconds
            : 0.0;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.bg,
        borderRadius: BorderRadius.circular(8),
        border:
            Border.all(color: AppColors.border.withOpacity(0.3), width: 0.5),
      ),
      child: Row(
        children: [
          GestureDetector(
            onTap: () {
              if (_playing) {
                _player.pause();
              } else {
                _player.play();
              }
            },
            child: Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.accent,
              ),
              child: Icon(
                _playing
                    ? Icons.pause_rounded
                    : Icons.play_arrow_rounded,
                size: 16,
                color: AppColors.crtBlack,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: progress.clamp(0.0, 1.0),
                minHeight: 3,
                backgroundColor: AppColors.border.withOpacity(0.3),
                valueColor:
                    AlwaysStoppedAnimation<Color>(AppColors.accent),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Text(
            '${_formatDuration(_position)} / ${_formatDuration(_duration)}',
            style: TextStyle(
              fontSize: 10,
              color: AppColors.textTertiary,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(width: 4),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _downloadRecording,
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Icon(
                Icons.download_rounded,
                size: 16,
                color: AppColors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _downloadRecording() async {
    try {
      final src = File(widget.filePath);
      if (!await src.exists()) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text('Recording file not found'),
              duration: const Duration(seconds: 2),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
        return;
      }
      final downloadsDir = await getDownloadsDirectory();
      if (downloadsDir == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text('Could not access Downloads folder'),
              duration: const Duration(seconds: 2),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
        return;
      }
      final name = src.uri.pathSegments.last;
      final dest = File('${downloadsDir.path}/$name');
      await src.copy(dest.path);
      await Process.run('open', [downloadsDir.path]);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Saved to Downloads/$name'),
            duration: const Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      debugPrint('[RecordingPlayer] Download failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Download failed: $e'),
            duration: const Duration(seconds: 3),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }
}

class _TranscriptLine extends StatelessWidget {
  final Map<String, dynamic> transcript;
  const _TranscriptLine({required this.transcript});

  Color get _roleColor {
    switch (transcript['role']) {
      case 'agent':
        return AppColors.accent;
      case 'host':
        return AppColors.hotSignal;
      case 'remote':
        return AppColors.burntAmber;
      default:
        return AppColors.textTertiary;
    }
  }

  String get _roleLabel {
    final speaker = transcript['speaker_name'] as String?;
    if (speaker != null && speaker.isNotEmpty) return speaker;
    switch (transcript['role']) {
      case 'agent':
        return 'AI';
      case 'host':
        return 'You';
      case 'remote':
        return 'Remote';
      case 'user':
        return 'You';
      default:
        return transcript['role'] as String? ?? '';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(
              color: _roleColor.withOpacity(0.12),
              borderRadius: BorderRadius.circular(3),
            ),
            child: Text(
              _roleLabel,
              style: TextStyle(
                  fontSize: 9, fontWeight: FontWeight.w600, color: _roleColor),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              transcript['text'] as String? ?? '',
              style: TextStyle(
                fontSize: 11,
                color: AppColors.textSecondary.withOpacity(0.85),
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
