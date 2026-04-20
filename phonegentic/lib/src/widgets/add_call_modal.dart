import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../conference/conference_service.dart';
import '../contact_service.dart';
import '../demo_mode_service.dart';
import '../messaging/messaging_service.dart';
import '../phone_formatter.dart';
import '../theme_provider.dart';
import 'action_button.dart';
import 'add_2_call_icon.dart';
import 'dialpad_autocomplete_overlay.dart';
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
  bool _placing = false;
  String _placedNumber = '';

  // Autocomplete state (mirrors main dialpad behavior)
  List<Map<String, dynamic>> _autocompleteMatches = [];
  bool _dropdownOpen = false;
  int _highlightedIndex = -1;
  Map<String, dynamic>? _selectedContact;

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
    HardwareKeyboard.instance.addHandler(_handleKeyEvent);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    _callTimer?.cancel();
    _failDismissTimer?.cancel();
    _placingFailSafe?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    final text = _controller.text;
    final contacts = Provider.of<ContactService>(context, listen: false);
    final hasLetters = RegExp(r'[a-zA-Z]').hasMatch(text);

    if (_selectedContact != null) {
      final selectedDigits =
          (_selectedContact!['phone_number'] as String? ?? '')
              .replaceAll(RegExp(r'[^\d+]'), '');
      if (text != selectedDigits) {
        setState(() => _selectedContact = null);
      }
    }

    if (_selectedContact == null && !hasLetters && text.length >= 7) {
      final match = contacts.lookupByPhone(text);
      if (match != null) {
        setState(() => _selectedContact = match);
      }
    }

    if (text.isEmpty) {
      if (_autocompleteMatches.isNotEmpty ||
          _dropdownOpen ||
          _selectedContact != null) {
        setState(() {
          _selectedContact = null;
          _autocompleteMatches = [];
          _dropdownOpen = false;
          _highlightedIndex = -1;
        });
      }
      return;
    }

    // Only run autocomplete search for letter input (name search).
    // Digit-only input resolves contacts passively via lookupByPhone above.
    if (!hasLetters) {
      if (_dropdownOpen) {
        setState(() {
          _dropdownOpen = false;
          _autocompleteMatches = [];
          _highlightedIndex = -1;
        });
      }
      return;
    }

    final List<Map<String, dynamic>> matches;
    if (text.length < 2) {
      if (_dropdownOpen) {
        matches = contacts.contacts.take(8).toList();
      } else {
        return;
      }
    } else {
      matches = contacts.autocompleteSearch(text);
    }

    if (!_listEquals(matches, _autocompleteMatches)) {
      setState(() {
        _autocompleteMatches = matches;
        _highlightedIndex = -1;
        if (matches.isEmpty && _dropdownOpen) {
          _dropdownOpen = false;
        } else if (matches.isNotEmpty && !_dropdownOpen) {
          _dropdownOpen = true;
        }
      });
    } else if (matches.isNotEmpty && !_dropdownOpen) {
      setState(() => _dropdownOpen = true);
    }
  }

  bool _listEquals(List<Map<String, dynamic>> a, List<Map<String, dynamic>> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i]['id'] != b[i]['id']) return false;
    }
    return true;
  }

  bool _handleKeyEvent(KeyEvent event) {
    if (!mounted) return false;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;
    if (_phase != _ModalPhase.dialing) return false;

    if (event.logicalKey == LogicalKeyboardKey.escape) {
      widget.onClose();
      return true;
    }

    if (_dropdownOpen && _autocompleteMatches.isNotEmpty) {
      final len = _autocompleteMatches.length;
      final key = event.logicalKey;
      if (key == LogicalKeyboardKey.arrowDown ||
          (key == LogicalKeyboardKey.tab &&
              !HardwareKeyboard.instance.isShiftPressed)) {
        setState(() => _highlightedIndex = (_highlightedIndex + 1) % len);
        return true;
      }
      if (key == LogicalKeyboardKey.arrowUp ||
          (key == LogicalKeyboardKey.tab &&
              HardwareKeyboard.instance.isShiftPressed)) {
        setState(
            () => _highlightedIndex = (_highlightedIndex - 1 + len) % len);
        return true;
      }
      if (key == LogicalKeyboardKey.enter && _highlightedIndex >= 0) {
        _onAutocompleteSelect(_autocompleteMatches[_highlightedIndex]);
        return true;
      }
    }

    if (event.logicalKey == LogicalKeyboardKey.enter) {
      _placeCall();
      return true;
    }

    if (event.logicalKey == LogicalKeyboardKey.backspace) {
      _handleBackspace();
      return true;
    }

    if (event.logicalKey == LogicalKeyboardKey.slash) {
      _toggleSearchDropdown();
      return true;
    }

    final character = event.character;
    if (character == null || character.isEmpty) return false;

    const dialChars = '0123456789*#+';
    if (dialChars.contains(character)) {
      _handleNum(character);
      return true;
    }

    if (RegExp(r'^[a-zA-Z ]$').hasMatch(character)) {
      setState(() => _controller.text += character);
      return true;
    }

    return false;
  }

  void _handleNum(String digit) {
    setState(() {
      _controller.text += digit;
      _controller.selection =
          TextSelection.collapsed(offset: _controller.text.length);
    });
    HapticFeedback.lightImpact();
  }

  void _handleBackspace() {
    final text = _controller.text;
    if (text.isNotEmpty) {
      setState(() {
        _controller.text = text.substring(0, text.length - 1);
        _controller.selection =
            TextSelection.collapsed(offset: _controller.text.length);
      });
    }
  }

  void _onAutocompleteSelect(Map<String, dynamic> contact) {
    final phone = contact['phone_number'] as String? ?? '';
    if (phone.isEmpty) return;
    final digits = phone.replaceAll(RegExp(r'[^\d+]'), '');
    setState(() {
      _selectedContact = contact;
      _controller.text = digits;
      _dropdownOpen = false;
      _highlightedIndex = -1;
    });
  }

  void _onAutocompleteCall(Map<String, dynamic> contact) {
    final phone = contact['phone_number'] as String? ?? '';
    if (phone.isEmpty) return;
    final digits = phone.replaceAll(RegExp(r'[^\d+]'), '');
    setState(() {
      _controller.text = digits;
      _dropdownOpen = false;
      _autocompleteMatches = [];
    });
    _placeCall();
  }

  void _onAutocompleteMessage(Map<String, dynamic> contact) {
    final phone = contact['phone_number'] as String? ?? '';
    if (phone.isEmpty) return;
    setState(() => _dropdownOpen = false);
    final messaging = context.read<MessagingService>();
    messaging.openToConversation(phone);
  }

  void _dismissAutocomplete() {
    if (_dropdownOpen) {
      setState(() {
        _dropdownOpen = false;
        _highlightedIndex = -1;
        _autocompleteMatches = [];
      });
    }
  }

  void _toggleSearchDropdown() {
    final opening = !_dropdownOpen;
    final hadNoSelection = _selectedContact == null;
    setState(() {
      _dropdownOpen = opening;
      if (!opening && hadNoSelection) {
        _controller.text = '';
        _autocompleteMatches = [];
      }
    });
    if (opening) {
      if (_autocompleteMatches.isEmpty) {
        final contacts = Provider.of<ContactService>(context, listen: false);
        final text = _controller.text;
        final matches = text.length >= 2
            ? contacts.autocompleteSearch(text)
            : contacts.contacts.take(8).toList();
        if (matches.isNotEmpty) {
          setState(() => _autocompleteMatches = matches);
        }
      }
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
      _dropdownOpen = false;
      _autocompleteMatches = [];
      _selectedContact = null;
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
          _buildHeader(conf, heldCount),
          const SizedBox(height: 4),
          Expanded(
            child: Align(
              alignment: Alignment.center,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 360),
                child: _phase == _ModalPhase.connected
                    ? _buildConnectedView()
                    : _phase == _ModalPhase.failed
                        ? _buildFailedView()
                        : _placing
                            ? _buildCallingView()
                            : _buildDialingView(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(ConferenceService conf, int heldCount) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        Add2CallIcon(size: 28, color: AppColors.accent),
        const SizedBox(width: 8),
        Text(
          'Add Call',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: AppColors.accent,
            letterSpacing: -0.3,
          ),
        ),
      ],
    );
  }

  Widget _buildDialingView() {
    final showDropdown = _dropdownOpen && _autocompleteMatches.isNotEmpty;

    return Stack(
      children: [
        if (showDropdown)
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _dismissAutocomplete,
            ),
          ),
        ScrollConfiguration(
          behavior:
              ScrollConfiguration.of(context).copyWith(scrollbars: false),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildNumberDisplay(),
                SizedBox(
                  width: double.infinity,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SizedBox(height: 14),
                          _buildNumPad(),
                          const SizedBox(height: 10),
                          _buildCallRow(),
                        ],
                      ),
                      if (showDropdown)
                        Positioned(
                          top: -0.5,
                          left: 0,
                          right: 0,
                          child: DialpadAutocompleteDropdown(
                            matches: _autocompleteMatches,
                            highlightedIndex: _highlightedIndex,
                            onSelect: _onAutocompleteSelect,
                            onCall: _onAutocompleteCall,
                            onMessage: _onAutocompleteMessage,
                            onDismiss: _dismissAutocomplete,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildNumberDisplay() {
    final raw = _controller.text;
    final demoMode = context.watch<DemoModeService>();
    final hasLetters = RegExp(r'[a-zA-Z]').hasMatch(raw);
    final showDropdown = _dropdownOpen && _autocompleteMatches.isNotEmpty;
    final hasSearchResults = _autocompleteMatches.isNotEmpty;
    final display = raw.isEmpty
        ? ''
        : hasLetters
            ? raw
            : demoMode.enabled
                ? demoMode.maskPhone(raw)
                : PhoneFormatter.format(raw);
    final borderColor = AppColors.border.withValues(alpha: 0.5);
    const borderWidth = 0.5;

    return Container(
      width: showDropdown ? double.infinity : null,
      decoration: showDropdown
          ? BoxDecoration(
              color: AppColors.surface.withValues(alpha: 0.40),
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(14),
                topRight: Radius.circular(14),
              ),
              border: Border(
                top: BorderSide(color: borderColor, width: borderWidth),
                left: BorderSide(color: borderColor, width: borderWidth),
                right: BorderSide(color: borderColor, width: borderWidth),
                bottom: BorderSide(color: borderColor, width: borderWidth),
              ),
            )
          : null,
      padding: showDropdown ? const EdgeInsets.only(top: 8, bottom: 8) : null,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Center(
            child: SizedBox(
              height: 48,
              child: raw.isEmpty
                  ? Text(
                      'Enter number or name',
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w200,
                        color: AppColors.textTertiary,
                        letterSpacing: 0.5,
                      ),
                    )
                  : _selectedContact != null
                      ? Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            ContactIdenticon(
                              seed: (_selectedContact!['display_name']
                                              as String? ??
                                          '')
                                      .isEmpty
                                  ? display
                                  : _selectedContact!['display_name'] as String,
                              size: 36,
                            ),
                            const SizedBox(width: 10),
                            Flexible(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    demoMode.maskDisplayName(
                                        _selectedContact!['display_name']
                                                as String? ??
                                            display),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.w600,
                                      color: AppColors.textPrimary,
                                      letterSpacing: -0.3,
                                    ),
                                  ),
                                  const SizedBox(height: 1),
                                  Text(
                                    display,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w400,
                                      color: AppColors.textSecondary,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        )
                      : FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            display,
                            style: TextStyle(
                              fontSize: hasLetters ? 28 : 34,
                              fontWeight: hasLetters
                                  ? FontWeight.w400
                                  : FontWeight.w300,
                              color: AppColors.textPrimary,
                              letterSpacing: hasLetters ? -0.3 : 2,
                              shadows: hasLetters
                                  ? null
                                  : [
                                      Shadow(
                                        color: AppColors.phosphor
                                            .withValues(alpha: 0.35),
                                        blurRadius: 12,
                                      ),
                                    ],
                            ),
                          ),
                        ),
            ),
          ),
          if (hasSearchResults)
            Positioned(
              top: 6,
              right: 10,
              child: GestureDetector(
                onTap: _toggleSearchDropdown,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOutCubic,
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: _dropdownOpen
                        ? AppColors.burntAmber.withValues(alpha: 0.18)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    Icons.search_rounded,
                    size: 24,
                    color: _dropdownOpen
                        ? AppColors.burntAmber
                        : AppColors.burntAmber.withValues(alpha: 0.55),
                  ),
                ),
              ),
            ),
        ],
      ),
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

  /// Resolve contact metadata for [_placedNumber].
  ({
    Map<String, dynamic>? contact,
    String? rawName,
    String? displayName,
    String formattedRemote,
    String? thumbnailPath,
  }) _resolveContact() {
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
    final thumb = matchedContact?['thumbnail_path'] as String?;
    return (
      contact: matchedContact,
      rawName: rawContactName,
      displayName: contactName,
      formattedRemote: formattedRemote,
      thumbnailPath: thumb,
    );
  }

  Widget _buildCallingView() {
    final c = _resolveContact();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Calling...',
          style: TextStyle(fontSize: 13, color: AppColors.phosphor),
        ),
        const SizedBox(height: 24),
        ContactIdenticon(
          seed: c.rawName ?? _placedNumber,
          size: 80,
          thumbnailPath: c.thumbnailPath,
        ),
        const SizedBox(height: 20),
        if (c.displayName != null) ...[
          Text(
            c.displayName!,
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            PhoneFormatter.format(c.formattedRemote),
            style: TextStyle(
              fontSize: 14,
              color: AppColors.textSecondary,
            ),
          ),
        ] else
          Text(
            PhoneFormatter.format(c.formattedRemote),
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w500,
              color: AppColors.textPrimary,
              letterSpacing: -0.5,
            ),
          ),
      ],
    );
  }

  Widget _buildConnectedView() {
    final c = _resolveContact();

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
          seed: c.rawName ?? _placedNumber,
          size: 80,
          thumbnailPath: c.thumbnailPath,
        ),
        const SizedBox(height: 20),
        if (c.displayName != null) ...[
          Text(
            c.displayName!,
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            PhoneFormatter.format(c.formattedRemote),
            style: TextStyle(
              fontSize: 14,
              color: AppColors.textSecondary,
            ),
          ),
        ] else
          Text(
            PhoneFormatter.format(c.formattedRemote),
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w500,
              color: AppColors.textPrimary,
              letterSpacing: -0.5,
            ),
          ),
        const SizedBox(height: 28),
        _buildConnectedActions(),
      ],
    );
  }

  Widget _buildConnectedActions() {
    final conf = context.watch<ConferenceService>();
    final placedLeg = _findPlacedLeg(conf);
    final isHeld = placedLeg?.state == LegState.held;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            ActionButton(
              title: isHeld ? 'Resume' : 'Hold',
              icon: isHeld ? Icons.play_arrow : Icons.pause,
              checked: isHeld,
              onPressed: () {
                if (placedLeg == null) return;
                if (isHeld) {
                  conf.unholdLeg(placedLeg.sipCallId);
                } else {
                  conf.holdLeg(placedLeg.sipCallId);
                }
              },
            ),
            ActionButton(
              title: 'Merge',
              icon: Icons.merge_type_rounded,
              onPressed: conf.canMerge
                  ? () {
                      conf.merge();
                      widget.onClose();
                    }
                  : null,
            ),
            ActionButton(
              title: 'Message',
              icon: Icons.message_rounded,
              onPressed: () {
                if (_placedNumber.isNotEmpty) {
                  context
                      .read<MessagingService>()
                      .openToConversation(_placedNumber);
                }
              },
            ),
          ],
        ),
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            ActionButton(
              title: 'Contact',
              icon: Icons.person_outline_rounded,
              onPressed: () {
                if (_placedNumber.isNotEmpty) {
                  context
                      .read<ContactService>()
                      .openContactForPhone(_placedNumber);
                }
              },
            ),
            _buildHangupButton(),
            ActionButton(
              title: 'Keypad',
              icon: Icons.dialpad,
              onPressed: () {
                // DTMF handled at callscreen level
              },
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildHangupButton() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        HoverButton(
          onTap: widget.onClose,
          borderRadius: BorderRadius.circular(32),
          child: Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.red,
              boxShadow: [
                BoxShadow(
                  color: AppColors.red.withValues(alpha: 0.35),
                  blurRadius: 16,
                  spreadRadius: 1,
                ),
              ],
            ),
            child: Icon(Icons.call_end_rounded,
                color: AppColors.onAccent, size: 26),
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
                child:
                    Icon(Icons.phone, size: 30, color: AppColors.crtBlack),
              );
            },
          ),
        ),
      ),
    );
  }
}
