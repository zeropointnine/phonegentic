import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../calendar_sync_service.dart';
import '../db/call_history_db.dart';
import '../job_function_service.dart';
import '../models/calendar_event.dart';
import '../theme_provider.dart';

enum _CalendarView { week, month }

class CalendarPanel extends StatefulWidget {
  const CalendarPanel({super.key});

  @override
  State<CalendarPanel> createState() => _CalendarPanelState();
}

class _CalendarPanelState extends State<CalendarPanel> {
  _CalendarView _view = _CalendarView.week;
  late DateTime _focusDate;
  List<CalendarEvent> _events = [];

  @override
  void initState() {
    super.initState();
    _focusDate = DateTime.now();
    _syncAndLoad();
  }

  Future<void> _syncAndLoad() async {
    final sync = context.read<CalendarSyncService>();
    await sync.syncNow();
    _loadEvents();
  }

  Future<void> _loadEvents() async {
    final range = _currentRange;
    final events =
        await CallHistoryDb.getEventsBetween(range[0], range[1]);
    if (mounted) setState(() => _events = events);
  }

  List<DateTime> get _currentRange {
    if (_view == _CalendarView.week) {
      final weekStart =
          _focusDate.subtract(Duration(days: _focusDate.weekday % 7));
      final start = DateTime.utc(weekStart.year, weekStart.month, weekStart.day);
      return [start, start.add(const Duration(days: 7))];
    } else {
      final start = DateTime.utc(_focusDate.year, _focusDate.month, 1);
      return [start, DateTime.utc(_focusDate.year, _focusDate.month + 1, 1)];
    }
  }

