import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:sip_ua/sip_ua.dart';

import '../call_history_service.dart';
import '../contact_service.dart';
import '../demo_mode_service.dart';
import '../messaging/messaging_service.dart';
import '../messaging/phone_numbers.dart';
import '../tear_sheet_service.dart';
import '../theme_provider.dart';
import '../transcript_exporter.dart';
import 'dialpad_contact_preview.dart';

class CallHistoryPanel extends StatefulWidget {
  const CallHistoryPanel({super.key});

  @override
  State<CallHistoryPanel> createState() => _CallHistoryPanelState();
}

class _CallHistoryPanelState extends State<CallHistoryPanel> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  final LayerLink _layerLink = LayerLink();
  OverlayEntry? _suggestionsOverlay;
  List<Map<String, String>> _suggestions = [];

  @override
  void initState() {
    super.initState();
    final service = context.read<CallHistoryService>();
    _searchController.text = service.searchQuery;
    _searchController.addListener(_onSearchChanged);
    _searchFocus.addListener(_onFocusChanged);
  }

  @override
  void dispose() {
    _dismissSuggestions();
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _onFocusChanged() {
    if (!_searchFocus.hasFocus) {
      Future.delayed(const Duration(milliseconds: 150), () {
        if (mounted && !_searchFocus.hasFocus) _dismissSuggestions();
      });
    }
  }

  void _onSearchChanged() {
    final text = _searchController.text;
    final service = context.read<CallHistoryService>();
    service.setSearchQuery(text);

    if (text.trim().isEmpty) {
      _dismissSuggestions();
      service.loadRecentCalls();
      return;
    }

    _fetchSuggestions(text.trim());
  }

  Future<void> _fetchSuggestions(String prefix) async {
    if (prefix.length < 2) {
      _dismissSuggestions();
      return;
    }
    final service = context.read<CallHistoryService>();
    final results = await service.getSuggestions(prefix);
    if (!mounted) return;
    setState(() => _suggestions = results);
    if (results.isNotEmpty && _searchFocus.hasFocus) {
      _showSuggestionsOverlay();
    } else {
      _dismissSuggestions();
    }
  }

  void _showSuggestionsOverlay() {
    _dismissSuggestions();
    _suggestionsOverlay = OverlayEntry(builder: (_) => _buildSuggestions());
    Overlay.of(context).insert(_suggestionsOverlay!);
  }

  void _dismissSuggestions() {
    _suggestionsOverlay?.remove();
    _suggestionsOverlay = null;
  }

  Widget _buildSuggestions() {
    return Positioned(
      width: 0,
      child: CompositedTransformFollower(
        link: _layerLink,
        showWhenUnlinked: false,
        offset: const Offset(0, 42),
        child: Builder(builder: (context) {
          final box = this.context.findRenderObject() as RenderBox?;
          final panelWidth = box?.size.width ?? 400;
          final width = panelWidth - 24 - 48;
          return Align(
            alignment: Alignment.topLeft,
            child: Material(
              elevation: 8,
              borderRadius: BorderRadius.circular(10),
              color: AppColors.surface,
              child: Container(
                width: width,
                constraints: const BoxConstraints(maxHeight: 260),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                      color: AppColors.border.withValues(alpha: 0.6),
                      width: 0.5),
                ),
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: _suggestions.length,
                  itemBuilder: (context, index) {
                    final s = _suggestions[index];
                    final label = s['label'] ?? '';
                    final phone = s['phone'] ?? '';
                    final showPhone = phone.isNotEmpty && phone != label;
                    return InkWell(
                      borderRadius: BorderRadius.circular(6),
                      onTap: () => _selectSuggestion(label),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        child: Row(
                          children: [
                            Icon(Icons.person_outline_rounded,
                                size: 14, color: AppColors.textTertiary),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(label,
                                      style: TextStyle(
                                          fontSize: 12,
                                          color: AppColors.textPrimary,
                                          fontWeight: FontWeight.w500)),
                                  if (showPhone)
                                    Text(phone,
                                        style: TextStyle(
                                            fontSize: 10,
                                            color: AppColors.textTertiary)),
                                ],
                              ),
                            ),
                            Icon(Icons.north_west_rounded,
                                size: 11, color: AppColors.textTertiary),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          );
        }),
      ),
    );
  }

  void _selectSuggestion(String label) {
    _searchController.text = label;
    _searchController.selection =
        TextSelection.fromPosition(TextPosition(offset: label.length));
    _dismissSuggestions();
    _runSearch();
  }

  void _runSearch() {
    _dismissSuggestions();
    final query = _searchController.text.trim();
    final service = context.read<CallHistoryService>();
    service.smartSearch(query);
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
      padding: const EdgeInsets.fromLTRB(20, 28, 16, 11),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border(bottom: BorderSide(color: AppColors.border, width: 0.5)),
      ),
      child: Row(
        children: [
          Icon(Icons.history_rounded, size: 18, color: AppColors.accent),
          const SizedBox(width: 8),
          Text(
            'History',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
              letterSpacing: -0.3,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: CompositedTransformTarget(
              link: _layerLink,
              child: Container(
                height: 34,
                decoration: BoxDecoration(
                  color: AppColors.card,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                      color: AppColors.border.withValues(alpha: 0.4),
                      width: 0.5),
                ),
                child: TextField(
                  controller: _searchController,
                  focusNode: _searchFocus,
                  style: TextStyle(fontSize: 13, color: AppColors.textPrimary),
                  decoration: InputDecoration(
                    hintText: 'calls to Lee, missed today, last hour...',
                    hintStyle:
                        TextStyle(color: AppColors.textTertiary, fontSize: 12),
                    prefixIcon: Icon(Icons.search_rounded,
                        size: 16, color: AppColors.textTertiary),
                    prefixIconConstraints:
                        const BoxConstraints(minWidth: 32, minHeight: 0),
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(vertical: 8),
                  ),
                  onSubmitted: (_) => _runSearch(),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          if (service.isLoading)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 1.5,
                  color: AppColors.accent,
                ),
              ),
            ),
          if (service.searchResults.isNotEmpty) ...[
            HoverButton(
              onTap: () {
                final tearSheet = context.read<TearSheetService>();
                tearSheet.createFromSearchResults(
                  service.searchResults,
                  name: service.searchQuery.isNotEmpty
                      ? service.searchQuery
                      : 'From History',
                );
                service.closeHistory();
              },
              borderRadius: BorderRadius.circular(8),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  color: AppColors.accent.withValues(alpha: 0.12),
                  border: Border.all(
                      color: AppColors.accent.withValues(alpha: 0.3),
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
            const SizedBox(width: 6),
          ],
          HoverButton(
            onTap: service.closeHistory,
            borderRadius: BorderRadius.circular(8),
            child: Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                color: AppColors.card,
                border: Border.all(
                    color: AppColors.border.withValues(alpha: 0.5), width: 0.5),
              ),
              child: Icon(Icons.close_rounded,
                  size: 16, color: AppColors.textSecondary),
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
                size: 36, color: AppColors.textTertiary.withValues(alpha: 0.4)),
            const SizedBox(height: 12),
            Text(
              'No calls found',
              style: TextStyle(
                  fontSize: 14, color: AppColors.textTertiary, height: 1.4),
            ),
            const SizedBox(height: 4),
            Text(
              'Try a different search — AI will kick in automatically',
              style: TextStyle(
                  fontSize: 12,
                  color: AppColors.textTertiary.withValues(alpha: 0.7)),
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
  bool _autoPlayRecording = false;

  @override
  void didUpdateWidget(_CallRecordTile old) {
    super.didUpdateWidget(old);
    if (widget.isExpanded && !old.isExpanded) {
      _loadTranscripts();
    }
    if (!widget.isExpanded && old.isExpanded) {
      _autoPlayRecording = false;
    }
  }

  Future<void> _loadTranscripts() async {
    if (_transcripts != null) return;
    setState(() => _loadingTranscripts = true);
    final service = context.read<CallHistoryService>();
    final results = await service.getTranscripts(widget.record['id'] as int);
    if (mounted) {
      setState(() {
        _transcripts = results;
        _loadingTranscripts = false;
      });
    }
  }

  static bool _looksLikePhone(String s) =>
      s.replaceAll(RegExp(r'[^\d]'), '').length >= 7 &&
      RegExp(r'^[\d\s\+\-\(\)\.]+$').hasMatch(s);

  String _name(DemoModeService demo, ContactService contacts) {
    final contactName = widget.record['contact_name'] as String? ?? '';
    final displayName = widget.record['remote_display_name'] as String? ?? '';
    final identity = widget.record['remote_identity'] as String? ?? '';
    if (contactName.isNotEmpty) return demo.maskDisplayName(contactName);
    final hasName = displayName.isNotEmpty && !_looksLikePhone(displayName);
    if (hasName) return demo.maskDisplayName(displayName);
    // Live fallback: contact may have been linked after this call was recorded.
    if (identity.isNotEmpty) {
      final live = contacts.lookupByPhone(identity);
      final liveName = live?['display_name'] as String?;
      if (liveName != null && liveName.isNotEmpty) {
        return demo.maskDisplayName(liveName);
      }
    }
    final number = identity.isNotEmpty ? identity : displayName;
    if (number.isEmpty) return 'Unknown';
    return demo.maskPhone(number);
  }

  String? _thumbnailPathFor(ContactService contacts) {
    // Prefer the thumbnail joined directly from the DB record.
    final direct = widget.record['contact_thumbnail'] as String?;
    if (direct != null && direct.isNotEmpty) return direct;
    // Fallback: live phone-cache lookup (catches contacts linked after the call).
    final identity = widget.record['remote_identity'] as String? ?? '';
    if (identity.isEmpty) return null;
    final match = contacts.lookupByPhone(identity);
    return match?['thumbnail_path'] as String?;
  }

  String _phone(DemoModeService demo) {
    final identity = widget.record['remote_identity'] as String? ?? '';
    if (identity.isEmpty) return '';
    return demo.maskPhone(identity);
  }

  bool _hasContactName(ContactService contacts) {
    final contactName = widget.record['contact_name'] as String? ?? '';
    final displayName = widget.record['remote_display_name'] as String? ?? '';
    if (contactName.isNotEmpty) return true;
    if (displayName.isNotEmpty && !_looksLikePhone(displayName)) return true;
    final identity = widget.record['remote_identity'] as String? ?? '';
    if (identity.isNotEmpty) {
      final live = contacts.lookupByPhone(identity);
      final liveName = live?['display_name'] as String?;
      if (liveName != null && liveName.isNotEmpty) return true;
    }
    return false;
  }

  bool get _isOutbound => widget.record['direction'] == 'outbound';

  bool get _hasRecording {
    final path = widget.record['recording_path'];
    return path != null && (path as String).isNotEmpty;
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
      final isToday =
          dt.year == now.year && dt.month == now.month && dt.day == now.day;
      final h = dt.hour > 12 ? dt.hour - 12 : (dt.hour == 0 ? 12 : dt.hour);
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

  void _openMessage(BuildContext context) {
    final number = widget.record['remote_identity'] as String?;
    if (number == null || number.isEmpty) return;
    final messaging = context.read<MessagingService>();
    context.read<CallHistoryService>().closeHistory();
    if (!messaging.isOpen) messaging.toggleOpen();
    messaging.selectConversation(ensureE164(number));
  }

  void _openContact(BuildContext context) {
    final number = widget.record['remote_identity'] as String?;
    if (number == null || number.isEmpty) return;
    context.read<CallHistoryService>().closeHistory();
    context.read<ContactService>().openContactForPhone(ensureE164(number));
  }

  Widget _buildRecordingSection() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.bg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
            color: AppColors.border.withValues(alpha: 0.3), width: 0.5),
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
                filePath: widget.record['recording_path'] as String,
                autoPlay: _autoPlayRecording),
          ] else ...[
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: 0,
                minHeight: 3,
                backgroundColor: AppColors.border.withValues(alpha: 0.15),
                valueColor: AlwaysStoppedAnimation<Color>(
                    AppColors.textTertiary.withValues(alpha: 0.2)),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _downloadTranscript(BuildContext context) async {
    if (_transcripts == null || _transcripts!.isEmpty) return;

    final record = widget.record;
    final content = TranscriptExporter.formatCallTranscript(
      transcripts: _transcripts!,
      remoteIdentity: record['remote_identity'] as String?,
      remoteDisplayName: record['remote_display_name'] as String?,
      direction: record['direction'] as String?,
      status: record['status'] as String?,
      startedAt: record['started_at'] as String?,
      durationSeconds: record['duration_seconds'] as int?,
    );

    final name = (record['remote_display_name'] as String?)?.isNotEmpty == true
        ? record['remote_display_name'] as String
        : record['remote_identity'] as String? ?? 'call';
    final safeName = name.replaceAll(RegExp(r'[^\w\-]'), '_');

    await TranscriptExporter.saveToDownloads(
      content,
      filenamePrefix: 'transcript_$safeName',
      context: context,
    );
  }

  Widget _buildTranscriptSection() {
    final hasTranscripts = _transcripts != null && _transcripts!.isNotEmpty;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.bg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
            color: AppColors.border.withValues(alpha: 0.3), width: 0.5),
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
          : !hasTranscripts
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
                    Row(
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
                        const Spacer(),
                        HoverButton(
                          onTap: () => _downloadTranscript(context),
                          tooltip: 'Download transcript',
                          borderRadius: BorderRadius.circular(6),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 3),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(6),
                              color: AppColors.accent.withValues(alpha: 0.10),
                              border: Border.all(
                                color: AppColors.accent.withValues(alpha: 0.25),
                                width: 0.5,
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.download_rounded,
                                    size: 11, color: AppColors.accent),
                                const SizedBox(width: 3),
                                Text(
                                  'Save',
                                  style: TextStyle(
                                    fontSize: 9,
                                    fontWeight: FontWeight.w600,
                                    color: AppColors.accent,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    ..._transcripts!.map((t) => _TranscriptLine(transcript: t)),
                  ],
                ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final demo = context.watch<DemoModeService>();
    final contacts = context.watch<ContactService>();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 3),
      child: HoverButton(
        onTap: widget.onTap,
        borderRadius: BorderRadius.circular(10),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: widget.isExpanded ? AppColors.surface : AppColors.card,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: widget.isExpanded
                  ? AppColors.accent.withValues(alpha: 0.3)
                  : AppColors.border.withValues(alpha: 0.4),
              width: 0.5,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  ContactIdenticon(
                    seed: _name(demo, contacts),
                    size: 48,
                    thumbnailPath: _thumbnailPathFor(contacts),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              widget.record['status'] == 'missed'
                                  ? Icons.phone_missed_rounded
                                  : _isOutbound
                                      ? Icons.call_made_rounded
                                      : Icons.call_received_rounded,
                              size: 15,
                              color: widget.record['status'] == 'missed'
                                  ? AppColors.burntAmber
                                  : AppColors.textTertiary,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _name(demo, contacts),
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                  color: AppColors.textPrimary,
                                  letterSpacing: -0.2,
                                ),
                              ),
                            ),
                          ],
                        ),
                        if (_hasContactName(contacts)) ...[
                          const SizedBox(height: 2),
                          Text(
                            _phone(demo),
                            style: TextStyle(
                              fontSize: 13,
                              color: AppColors.textTertiary,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                        const SizedBox(height: 3),
                        Row(
                          children: [
                            Text(
                              _durationLabel,
                              style: TextStyle(
                                  fontSize: 14, color: AppColors.textTertiary),
                            ),
                            if (_hasRecording) ...[
                              const SizedBox(width: 6),
                              GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: () {
                                  setState(() => _autoPlayRecording = true);
                                  if (!widget.isExpanded) widget.onTap();
                                },
                                child: Padding(
                                  padding: const EdgeInsets.all(2),
                                  child: SvgPicture.asset(
                                    'assets/tape_reel.svg',
                                    width: 18,
                                    height: 18,
                                    colorFilter: ColorFilter.mode(
                                        AppColors.accent, BlendMode.srcIn),
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                  HoverButton(
                    onTap: () => _redial(context),
                    child: Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: AppColors.accent.withValues(alpha: 0.12),
                        border: Border.all(
                            color: AppColors.accent.withValues(alpha: 0.3),
                            width: 0.5),
                      ),
                      child: Icon(Icons.phone_rounded,
                          size: 13, color: AppColors.accent),
                    ),
                  ),
                  const SizedBox(width: 8),
                  HoverButton(
                    onTap: () => _openMessage(context),
                    child: Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: AppColors.accent.withValues(alpha: 0.12),
                        border: Border.all(
                            color: AppColors.accent.withValues(alpha: 0.3),
                            width: 0.5),
                      ),
                      child: Icon(Icons.chat_bubble_outline_rounded,
                          size: 12, color: AppColors.accent),
                    ),
                  ),
                  const SizedBox(width: 8),
                  HoverButton(
                    onTap: () => _openContact(context),
                    child: Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: AppColors.accent.withValues(alpha: 0.12),
                        border: Border.all(
                            color: AppColors.accent.withValues(alpha: 0.3),
                            width: 0.5),
                      ),
                      child: Icon(Icons.person_outline_rounded,
                          size: 13, color: AppColors.accent),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _timeLabel,
                    style: TextStyle(
                      fontSize: 12,
                      color: AppColors.textTertiary.withValues(alpha: 0.8),
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
                _buildRecordingSection(),
                const SizedBox(height: 10),
                _buildTranscriptSection(),
              ],
            ],
          ),
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
  final bool autoPlay;
  const _RecordingPlayer({required this.filePath, this.autoPlay = false});

  @override
  State<_RecordingPlayer> createState() => _RecordingPlayerState();
}

class _RecordingPlayerState extends State<_RecordingPlayer> {
  late AudioPlayer _player;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _playing = false;
  bool _dragging = false;
  double _dragValue = 0.0;

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
        if (widget.autoPlay) _player.play();
      }
    } catch (e) {
      debugPrint('[RecordingPlayer] Failed to load: $e');
    }

    _player.positionStream.listen((pos) {
      if (mounted && !_dragging) setState(() => _position = pos);
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
    final progress = _duration.inMilliseconds > 0
        ? _position.inMilliseconds / _duration.inMilliseconds
        : 0.0;
    final sliderValue = _dragging ? _dragValue : progress.clamp(0.0, 1.0);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.bg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
            color: AppColors.border.withValues(alpha: 0.3), width: 0.5),
      ),
      child: Row(
        children: [
          HoverButton(
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
                _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                size: 16,
                color: AppColors.crtBlack,
              ),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: SliderTheme(
              data: SliderThemeData(
                trackHeight: 3,
                activeTrackColor: AppColors.accent,
                inactiveTrackColor: AppColors.border.withValues(alpha: 0.3),
                thumbColor: AppColors.accent,
                overlayColor: AppColors.accent.withValues(alpha: 0.12),
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                trackShape: const RoundedRectSliderTrackShape(),
              ),
              child: Slider(
                value: sliderValue,
                onChangeStart: (v) {
                  setState(() {
                    _dragging = true;
                    _dragValue = v;
                  });
                },
                onChanged: (v) {
                  setState(() => _dragValue = v);
                },
                onChangeEnd: (v) {
                  final target = Duration(
                    milliseconds: (v * _duration.inMilliseconds).round(),
                  );
                  _player.seek(target);
                  setState(() => _dragging = false);
                },
              ),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '${_formatDuration(_position)} / ${_formatDuration(_duration)}',
            style: TextStyle(
              fontSize: 10,
              color: AppColors.textTertiary,
              fontFamily: AppColors.timerFontFamily,
              fontFamilyFallback: AppColors.timerFontFamilyFallback,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(width: 4),
          HoverButton(
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
              color: _roleColor.withValues(alpha: 0.12),
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
                color: AppColors.textSecondary.withValues(alpha: 0.85),
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
