import 'dart:async';
// ignore: unnecessary_import
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../calendar_sync_service.dart';
import '../chrome/google_calendar_service.dart';
import '../db/call_history_db.dart';
import '../job_function_service.dart';
import '../manager_presence_service.dart';
import '../messaging/messaging_service.dart';
import '../models/calendar_event.dart';
import '../theme_provider.dart';

enum _CalendarView { day, week, month }

class CalendarPanel extends StatefulWidget {
  const CalendarPanel({super.key});

  @override
  State<CalendarPanel> createState() => _CalendarPanelState();
}

class _CalendarPanelState extends State<CalendarPanel> {
  _CalendarView _view = _CalendarView.week;
  late DateTime _focusDate;
  List<CalendarEvent> _events = [];
  String _searchQuery = '';
  final Set<EventSource> _hiddenSources = {};
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  final LayerLink _searchLayerLink = LayerLink();
  OverlayEntry? _searchOverlay;

  List<CalendarEvent> _searchResults = [];
  bool get _isSearching => _searchQuery.isNotEmpty;

  List<CalendarEvent> get _filteredEvents {
    final source = _isSearching ? _searchResults : _events;
    var result = source;
    if (_hiddenSources.isNotEmpty) {
      result = result.where((e) => !_hiddenSources.contains(e.source)).toList();
    }
    return result;
  }

  static bool _eventMatchesQuery(CalendarEvent e, String q) {
    return e.title.toLowerCase().contains(q) ||
        (e.inviteeName?.toLowerCase().contains(q) ?? false) ||
        (e.inviteeEmail?.toLowerCase().contains(q) ?? false) ||
        (e.description?.toLowerCase().contains(q) ?? false) ||
        (e.location?.toLowerCase().contains(q) ?? false) ||
        (e.eventType?.toLowerCase().contains(q) ?? false);
  }

  Future<void> _onSearchChanged(String value) async {
    setState(() => _searchQuery = value);
    if (value.isEmpty) {
      setState(() => _searchResults = []);
      _removeSearchOverlay();
      return;
    }
    final q = value.toLowerCase();
    final all = await CallHistoryDb.getAllCalendarEvents();
    final matches = all.where((e) => _eventMatchesQuery(e, q)).toList();
    if (mounted) {
      setState(() => _searchResults = matches);
      _showSearchOverlay();
    }
  }

