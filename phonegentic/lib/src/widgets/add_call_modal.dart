import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../conference/conference_service.dart';
import '../contact_service.dart';
import '../db/call_history_db.dart';
import '../demo_mode_service.dart';
import '../phone_formatter.dart';
import '../theme_provider.dart';
import 'action_button.dart';
import 'dialpad_contact_preview.dart';

/// Full-height modal overlay with an integrated keypad and contact search.
///
/// Shown when the user taps "Add Call" during an active call.
/// Typing digits shows a phone number; typing letters triggers contact search.
class AddCallModal extends StatefulWidget {
  final void Function(String number) onCall;
  final VoidCallback onClose;

  const AddCallModal({
    super.key,
    required this.onCall,
    required this.onClose,
  });

  @override
  State<AddCallModal> createState() => _AddCallModalState();
}

enum _ModalPhase { dialing, ringing, connected, failed }

class _AddCallModalState extends State<AddCallModal> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  List<Map<String, dynamic>> _searchResults = [];
  Timer? _searchDebounce;
  bool _placing = false;
  String _placedNumber = '';

  _ModalPhase _phase = _ModalPhase.dialing;
  Timer? _callTimer;
  int _callSeconds = 0;
  Timer? _failDismissTimer;
  Timer? _placingFailSafe;
  bool _legEverSeen = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _callTimer?.cancel();
    _failDismissTimer?.cancel();
    _placingFailSafe?.cancel();
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    final text = _controller.text;
    if (text.isEmpty) {
      setState(() => _searchResults = []);
      return;
    }

    if (RegExp(r'[a-zA-Z]').hasMatch(text)) {
      _searchDebounce?.cancel();
      _searchDebounce = Timer(const Duration(milliseconds: 200), () async {
        final results = await CallHistoryDb.searchContacts(text);
        if (mounted) {
          setState(() => _searchResults = results);
        }
      });
    } else {
      setState(() => _searchResults = []);
    }
  }

  void _handleNum(String digit) {
    _controller.text += digit;
    _controller.selection =
        TextSelection.collapsed(offset: _controller.text.length);
    HapticFeedback.lightImpact();
  }

  void _handleBackspace() {
    final text = _controller.text;
    if (text.isNotEmpty) {
      _controller.text = text.substring(0, text.length - 1);
      _controller.selection =
          TextSelection.collapsed(offset: _controller.text.length);
    }
  }

  void _selectContact(Map<String, dynamic> contact) {
    if (_placing) return;
    final phone = contact['phone'] as String? ?? '';
    if (phone.isNotEmpty) {
      setState(() {
        _placing = true;
        _placedNumber = phone;
      });
      _startPlacingFailSafe();
      widget.onCall(phone);
    }
  }

  void _placeCall() {
    if (_placing) return;
    final number =
        _controller.text.replaceAll(RegExp(r'[\s\-\(\)\.]'), '').trim();
    if (number.isEmpty) return;
    setState(() {
      _placing = true;
      _placedNumber = number;
      _controller.clear();
    });
    _startPlacingFailSafe();
    widget.onCall(number);
  }

  void _startPlacingFailSafe() {
    _legEverSeen = false;
    _placingFailSafe?.cancel();
    _placingFailSafe = Timer(const Duration(seconds: 3), () {
      if (mounted && _placing && _phase == _ModalPhase.dialing) {
        setState(() => _applyPhase(_ModalPhase.failed));
      }
    });
  }

  ConferenceCallLeg? _findPlacedLeg(ConferenceService conf) {
    if (_placedNumber.isEmpty) return null;
    final normalised = _placedNumber.replaceAll(RegExp(r'[\s\-\(\)\.]'), '');
    for (final l in conf.legs) {
      final legNum = l.remoteNumber.replaceAll(RegExp(r'[\s\-\(\)\.]'), '');
      if (legNum == normalised ||
          legNum.endsWith(normalised) ||
          normalised.endsWith(legNum)) {
        return l;
      }
    }
    return null;
  }

  _ModalPhase _derivePhase(ConferenceService conf) {
    if (!_placing) return _ModalPhase.dialing;
    if (_phase == _ModalPhase.failed) return _ModalPhase.failed;

    final leg = _findPlacedLeg(conf);
    if (leg != null) _legEverSeen = true;
    if (leg == null) {
      // Leg disappeared after we saw it, or was never seen because the call
      // failed between frames (rapid Telnyx rejection).
      if (_legEverSeen ||
          _phase == _ModalPhase.ringing ||
          _phase == _ModalPhase.connected) {
        return _ModalPhase.failed;
      }
      return _phase;
    }
    if (leg.state == LegState.active) return _ModalPhase.connected;
    if (leg.state == LegState.ringing) return _ModalPhase.ringing;
    return _phase;
  }

  void _applyPhase(_ModalPhase next) {
    if (_phase == next) return;
    final prev = _phase;
    _phase = next;

    if (next != _ModalPhase.dialing) {
      _placingFailSafe?.cancel();
    }

    if (next == _ModalPhase.connected && prev != _ModalPhase.connected) {
      _callSeconds = 0;
      _callTimer?.cancel();
      _callTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() => _callSeconds++);
      });
    }

    if (next == _ModalPhase.failed) {
      _callTimer?.cancel();
      _failDismissTimer?.cancel();
      _failDismissTimer = Timer(const Duration(seconds: 2), () {
        if (mounted) widget.onClose();
      });
    }
  }

  String get _timerLabel {
    final m = (_callSeconds ~/ 60).toString().padLeft(2, '0');
    final s = (_callSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final conf = context.watch<ConferenceService>();
    final heldCount = conf.legs.where((l) => l.state == LegState.held).length;
    final derived = _derivePhase(conf);
    _applyPhase(derived);

    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 44, 28, 44),
      child: Column(
        children: [
          _buildHeader(heldCount),
          const SizedBox(height: 4),
          Expanded(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 360),
                child: _phase == _ModalPhase.connected
                    ? _buildConnectedView()
                    : _phase == _ModalPhase.failed
                        ? _buildFailedView()
                        : _searchResults.isNotEmpty
                            ? _buildSearchResults()
                            : ScrollConfiguration(
                                behavior: ScrollConfiguration.of(context)
                                    .copyWith(scrollbars: false),
                                child: SingleChildScrollView(
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      _buildNumberDisplay(),
                                      const SizedBox(height: 14),
                                      if (_phase == _ModalPhase.dialing) ...[
                                        _buildNumPad(),
                                        const SizedBox(height: 10),
                                      ],
                                      _buildCallRow(),
                                    ],
                                  ),
                                ),
                              ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(int heldCount) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.add_ic_call_rounded, size: 20, color: AppColors.accent),
        const SizedBox(width: 6),
        Text(
          'Add Call',
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: AppColors.accent,
            letterSpacing: -0.3,
          ),
        ),
      ],
    );
  }

  Widget _buildNumberDisplay() {
    final raw = _controller.text;
    final display = raw.isEmpty ? '' : PhoneFormatter.format(raw);

    return Column(
      children: [
        SizedBox(
          height: 52,
          child: raw.isEmpty
              ? Text(
                  'Enter number',
                  style: TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.w200,
                    color: AppColors.textTertiary,
                    letterSpacing: 1,
                  ),
                )
              : FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    display,
                    style: TextStyle(
                      fontSize: 36,
                      fontWeight: FontWeight.w300,
                      color: AppColors.textPrimary,
                      letterSpacing: 2,
                      shadows: [
                        Shadow(
                          color: AppColors.phosphor.withValues(alpha: 0.35),
                          blurRadius: 12,
                        ),
                      ],
                    ),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildSearchResults() {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: _searchResults.length,
      itemBuilder: (context, index) {
        final contact = _searchResults[index];
        final name = contact['name'] as String? ?? 'Unknown';
        final phone = contact['phone'] as String? ?? '';
        final company = contact['company'] as String? ?? '';

        return InkWell(
          onTap: () => _selectContact(contact),
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppColors.accent.withValues(alpha: 0.12),
                  ),
                  child: Center(
                    child: Text(
                      name.isNotEmpty ? name[0].toUpperCase() : '?',
                      style: TextStyle(
                        color: AppColors.accent,
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      Text(
                        company.isNotEmpty ? '$phone  ·  $company' : phone,
                        style: TextStyle(
                          fontSize: 12,
                          color: AppColors.textTertiary,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.phone_rounded,
                    size: 18, color: AppColors.green.withValues(alpha: 0.7)),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildNumPad() {
    const labels = [
      [
        {'1': ''},
        {'2': 'ABC'},
        {'3': 'DEF'}
      ],
      [
        {'4': 'GHI'},
        {'5': 'JKL'},
        {'6': 'MNO'}
      ],
      [
        {'7': 'PQRS'},
        {'8': 'TUV'},
        {'9': 'WXYZ'}
      ],
      [
        {'*': ''},
        {'0': '+'},
        {'#': ''}
      ],
    ];

    return Column(
      children: labels
          .map((row) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: row
                      .map((label) => ActionButton(
                            title: label.keys.first,
                            subTitle: label.values.first,
                            onPressed: () => _handleNum(label.keys.first),
                            onLongPress: label.keys.first == '0'
                                ? () => _handleNum('+')
                                : null,
                            number: true,
                          ))
                      .toList(),
                ),
              ))
          .toList(),
    );
  }

  Widget _buildConnectedView() {
    final contactService = context.read<ContactService>();
    final demoMode = context.watch<DemoModeService>();
    final matchedContact = contactService.lookupByPhone(_placedNumber);
    final rawContactName = matchedContact?['display_name'] as String?;
    final nameIsPhone = rawContactName != null &&
        rawContactName.replaceAll(RegExp(r'[^\d]'), '').length >= 7 &&
        RegExp(r'^[\d\s\+\-\(\)\.]+$').hasMatch(rawContactName);
    final contactName = (rawContactName != null && !nameIsPhone)
        ? demoMode.maskDisplayName(rawContactName)
        : null;
    final formattedRemote = demoMode.maskPhone(_placedNumber);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Connected',
              style: TextStyle(fontSize: 13, color: AppColors.green),
            ),
            const SizedBox(width: 8),
            Text(
              _timerLabel,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: AppColors.textSecondary,
                fontFamily: AppColors.timerFontFamily,
                fontFamilyFallback: AppColors.timerFontFamilyFallback,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
        ContactIdenticon(
          seed: rawContactName ?? _placedNumber,
          size: 80,
        ),
        const SizedBox(height: 20),
        if (contactName != null) ...[
          Text(
            contactName,
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            PhoneFormatter.format(formattedRemote),
            style: TextStyle(
              fontSize: 14,
              color: AppColors.textSecondary,
            ),
          ),
        ] else
          Text(
            PhoneFormatter.format(formattedRemote),
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w500,
              color: AppColors.textPrimary,
              letterSpacing: -0.5,
            ),
          ),
        const SizedBox(height: 32),
        SizedBox(
          width: 56,
          height: 56,
          child: Material(
            color: AppColors.red.withValues(alpha: 0.15),
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: widget.onClose,
              child: Icon(Icons.call_end_rounded, color: AppColors.red, size: 26),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildFailedView() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppColors.red.withValues(alpha: 0.12),
          ),
          child: Icon(Icons.call_end_rounded, color: AppColors.red, size: 28),
        ),
        const SizedBox(height: 16),
        Text(
          'Call Failed',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: AppColors.red,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          PhoneFormatter.format(_placedNumber),
          style: TextStyle(fontSize: 14, color: AppColors.textTertiary),
        ),
      ],
    );
  }

  Widget _buildCallRow() {
    final text = _controller.text;

    if (_placing) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Calling ${PhoneFormatter.format(_placedNumber)}...',
            style: TextStyle(
              color: AppColors.phosphor,
              fontSize: 15,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: AppColors.phosphor.withValues(alpha: 0.6),
            ),
          ),
        ],
      );
    }

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        const SizedBox(width: 56),
        _ConferenceCallButton(onTap: _placeCall),
        SizedBox(
          width: 56,
          child: text.isNotEmpty
              ? HoverButton(
                  onTap: _handleBackspace,
                  onLongPress: () {
                    _controller.clear();
                    HapticFeedback.mediumImpact();
                  },
                  borderRadius: BorderRadius.circular(28),
                  child: SizedBox(
                    width: 56,
                    height: 56,
                    child: Icon(Icons.backspace_outlined,
                        size: 22, color: AppColors.textTertiary),
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }
}

class _ConferenceCallButton extends StatefulWidget {
  final VoidCallback onTap;
  const _ConferenceCallButton({required this.onTap});

  @override
  State<_ConferenceCallButton> createState() => _ConferenceCallButtonState();
}

class _ConferenceCallButtonState extends State<_ConferenceCallButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;
  late final Animation<double> _glowAnim;
  bool _pressed = false;
  bool _hovered = false;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat(reverse: true);
    _glowAnim = Tween<double>(begin: 0.25, end: 0.55).animate(
      CurvedAnimation(parent: _pulse, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scale = _pressed ? 0.88 : (_hovered ? 1.08 : 1.0);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        child: AnimatedScale(
          scale: scale,
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOut,
          child: AnimatedBuilder(
            animation: _glowAnim,
            builder: (context, child) {
              return Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      AppColors.hotSignal,
                      AppColors.phosphor,
                      AppColors.burntAmber,
                    ],
                    stops: const [0.0, 0.45, 1.0],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.phosphor
                          .withValues(alpha: _hovered ? 0.6 : _glowAnim.value),
                      blurRadius: _hovered ? 28 : 20,
                      spreadRadius: _hovered ? 4 : 2,
                    ),
                    if (_hovered)
                      BoxShadow(
                        color: AppColors.hotSignal.withValues(alpha: 0.3),
                        blurRadius: 40,
                        spreadRadius: 6,
                      ),
                  ],
                ),
                child: Icon(
                    Icons.phone, size: 30, color: AppColors.crtBlack),
              );
            },
          ),
        ),
      ),
    );
  }
}
