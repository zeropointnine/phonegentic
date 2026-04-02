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
  const CalendarPanel({Key? key}) : super(key: key);

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
                      onEventTap: (e) => _showEventDetail(context, e),
                    )
                  : _MonthView(
                      focusDate: _focusDate,
                      events: _events,
                      onDayTap: _goToDay,
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
          GestureDetector(
            onTap: sync.close,
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
    return GestureDetector(
      onTap: onTap,
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
    return GestureDetector(
      onTap: () => _switchView(v),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? AppColors.accent : AppColors.card,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected
                ? AppColors.accent
                : AppColors.border.withOpacity(0.5),
            width: 0.5,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: selected ? Colors.white : AppColors.textSecondary,
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

  void _showEventDetail(BuildContext context, CalendarEvent event) {
    final jfService = context.read<JobFunctionService>();
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => _EventDetailSheet(
        event: event,
        jobFunctions: jfService.items,
        onJobFunctionChanged: (jfId) async {
          await CallHistoryDb.updateCalendarEventJobFunction(
              event.id!, jfId);
          _loadEvents();
        },
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

  const _WeekView({
    required this.focusDate,
    required this.events,
    required this.onEventTap,
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

    return SingleChildScrollView(
      controller: _scrollController,
      padding: const EdgeInsets.only(bottom: 20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Time gutter
          SizedBox(
            width: 44,
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
                            fontSize: 10,
                            color: AppColors.textTertiary,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          // Day columns
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
              ),
            ),
        ],
      ),
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

class _DayColumn extends StatelessWidget {
  final DateTime day;
  final List<CalendarEvent> events;
  final int startHour;
  final int endHour;
  final double hourHeight;
  final bool isToday;
  final DateTime now;
  final ValueChanged<CalendarEvent> onEventTap;

  const _DayColumn({
    required this.day,
    required this.events,
    required this.startHour,
    required this.endHour,
    required this.hourHeight,
    required this.isToday,
    required this.now,
    required this.onEventTap,
  });

  @override
  Widget build(BuildContext context) {
    final totalHeight = (endHour - startHour + 1) * hourHeight;
    final dayLabel = DateFormat.E().format(day).substring(0, 2);
    final dayNum = day.day.toString();

    return Column(
      children: [
        // Day header
        Container(
          height: 40,
          decoration: BoxDecoration(
            border: Border(
              bottom:
                  BorderSide(color: AppColors.border.withOpacity(0.3), width: 0.5),
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                dayLabel,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w500,
                  color: isToday ? AppColors.accent : AppColors.textTertiary,
                ),
              ),
              const SizedBox(height: 1),
              Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isToday ? AppColors.accent : Colors.transparent,
                ),
                child: Center(
                  child: Text(
                    dayNum,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: isToday ? Colors.white : AppColors.textSecondary,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        // Time grid + events
        SizedBox(
          height: totalHeight,
          child: Stack(
            children: [
              // Hour grid lines
              for (var h = startHour; h <= endHour; h++)
                Positioned(
                  top: (h - startHour) * hourHeight,
                  left: 0,
                  right: 0,
                  child: Container(
                    height: 0.5,
                    color: AppColors.border.withOpacity(0.2),
                  ),
                ),
              // Current time indicator
              if (isToday) _buildNowLine(),
              // Events
              for (final event in events) _buildEvent(event),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildNowLine() {
    final minutesFromStart = (now.hour - startHour) * 60 + now.minute;
    final top = minutesFromStart * hourHeight / 60;
    if (top < 0 || top > (endHour - startHour + 1) * hourHeight) {
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
              color: AppColors.accent.withOpacity(0.4),
              blurRadius: 3,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEvent(CalendarEvent event) {
    final localStart = event.startTime.toLocal();
    final localEnd = event.endTime.toLocal();
    final startMin = (localStart.hour - startHour) * 60 + localStart.minute;
    final endMin = (localEnd.hour - startHour) * 60 + localEnd.minute;
    final top = startMin * hourHeight / 60;
    final height = ((endMin - startMin).clamp(15, 9999)) * hourHeight / 60;

    return Positioned(
      top: top.clamp(0, double.infinity),
      left: 1,
      right: 1,
      height: height,
      child: GestureDetector(
        onTap: () => onEventTap(event),
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 1),
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: AppColors.accent.withOpacity(0.18),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(
                color: AppColors.accent.withOpacity(0.35), width: 0.5),
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

  const _MonthView({
    required this.focusDate,
    required this.events,
    required this.onDayTap,
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
          // Day-of-week header
          Row(
            children: dayLabels
                .map((d) => Expanded(
                      child: Center(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Text(
                            d,
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: AppColors.textTertiary,
                            ),
                          ),
                        ),
                      ),
                    ))
                .toList(),
          ),
          // Grid
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

                return GestureDetector(
                  onTap: () => onDayTap(day),
                  child: Container(
                    margin: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      color: isToday
                          ? AppColors.accent.withOpacity(0.12)
                          : Colors.transparent,
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          '$dayNum',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight:
                                isToday ? FontWeight.w700 : FontWeight.w500,
                            color: isToday
                                ? AppColors.accent
                                : AppColors.textPrimary,
                          ),
                        ),
                        if (dayEvents.isNotEmpty) ...[
                          const SizedBox(height: 3),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              for (var i = 0;
                                  i < dayEvents.length.clamp(0, 3);
                                  i++)
                                Container(
                                  width: 4,
                                  height: 4,
                                  margin:
                                      const EdgeInsets.symmetric(horizontal: 1),
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
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Event Detail Bottom Sheet
// ---------------------------------------------------------------------------

class _EventDetailSheet extends StatefulWidget {
  final CalendarEvent event;
  final List<dynamic> jobFunctions;
  final ValueChanged<int?> onJobFunctionChanged;

  const _EventDetailSheet({
    required this.event,
    required this.jobFunctions,
    required this.onJobFunctionChanged,
  });

  @override
  State<_EventDetailSheet> createState() => _EventDetailSheetState();
}

class _EventDetailSheetState extends State<_EventDetailSheet> {
  late int? _selectedJfId;

  @override
  void initState() {
    super.initState();
    _selectedJfId = widget.event.jobFunctionId;
  }

  @override
  Widget build(BuildContext context) {
    final event = widget.event;
    final timeFmt = DateFormat.jm();
    final dateFmt = DateFormat.yMMMd();
    final startLocal = event.startTime.toLocal();
    final endLocal = event.endTime.toLocal();

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            event.title,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
              letterSpacing: -0.3,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(Icons.access_time_rounded,
                  size: 14, color: AppColors.textTertiary),
              const SizedBox(width: 6),
              Text(
                '${dateFmt.format(startLocal)}  ${timeFmt.format(startLocal)} – ${timeFmt.format(endLocal)}',
                style:
                    TextStyle(fontSize: 13, color: AppColors.textSecondary),
              ),
            ],
          ),
          if (event.description != null &&
              event.description!.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              event.description!,
              style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
            ),
          ],
          if (event.location != null && event.location!.isNotEmpty) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.location_on_outlined,
                    size: 14, color: AppColors.textTertiary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    event.location!,
                    style: TextStyle(
                        fontSize: 13, color: AppColors.textSecondary),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 16),
          Text(
            'AUTO-SWITCH JOB FUNCTION',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: AppColors.textTertiary,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: AppColors.card,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                  color: AppColors.border.withOpacity(0.5), width: 0.5),
            ),
            child: DropdownButton<int?>(
              value: _selectedJfId,
              isExpanded: true,
              underline: const SizedBox.shrink(),
              dropdownColor: AppColors.card,
              style: TextStyle(fontSize: 13, color: AppColors.textPrimary),
              icon: Icon(Icons.unfold_more_rounded,
                  size: 16, color: AppColors.textTertiary),
              hint: Text('None',
                  style: TextStyle(
                      fontSize: 13, color: AppColors.textTertiary)),
              items: [
                DropdownMenuItem<int?>(
                  value: null,
                  child: Text('None',
                      style: TextStyle(color: AppColors.textTertiary)),
                ),
                ...widget.jobFunctions.map((jf) {
                  final id = (jf as dynamic).id as int?;
                  final name = (jf as dynamic).name as String;
                  return DropdownMenuItem<int?>(
                    value: id,
                    child: Text(name),
                  );
                }),
              ],
              onChanged: (v) {
                setState(() => _selectedJfId = v);
                widget.onJobFunctionChanged(v);
              },
            ),
          ),
        ],
      ),
    );
  }
}