  void _showSearchOverlay() {
    _removeSearchOverlay();
    if (_searchResults.isEmpty && _searchQuery.isEmpty) return;

    _searchOverlay = OverlayEntry(builder: (context) {
      final results = _filteredEvents;
      return GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: _dismissSearch,
        child: Stack(
          children: [
            CompositedTransformFollower(
              link: _searchLayerLink,
              showWhenUnlinked: false,
              offset: const Offset(0, 38),
              child: Material(
                color: Colors.transparent,
                child: Container(
                  constraints:
                      const BoxConstraints(maxHeight: 320, maxWidth: 400),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: AppColors.border.withValues(alpha: 0.6),
                      width: 0.5,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.25),
                        blurRadius: 16,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: results.isEmpty
                        ? Padding(
                            padding: const EdgeInsets.symmetric(
                                vertical: 20, horizontal: 16),
                            child: Text(
                              'No events found',
                              style: TextStyle(
                                fontSize: 12,
                                color: AppColors.textTertiary,
                              ),
                            ),
                          )
                        : ListView.separated(
                            shrinkWrap: true,
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            itemCount: results.length,
                            separatorBuilder: (_, __) => Divider(
                              height: 1,
                              color: AppColors.border.withValues(alpha: 0.25),
                            ),
                            itemBuilder: (context, index) {
                              final event = results[index];
                              final stateContext = this.context;
                              return _SearchResultRow(
                                event: event,
                                onTap: () {
                                  _navigateToEvent(event);
                                  _dismissSearch();
                                  _showEditEventDialog(stateContext, event);
                                },
                              );
                            },
                          ),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    });

    Overlay.of(context).insert(_searchOverlay!);
  }

  void _removeSearchOverlay() {
    _searchOverlay?.remove();
    _searchOverlay = null;
  }

  void _dismissSearch() {
    _searchController.clear();
    _searchFocusNode.unfocus();
    setState(() {
      _searchQuery = '';
      _searchResults = [];
    });
    _removeSearchOverlay();
  }

  void _navigateToEvent(CalendarEvent event) {
    final day = event.startTime.toLocal();
    setState(() {
      _focusDate = DateTime(day.year, day.month, day.day);
    });
    _loadEvents();
  }

  @override
  void initState() {
    super.initState();
    _focusDate = DateTime.now();
    _syncAndLoad();
  }

  @override
  void dispose() {
    _removeSearchOverlay();
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  Future<void> _syncAndLoad() async {
    final sync = context.read<CalendarSyncService>();
    await sync.syncNow();
    _loadEvents();
  }

  Future<void> _loadEvents() async {
    final range = _currentRange;
    final events = await CallHistoryDb.getEventsBetween(range[0], range[1]);
    if (mounted) setState(() => _events = events);
  }

  List<DateTime> get _currentRange {
    switch (_view) {
      case _CalendarView.day:
        final start =
            DateTime.utc(_focusDate.year, _focusDate.month, _focusDate.day);
        return [start, start.add(const Duration(days: 1))];
      case _CalendarView.week:
        final weekStart =
            _focusDate.subtract(Duration(days: _focusDate.weekday % 7));
        final start =
            DateTime.utc(weekStart.year, weekStart.month, weekStart.day);
        return [start, start.add(const Duration(days: 7))];
      case _CalendarView.month:
        final start = DateTime.utc(_focusDate.year, _focusDate.month, 1);
        return [start, DateTime.utc(_focusDate.year, _focusDate.month + 1, 1)];
    }
  }

  void _navigate(int delta) {
    setState(() {
      switch (_view) {
        case _CalendarView.day:
          _focusDate = _focusDate.add(Duration(days: delta));
          break;
        case _CalendarView.week:
          _focusDate = _focusDate.add(Duration(days: 7 * delta));
          break;
        case _CalendarView.month:
          _focusDate = DateTime(_focusDate.year, _focusDate.month + delta, 1);
          break;
      }
    });
    _loadEvents();
  }

  void _switchView(_CalendarView v) {
    setState(() => _view = v);
    _loadEvents();
  }

  void _goToDay(DateTime day) {
    setState(() {
      _focusDate = day;
      _view = _CalendarView.day;
    });
    _loadEvents();
  }

  @override
  Widget build(BuildContext context) {
    final syncService = context.watch<CalendarSyncService>();
    final gcalService = context.watch<GoogleCalendarService>();
    final hasAnyIntegration =
        syncService.hasCalendly || gcalService.config.enabled;

    return Container(
      color: AppColors.bg,
      child: SafeArea(
        child: Column(
          children: [
            _buildHeader(syncService),
            _buildViewToggle(),
            if (!hasAnyIntegration && _events.isEmpty)
              _SetupGuidanceCard(onClose: () => setState(() {}))
            else
              Expanded(child: _buildCalendarBody(context)),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(CalendarSyncService sync) {
    String title;
    switch (_view) {
      case _CalendarView.day:
        title = DateFormat.yMMMMEEEEd().format(_focusDate);
        break;
      case _CalendarView.week:
        title = _weekTitle();
        break;
      case _CalendarView.month:
        title = DateFormat.yMMMM().format(_focusDate);
        break;
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 28, 13, 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border(bottom: BorderSide(color: AppColors.border, width: 0.5)),
      ),
      child: Row(
        children: [
          Icon(Icons.calendar_month_rounded, size: 18, color: AppColors.accent),
          const SizedBox(width: 8),
          Text(
            title,
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
              link: _searchLayerLink,
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
                  focusNode: _searchFocusNode,
                  onChanged: _onSearchChanged,
                  style: TextStyle(fontSize: 13, color: AppColors.textPrimary),
                  decoration: InputDecoration(
                    hintText: 'Search...',
                    hintStyle:
                        TextStyle(fontSize: 13, color: AppColors.textTertiary),
                    prefixIcon: Icon(Icons.search_rounded,
                        size: 16, color: AppColors.textTertiary),
                    prefixIconConstraints:
                        const BoxConstraints(minWidth: 32, minHeight: 0),
                    suffixIcon: _searchQuery.isNotEmpty
                        ? GestureDetector(
                            onTap: _dismissSearch,
                            child: Icon(Icons.close_rounded,
                                size: 15, color: AppColors.textTertiary),
                          )
                        : null,
                    suffixIconConstraints:
                        const BoxConstraints(minWidth: 32, minHeight: 0),
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(vertical: 8),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          _navButton(Icons.chevron_left_rounded, () => _navigate(-1)),
          const SizedBox(width: 2),
          _navButton(Icons.today_rounded, () {
            setState(() => _focusDate = DateTime.now());
            _loadEvents();
          }),
          const SizedBox(width: 2),
          _navButton(Icons.chevron_right_rounded, () => _navigate(1)),
          const SizedBox(width: 6),
          HoverButton(
            onTap: () => _showNewEventDialog(context, _focusDate),
            borderRadius: BorderRadius.circular(8),
            child: Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                color: AppColors.accent,
              ),
              child:
                  Icon(Icons.add_rounded, size: 16, color: AppColors.onAccent),
            ),
          ),
          const SizedBox(width: 4),
          HoverButton(
            onTap: sync.close,
            borderRadius: BorderRadius.circular(8),
            child: Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                color: AppColors.card,
              ),
              child: Icon(Icons.close_rounded,
                  size: 16, color: AppColors.textTertiary),
            ),
          ),
        ],
      ),
    );
  }

  Widget _navButton(IconData icon, VoidCallback onTap) {
    return HoverButton(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: AppColors.card,
        ),
        child: Icon(icon, size: 18, color: AppColors.textSecondary),
      ),
    );
  }

  Widget _buildViewToggle() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          _buildSegmentedControl(),
          const Spacer(),
          for (final source in EventSource.values) ...[
            _sourceToggle(source),
            const SizedBox(width: 6),
          ],
        ],
      ),
    );
  }

  Widget _buildSegmentedControl() {
    const views = _CalendarView.values;
    const labels = {'day': 'Day', 'week': 'Week', 'month': 'Month'};
    return Container(
      height: 28,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        color: AppColors.card,
        border: Border.all(
          color: AppColors.border.withValues(alpha: 0.5),
          width: 0.5,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < views.length; i++) ...[
            _segmentButton(labels[views[i].name]!, views[i]),
            if (i < views.length - 1)
              Container(
                width: 0.5,
                height: 16,
                color: AppColors.border.withValues(alpha: 0.4),
              ),
          ],
        ],
      ),
    );
  }

  Widget _segmentButton(String label, _CalendarView v) {
    final selected = _view == v;
    return GestureDetector(
      onTap: () => _switchView(v),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(5),
          color: selected ? AppColors.accent : Colors.transparent,
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: selected ? AppColors.onAccent : AppColors.textSecondary,
            letterSpacing: -0.1,
          ),
        ),
      ),
    );
  }

  Widget _sourceToggle(EventSource source) {
    final active = !_hiddenSources.contains(source);
    final color = AppColors.colorForSource(source);

    return HoverButton(
      onTap: () {
        setState(() {
          if (active) {
            _hiddenSources.add(source);
          } else {
            _hiddenSources.remove(source);
          }
        });
      },
      borderRadius: BorderRadius.circular(6),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          color: active ? color.withValues(alpha: 0.15) : AppColors.card,
          border: Border.all(
            color: active
                ? color.withValues(alpha: 0.4)
                : AppColors.border.withValues(alpha: 0.3),
            width: 0.5,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: active
                    ? color
                    : AppColors.textTertiary.withValues(alpha: 0.3),
              ),
            ),
            const SizedBox(width: 5),
            Text(
              AppColors.labelForSource(source),
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: active
                    ? AppColors.textSecondary
                    : AppColors.textTertiary.withValues(alpha: 0.5),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCalendarBody(BuildContext context) {
    switch (_view) {
      case _CalendarView.day:
        return _DayView(
          focusDate: _focusDate,
          events: _filteredEvents,
          onEventTap: (e) => _showEditEventDialog(context, e),
          onAddEvent: (day) => _showNewEventDialog(context, day),
        );
      case _CalendarView.week:
        return _WeekView(
          focusDate: _focusDate,
          events: _filteredEvents,
          onEventTap: (e) => _showEditEventDialog(context, e),
          onAddEvent: (day) => _showNewEventDialog(context, day),
        );
      case _CalendarView.month:
        return _MonthView(
          focusDate: _focusDate,
          events: _filteredEvents,
          onDayTap: _goToDay,
          onEventTap: (e) => _showEditEventDialog(context, e),
          onAddEvent: (day) => _showNewEventDialog(context, day),
        );
    }
  }

  String _weekTitle() {
    final weekStart =
        _focusDate.subtract(Duration(days: _focusDate.weekday % 7));
    final weekEnd = weekStart.add(const Duration(days: 6));
    final startFmt = DateFormat.MMMd().format(weekStart);
    final endFmt = weekStart.month == weekEnd.month
        ? DateFormat.d().format(weekEnd)
        : DateFormat.MMMd().format(weekEnd);
    return '$startFmt – $endFmt, ${weekStart.year}';
  }

  void _showNewEventDialog(BuildContext context, DateTime day) {
    final parentContext = context;
    showDialog(
      context: parentContext,
      useRootNavigator: true,
      barrierColor: Colors.black54,
      builder: (_) => _NewEventDialog(
        initialDate: day,
        onCreated: () => _loadEvents(),
        parentContext: parentContext,
      ),
    );
  }

  void _showEditEventDialog(BuildContext context, CalendarEvent event) {
    final parentContext = context;
    showDialog(
      context: parentContext,
      useRootNavigator: true,
      barrierColor: Colors.black54,
      builder: (_) => _EditEventDialog(
        event: event,
        onSaved: () => _loadEvents(),
        onDeleted: () => _loadEvents(),
        parentContext: parentContext,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Search result row (used in the overlay dropdown)
// ---------------------------------------------------------------------------

class _SearchResultRow extends StatefulWidget {
  final CalendarEvent event;
  final VoidCallback onTap;

  const _SearchResultRow({required this.event, required this.onTap});

  @override
  State<_SearchResultRow> createState() => _SearchResultRowState();
}

class _SearchResultRowState extends State<_SearchResultRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final event = widget.event;
    final sourceColor = AppColors.colorForSource(event.source);
    final localStart = event.startTime.toLocal();
    final dateStr = DateFormat.MMMd().format(localStart);
    final timeStr = DateFormat.jm().format(localStart);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          color: _hovered
              ? AppColors.accent.withValues(alpha: 0.08)
              : Colors.transparent,
          child: Row(
            children: [
              Container(
                width: 3,
                height: 28,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(1.5),
                  color: sourceColor,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      event.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      '$dateStr \u00B7 $timeStr',
                      style: TextStyle(
                        fontSize: 10,
                        color: AppColors.textTertiary,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
              if (event.inviteeName != null && event.inviteeName!.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: Text(
                    event.inviteeName!,
                    style: TextStyle(
                      fontSize: 10,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
              const SizedBox(width: 4),
              Icon(Icons.arrow_forward_ios_rounded,
                  size: 10, color: AppColors.textTertiary),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Week View
// ---------------------------------------------------------------------------

class _WeekView extends StatefulWidget {
  final DateTime focusDate;
  final List<CalendarEvent> events;
  final ValueChanged<CalendarEvent> onEventTap;
  final ValueChanged<DateTime> onAddEvent;

  const _WeekView({
    required this.focusDate,
    required this.events,
    required this.onEventTap,
    required this.onAddEvent,
  });

  @override
  State<_WeekView> createState() => _WeekViewState();
}

class _WeekViewState extends State<_WeekView> {
  static const _startHour = 0;
  static const _endHour = 23;
  static const _hourHeight = 52.0;

  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToNow());
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToNow() {
    final now = DateTime.now();
    final targetHour = (now.hour - 1).clamp(_startHour, _endHour);
    final offset = (targetHour - _startHour) * _hourHeight;
    if (_scrollController.hasClients) {
      _scrollController.jumpTo(
        offset.clamp(0, _scrollController.position.maxScrollExtent),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final weekStart =
        widget.focusDate.subtract(Duration(days: widget.focusDate.weekday % 7));
    final now = DateTime.now();

    return Column(
      children: [
        // Fixed day-of-week header
        Row(
          children: [
            Container(
              width: 44,
              height: 50,
              decoration: BoxDecoration(
                color: AppColors.surface,
                border: Border(
                  right: BorderSide(
                      color: AppColors.border.withValues(alpha: 0.6),
                      width: 0.5),
                  bottom: BorderSide(
                      color: AppColors.border.withValues(alpha: 0.5),
                      width: 0.5),
                ),
              ),
            ),
            for (var d = 0; d < 7; d++)
              Expanded(
                child: _DayHeader(
                  day: weekStart.add(Duration(days: d)),
                  isToday: _isSameDay(weekStart.add(Duration(days: d)), now),
                  onAddEvent: widget.onAddEvent,
                  showRightBorder: d < 6,
                ),
              ),
          ],
        ),
        // Scrollable time grid
        Expanded(
          child: SingleChildScrollView(
            controller: _scrollController,
            padding: const EdgeInsets.only(bottom: 20),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 44,
                  decoration: BoxDecoration(
                    border: Border(
                      right: BorderSide(
                          color: AppColors.border.withValues(alpha: 0.6),
                          width: 0.5),
                    ),
                  ),
                  child: Column(
                    children: [
                      for (var h = _startHour; h <= _endHour; h++)
                        SizedBox(
                          height: _hourHeight,
                          child: Align(
                            alignment: Alignment.topRight,
                            child: Padding(
                              padding: const EdgeInsets.only(right: 6, top: 0),
                              child: Text(
                                _formatHour(h),
                                style: TextStyle(
                                  fontSize: 12,
                                  color: AppColors.accent,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                for (var d = 0; d < 7; d++)
                  Expanded(
                    child: _DayColumn(
                      day: weekStart.add(Duration(days: d)),
                      events: _eventsForDay(weekStart.add(Duration(days: d))),
                      startHour: _startHour,
                      endHour: _endHour,
                      hourHeight: _hourHeight,
                      isToday:
                          _isSameDay(weekStart.add(Duration(days: d)), now),
                      now: now,
                      onEventTap: widget.onEventTap,
                      onAddEvent: widget.onAddEvent,
                      showRightBorder: d < 6,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  List<CalendarEvent> _eventsForDay(DateTime day) {
    return widget.events.where((e) {
      return _isSameDay(e.startTime.toLocal(), day);
    }).toList();
  }

  static bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  String _formatHour(int h) {
    if (h == 0 || h == 24) return '12a';
    if (h < 12) return '${h}a';
    if (h == 12) return '12p';
    return '${h - 12}p';
  }
}

// Fixed day-of-week header cell (does not scroll)
class _DayHeader extends StatefulWidget {
  final DateTime day;
  final bool isToday;
  final ValueChanged<DateTime> onAddEvent;
  final bool showRightBorder;

  const _DayHeader({
    required this.day,
    required this.isToday,
    required this.onAddEvent,
    this.showRightBorder = false,
  });

  @override
  State<_DayHeader> createState() => _DayHeaderState();
}

class _DayHeaderState extends State<_DayHeader> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final String dayLabel = DateFormat.EEEE().format(widget.day);
    final String dayNum = widget.day.day.toString();

    return Container(
      decoration: widget.showRightBorder
          ? BoxDecoration(
              border: Border(
                right: BorderSide(
                    color: AppColors.border.withValues(alpha: 0.35),
                    width: 0.5),
              ),
            )
          : null,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => widget.onAddEvent(widget.day),
          child: Container(
            height: 50,
            decoration: BoxDecoration(
              color: AppColors.surface,
              border: Border(
                bottom: BorderSide(
                    color: AppColors.border.withValues(alpha: 0.5), width: 0.5),
              ),
            ),
            child: Stack(
              children: [
                Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        dayLabel,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                          color: widget.isToday
                              ? AppColors.textSecondary
                              : AppColors.textTertiary,
                          letterSpacing: 0.2,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Container(
                        width: 26,
                        height: 26,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: widget.isToday
                              ? AppColors.accent
                              : Colors.transparent,
                        ),
                        child: Center(
                          child: Text(
                            dayNum,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: widget.isToday
                                  ? AppColors.onAccent
                                  : AppColors.textSecondary,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (_isHovered)
                  Positioned(
                    right: 2,
                    top: 2,
                    child: AnimatedOpacity(
                      opacity: _isHovered ? 1.0 : 0.0,
                      duration: const Duration(milliseconds: 150),
                      child: Container(
                        width: 22,
                        height: 22,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: AppColors.accent,
                          boxShadow: [
                            BoxShadow(
                              color: AppColors.accent.withValues(alpha: 0.4),
                              blurRadius: 4,
                            ),
                          ],
                        ),
                        child: Icon(
                          Icons.add_rounded,
                          size: 14,
                          color: AppColors.onAccent,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// Scrollable day column (time grid + events only, no header)
class _DayColumn extends StatelessWidget {
  final DateTime day;
  final List<CalendarEvent> events;
  final int startHour;
  final int endHour;
  final double hourHeight;
  final bool isToday;
  final DateTime now;
  final ValueChanged<CalendarEvent> onEventTap;
  final ValueChanged<DateTime> onAddEvent;
  final bool showRightBorder;

  const _DayColumn({
    required this.day,
    required this.events,
    required this.startHour,
    required this.endHour,
    required this.hourHeight,
    required this.isToday,
    required this.now,
    required this.onEventTap,
    required this.onAddEvent,
    this.showRightBorder = false,
  });

  @override
  Widget build(BuildContext context) {
    final double totalHeight = (endHour - startHour + 1) * hourHeight;

    return Container(
      decoration: showRightBorder
          ? BoxDecoration(
              border: Border(
                right: BorderSide(
                    color: AppColors.border.withValues(alpha: 0.35),
                    width: 0.5),
              ),
            )
          : null,
      child: SizedBox(
        height: totalHeight,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: () => onAddEvent(day),
              ),
            ),
            for (var h = startHour; h <= endHour; h++)
              Positioned(
                top: (h - startHour) * hourHeight,
                left: 0,
                right: 0,
                child: Container(
                  height: 0.5,
                  color: AppColors.border.withValues(alpha: 0.5),
                ),
              ),
            if (isToday) _buildNowLine(),
            for (final event in events) _buildEvent(event),
          ],
        ),
      ),
    );
  }

  Widget _buildNowLine() {
    final int minutesFromStart = (now.hour - startHour) * 60 + now.minute;
    final double top = minutesFromStart * hourHeight / 60;
    if (top < 0 || top > (endHour - startHour + 1) * hourHeight) {
      return const SizedBox.shrink();
    }
    const double markerHeight = 14.0;
    return Positioned(
      top: top - markerHeight / 2,
      left: 0,
      right: 0,
      height: markerHeight,
      child: CustomPaint(
        size: Size(double.infinity, markerHeight),
        painter: _NowLinePainter(
          triangleColor: AppColors.hotSignal,
          lineColor: AppColors.accent,
        ),
      ),
    );
  }

  Widget _buildEvent(CalendarEvent event) {
    final DateTime localStart = event.startTime.toLocal();
    final DateTime localEnd = event.endTime.toLocal();
    final int startMin = (localStart.hour - startHour) * 60 + localStart.minute;
    final int endMin = (localEnd.hour - startHour) * 60 + localEnd.minute;
    final double top = startMin * hourHeight / 60;
    final double height =
        ((endMin - startMin).clamp(15, 9999)) * hourHeight / 60;

    final sourceColor = AppColors.colorForSource(event.source);
    final hasContact =
        event.inviteeName != null && event.inviteeName!.isNotEmpty;

    return Positioned(
      top: top.clamp(0, double.infinity),
      left: 1,
      right: 1,
      height: height,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => onEventTap(event),
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 1),
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: sourceColor.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(4),
              border: Border(
                left: BorderSide(color: sourceColor, width: 2.5),
              ),
            ),
            child: Stack(
              children: [
                Padding(
                  padding: EdgeInsets.only(right: hasContact ? 14 : 0),
                  child: Text(
                    event.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.w600,
                      color: sourceColor,
                      height: 1.2,
                    ),
                  ),
                ),
                if (hasContact)
                  Positioned(
                    top: 0,
                    right: 0,
                    child: _SmsQuickButton(event: event, color: sourceColor),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Quick SMS button on event cards
// ---------------------------------------------------------------------------

class _SmsQuickButton extends StatelessWidget {
  final CalendarEvent event;
  final Color color;
  final double size;
  const _SmsQuickButton({
    required this.event,
    required this.color,
    this.size = 14,
  });

  @override
  Widget build(BuildContext context) {
    final iconSize = size * 0.64;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _sendQuickSms(context),
      child: Tooltip(
        message: 'SMS ${event.inviteeName}',
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(size * 0.21),
          ),
          child: Icon(Icons.sms_rounded, size: iconSize, color: color),
        ),
      ),
    );
  }

  Future<void> _sendQuickSms(BuildContext ctx) async {
    final name = event.inviteeName ?? '';
    if (name.isEmpty) return;

    final results = await CallHistoryDb.searchContacts(name);
    final phone = results.isNotEmpty
        ? results.first['phone_number'] as String? ?? ''
        : '';
    if (phone.isEmpty) {
      if (ctx.mounted) {
        ScaffoldMessenger.of(ctx).showSnackBar(
          SnackBar(
            content: Text('No phone number found for $name'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
      return;
    }

    final localStart = event.startTime.toLocal();
    final h = localStart.hour > 12
        ? localStart.hour - 12
        : (localStart.hour == 0 ? 12 : localStart.hour);
    final m = localStart.minute.toString().padLeft(2, '0');
    final ap = localStart.hour >= 12 ? 'PM' : 'AM';
    final dateStr = DateFormat.MMMd().format(localStart);
    final contactName = name.split(' ').first;
    final body = 'Hi $contactName, just a heads up about our '
        'appointment at $h:$m $ap on $dateStr.';

    try {
      final messaging = ctx.read<MessagingService>();
      await messaging.sendMessage(to: phone, text: body);
      if (ctx.mounted) {
        ScaffoldMessenger.of(ctx).showSnackBar(
          SnackBar(
            content: Text('SMS sent to $name'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (_) {
      if (ctx.mounted) {
        ScaffoldMessenger.of(ctx).showSnackBar(
          const SnackBar(content: Text('Failed to send SMS')),
        );
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Day View (single-day time grid, mirrors _WeekView but for one day)
// ---------------------------------------------------------------------------

class _DayView extends StatefulWidget {
  final DateTime focusDate;
  final List<CalendarEvent> events;
  final ValueChanged<CalendarEvent> onEventTap;
  final ValueChanged<DateTime> onAddEvent;

  const _DayView({
    required this.focusDate,
    required this.events,
    required this.onEventTap,
    required this.onAddEvent,
  });

  @override
  State<_DayView> createState() => _DayViewState();
}

class _DayViewState extends State<_DayView> {
  static const _startHour = 0;
  static const _endHour = 23;
  static const _hourHeight = 52.0;

  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToNow());
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToNow() {
    final now = DateTime.now();
    final targetHour = (now.hour - 1).clamp(_startHour, _endHour);
    final offset = (targetHour - _startHour) * _hourHeight;
    if (_scrollController.hasClients) {
      _scrollController.jumpTo(
        offset.clamp(0, _scrollController.position.maxScrollExtent),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final isToday = widget.focusDate.year == now.year &&
        widget.focusDate.month == now.month &&
        widget.focusDate.day == now.day;
    final dayEvents = widget.events.where((e) {
      final s = e.startTime.toLocal();
      return s.year == widget.focusDate.year &&
          s.month == widget.focusDate.month &&
          s.day == widget.focusDate.day;
    }).toList();

    return Column(
      children: [
        Container(
          height: 44,
          decoration: BoxDecoration(
            color: AppColors.surface,
            border: Border(
              bottom: BorderSide(
                  color: AppColors.border.withValues(alpha: 0.5), width: 0.5),
            ),
          ),
          child: Center(
            child: Text(
              DateFormat.EEEE().format(widget.focusDate),
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: isToday ? AppColors.accent : AppColors.textSecondary,
                letterSpacing: 0.2,
              ),
            ),
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            controller: _scrollController,
            padding: const EdgeInsets.only(bottom: 20),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 44,
                  decoration: BoxDecoration(
                    border: Border(
                      right: BorderSide(
                          color: AppColors.border.withValues(alpha: 0.6),
                          width: 0.5),
                    ),
                  ),
                  child: Column(
                    children: [
                      for (var h = _startHour; h <= _endHour; h++)
                        SizedBox(
                          height: _hourHeight,
                          child: Align(
                            alignment: Alignment.topRight,
                            child: Padding(
                              padding: const EdgeInsets.only(right: 6, top: 0),
                              child: Text(
                                _formatHour(h),
                                style: TextStyle(
                                  fontSize: 12,
                                  color: AppColors.accent,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                Expanded(
                  child: _DayColumn(
                    day: widget.focusDate,
                    events: dayEvents,
                    startHour: _startHour,
                    endHour: _endHour,
                    hourHeight: _hourHeight,
                    isToday: isToday,
                    now: now,
                    onEventTap: widget.onEventTap,
                    onAddEvent: widget.onAddEvent,
                    showRightBorder: false,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  String _formatHour(int h) {
    if (h == 0 || h == 24) return '12a';
    if (h < 12) return '${h}a';
    if (h == 12) return '12p';
    return '${h - 12}p';
  }
}

// ---------------------------------------------------------------------------
// Month View
// ---------------------------------------------------------------------------

class _NowLinePainter extends CustomPainter {
  final Color triangleColor;
  final Color lineColor;

  _NowLinePainter({required this.triangleColor, required this.lineColor});

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;

    final midY = size.height / 2;
    final triangleH = size.height;
    final triangleW = triangleH * 1.0;

    // Filled triangle on the left.
    final triPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [triangleColor, lineColor],
      ).createShader(Rect.fromLTWH(0, 0, triangleW, triangleH))
      ..style = PaintingStyle.fill;

    final triangle = Path()
      ..moveTo(0, 0)
      ..lineTo(triangleW, midY)
      ..lineTo(0, triangleH)
      ..close();
    canvas.drawPath(triangle, triPaint);

    // Glow behind triangle.
    final glowPaint = Paint()
      ..color = lineColor.withValues(alpha: 0.5)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
    canvas.drawPath(triangle, glowPaint);

    // Gradient line connected to triangle tip, fading to transparent.
    final lineRect =
        Rect.fromLTRB(triangleW - 0.5, midY - 1.5, size.width, midY + 1.5);
    final linePaint = Paint()
      ..shader = LinearGradient(
        colors: [lineColor, lineColor.withValues(alpha: 0)],
      ).createShader(lineRect)
      ..style = PaintingStyle.fill;
    canvas.drawRect(lineRect, linePaint);
  }

  @override
  bool shouldRepaint(_NowLinePainter old) =>
      old.triangleColor != triangleColor || old.lineColor != lineColor;
}

class _MonthView extends StatelessWidget {
  final DateTime focusDate;
  final List<CalendarEvent> events;
  final ValueChanged<DateTime> onDayTap;
  final ValueChanged<CalendarEvent> onEventTap;
  final ValueChanged<DateTime> onAddEvent;

  const _MonthView({
    required this.focusDate,
    required this.events,
    required this.onDayTap,
    required this.onEventTap,
    required this.onAddEvent,
  });

  @override
  Widget build(BuildContext context) {
    final firstOfMonth = DateTime(focusDate.year, focusDate.month, 1);
    final startWeekday = firstOfMonth.weekday % 7; // 0 = Sun
    final daysInMonth = DateTime(focusDate.year, focusDate.month + 1, 0).day;
    final now = DateTime.now();
    const dayLabels = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];

    final prevMonthDays = DateTime(focusDate.year, focusDate.month, 0).day;
    final totalCells = startWeekday + daysInMonth;
    final rowCount = ((totalCells + 6) ~/ 7);
    final gridCells = rowCount * 7;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Column(
        children: [
          Container(
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                    color: AppColors.border.withValues(alpha: 0.5), width: 0.5),
              ),
            ),
            child: Row(
              children: dayLabels
                  .map((d) => Expanded(
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: Padding(
                            padding: const EdgeInsets.only(
                                top: 6, bottom: 6, right: 6),
                            child: Text(
                              d,
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w500,
                                color: AppColors.textTertiary,
                                letterSpacing: 0.2,
                              ),
                            ),
                          ),
                        ),
                      ))
                  .toList(),
            ),
          ),
          Expanded(
            child: GridView.builder(
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 7,
                childAspectRatio: 1.05,
              ),
              itemCount: gridCells,
              itemBuilder: (context, index) {
                final int dayNum;
                final bool isCurrentMonth;
                final DateTime day;

                if (index < startWeekday) {
                  dayNum = prevMonthDays - startWeekday + index + 1;
                  day = DateTime(focusDate.year, focusDate.month - 1, dayNum);
                  isCurrentMonth = false;
                } else if (index >= startWeekday + daysInMonth) {
                  dayNum = index - startWeekday - daysInMonth + 1;
                  day = DateTime(focusDate.year, focusDate.month + 1, dayNum);
                  isCurrentMonth = false;
                } else {
                  dayNum = index - startWeekday + 1;
                  day = DateTime(focusDate.year, focusDate.month, dayNum);
                  isCurrentMonth = true;
                }

                final isToday = day.year == now.year &&
                    day.month == now.month &&
                    day.day == now.day;
                final dayEvents = events.where((e) {
                  final s = e.startTime.toLocal();
                  return s.year == day.year &&
                      s.month == day.month &&
                      s.day == day.day;
                }).toList();

                final row = index ~/ 7;

                final borderSide = BorderSide(
                  color: AppColors.border.withValues(alpha: 0.4),
                  width: 0.5,
                );

                return Container(
                  decoration: BoxDecoration(
                    border: Border(
                      top: row == 0 ? borderSide : BorderSide.none,
                      left: borderSide,
                      right: borderSide,
                      bottom: borderSide,
                    ),
                  ),
                  child: _MonthDayCell(
                    day: day,
                    dayNum: dayNum,
                    isToday: isToday,
                    isCurrentMonth: isCurrentMonth,
                    events: dayEvents,
                    onTap: () => onDayTap(day),
                    onEventTap: onEventTap,
                    onAdd: () => onAddEvent(day),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _MonthDayCell extends StatefulWidget {
  final DateTime day;
  final int dayNum;
  final bool isToday;
  final bool isCurrentMonth;
  final List<CalendarEvent> events;
  final VoidCallback onTap;
  final ValueChanged<CalendarEvent> onEventTap;
  final VoidCallback onAdd;

  const _MonthDayCell({
    required this.day,
    required this.dayNum,
    required this.isToday,
    required this.isCurrentMonth,
    required this.events,
    required this.onTap,
    required this.onEventTap,
    required this.onAdd,
  });

  @override
  State<_MonthDayCell> createState() => _MonthDayCellState();
}

class _MonthDayCellState extends State<_MonthDayCell> {
  bool _hovered = false;

  static const _maxPills = 5;

  String _shortTime(DateTime dt) {
    final h = dt.hour > 12 ? dt.hour - 12 : (dt.hour == 0 ? 12 : dt.hour);
    final m = dt.minute.toString().padLeft(2, '0');
    final ap = dt.hour >= 12 ? 'p' : 'a';
    return '$h:$m$ap';
  }

  @override
  Widget build(BuildContext context) {
    final visible = widget.events.take(_maxPills).toList();
    final overflow = widget.events.length - _maxPills;
    final dimmed = !widget.isCurrentMonth;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2, left: 2, right: 2),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Align(
                    alignment: Alignment.topRight,
                    child: Padding(
                      padding: const EdgeInsets.only(right: 4, top: 1),
                      child: Text(
                        '${widget.dayNum}',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: widget.isToday
                              ? FontWeight.w600
                              : FontWeight.w300,
                          color: widget.isToday
                              ? AppColors.accent
                              : dimmed
                                  ? AppColors.textTertiary
                                      .withValues(alpha: 0.35)
                                  : AppColors.textSecondary
                                      .withValues(alpha: 0.7),
                          height: 1.1,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 1),
                  for (final ev in visible)
                    _EventPill(
                      event: ev,
                      shortTime: _shortTime,
                      onTap: () => widget.onEventTap(ev),
                    ),
                  if (overflow > 0)
                    Padding(
                      padding: const EdgeInsets.only(left: 2, top: 1),
                      child: Text(
                        '+$overflow more',
                        style: TextStyle(
                          fontSize: 7,
                          color: AppColors.textTertiary,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (_hovered)
              Positioned(
                left: 2,
                top: 3,
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: widget.onAdd,
                    child: Container(
                      width: 20,
                      height: 20,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: AppColors.accent,
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.accent.withValues(alpha: 0.4),
                            blurRadius: 4,
                          ),
                        ],
                      ),
                      child: Icon(
                        Icons.add_rounded,
                        size: 14,
                        color: AppColors.onAccent,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _EventPill extends StatelessWidget {
  final CalendarEvent event;
  final String Function(DateTime) shortTime;
  final VoidCallback? onTap;

  const _EventPill({required this.event, required this.shortTime, this.onTap});

  @override
  Widget build(BuildContext context) {
    final sourceColor = AppColors.colorForSource(event.source);
    final localStart = event.startTime.toLocal();
    final hasContact =
        event.inviteeName != null && event.inviteeName!.isNotEmpty;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          width: double.infinity,
          height: 16,
          margin: const EdgeInsets.only(bottom: 1),
          padding: const EdgeInsets.symmetric(horizontal: 3),
          decoration: BoxDecoration(
            color: sourceColor.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(3),
            border: Border(
              left: BorderSide(color: sourceColor, width: 1.5),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '${shortTime(localStart)} ${event.title}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w600,
                    color: sourceColor,
                    height: 1.1,
                  ),
                ),
              ),
              if (hasContact)
                Padding(
                  padding: const EdgeInsets.only(left: 2),
                  child: _SmsQuickButton(
                    event: event,
                    color: sourceColor,
                    size: 11,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Shared field builder
// ---------------------------------------------------------------------------

Widget _buildField({
  required String label,
  required TextEditingController controller,
  String? hint,
  int maxLines = 1,
  TextInputType? keyboardType,
}) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label.toUpperCase(),
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: AppColors.textTertiary,
          letterSpacing: 0.6,
        ),
      ),
      const SizedBox(height: 5),
      TextField(
        controller: controller,
        maxLines: maxLines,
        keyboardType: keyboardType,
        style: TextStyle(fontSize: 13, color: AppColors.textPrimary),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: TextStyle(
              fontSize: 13,
              color: AppColors.textTertiary.withValues(alpha: 0.6)),
          filled: true,
          fillColor: AppColors.card,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(
                color: AppColors.border.withValues(alpha: 0.5), width: 0.5),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(
                color: AppColors.border.withValues(alpha: 0.5), width: 0.5),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: AppColors.accent, width: 1),
          ),
        ),
      ),
    ],
  );
}

Future<TimeOfDay?> _showQuickTimePicker(
    BuildContext context, TimeOfDay current) async {
  return showDialog<TimeOfDay>(
    context: context,
    builder: (ctx) => _QuickTimeInput(current: current),
  );
}

class _QuickTimeInput extends StatefulWidget {
  final TimeOfDay current;
  const _QuickTimeInput({required this.current});
  @override
  State<_QuickTimeInput> createState() => _QuickTimeInputState();
}

class _QuickTimeInputState extends State<_QuickTimeInput> {
  late final TextEditingController _hourCtrl;
  late final TextEditingController _minCtrl;
  late bool _isAm;
  final _hourFocus = FocusNode();
  final _minFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _hourCtrl = TextEditingController();
    _minCtrl = TextEditingController();
    _isAm = widget.current.period == DayPeriod.am;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _hourFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _hourCtrl.dispose();
    _minCtrl.dispose();
    _hourFocus.dispose();
    _minFocus.dispose();
    super.dispose();
  }

  String get _hourHint {
    final h = widget.current.hourOfPeriod;
    return (h == 0 ? 12 : h).toString();
  }

  String get _minHint => widget.current.minute.toString().padLeft(2, '0');

  void _submit() {
    final hText = _hourCtrl.text.trim();
    final mText = _minCtrl.text.trim();
    final h = hText.isEmpty ? widget.current.hourOfPeriod : int.tryParse(hText);
    final m = mText.isEmpty ? widget.current.minute : int.tryParse(mText);
    if (h == null || m == null || h < 1 || h > 12 || m < 0 || m > 59) {
      return;
    }
    var hour24 = h % 12;
    if (!_isAm) hour24 += 12;
    Navigator.of(context).pop(TimeOfDay(hour: hour24, minute: m));
  }

  InputDecoration _fieldDeco(String hint) => InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w500,
            color: AppColors.textTertiary.withValues(alpha: 0.35)),
        filled: true,
        fillColor: AppColors.card,
        contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(
              color: AppColors.border.withValues(alpha: 0.5), width: 0.5),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(
              color: AppColors.border.withValues(alpha: 0.5), width: 0.5),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: AppColors.accent, width: 1),
        ),
        counterText: '',
      );

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppColors.surface,
      insetPadding: const EdgeInsets.all(0),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: IntrinsicWidth(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Enter time',
                  style: TextStyle(
                      fontSize: 11,
                      color: AppColors.textTertiary,
                      letterSpacing: 0.4)),
              const SizedBox(height: 12),
              Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 50,
                    child: TextField(
                      controller: _hourCtrl,
                      focusNode: _hourFocus,
                      keyboardType: TextInputType.number,
                      textAlign: TextAlign.center,
                      maxLength: 2,
                      style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w500,
                          color: AppColors.textPrimary),
                      decoration: _fieldDeco(_hourHint),
                      onChanged: (v) {
                        if (v.length == 2) _minFocus.requestFocus();
                      },
                      onSubmitted: (_) => _minFocus.requestFocus(),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Text(':',
                        style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textTertiary)),
                  ),
                  SizedBox(
                    width: 50,
                    child: TextField(
                      controller: _minCtrl,
                      focusNode: _minFocus,
                      keyboardType: TextInputType.number,
                      textAlign: TextAlign.center,
                      maxLength: 2,
                      style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w500,
                          color: AppColors.textPrimary),
                      decoration: _fieldDeco(_minHint),
                      onSubmitted: (_) => _submit(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _amPmButton('AM', true),
                      const SizedBox(height: 2),
                      _amPmButton('PM', false),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  HoverButton(
                    onTap: () => Navigator.of(context).pop(),
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                            color: AppColors.border.withValues(alpha: 0.5),
                            width: 0.5),
                      ),
                      child: Text('Cancel',
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: AppColors.textSecondary)),
                    ),
                  ),
                  const SizedBox(width: 8),
                  HoverButton(
                    onTap: _submit,
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 18, vertical: 8),
                      decoration: BoxDecoration(
                        color: AppColors.accent,
                        borderRadius: BorderRadius.circular(8),
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.accent.withValues(alpha: 0.3),
                            blurRadius: 6,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Text('OK',
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: AppColors.onAccent)),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _amPmButton(String text, bool am) {
    final selected = _isAm == am;
    return GestureDetector(
      onTap: () => setState(() => _isAm = am),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: selected ? AppColors.accent.withValues(alpha: 0.2) : null,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: selected
                ? AppColors.accent
                : AppColors.border.withValues(alpha: 0.4),
            width: 0.5,
          ),
        ),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 11,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            color: selected ? AppColors.accent : AppColors.textTertiary,
          ),
        ),
      ),
    );
  }
}

Widget _buildTimeSelector({
  required String label,
  required TimeOfDay value,
  required BuildContext context,
  required ValueChanged<TimeOfDay> onChanged,
}) {
  final formatted = value.format(context);
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label.toUpperCase(),
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: AppColors.textTertiary,
          letterSpacing: 0.6,
        ),
      ),
      const SizedBox(height: 5),
      HoverButton(
        onTap: () async {
          final picked = await _showQuickTimePicker(context, value);
          if (picked != null) onChanged(picked);
        },
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
                color: AppColors.border.withValues(alpha: 0.5), width: 0.5),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  formatted,
                  style: TextStyle(fontSize: 13, color: AppColors.textPrimary),
                ),
              ),
              Icon(Icons.schedule_rounded,
                  size: 14, color: AppColors.textTertiary),
            ],
          ),
        ),
      ),
    ],
  );
}

Widget _buildDateSelector({
  required String label,
  required DateTime value,
  required BuildContext context,
  required ValueChanged<DateTime> onChanged,
}) {
  final formatted = DateFormat.yMMMd().format(value);
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label.toUpperCase(),
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: AppColors.textTertiary,
          letterSpacing: 0.6,
        ),
      ),
      const SizedBox(height: 5),
      HoverButton(
        onTap: () async {
          final picked = await showDatePicker(
            context: context,
            initialDate: value,
            firstDate: DateTime(2020),
            lastDate: DateTime(2030),
            builder: (ctx, child) {
              return Theme(
                data: Theme.of(ctx).copyWith(
                  colorScheme: ColorScheme.dark(
                    primary: AppColors.accent,
                    surface: AppColors.surface,
                    onSurface: AppColors.textPrimary,
                  ),
                ),
                child: child!,
              );
            },
          );
          if (picked != null) onChanged(picked);
        },
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
                color: AppColors.border.withValues(alpha: 0.5), width: 0.5),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  formatted,
                  style: TextStyle(fontSize: 13, color: AppColors.textPrimary),
                ),
              ),
              Icon(Icons.calendar_today_rounded,
                  size: 14, color: AppColors.textTertiary),
            ],
          ),
        ),
      ),
    ],
  );
}

// ---------------------------------------------------------------------------
// New Event Dialog
// ---------------------------------------------------------------------------

class _NewEventDialog extends StatefulWidget {
  final DateTime initialDate;
  final VoidCallback onCreated;
  final BuildContext parentContext;

  const _NewEventDialog({
    required this.initialDate,
    required this.onCreated,
    required this.parentContext,
  });

  @override
  State<_NewEventDialog> createState() => _NewEventDialogState();
}

class _NewEventDialogState extends State<_NewEventDialog> {
  final _titleCtrl = TextEditingController(text: 'New Meeting');
  final _nameCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  final _locationCtrl = TextEditingController();
  final _nameFocus = FocusNode();

  late DateTime _date;
  late TimeOfDay _startTime;
  late TimeOfDay _endTime;
  int? _selectedJfId;
  late bool _syncToCalendly;
  late bool _syncToGoogle;
  bool _notifyRecipient = true;
  bool _isSaving = false;

  List<Map<String, dynamic>> _searchResults = [];
  bool _showSearchResults = false;
  Timer? _searchDebounce;

  @override
  void initState() {
    super.initState();
    _date = widget.initialDate;
    final now = TimeOfDay.now();
    _startTime = TimeOfDay(hour: now.hour + 1, minute: 0);
    _endTime = TimeOfDay(hour: now.hour + 1, minute: 30);
    final sync = widget.parentContext.read<CalendarSyncService>();
    final gcal = widget.parentContext.read<GoogleCalendarService>();
    _syncToCalendly = sync.hasCalendly;
    _syncToGoogle = gcal.config.enabled;
    _nameFocus.addListener(_onNameFocusChanged);
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    _emailCtrl.dispose();
    _descCtrl.dispose();
    _locationCtrl.dispose();
    _nameFocus.removeListener(_onNameFocusChanged);
    _nameFocus.dispose();
    _searchDebounce?.cancel();
    super.dispose();
  }

  String _fmtTime(TimeOfDay t) {
    final h = t.hourOfPeriod == 0 ? 12 : t.hourOfPeriod;
    final m = t.minute.toString().padLeft(2, '0');
    final p = t.period == DayPeriod.am ? 'a' : 'p';
    return '$h:$m$p';
  }

  void _onNameFocusChanged() {
    if (_nameFocus.hasFocus) {
      _runContactSearch(_nameCtrl.text);
    } else {
      Future.delayed(const Duration(milliseconds: 150), () {
        if (mounted && !_nameFocus.hasFocus) {
          setState(() => _showSearchResults = false);
        }
      });
    }
  }

  void _onNameChanged(String query) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 200), () {
      _runContactSearch(query);
    });
  }

  Future<void> _runContactSearch(String query) async {
    if (query.trim().length < 2) {
      if (_showSearchResults) {
        setState(() {
          _searchResults = [];
          _showSearchResults = false;
        });
      }
      return;
    }
    final results = await CallHistoryDb.searchContacts(query);
    if (mounted) {
      setState(() {
        _searchResults = results;
        _showSearchResults = results.isNotEmpty;
      });
    }
  }

  void _selectContact(Map<String, dynamic> contact) {
    setState(() {
      _nameCtrl.text = contact['display_name'] as String? ?? '';
      _phoneCtrl.text = contact['phone_number'] as String? ?? '';
      _emailCtrl.text = contact['email'] as String? ?? '';
      _searchResults = [];
      _showSearchResults = false;
    });
  }

  Widget _buildContactField() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'CONTACT',
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w600,
            color: AppColors.textTertiary,
            letterSpacing: 0.6,
          ),
        ),
        const SizedBox(height: 5),
        _buildMiniField(
          icon: Icons.person_search_rounded,
          controller: _nameCtrl,
          hint: 'Search contacts...',
          onChanged: _onNameChanged,
          focusNode: _nameFocus,
        ),
        if (_showSearchResults)
          Container(
            constraints: const BoxConstraints(maxHeight: 140),
            margin: const EdgeInsets.only(top: 4),
            decoration: BoxDecoration(
              color: AppColors.card,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                  color: AppColors.border.withValues(alpha: 0.5), width: 0.5),
            ),
            child: ListView.builder(
              padding: EdgeInsets.zero,
              shrinkWrap: true,
              itemCount: _searchResults.length,
              itemBuilder: (_, i) {
                final c = _searchResults[i];
                final cName = c['display_name'] as String? ?? '';
                final cPhone = c['phone_number'] as String? ?? '';
                return InkWell(
                  onTap: () => _selectContact(c),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    child: Row(
                      children: [
                        Icon(Icons.person_outline_rounded,
                            size: 14, color: AppColors.textTertiary),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                cName,
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: AppColors.textPrimary,
                                ),
                              ),
                              if (cPhone.isNotEmpty)
                                Text(
                                  cPhone,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: AppColors.textTertiary,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        const SizedBox(height: 6),
        _buildMiniField(
          icon: Icons.phone_rounded,
          controller: _phoneCtrl,
          hint: 'Phone',
        ),
        const SizedBox(height: 6),
        _buildMiniField(
          icon: Icons.email_outlined,
          controller: _emailCtrl,
          hint: 'Email',
        ),
      ],
    );
  }

  Widget _buildMiniField({
    required IconData icon,
    required TextEditingController controller,
    required String hint,
    ValueChanged<String>? onChanged,
    FocusNode? focusNode,
  }) {
    return TextField(
      controller: controller,
      onChanged: onChanged,
      focusNode: focusNode,
      style: TextStyle(fontSize: 12, color: AppColors.textPrimary),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(
            fontSize: 12, color: AppColors.textTertiary.withValues(alpha: 0.5)),
        prefixIcon: Icon(icon, size: 14, color: AppColors.textTertiary),
        prefixIconConstraints: const BoxConstraints(minWidth: 32),
        filled: true,
        fillColor: AppColors.card,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(7),
          borderSide: BorderSide(
              color: AppColors.border.withValues(alpha: 0.4), width: 0.5),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(7),
          borderSide: BorderSide(
              color: AppColors.border.withValues(alpha: 0.4), width: 0.5),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(7),
          borderSide: BorderSide(color: AppColors.accent, width: 1),
        ),
      ),
    );
  }

  Future<void> _create() async {
    if (_titleCtrl.text.trim().isEmpty) return;
    setState(() => _isSaving = true);

    final name = _nameCtrl.text.trim();
    final phone = _phoneCtrl.text.trim();
    final email = _emailCtrl.text.trim();

    final start = DateTime(
      _date.year,
      _date.month,
      _date.day,
      _startTime.hour,
      _startTime.minute,
    ).toUtc();
    final end = DateTime(
      _date.year,
      _date.month,
      _date.day,
      _endTime.hour,
      _endTime.minute,
    ).toUtc();

    final event = CalendarEvent(
      title: _titleCtrl.text.trim(),
      startTime: start,
      endTime: end,
      inviteeName: name.isEmpty ? null : name,
      inviteeEmail: email.isEmpty ? null : email,
      description: _descCtrl.text.trim().isEmpty ? null : _descCtrl.text.trim(),
      location:
          _locationCtrl.text.trim().isEmpty ? null : _locationCtrl.text.trim(),
      jobFunctionId: _selectedJfId,
      status: 'active',
      createdAt: DateTime.now().toUtc(),
    );

    final localId = await CallHistoryDb.insertCalendarEvent(event);

    // Save contact if name or phone provided
    if (name.isNotEmpty || phone.isNotEmpty) {
      final lookupPhone = phone.isNotEmpty ? phone : null;
      final existing = lookupPhone != null
          ? await CallHistoryDb.getContactByPhone(lookupPhone)
          : null;
      if (existing == null) {
        await CallHistoryDb.insertContact(
          displayName: name.isNotEmpty ? name : 'Unknown',
          phoneNumber: phone,
          email: email.isEmpty ? null : email,
        );
      }
    }

    // Sync to Calendly
    if (_syncToCalendly && mounted) {
      final sync = widget.parentContext.read<CalendarSyncService>();
      if (sync.hasCalendly && sync.calendlyService != null) {
        try {
          final eventTypes = await sync.calendlyService!.listEventTypes();
          if (eventTypes.isNotEmpty) {
            if (_notifyRecipient && email.isNotEmpty) {
              // Create invitee -- Calendly sends notification to recipient
              final calendlyUri = await sync.calendlyService!.createInvitee(
                eventTypeUri: eventTypes.first.uri,
                startTime: start,
                inviteeName: name.isEmpty ? 'Guest' : name,
                inviteeEmail: email,
              );
              if (calendlyUri != null) {
                await CallHistoryDb.updateCalendarEvent(
                  event.copyWith(
                    id: localId,
                    calendlyEventId: calendlyUri,
                    source: EventSource.calendly,
                  ),
                );
              }
            } else {
              // Create scheduling link without notifying
              final link = await sync.calendlyService!.createSchedulingLink(
                eventTypeUri: eventTypes.first.uri,
              );
              if (link != null) {
                await CallHistoryDb.updateCalendarEvent(
                  event.copyWith(
                    id: localId,
                    description: event.description != null
                        ? '${event.description}\nScheduling link: $link'
                        : 'Scheduling link: $link',
                    source: EventSource.calendly,
                  ),
                );
              }
            }
          }
        } catch (_) {}
        await sync.syncNow();
      }
    }

    // Sync to Google Calendar — ensure 'Calendly' calendar exists
    if (_syncToGoogle && mounted) {
      try {
        final gcal = widget.parentContext.read<GoogleCalendarService>();
        final dateStr =
            '${_date.year}-${_date.month.toString().padLeft(2, '0')}-${_date.day.toString().padLeft(2, '0')}';
        final startStr =
            '${_startTime.hour.toString().padLeft(2, '0')}:${_startTime.minute.toString().padLeft(2, '0')}';
        final endStr =
            '${_endTime.hour.toString().padLeft(2, '0')}:${_endTime.minute.toString().padLeft(2, '0')}';

        var calendars = await gcal.listCalendars();
        var calendlyCalendar = calendars
            .where((c) => (c['name'] ?? '').toLowerCase().contains('calendly'))
            .toList();

        if (calendlyCalendar.isEmpty) {
          await gcal.createCalendar(name: 'Calendly');
          calendars = await gcal.listCalendars();
          calendlyCalendar = calendars
              .where(
                  (c) => (c['name'] ?? '').toLowerCase().contains('calendly'))
              .toList();
        }
        final calId =
            calendlyCalendar.isNotEmpty ? calendlyCalendar.first['id'] : null;

        final ok = await gcal.createEvent(
          title: _titleCtrl.text.trim(),
          date: dateStr,
          startTime: startStr,
          endTime: endStr,
          description: _descCtrl.text.trim(),
          location: _locationCtrl.text.trim(),
          calendarId: calId,
        );
        if (ok) {
          final gcalId = GoogleCalendarService.gcalCompositeId(
              _titleCtrl.text.trim(), dateStr, startStr);
          await CallHistoryDb.updateCalendarEvent(
            event.copyWith(
              id: localId,
              googleCalendarEventId: gcalId,
            ),
          );
        }
      } catch (_) {}
    }

    // SMS the contact about the new event
    if (_notifyRecipient && phone.isNotEmpty && mounted) {
      try {
        final messaging = widget.parentContext.read<MessagingService>();
        final contactName = name.isNotEmpty ? name : 'there';
        final body = 'Hi $contactName, you have an appointment on '
            '${DateFormat.MMMd().format(_date)} at '
            '${_fmtTime(_startTime)}.';
        await messaging.sendMessage(to: phone, text: body);
      } catch (_) {}
    }

    // Schedule a 15-minute reminder linked to this calendar event so the
    // firing logic can validate the event still exists / hasn't ended yet
    // and so calendar reschedules can re-align the reminder automatically.
    if (start.isAfter(DateTime.now().toUtc()) && mounted) {
      try {
        final remindAt = start.subtract(const Duration(minutes: 15));
        await CallHistoryDb.insertReminder(
          title: _titleCtrl.text.trim(),
          description: name.isNotEmpty ? 'Meeting with $name' : null,
          remindAt: remindAt,
          source: 'calendar',
          calendarEventId: localId,
          contactPhone: phone.isNotEmpty ? phone : null,
        );
        widget.parentContext
            .read<ManagerPresenceService>()
            .onReminderCreatedOrChanged();
      } catch (_) {}
    }

    widget.onCreated();
    if (mounted) Navigator.of(context).pop();
  }

  Widget _syncCheckbox({
    required String label,
    required bool value,
    required Color color,
    required VoidCallback onTap,
    IconData? icon,
  }) {
    return HoverButton(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: value ? color.withValues(alpha: 0.1) : AppColors.card,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: value
                ? color.withValues(alpha: 0.4)
                : AppColors.border.withValues(alpha: 0.5),
            width: 0.5,
          ),
        ),
        child: Row(
          children: [
            if (icon != null) ...[
              Icon(icon,
                  size: 14, color: value ? color : AppColors.textTertiary),
              const SizedBox(width: 6),
            ] else ...[
              Container(
                width: 16,
                height: 16,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(3),
                  color: value ? color : Colors.transparent,
                  border: Border.all(
                    color: value ? color : AppColors.textTertiary,
                    width: 1.5,
                  ),
                ),
                child: value
                    ? Icon(Icons.check_rounded,
                        size: 12, color: AppColors.onAccent)
                    : null,
              ),
              const SizedBox(width: 8),
            ],
            Flexible(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: value ? color : AppColors.textSecondary,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pCtx = widget.parentContext;
    final sync = pCtx.watch<CalendarSyncService>();
    final gcalService = pCtx.watch<GoogleCalendarService>();
    final jfService = pCtx.read<JobFunctionService>();

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 420),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.border, width: 0.5),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.5),
              blurRadius: 24,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header
            Container(
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 16),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                      color: AppColors.border.withValues(alpha: 0.5),
                      width: 0.5),
                ),
              ),
              child: Row(
                children: [
                  Icon(Icons.event_rounded, size: 18, color: AppColors.accent),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'New Meeting',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary,
                        letterSpacing: -0.3,
                      ),
                    ),
                  ),
                  HoverButton(
                    onTap: () => Navigator.of(context).pop(),
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        color: AppColors.card,
                      ),
                      child: Icon(Icons.close_rounded,
                          size: 14, color: AppColors.textTertiary),
                    ),
                  ),
                ],
              ),
            ),
            // Body
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildField(
                      label: 'Title',
                      controller: _titleCtrl,
                      hint: 'Meeting title',
                    ),
                    const SizedBox(height: 14),
                    _buildDateSelector(
                      label: 'Date',
                      value: _date,
                      context: context,
                      onChanged: (d) => setState(() => _date = d),
                    ),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        Expanded(
                          child: _buildTimeSelector(
                            label: 'Start',
                            value: _startTime,
                            context: context,
                            onChanged: (t) => setState(() {
                              _startTime = t;
                              final mins = t.hour * 60 + t.minute + 30;
                              _endTime = TimeOfDay(
                                  hour: (mins ~/ 60) % 24, minute: mins % 60);
                            }),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _buildTimeSelector(
                            label: 'End',
                            value: _endTime,
                            context: context,
                            onChanged: (t) => setState(() => _endTime = t),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    _buildContactField(),
                    const SizedBox(height: 14),
                    _buildField(
                      label: 'Description',
                      controller: _descCtrl,
                      hint: 'Optional notes',
                      maxLines: 2,
                    ),
                    const SizedBox(height: 10),
                    _buildField(
                      label: 'Location',
                      controller: _locationCtrl,
                      hint: 'Optional location',
                    ),
                    const SizedBox(height: 14),
                    // Job function
                    Text(
                      'JOB FUNCTION',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textTertiary,
                        letterSpacing: 0.6,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        color: AppColors.card,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                            color: AppColors.border.withValues(alpha: 0.5),
                            width: 0.5),
                      ),
                      child: DropdownButton<int?>(
                        value: _selectedJfId,
                        isExpanded: true,
                        underline: const SizedBox.shrink(),
                        dropdownColor: AppColors.card,
                        style: TextStyle(
                            fontSize: 13, color: AppColors.textPrimary),
                        icon: Icon(Icons.unfold_more_rounded,
                            size: 16, color: AppColors.textTertiary),
                        hint: Text('None',
                            style: TextStyle(
                                fontSize: 13, color: AppColors.textTertiary)),
                        items: [
                          DropdownMenuItem<int?>(
                            value: null,
                            child: Text('None',
                                style:
                                    TextStyle(color: AppColors.textTertiary)),
                          ),
                          ...jfService.items.map((jf) {
                            final id = (jf as dynamic).id as int?;
                            final name = (jf as dynamic).title as String;
                            return DropdownMenuItem<int?>(
                              value: id,
                              child: Text(name),
                            );
                          }),
                        ],
                        onChanged: (v) => setState(() => _selectedJfId = v),
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                ),
              ),
            ),
            // Footer: checkboxes + buttons
            Container(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(
                      color: AppColors.border.withValues(alpha: 0.5),
                      width: 0.5),
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'SYNC',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textTertiary,
                        letterSpacing: 0.6,
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      if (sync.hasCalendly) ...[
                        Expanded(
                          child: _syncCheckbox(
                            label: 'Calendly',
                            value: _syncToCalendly,
                            color:
                                AppColors.colorForSource(EventSource.calendly),
                            onTap: () => setState(
                                () => _syncToCalendly = !_syncToCalendly),
                          ),
                        ),
                        const SizedBox(width: 8),
                      ],
                      if (gcalService.config.enabled) ...[
                        Expanded(
                          child: _syncCheckbox(
                            label: 'Google',
                            value: _syncToGoogle,
                            color: AppColors.colorForSource(EventSource.google),
                            onTap: () =>
                                setState(() => _syncToGoogle = !_syncToGoogle),
                          ),
                        ),
                        const SizedBox(width: 8),
                      ],
                      Expanded(
                        child: _syncCheckbox(
                          label: 'SMS Contact',
                          value: _notifyRecipient,
                          color: AppColors.accent,
                          icon: Icons.sms_rounded,
                          onTap: () => setState(
                              () => _notifyRecipient = !_notifyRecipient),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  // Action buttons
                  Row(
                    children: [
                      Expanded(
                        child: HoverButton(
                          onTap: () => Navigator.of(context).pop(),
                          borderRadius: BorderRadius.circular(8),
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                  color:
                                      AppColors.border.withValues(alpha: 0.5),
                                  width: 0.5),
                            ),
                            child: Center(
                              child: Text(
                                'Cancel',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: AppColors.textSecondary,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: HoverButton(
                          onTap: _isSaving ? null : _create,
                          borderRadius: BorderRadius.circular(8),
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            decoration: BoxDecoration(
                              color: AppColors.accent,
                              borderRadius: BorderRadius.circular(8),
                              boxShadow: [
                                BoxShadow(
                                  color:
                                      AppColors.accent.withValues(alpha: 0.3),
                                  blurRadius: 8,
                                  offset: const Offset(0, 2),
                                ),
                              ],
                            ),
                            child: Center(
                              child: _isSaving
                                  ? SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: AppColors.onAccent,
                                      ),
                                    )
                                  : Text(
                                      'Create',
                                      style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                        color: AppColors.onAccent,
                                      ),
                                    ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Edit Event Dialog
// ---------------------------------------------------------------------------

class _EditEventDialog extends StatefulWidget {
  final CalendarEvent event;
  final VoidCallback onSaved;
  final VoidCallback onDeleted;
  final BuildContext parentContext;

  const _EditEventDialog({
    required this.event,
    required this.onSaved,
    required this.onDeleted,
    required this.parentContext,
  });

  @override
  State<_EditEventDialog> createState() => _EditEventDialogState();
}

class _EditEventDialogState extends State<_EditEventDialog> {
  late final TextEditingController _titleCtrl;
  late final TextEditingController _nameCtrl;
  late final TextEditingController _phoneCtrl;
  late final TextEditingController _emailCtrl;
  late final TextEditingController _descCtrl;
  late final TextEditingController _locationCtrl;
  final _nameFocus = FocusNode();

  late DateTime _date;
  late TimeOfDay _startTime;
  late TimeOfDay _endTime;
  late final TimeOfDay _origStartTime;
  late final TimeOfDay _origEndTime;
  late int? _selectedJfId;
  bool _isSaving = false;
  bool _confirmDelete = false;
  late bool _syncToCalendly;
  late bool _syncToGoogle;
  bool _notifyRecipient = false;

  List<Map<String, dynamic>> _searchResults = [];
  bool _showSearchResults = false;
  Timer? _searchDebounce;

  @override
  void initState() {
    super.initState();
    final e = widget.event;
    final sl = e.startTime.toLocal();
    final el = e.endTime.toLocal();
    _titleCtrl = TextEditingController(text: e.title);
    _nameCtrl = TextEditingController(text: e.inviteeName ?? '');
    _phoneCtrl = TextEditingController();
    _emailCtrl = TextEditingController(text: e.inviteeEmail ?? '');
    _descCtrl = TextEditingController(text: e.description ?? '');
    _locationCtrl = TextEditingController(text: e.location ?? '');
    _date = DateTime(sl.year, sl.month, sl.day);
    _startTime = TimeOfDay(hour: sl.hour, minute: sl.minute);
    _endTime = TimeOfDay(hour: el.hour, minute: el.minute);
    _origStartTime = _startTime;
    _origEndTime = _endTime;
    _lookupContactPhone();
    _selectedJfId = e.jobFunctionId;
    final sync = widget.parentContext.read<CalendarSyncService>();
    final gcal = widget.parentContext.read<GoogleCalendarService>();
    _syncToCalendly = sync.hasCalendly;
    _syncToGoogle = gcal.config.enabled;
    _nameFocus.addListener(_onNameFocusChanged);
  }

  Future<void> _lookupContactPhone() async {
    final name = _nameCtrl.text;
    final email = _emailCtrl.text;
    if (name.isEmpty && email.isEmpty) return;
    final query = name.isNotEmpty ? name : email;
    final results = await CallHistoryDb.searchContacts(query);
    if (!mounted || results.isEmpty) return;
    final phone = results.first['phone_number'] as String? ?? '';
    if (phone.isNotEmpty && _phoneCtrl.text.isEmpty) {
      setState(() => _phoneCtrl.text = phone);
    }
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    _emailCtrl.dispose();
    _descCtrl.dispose();
    _locationCtrl.dispose();
    _nameFocus.removeListener(_onNameFocusChanged);
    _nameFocus.dispose();
    _searchDebounce?.cancel();
    super.dispose();
  }

  void _onNameFocusChanged() {
    if (_nameFocus.hasFocus) {
      _runContactSearch(_nameCtrl.text);
    } else {
      Future.delayed(const Duration(milliseconds: 150), () {
        if (mounted && !_nameFocus.hasFocus) {
          setState(() => _showSearchResults = false);
        }
      });
    }
  }

  void _onNameChanged(String query) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 200), () {
      _runContactSearch(query);
    });
  }

  Future<void> _runContactSearch(String query) async {
    if (query.trim().length < 2) {
      if (_showSearchResults) {
        setState(() {
          _searchResults = [];
          _showSearchResults = false;
        });
      }
      return;
    }
    final results = await CallHistoryDb.searchContacts(query);
    if (mounted) {
      setState(() {
        _searchResults = results;
        _showSearchResults = results.isNotEmpty;
      });
    }
  }

  void _selectContact(Map<String, dynamic> contact) {
    setState(() {
      _nameCtrl.text = contact['display_name'] as String? ?? '';
      _phoneCtrl.text = contact['phone_number'] as String? ?? '';
      _emailCtrl.text = contact['email'] as String? ?? '';
      _searchResults = [];
      _showSearchResults = false;
    });
  }

  Widget _buildContactField() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'CONTACT',
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w600,
            color: AppColors.textTertiary,
            letterSpacing: 0.6,
          ),
        ),
        const SizedBox(height: 5),
        _buildMiniField(
          icon: Icons.person_search_rounded,
          controller: _nameCtrl,
          hint: 'Search contacts...',
          onChanged: _onNameChanged,
          focusNode: _nameFocus,
        ),
        if (_showSearchResults)
          Container(
            constraints: const BoxConstraints(maxHeight: 140),
            margin: const EdgeInsets.only(top: 4),
            decoration: BoxDecoration(
              color: AppColors.card,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                  color: AppColors.border.withValues(alpha: 0.5), width: 0.5),
            ),
            child: ListView.builder(
              padding: EdgeInsets.zero,
              shrinkWrap: true,
              itemCount: _searchResults.length,
              itemBuilder: (_, i) {
                final c = _searchResults[i];
                final cName = c['display_name'] as String? ?? '';
                final cPhone = c['phone_number'] as String? ?? '';
                return InkWell(
                  onTap: () => _selectContact(c),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    child: Row(
                      children: [
                        Icon(Icons.person_outline_rounded,
                            size: 14, color: AppColors.textTertiary),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                cName,
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: AppColors.textPrimary,
                                ),
                              ),
                              if (cPhone.isNotEmpty)
                                Text(
                                  cPhone,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: AppColors.textTertiary,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        const SizedBox(height: 6),
        _buildMiniField(
          icon: Icons.phone_rounded,
          controller: _phoneCtrl,
          hint: 'Phone',
        ),
        const SizedBox(height: 6),
        _buildMiniField(
          icon: Icons.email_outlined,
          controller: _emailCtrl,
          hint: 'Email',
        ),
      ],
    );
  }

  Widget _buildMiniField({
    required IconData icon,
    required TextEditingController controller,
    required String hint,
    ValueChanged<String>? onChanged,
    FocusNode? focusNode,
  }) {
    return TextField(
      controller: controller,
      onChanged: onChanged,
      focusNode: focusNode,
      style: TextStyle(fontSize: 12, color: AppColors.textPrimary),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(
            fontSize: 12, color: AppColors.textTertiary.withValues(alpha: 0.5)),
        prefixIcon: Icon(icon, size: 14, color: AppColors.textTertiary),
        prefixIconConstraints: const BoxConstraints(minWidth: 32),
        filled: true,
        fillColor: AppColors.card,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(7),
          borderSide: BorderSide(
              color: AppColors.border.withValues(alpha: 0.4), width: 0.5),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(7),
          borderSide: BorderSide(
              color: AppColors.border.withValues(alpha: 0.4), width: 0.5),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(7),
          borderSide: BorderSide(color: AppColors.accent, width: 1),
        ),
      ),
    );
  }

  bool get _timeChanged =>
      _startTime != _origStartTime || _endTime != _origEndTime;

  String _fmtTime(TimeOfDay t) {
    final h = t.hourOfPeriod == 0 ? 12 : t.hourOfPeriod;
    final m = t.minute.toString().padLeft(2, '0');
    final p = t.period == DayPeriod.am ? 'a' : 'p';
    return '$h:$m$p';
  }

  String get _smsLabel {
    if (!_timeChanged) return 'SMS Contact';
    return 'SMS Contact  ${_fmtTime(_origStartTime)} → ${_fmtTime(_startTime)}';
  }

  Widget _syncCheckbox({
    required String label,
    required bool value,
    required Color color,
    required VoidCallback onTap,
    IconData? icon,
  }) {
    return HoverButton(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: value ? color.withValues(alpha: 0.1) : AppColors.card,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: value
                ? color.withValues(alpha: 0.4)
                : AppColors.border.withValues(alpha: 0.5),
            width: 0.5,
          ),
        ),
        child: Row(
          children: [
            if (icon != null) ...[
              Icon(icon,
                  size: 14, color: value ? color : AppColors.textTertiary),
              const SizedBox(width: 6),
            ] else ...[
              Container(
                width: 16,
                height: 16,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(3),
                  color: value ? color : Colors.transparent,
                  border: Border.all(
                    color: value ? color : AppColors.textTertiary,
                    width: 1.5,
                  ),
                ),
                child: value
                    ? Icon(Icons.check_rounded,
                        size: 12, color: AppColors.onAccent)
                    : null,
              ),
              const SizedBox(width: 8),
            ],
            Flexible(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: value ? color : AppColors.textSecondary,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _save() async {
    if (_titleCtrl.text.trim().isEmpty) return;
    setState(() => _isSaving = true);

    final name = _nameCtrl.text.trim();
    final phone = _phoneCtrl.text.trim();
    final email = _emailCtrl.text.trim();
    final evt = widget.event;

    final start = DateTime(
      _date.year,
      _date.month,
      _date.day,
      _startTime.hour,
      _startTime.minute,
    ).toUtc();
    final end = DateTime(
      _date.year,
      _date.month,
      _date.day,
      _endTime.hour,
      _endTime.minute,
    ).toUtc();

    final updated = evt.copyWith(
      title: _titleCtrl.text.trim(),
      startTime: start,
      endTime: end,
      inviteeName: name.isEmpty ? null : name,
      inviteeEmail: email.isEmpty ? null : email,
      description: _descCtrl.text.trim().isEmpty ? null : _descCtrl.text.trim(),
      location:
          _locationCtrl.text.trim().isEmpty ? null : _locationCtrl.text.trim(),
      jobFunctionId: _selectedJfId,
    );

    await CallHistoryDb.updateCalendarEvent(updated, markLocallyModified: true);

    // ── Update or create contact in DB ──
    if (name.isNotEmpty || phone.isNotEmpty || email.isNotEmpty) {
      try {
        final query = name.isNotEmpty ? name : email;
        final existing = query.isNotEmpty
            ? await CallHistoryDb.searchContacts(query)
            : <Map<String, dynamic>>[];

        if (existing.isNotEmpty) {
          final contactId = existing.first['id'] as int;
          final updates = <String, dynamic>{};
          if (phone.isNotEmpty) updates['phone_number'] = phone;
          if (email.isNotEmpty) updates['email'] = email;
          if (name.isNotEmpty) updates['display_name'] = name;
          if (updates.isNotEmpty) {
            await CallHistoryDb.updateContact(contactId, updates);
          }
        } else if (name.isNotEmpty) {
          await CallHistoryDb.insertContact(
            displayName: name,
            phoneNumber: phone,
            email: email.isEmpty ? null : email,
          );
        }
      } catch (_) {}
    }

    // ── Calendly sync ──
    // For existing Calendly events: cancel the old booking, then re-invite
    // at the new time so the invitee gets notified of the change.
    // For local events: create a new Calendly booking.
    if (_syncToCalendly && mounted) {
      final syncSvc = widget.parentContext.read<CalendarSyncService>();
      if (syncSvc.hasCalendly && syncSvc.calendlyService != null) {
        try {
          if (evt.calendlyEventId != null) {
            await syncSvc.calendlyService!.cancelEvent(
              evt.calendlyEventId!,
              reason: 'Rescheduled via Phonegentic',
            );
          }
          final eventTypes = await syncSvc.calendlyService!.listEventTypes();
          if (eventTypes.isNotEmpty && email.isNotEmpty) {
            final calendlyUri = await syncSvc.calendlyService!.createInvitee(
              eventTypeUri: eventTypes.first.uri,
              startTime: start,
              inviteeName: name.isEmpty ? 'Guest' : name,
              inviteeEmail: email,
            );
            if (calendlyUri != null) {
              await CallHistoryDb.updateCalendarEvent(
                updated.copyWith(
                  calendlyEventId: calendlyUri,
                  source: EventSource.calendly,
                ),
              );
            }
          } else if (eventTypes.isNotEmpty) {
            final link = await syncSvc.calendlyService!.createSchedulingLink(
              eventTypeUri: eventTypes.first.uri,
            );
            if (link != null) {
              await CallHistoryDb.updateCalendarEvent(
                updated.copyWith(
                  description: updated.description != null
                      ? '${updated.description}\nScheduling link: $link'
                      : 'Scheduling link: $link',
                  source: EventSource.calendly,
                ),
              );
            }
          }
        } catch (_) {}
        await syncSvc.syncNow();
      }
    }

    // ── Google Calendar sync ──
    // Ensure the 'Calendly' calendar exists; create it if missing.
    // Push new events or re-push updated ones.
    if (_syncToGoogle && mounted) {
      try {
        final gcal = widget.parentContext.read<GoogleCalendarService>();
        final dateStr =
            '${_date.year}-${_date.month.toString().padLeft(2, '0')}-${_date.day.toString().padLeft(2, '0')}';
        final startStr =
            '${_startTime.hour.toString().padLeft(2, '0')}:${_startTime.minute.toString().padLeft(2, '0')}';
        final endStr =
            '${_endTime.hour.toString().padLeft(2, '0')}:${_endTime.minute.toString().padLeft(2, '0')}';

        var calendars = await gcal.listCalendars();
        var calendlyCalendar = calendars
            .where((c) => (c['name'] ?? '').toLowerCase().contains('calendly'))
            .toList();

        if (calendlyCalendar.isEmpty) {
          await gcal.createCalendar(name: 'Calendly');
          calendars = await gcal.listCalendars();
          calendlyCalendar = calendars
              .where(
                  (c) => (c['name'] ?? '').toLowerCase().contains('calendly'))
              .toList();
        }
        final calId =
            calendlyCalendar.isNotEmpty ? calendlyCalendar.first['id'] : null;

        final ok = await gcal.createEvent(
          title: _titleCtrl.text.trim(),
          date: dateStr,
          startTime: startStr,
          endTime: endStr,
          calendarId: calId,
        );
        if (ok) {
          final gcalId = GoogleCalendarService.gcalCompositeId(
              _titleCtrl.text.trim(), dateStr, startStr);
          await CallHistoryDb.updateCalendarEvent(
            updated.copyWith(googleCalendarEventId: gcalId),
          );
        }
      } catch (_) {}
    }

    // ── SMS the contact about the change ──
    if (_notifyRecipient && phone.isNotEmpty && mounted) {
      try {
        final messaging = widget.parentContext.read<MessagingService>();
        final contactName = name.isNotEmpty ? name : 'there';
        String body;
        if (_timeChanged) {
          body = 'Hi $contactName, your appointment has been '
              'rescheduled from ${_fmtTime(_origStartTime)} to '
              '${_fmtTime(_startTime)} on '
              '${DateFormat.MMMd().format(_date)}.';
        } else {
          body = 'Hi $contactName, your appointment on '
              '${DateFormat.MMMd().format(_date)} at '
              '${_fmtTime(_startTime)} has been updated.';
        }
        await messaging.sendMessage(to: phone, text: body);
      } catch (_) {}
    }

    // ── Realign the existing 15-minute reminder for this event ──
    // If the event was rescheduled, find the linked pending reminder and
    // move it to the new time rather than creating a duplicate. Falls back
    // to insert if no linked reminder exists yet (older events from before
    // calendar_event_id was tracked).
    if (_timeChanged && start.isAfter(DateTime.now().toUtc()) && mounted) {
      try {
        final remindAt = start.subtract(const Duration(minutes: 15));
        final eventId = widget.event.id;
        Map<String, dynamic>? existing;
        if (eventId != null) {
          existing =
              await CallHistoryDb.getPendingReminderForCalendarEvent(eventId);
        }
        if (existing != null) {
          await CallHistoryDb.updateReminderRemindAt(
              existing['id'] as int, remindAt);
        } else {
          await CallHistoryDb.insertReminder(
            title: _titleCtrl.text.trim(),
            description: name.isNotEmpty ? 'Meeting with $name' : null,
            remindAt: remindAt,
            source: 'calendar',
            calendarEventId: eventId,
            contactPhone: phone.isNotEmpty ? phone : null,
          );
        }
        widget.parentContext
            .read<ManagerPresenceService>()
            .onReminderCreatedOrChanged();
      } catch (_) {}
    }

    widget.onSaved();
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _delete() async {
    if (!_confirmDelete) {
      setState(() => _confirmDelete = true);
      Future.delayed(const Duration(seconds: 3), () {
        if (mounted) setState(() => _confirmDelete = false);
      });
      return;
    }
    await CallHistoryDb.deleteCalendarEvent(widget.event.id!);
    widget.onDeleted();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final pCtx = widget.parentContext;
    final sync = pCtx.watch<CalendarSyncService>();
    final gcalService = pCtx.watch<GoogleCalendarService>();
    final jfService = pCtx.read<JobFunctionService>();

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 420),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.border, width: 0.5),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.5),
              blurRadius: 24,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header
            Container(
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 16),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                      color: AppColors.border.withValues(alpha: 0.5),
                      width: 0.5),
                ),
              ),
              child: Row(
                children: [
                  Icon(Icons.edit_calendar_rounded,
                      size: 18, color: AppColors.accent),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Edit Event',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary,
                        letterSpacing: -0.3,
                      ),
                    ),
                  ),
                  HoverButton(
                    onTap: () => Navigator.of(context).pop(),
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        color: AppColors.card,
                      ),
                      child: Icon(Icons.close_rounded,
                          size: 14, color: AppColors.textTertiary),
                    ),
                  ),
                ],
              ),
            ),
            // Body
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildField(
                      label: 'Title',
                      controller: _titleCtrl,
                      hint: 'Meeting title',
                    ),
                    const SizedBox(height: 14),
                    _buildDateSelector(
                      label: 'Date',
                      value: _date,
                      context: context,
                      onChanged: (d) => setState(() => _date = d),
                    ),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        Expanded(
                          child: _buildTimeSelector(
                            label: 'Start',
                            value: _startTime,
                            context: context,
                            onChanged: (t) => setState(() {
                              _startTime = t;
                              final mins = t.hour * 60 + t.minute + 30;
                              _endTime = TimeOfDay(
                                  hour: (mins ~/ 60) % 24, minute: mins % 60);
                            }),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _buildTimeSelector(
                            label: 'End',
                            value: _endTime,
                            context: context,
                            onChanged: (t) => setState(() => _endTime = t),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    _buildContactField(),
                    const SizedBox(height: 14),
                    _buildField(
                      label: 'Description',
                      controller: _descCtrl,
                      hint: 'Optional notes',
                      maxLines: 2,
                    ),
                    const SizedBox(height: 10),
                    _buildField(
                      label: 'Location',
                      controller: _locationCtrl,
                      hint: 'Optional location',
                    ),
                    const SizedBox(height: 14),
                    // Job function
                    Text(
                      'JOB FUNCTION',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textTertiary,
                        letterSpacing: 0.6,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        color: AppColors.card,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                            color: AppColors.border.withValues(alpha: 0.5),
                            width: 0.5),
                      ),
                      child: DropdownButton<int?>(
                        value: _selectedJfId,
                        isExpanded: true,
                        underline: const SizedBox.shrink(),
                        dropdownColor: AppColors.card,
                        style: TextStyle(
                            fontSize: 13, color: AppColors.textPrimary),
                        icon: Icon(Icons.unfold_more_rounded,
                            size: 16, color: AppColors.textTertiary),
                        hint: Text('None',
                            style: TextStyle(
                                fontSize: 13, color: AppColors.textTertiary)),
                        items: [
                          DropdownMenuItem<int?>(
                            value: null,
                            child: Text('None',
                                style:
                                    TextStyle(color: AppColors.textTertiary)),
                          ),
                          ...jfService.items.map((jf) {
                            final id = (jf as dynamic).id as int?;
                            final name = (jf as dynamic).title as String;
                            return DropdownMenuItem<int?>(
                              value: id,
                              child: Text(name),
                            );
                          }),
                        ],
                        onChanged: (v) => setState(() => _selectedJfId = v),
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                ),
              ),
            ),
            // Footer
            Container(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(
                      color: AppColors.border.withValues(alpha: 0.5),
                      width: 0.5),
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'SYNC',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textTertiary,
                        letterSpacing: 0.6,
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      if (sync.hasCalendly) ...[
                        Expanded(
                          child: _syncCheckbox(
                            label: 'Calendly',
                            value: _syncToCalendly,
                            color:
                                AppColors.colorForSource(EventSource.calendly),
                            onTap: () => setState(
                                () => _syncToCalendly = !_syncToCalendly),
                          ),
                        ),
                        const SizedBox(width: 8),
                      ],
                      if (gcalService.config.enabled) ...[
                        Expanded(
                          child: _syncCheckbox(
                            label: 'Google',
                            value: _syncToGoogle,
                            color: AppColors.colorForSource(EventSource.google),
                            onTap: () =>
                                setState(() => _syncToGoogle = !_syncToGoogle),
                          ),
                        ),
                        const SizedBox(width: 8),
                      ],
                      Expanded(
                        child: _syncCheckbox(
                          label: _smsLabel,
                          value: _notifyRecipient,
                          color: AppColors.accent,
                          icon: Icons.sms_rounded,
                          onTap: () => setState(
                              () => _notifyRecipient = !_notifyRecipient),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      // Delete
                      HoverButton(
                        onTap: _delete,
                        borderRadius: BorderRadius.circular(8),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 10),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(8),
                            color: _confirmDelete
                                ? AppColors.red.withValues(alpha: 0.15)
                                : Colors.transparent,
                            border: Border.all(
                              color: _confirmDelete
                                  ? AppColors.red
                                  : AppColors.red.withValues(alpha: 0.4),
                              width: 0.5,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.delete_outline_rounded,
                                  size: 14,
                                  color: _confirmDelete
                                      ? AppColors.red
                                      : AppColors.red.withValues(alpha: 0.7)),
                              const SizedBox(width: 4),
                              Text(
                                _confirmDelete ? 'Confirm' : 'Delete',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: _confirmDelete
                                      ? AppColors.red
                                      : AppColors.red.withValues(alpha: 0.7),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const Spacer(),
                      // Cancel
                      HoverButton(
                        onTap: () => Navigator.of(context).pop(),
                        borderRadius: BorderRadius.circular(8),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 10),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                                color: AppColors.border.withValues(alpha: 0.5),
                                width: 0.5),
                          ),
                          child: Text(
                            'Cancel',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: AppColors.textSecondary,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      // Save
                      HoverButton(
                        onTap: _isSaving ? null : _save,
                        borderRadius: BorderRadius.circular(8),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 20, vertical: 10),
                          decoration: BoxDecoration(
                            color: AppColors.accent,
                            borderRadius: BorderRadius.circular(8),
                            boxShadow: [
                              BoxShadow(
                                color: AppColors.accent.withValues(alpha: 0.3),
                                blurRadius: 8,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                          child: _isSaving
                              ? SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: AppColors.onAccent,
                                  ),
                                )
                              : Text(
                                  'Save',
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: AppColors.onAccent,
                                  ),
                                ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Setup Guidance Card
// ---------------------------------------------------------------------------

class _SetupGuidanceCard extends StatelessWidget {
  final VoidCallback onClose;

  const _SetupGuidanceCard({required this.onClose});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Center(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 360),
          margin: const EdgeInsets.symmetric(horizontal: 24),
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.border, width: 0.5),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.calendar_month_rounded,
                  size: 36, color: AppColors.textTertiary),
              const SizedBox(height: 16),
              Text(
                'Connect Your Calendars',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                  letterSpacing: -0.3,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Link Calendly and Google Calendar to see all your meetings in one place.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  color: AppColors.textSecondary,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 24),
              _integrationRow(
                icon: Icons.event_available_rounded,
                color: AppColors.colorForSource(EventSource.calendly),
                label: 'Calendly',
                sublabel: 'API key in Settings > User',
              ),
              const SizedBox(height: 12),
              _integrationRow(
                icon: Icons.public_rounded,
                color: AppColors.colorForSource(EventSource.google),
                label: 'Google Calendar',
                sublabel: 'Chrome debug in Settings > User',
              ),
              const SizedBox(height: 20),
              Text(
                'You can also create events directly using the + button on any day.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 11,
                  color: AppColors.textTertiary,
                  height: 1.3,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _integrationRow({
    required IconData icon,
    required Color color,
    required String label,
    required String sublabel,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.25), width: 0.5),
      ),
      child: Row(
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color.withValues(alpha: 0.15),
            ),
            child: Icon(icon, size: 14, color: color),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: color,
                  ),
                ),
                Text(
                  sublabel,
                  style: TextStyle(
                    fontSize: 10,
                    color: AppColors.textTertiary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