  void _navigate(int delta) {
    setState(() {
      if (_view == _CalendarView.week) {
        _focusDate = _focusDate.add(Duration(days: 7 * delta));
      } else {
        _focusDate =
            DateTime(_focusDate.year, _focusDate.month + delta, 1);
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
      _view = _CalendarView.week;
    });
    _loadEvents();
  }

  @override
  Widget build(BuildContext context) {
    final syncService = context.watch<CalendarSyncService>();
    return Container(
      color: AppColors.bg,
      child: SafeArea(
        child: Column(
          children: [
            _buildHeader(syncService),
            _buildViewToggle(),
            Expanded(
              child: _view == _CalendarView.week
                  ? _WeekView(
                      focusDate: _focusDate,
                      events: _events,
                      onEventTap: (e) => _showEditEventDialog(context, e),
                      onAddEvent: (day) => _showNewEventDialog(context, day),
                    )
                  : _MonthView(
                      focusDate: _focusDate,
                      events: _events,
                      onDayTap: _goToDay,
                      onAddEvent: (day) => _showNewEventDialog(context, day),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(CalendarSyncService sync) {
    final title = _view == _CalendarView.week
        ? _weekTitle()
        : DateFormat.yMMMM().format(_focusDate);

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 28, 8, 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border:
            Border(bottom: BorderSide(color: AppColors.border, width: 0.5)),
      ),
      child: Row(
        children: [
          Icon(Icons.calendar_month_rounded,
              size: 18, color: AppColors.accent),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              title,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
                letterSpacing: -0.3,
              ),
            ),
          ),
          _navButton(Icons.chevron_left_rounded, () => _navigate(-1)),
          const SizedBox(width: 2),
          _navButton(Icons.today_rounded, () {
            setState(() => _focusDate = DateTime.now());
            _loadEvents();
          }),
          const SizedBox(width: 2),
          _navButton(Icons.chevron_right_rounded, () => _navigate(1)),
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
          _viewChip('Week', _CalendarView.week),
          const SizedBox(width: 8),
          _viewChip('Month', _CalendarView.month),
        ],
      ),
    );
  }

  Widget _viewChip(String label, _CalendarView v) {
    final selected = _view == v;
    return HoverButton(
      onTap: () => _switchView(v),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? AppColors.accent : AppColors.card,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected
                ? AppColors.accent
                : AppColors.border.withValues(alpha: 0.5),
            width: 0.5,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: selected ? AppColors.onAccent : AppColors.textSecondary,
          ),
        ),
      ),
    );
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
              height: 40,
              decoration: BoxDecoration(
                color: AppColors.surface,
                border: Border(
                  right: BorderSide(
                      color: AppColors.border.withValues(alpha: 0.6), width: 0.5),
                  bottom: BorderSide(
                      color: AppColors.border.withValues(alpha: 0.5), width: 0.5),
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
                          color: AppColors.border.withValues(alpha: 0.6), width: 0.5),
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
                      isToday: _isSameDay(weekStart.add(Duration(days: d)), now),
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
    final String dayLabel = DateFormat.E().format(widget.day).substring(0, 2);
    final String dayNum = widget.day.day.toString();

    return Container(
      decoration: widget.showRightBorder
          ? BoxDecoration(
              border: Border(
                right: BorderSide(
                    color: AppColors.border.withValues(alpha: 0.35), width: 0.5),
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
            height: 40,
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
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: widget.isToday
                              ? AppColors.accent
                              : AppColors.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 1),
                      Container(
                        width: 22,
                        height: 22,
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
                              fontSize: 11,
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
                        width: 18,
                        height: 18,
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
                          size: 12,
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
                    color: AppColors.border.withValues(alpha: 0.35), width: 0.5),
              ),
            )
          : null,
      child: SizedBox(
        height: totalHeight,
        child: Stack(
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
    final int minutesFromStart =
        (now.hour - startHour) * 60 + now.minute;
    final double top = minutesFromStart * hourHeight / 60;
    if (top < 0 ||
        top > (endHour - startHour + 1) * hourHeight) {
      return const SizedBox.shrink();
    }
    return Positioned(
      top: top,
      left: 0,
      right: 0,
      child: Container(
        height: 1.5,
        decoration: BoxDecoration(
          color: AppColors.accent,
          boxShadow: [
            BoxShadow(
              color: AppColors.accent.withValues(alpha: 0.4),
              blurRadius: 3,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEvent(CalendarEvent event) {
    final DateTime localStart = event.startTime.toLocal();
    final DateTime localEnd = event.endTime.toLocal();
    final int startMin =
        (localStart.hour - startHour) * 60 + localStart.minute;
    final int endMin = (localEnd.hour - startHour) * 60 + localEnd.minute;
    final double top = startMin * hourHeight / 60;
    final double height =
        ((endMin - startMin).clamp(15, 9999)) * hourHeight / 60;

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
              color: AppColors.accent.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(
                  color: AppColors.accent.withValues(alpha: 0.35), width: 0.5),
            ),
            child: Text(
              event.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w600,
                color: AppColors.accent,
                height: 1.2,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Month View
// ---------------------------------------------------------------------------

class _MonthView extends StatelessWidget {
  final DateTime focusDate;
  final List<CalendarEvent> events;
  final ValueChanged<DateTime> onDayTap;
  final ValueChanged<DateTime> onAddEvent;

  const _MonthView({
    required this.focusDate,
    required this.events,
    required this.onDayTap,
    required this.onAddEvent,
  });

  @override
  Widget build(BuildContext context) {
    final firstOfMonth = DateTime(focusDate.year, focusDate.month, 1);
    final startWeekday = firstOfMonth.weekday % 7;
    final daysInMonth =
        DateTime(focusDate.year, focusDate.month + 1, 0).day;
    final now = DateTime.now();
    final dayLabels = ['Su', 'Mo', 'Tu', 'We', 'Th', 'Fr', 'Sa'];

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Column(
        children: [
          Container(
            decoration: BoxDecoration(
              color: AppColors.surface,
              border: Border(
                bottom: BorderSide(
                    color: AppColors.border.withValues(alpha: 0.5), width: 0.5),
              ),
            ),
            child: Row(
              children: dayLabels
                  .map((d) => Expanded(
                        child: Center(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Text(
                              d,
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                color: AppColors.textSecondary,
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
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 7,
                childAspectRatio: 1.0,
              ),
              itemCount: startWeekday + daysInMonth,
              itemBuilder: (context, index) {
                if (index < startWeekday) return const SizedBox.shrink();
                final dayNum = index - startWeekday + 1;
                final day = DateTime(
                    focusDate.year, focusDate.month, dayNum);
                final isToday = day.year == now.year &&
                    day.month == now.month &&
                    day.day == now.day;
                final dayEvents = events.where((e) {
                  final s = e.startTime.toLocal();
                  return s.year == day.year &&
                      s.month == day.month &&
                      s.day == day.day;
                }).toList();

                return _MonthDayCell(
                  day: day,
                  dayNum: dayNum,
                  isToday: isToday,
                  eventCount: dayEvents.length,
                  onTap: () => onDayTap(day),
                  onAdd: () => onAddEvent(day),
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
  final int eventCount;
  final VoidCallback onTap;
  final VoidCallback onAdd;

  const _MonthDayCell({
    required this.day,
    required this.dayNum,
    required this.isToday,
    required this.eventCount,
    required this.onTap,
    required this.onAdd,
  });

  @override
  State<_MonthDayCell> createState() => _MonthDayCellState();
}

class _MonthDayCellState extends State<_MonthDayCell> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          margin: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            color: widget.isToday
                ? AppColors.accent.withValues(alpha: 0.12)
                : Colors.transparent,
          ),
          child: Stack(
            children: [
              Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      '${widget.dayNum}',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: widget.isToday
                            ? FontWeight.w700
                            : FontWeight.w500,
                        color: widget.isToday
                            ? AppColors.accent
                            : AppColors.textPrimary,
                      ),
                    ),
                    if (widget.eventCount > 0) ...[
                      const SizedBox(height: 3),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          for (var i = 0;
                              i < widget.eventCount.clamp(0, 3);
                              i++)
                            Container(
                              width: 4,
                              height: 4,
                              margin: const EdgeInsets.symmetric(
                                  horizontal: 1),
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: AppColors.accent,
                              ),
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              if (_hovered)
                Positioned(
                  right: 2,
                  top: 2,
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      onTap: widget.onAdd,
                      child: Container(
                        width: 16,
                        height: 16,
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
                          size: 11,
                          color: AppColors.onAccent,
                        ),
                      ),
                    ),
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
              fontSize: 13, color: AppColors.textTertiary.withValues(alpha: 0.6)),
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
          final picked = await showTimePicker(
            context: context,
            initialTime: value,
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
                  style: TextStyle(
                      fontSize: 13, color: AppColors.textPrimary),
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
                  style: TextStyle(
                      fontSize: 13, color: AppColors.textPrimary),
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
  final _searchCtrl = TextEditingController();

  late DateTime _date;
  late TimeOfDay _startTime;
  late TimeOfDay _endTime;
  int? _selectedJfId;
  bool _syncToCalendly = false;
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
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    _emailCtrl.dispose();
    _descCtrl.dispose();
    _locationCtrl.dispose();
    _searchCtrl.dispose();
    _searchDebounce?.cancel();
    super.dispose();
  }

  void _onSearchChanged(String query) {
    _searchDebounce?.cancel();
    if (query.trim().isEmpty) {
      setState(() {
        _searchResults = [];
        _showSearchResults = false;
      });
      return;
    }
    _searchDebounce = Timer(const Duration(milliseconds: 250), () async {
      final results = await CallHistoryDb.searchContacts(query);
      if (mounted) {
        setState(() {
          _searchResults = results;
          _showSearchResults = results.isNotEmpty;
        });
      }
    });
  }

  void _selectContact(Map<String, dynamic> contact) {
    _nameCtrl.text = contact['display_name'] as String? ?? '';
    _phoneCtrl.text = contact['phone_number'] as String? ?? '';
    _emailCtrl.text = contact['email'] as String? ?? '';
    _searchCtrl.clear();
    setState(() {
      _searchResults = [];
      _showSearchResults = false;
    });
  }

  Future<void> _create() async {
    if (_titleCtrl.text.trim().isEmpty) return;
    setState(() => _isSaving = true);

    final start = DateTime(
      _date.year, _date.month, _date.day,
      _startTime.hour, _startTime.minute,
    ).toUtc();
    final end = DateTime(
      _date.year, _date.month, _date.day,
      _endTime.hour, _endTime.minute,
    ).toUtc();

    final event = CalendarEvent(
      title: _titleCtrl.text.trim(),
      startTime: start,
      endTime: end,
      inviteeName: _nameCtrl.text.trim().isEmpty
          ? null
          : _nameCtrl.text.trim(),
      inviteeEmail: _emailCtrl.text.trim().isEmpty
          ? null
          : _emailCtrl.text.trim(),
      description: _descCtrl.text.trim().isEmpty
          ? null
          : _descCtrl.text.trim(),
      location: _locationCtrl.text.trim().isEmpty
          ? null
          : _locationCtrl.text.trim(),
      jobFunctionId: _selectedJfId,
      status: 'active',
      createdAt: DateTime.now().toUtc(),
    );

    final localId = await CallHistoryDb.insertCalendarEvent(event);

    if (_syncToCalendly && mounted) {
      final sync = widget.parentContext.read<CalendarSyncService>();
      if (sync.hasCalendly && sync.calendlyService != null) {
        try {
          final eventTypes = await sync.calendlyService!.listEventTypes();
          if (eventTypes.isNotEmpty) {
            final calendlyUri = await sync.calendlyService!.createInvitee(
              eventTypeUri: eventTypes.first.uri,
              startTime: start,
              inviteeName: _nameCtrl.text.trim().isEmpty
                  ? 'Guest'
                  : _nameCtrl.text.trim(),
              inviteeEmail: _emailCtrl.text.trim().isEmpty
                  ? 'guest@example.com'
                  : _emailCtrl.text.trim(),
            );
            if (calendlyUri != null) {
              await CallHistoryDb.updateCalendarEvent(
                event.copyWith(
                    id: localId, calendlyEventId: calendlyUri),
              );
            }
          }
        } catch (_) {}
        await sync.syncNow();
      }
    }

    widget.onCreated();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final pCtx = widget.parentContext;
    final sync = pCtx.watch<CalendarSyncService>();
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
                      color: AppColors.border.withValues(alpha: 0.5), width: 0.5),
                ),
              ),
              child: Row(
                children: [
                  Icon(Icons.event_rounded,
                      size: 18, color: AppColors.accent),
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
                            onChanged: (t) =>
                                setState(() => _startTime = t),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _buildTimeSelector(
                            label: 'End',
                            value: _endTime,
                            context: context,
                            onChanged: (t) =>
                                setState(() => _endTime = t),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    // Contact search
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
                    TextField(
                      controller: _searchCtrl,
                      onChanged: _onSearchChanged,
                      style: TextStyle(
                          fontSize: 13, color: AppColors.textPrimary),
                      decoration: InputDecoration(
                        hintText: 'Search contacts...',
                        hintStyle: TextStyle(
                            fontSize: 13,
                            color: AppColors.textTertiary.withValues(alpha: 0.6)),
                        prefixIcon: Icon(Icons.search_rounded,
                            size: 16, color: AppColors.textTertiary),
                        prefixIconConstraints:
                            const BoxConstraints(minWidth: 36),
                        filled: true,
                        fillColor: AppColors.card,
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 10),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide(
                              color: AppColors.border.withValues(alpha: 0.5),
                              width: 0.5),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide(
                              color: AppColors.border.withValues(alpha: 0.5),
                              width: 0.5),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide(
                              color: AppColors.accent, width: 1),
                        ),
                      ),
                    ),
                    if (_showSearchResults)
                      Container(
                        constraints:
                            const BoxConstraints(maxHeight: 140),
                        margin: const EdgeInsets.only(top: 4),
                        decoration: BoxDecoration(
                          color: AppColors.card,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                              color: AppColors.border.withValues(alpha: 0.5),
                              width: 0.5),
                        ),
                        child: ListView.builder(
                          padding: EdgeInsets.zero,
                          shrinkWrap: true,
                          itemCount: _searchResults.length,
                          itemBuilder: (_, i) {
                            final c = _searchResults[i];
                            final name =
                                c['display_name'] as String? ?? '';
                            final phone =
                                c['phone_number'] as String? ?? '';
                            return InkWell(
                              onTap: () => _selectContact(c),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 8),
                                child: Row(
                                  children: [
                                    Icon(Icons.person_outline_rounded,
                                        size: 14,
                                        color: AppColors.textTertiary),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            name,
                                            style: TextStyle(
                                              fontSize: 12,
                                              fontWeight: FontWeight.w600,
                                              color:
                                                  AppColors.textPrimary,
                                            ),
                                          ),
                                          if (phone.isNotEmpty)
                                            Text(
                                              phone,
                                              style: TextStyle(
                                                fontSize: 11,
                                                color: AppColors
                                                    .textTertiary,
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
                    const SizedBox(height: 10),
                    _buildField(
                      label: 'Name',
                      controller: _nameCtrl,
                      hint: 'Invitee name',
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: _buildField(
                            label: 'Phone',
                            controller: _phoneCtrl,
                            hint: '+1 555-123-4567',
                            keyboardType: TextInputType.phone,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _buildField(
                            label: 'Email',
                            controller: _emailCtrl,
                            hint: 'email@example.com',
                            keyboardType: TextInputType.emailAddress,
                          ),
                        ),
                      ],
                    ),
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
                      padding:
                          const EdgeInsets.symmetric(horizontal: 12),
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
                            fontSize: 13,
                            color: AppColors.textPrimary),
                        icon: Icon(Icons.unfold_more_rounded,
                            size: 16, color: AppColors.textTertiary),
                        hint: Text('None',
                            style: TextStyle(
                                fontSize: 13,
                                color: AppColors.textTertiary)),
                        items: [
                          DropdownMenuItem<int?>(
                            value: null,
                            child: Text('None',
                                style: TextStyle(
                                    color: AppColors.textTertiary)),
                          ),
                          ...jfService.items.map((jf) {
                            final id = (jf as dynamic).id as int?;
                            final name =
                                (jf as dynamic).title as String;
                            return DropdownMenuItem<int?>(
                              value: id,
                              child: Text(name),
                            );
                          }),
                        ],
                        onChanged: (v) =>
                            setState(() => _selectedJfId = v),
                      ),
                    ),
                    // Calendly sync
                    if (sync.hasCalendly) ...[
                      const SizedBox(height: 14),
                      HoverButton(
                        onTap: () => setState(
                            () => _syncToCalendly = !_syncToCalendly),
                        borderRadius: BorderRadius.circular(8),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 10),
                          decoration: BoxDecoration(
                            color: _syncToCalendly
                                ? AppColors.accent.withValues(alpha: 0.1)
                                : AppColors.card,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: _syncToCalendly
                                  ? AppColors.accent.withValues(alpha: 0.4)
                                  : AppColors.border.withValues(alpha: 0.5),
                              width: 0.5,
                            ),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                _syncToCalendly
                                    ? Icons.check_circle_rounded
                                    : Icons.circle_outlined,
                                size: 16,
                                color: _syncToCalendly
                                    ? AppColors.accent
                                    : AppColors.textTertiary,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                'Sync to Calendly',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: _syncToCalendly
                                      ? AppColors.accent
                                      : AppColors.textSecondary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
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
              child: Row(
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
                              color: AppColors.border.withValues(alpha: 0.5),
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
                              color: AppColors.accent.withValues(alpha: 0.3),
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
  final _searchCtrl = TextEditingController();

  late DateTime _date;
  late TimeOfDay _startTime;
  late TimeOfDay _endTime;
  late int? _selectedJfId;
  bool _isSaving = false;
  bool _confirmDelete = false;

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
    _selectedJfId = e.jobFunctionId;
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    _emailCtrl.dispose();
    _descCtrl.dispose();
    _locationCtrl.dispose();
    _searchCtrl.dispose();
    _searchDebounce?.cancel();
    super.dispose();
  }

  void _onSearchChanged(String query) {
    _searchDebounce?.cancel();
    if (query.trim().isEmpty) {
      setState(() {
        _searchResults = [];
        _showSearchResults = false;
      });
      return;
    }
    _searchDebounce = Timer(const Duration(milliseconds: 250), () async {
      final results = await CallHistoryDb.searchContacts(query);
      if (mounted) {
        setState(() {
          _searchResults = results;
          _showSearchResults = results.isNotEmpty;
        });
      }
    });
  }

  void _selectContact(Map<String, dynamic> contact) {
    _nameCtrl.text = contact['display_name'] as String? ?? '';
    _phoneCtrl.text = contact['phone_number'] as String? ?? '';
    _emailCtrl.text = contact['email'] as String? ?? '';
    _searchCtrl.clear();
    setState(() {
      _searchResults = [];
      _showSearchResults = false;
    });
  }

  Future<void> _save() async {
    if (_titleCtrl.text.trim().isEmpty) return;
    setState(() => _isSaving = true);

    final start = DateTime(
      _date.year, _date.month, _date.day,
      _startTime.hour, _startTime.minute,
    ).toUtc();
    final end = DateTime(
      _date.year, _date.month, _date.day,
      _endTime.hour, _endTime.minute,
    ).toUtc();

    final updated = widget.event.copyWith(
      title: _titleCtrl.text.trim(),
      startTime: start,
      endTime: end,
      inviteeName: _nameCtrl.text.trim().isEmpty
          ? null
          : _nameCtrl.text.trim(),
      inviteeEmail: _emailCtrl.text.trim().isEmpty
          ? null
          : _emailCtrl.text.trim(),
      description: _descCtrl.text.trim().isEmpty
          ? null
          : _descCtrl.text.trim(),
      location: _locationCtrl.text.trim().isEmpty
          ? null
          : _locationCtrl.text.trim(),
      jobFunctionId: _selectedJfId,
    );

    await CallHistoryDb.updateCalendarEvent(updated);
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
    final jfService = widget.parentContext.read<JobFunctionService>();

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
                      color: AppColors.border.withValues(alpha: 0.5), width: 0.5),
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
                            onChanged: (t) =>
                                setState(() => _startTime = t),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _buildTimeSelector(
                            label: 'End',
                            value: _endTime,
                            context: context,
                            onChanged: (t) =>
                                setState(() => _endTime = t),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    // Contact search
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
                    TextField(
                      controller: _searchCtrl,
                      onChanged: _onSearchChanged,
                      style: TextStyle(
                          fontSize: 13, color: AppColors.textPrimary),
                      decoration: InputDecoration(
                        hintText: 'Search contacts...',
                        hintStyle: TextStyle(
                            fontSize: 13,
                            color: AppColors.textTertiary.withValues(alpha: 0.6)),
                        prefixIcon: Icon(Icons.search_rounded,
                            size: 16, color: AppColors.textTertiary),
                        prefixIconConstraints:
                            const BoxConstraints(minWidth: 36),
                        filled: true,
                        fillColor: AppColors.card,
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 10),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide(
                              color: AppColors.border.withValues(alpha: 0.5),
                              width: 0.5),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide(
                              color: AppColors.border.withValues(alpha: 0.5),
                              width: 0.5),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide(
                              color: AppColors.accent, width: 1),
                        ),
                      ),
                    ),
                    if (_showSearchResults)
                      Container(
                        constraints:
                            const BoxConstraints(maxHeight: 140),
                        margin: const EdgeInsets.only(top: 4),
                        decoration: BoxDecoration(
                          color: AppColors.card,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                              color: AppColors.border.withValues(alpha: 0.5),
                              width: 0.5),
                        ),
                        child: ListView.builder(
                          padding: EdgeInsets.zero,
                          shrinkWrap: true,
                          itemCount: _searchResults.length,
                          itemBuilder: (_, i) {
                            final c = _searchResults[i];
                            final name =
                                c['display_name'] as String? ?? '';
                            final phone =
                                c['phone_number'] as String? ?? '';
                            return InkWell(
                              onTap: () => _selectContact(c),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 8),
                                child: Row(
                                  children: [
                                    Icon(Icons.person_outline_rounded,
                                        size: 14,
                                        color: AppColors.textTertiary),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            name,
                                            style: TextStyle(
                                              fontSize: 12,
                                              fontWeight: FontWeight.w600,
                                              color:
                                                  AppColors.textPrimary,
                                            ),
                                          ),
                                          if (phone.isNotEmpty)
                                            Text(
                                              phone,
                                              style: TextStyle(
                                                fontSize: 11,
                                                color: AppColors
                                                    .textTertiary,
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
                    const SizedBox(height: 10),
                    _buildField(
                      label: 'Name',
                      controller: _nameCtrl,
                      hint: 'Invitee name',
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: _buildField(
                            label: 'Phone',
                            controller: _phoneCtrl,
                            hint: '+1 555-123-4567',
                            keyboardType: TextInputType.phone,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _buildField(
                            label: 'Email',
                            controller: _emailCtrl,
                            hint: 'email@example.com',
                            keyboardType: TextInputType.emailAddress,
                          ),
                        ),
                      ],
                    ),
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
                      padding:
                          const EdgeInsets.symmetric(horizontal: 12),
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
                            fontSize: 13,
                            color: AppColors.textPrimary),
                        icon: Icon(Icons.unfold_more_rounded,
                            size: 16, color: AppColors.textTertiary),
                        hint: Text('None',
                            style: TextStyle(
                                fontSize: 13,
                                color: AppColors.textTertiary)),
                        items: [
                          DropdownMenuItem<int?>(
                            value: null,
                            child: Text('None',
                                style: TextStyle(
                                    color: AppColors.textTertiary)),
                          ),
                          ...jfService.items.map((jf) {
                            final id = (jf as dynamic).id as int?;
                            final name =
                                (jf as dynamic).title as String;
                            return DropdownMenuItem<int?>(
                              value: id,
                              child: Text(name),
                            );
                          }),
                        ],
                        onChanged: (v) =>
                            setState(() => _selectedJfId = v),
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
              child: Row(
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
            ),
          ],
        ),
      ),
    );
  }
}
