import 'dart:async';

import 'package:phonegentic/src/agent_service.dart';
import 'package:phonegentic/src/call_history_service.dart';
import 'package:phonegentic/src/test_credentials.dart';
import 'package:phonegentic/src/theme_provider.dart';
import 'package:phonegentic/src/user_state/sip_user_cubit.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:logger/logger.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:sip_ua/sip_ua.dart';

import 'calendar_sync_service.dart';
import 'callscreen.dart';
import 'conference/conference_service.dart';
import 'contact_service.dart';
import 'demo_mode_service.dart';
import 'inbound_call_flow_service.dart';
import 'models/agent_context.dart';
import 'messaging/messaging_service.dart';
import 'messaging/phone_numbers.dart';
import 'phone_formatter.dart';
import 'job_function_service.dart';
import 'ringtone_service.dart';
import 'tear_sheet_service.dart';
import 'widgets/action_button.dart';
import 'widgets/agent_panel.dart';
import 'widgets/audio_device_sheet.dart';
import 'widgets/calendar_panel.dart';
import 'widgets/call_history_panel.dart';
import 'widgets/contact_list_panel.dart';
import 'widgets/messaging_panel.dart';
import 'widgets/inbound_call_flow_editor.dart';
import 'widgets/job_function_editor.dart';
import 'widgets/dialpad_autocomplete_overlay.dart';
import 'widgets/dialpad_contact_preview.dart';
import 'widgets/phonegentic_logo.dart';
import 'widgets/quick_add_overlay.dart';
import 'widgets/tear_sheet_editor.dart';
import 'widgets/tear_sheet_strip.dart';

class DialPadWidget extends StatefulWidget {
  final SIPUAHelper? _helper;
  DialPadWidget(this._helper, {super.key});

  @override
  State<DialPadWidget> createState() => _MyDialPadWidget();
}

class _MyDialPadWidget extends State<DialPadWidget>
    implements SipUaHelperListener {
  String? _dest;
  SIPUAHelper? get helper => widget._helper;
  TextEditingController? _textController;
  late SipUserCubit currentUserCubit;
  final FocusNode _focusNode = FocusNode();
  final Logger _logger = Logger();

  String? receivedMsg;
  bool _audioMuted = false;
  bool _speakerOn = false;
  bool _hasAttemptedAutoRegister = false;
  final Map<String?, Call> _calls = {};
  Call? _focusedCall;
  Call? get _activeCall => _focusedCall;

  List<Map<String, dynamic>> _autocompleteMatches = [];
  bool _dropdownOpen = false;
  int _highlightedIndex = -1;
  Map<String, dynamic>? _selectedContact;
  String? _lastDialedNumber;

  static const _tapChannel = MethodChannel('com.agentic_ai/audio_tap_control');
  bool _safetyCallModeForced = false;
  Timer? _conferenceTimeout;
  String? _conferenceTimeoutCallId;

  // Inbound fork coalescing: Telnyx (and some other providers) deliver a
  // single inbound call as multiple INVITE forks with different Call-IDs.
  // We track the active ring session by caller identity so subsequent forks
  // are adopted seamlessly instead of resetting the UI.
  String? _inboundRingCaller;
  DateTime? _inboundRingStart;
  Timer? _forkGraceTimer;
  static const _forkGraceMs = 4000;
  // Stable key for the CallScreenWidget so fork replacements don't tear down
  // and recreate the widget (which resets the call timer and flickers the UI).
  String? _logicalCallKey;

  @override
  void initState() {
    super.initState();
    receivedMsg = '';
    _bindEventListeners();
    _loadSettings();
    HardwareKeyboard.instance.addHandler(_handleGlobalKeyEvent);
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeAutoRegister());
  }

  void _maybeAutoRegister() {
    if (!mounted || _hasAttemptedAutoRegister) return;
    final h = helper;
    if (h == null) return;
    if (h.registered) return;
    final user = TestCredentials.sipUser;
    if (user.authUser.isEmpty || user.password.isEmpty) return;
    _hasAttemptedAutoRegister = true;
    context.read<SipUserCubit>().register(user);
  }

  @override
  void dispose() {
    _forkGraceTimer?.cancel();
    HardwareKeyboard.instance.removeHandler(_handleGlobalKeyEvent);
    _focusNode.dispose();
    _textController?.dispose();
    super.dispose();
  }

  void _loadSettings() {
    _dest = '';
    _textController = TextEditingController(text: _dest);
    _textController!.text = _dest ?? '';
    _textController!.addListener(_onDigitsChanged);
    setState(() {});
  }

  void _onDigitsChanged() {
    final text = _textController?.text ?? '';
    final contacts = Provider.of<ContactService>(context, listen: false);
    final hasLetters = RegExp(r'[a-zA-Z]').hasMatch(text);

    if (_selectedContact != null) {
      final selectedDigits =
          (_selectedContact!['phone_number'] as String? ?? '')
              .replaceAll(RegExp(r'[^\d+]'), '');
      if (text != selectedDigits) {
        _selectedContact = null;
      }
    }

    if (_selectedContact == null && !hasLetters && text.length >= 7) {
      final match = contacts.lookupByPhone(text);
      if (match != null) {
        _selectedContact = match;
      }
    }

    if (text.isEmpty) {
      if (_autocompleteMatches.isNotEmpty || _dropdownOpen) {
        setState(() {
          _selectedContact = null;
          _autocompleteMatches = [];
          _dropdownOpen = false;
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
      final wasOpen = _dropdownOpen;
      setState(() {
        _autocompleteMatches = matches;
        _highlightedIndex = -1;
        if (matches.isEmpty && _dropdownOpen) {
          _dropdownOpen = false;
        } else if (hasLetters && matches.isNotEmpty && !_dropdownOpen) {
          _dropdownOpen = true;
        }
      });
      if (!wasOpen && _dropdownOpen) _focusNode.requestFocus();
    } else if (hasLetters && matches.isNotEmpty && !_dropdownOpen) {
      setState(() => _dropdownOpen = true);
      _focusNode.requestFocus();
    }
  }

  bool _listEquals(List<Map<String, dynamic>> a, List<Map<String, dynamic>> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i]['id'] != b[i]['id']) return false;
    }
    return true;
  }

  bool _handleGlobalKeyEvent(KeyEvent event) {
    if (!mounted) return false;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;
    if (_activeCall != null) return false;

    final FocusNode? primary = FocusManager.instance.primaryFocus;
    final bool inTextField = primary != null &&
        primary.context != null &&
        primary.context!.findAncestorWidgetOfExactType<EditableText>() != null;

    if (event.logicalKey == LogicalKeyboardKey.slash && !inTextField) {
      _handleSlashSearch();
      return true;
    }

    if (inTextField) return false;

    if (event.logicalKey == LogicalKeyboardKey.escape) {
      if (_dropdownOpen) {
        setState(() => _dropdownOpen = false);
        return true;
      }
      if (_textController!.text.isNotEmpty) {
        setState(() {
          _textController!.text = '';
          _autocompleteMatches = [];
        });
        return true;
      }
      return false;
    }

    if (event.logicalKey == LogicalKeyboardKey.backspace) {
      final String text = _textController!.text;
      if (text.isNotEmpty) {
        setState(() {
          _textController!.text = text.substring(0, text.length - 1);
        });
        return true;
      }
      return false;
    }

    if (event.logicalKey == LogicalKeyboardKey.enter &&
        _dropdownOpen &&
        _highlightedIndex >= 0 &&
        _highlightedIndex < _autocompleteMatches.length) {
      _onAutocompleteSelect(_autocompleteMatches[_highlightedIndex]);
      return true;
    }

    final String? character = event.character;
    if (character == null || character.isEmpty) return false;

    const String dialChars = '0123456789*#+';
    if (dialChars.contains(character)) {
      setState(() {
        _textController!.text += character;
      });
      return true;
    }

    if (RegExp(r'^[a-zA-Z ]$').hasMatch(character)) {
      setState(() {
        _textController!.text += character;
      });
      return true;
    }

    return false;
  }

  void _handleMute() {
    final call = helper?.activeCall;
    if (call == null) return;
    _audioMuted = !_audioMuted;
    if (_audioMuted) {
      call.mute(true, false);
    } else {
      call.unmute(true, false);
    }
    setState(() {});
  }

  void _handleSpeaker() {
    final call = helper?.activeCall;
    if (call == null) return;
    _speakerOn = !_speakerOn;
    call.setSpeaker(_speakerOn);
    setState(() {});
  }

  void _bindEventListeners() {
    helper!.addSipUaHelperListener(this);
  }

  Future<Widget?> _handleCall(BuildContext context) async {
    var dest = _textController?.text;
    if (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS) {
      await Permission.microphone.request();
      await Permission.camera.request();
    }
    if (dest == null || dest.isEmpty) {
      if (_lastDialedNumber != null && _lastDialedNumber!.isNotEmpty) {
        setState(() {
          _textController!.text = _lastDialedNumber!;
        });
        _onDigitsChanged();
        return null;
      }
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (BuildContext context) {
          return AlertDialog(
            backgroundColor: AppColors.card,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            title: const Text('No number entered'),
            content: const Text('Please enter a number or SIP URI.'),
            actions: [
              TextButton(
                child: const Text('OK'),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          );
        },
      );
      return null;
    }
    _lastDialedNumber = dest;

    final mediaConstraints = <String, dynamic>{
      'audio': {
        'echoCancellation': true,
        'noiseSuppression': true,
        'autoGainControl': true,
        'channelCount': 2,
      },
      'video': false,
    };
    final mediaStream =
        await navigator.mediaDevices.getUserMedia(mediaConstraints);
    final normalized = dest.contains('@') ? dest : ensureE164(dest);
    helper!.call(normalized, voiceOnly: true, mediaStream: mediaStream);
    return null;
  }

  void _handleNum(String number) {
    setState(() {
      _textController!.text += number;
    });
  }

  void _handleBackspace() {
    final text = _textController!.text;
    if (text.isNotEmpty) {
      setState(() {
        _textController!.text = text.substring(0, text.length - 1);
      });
    }
  }

  // -- Registration status helpers --
  bool get _hasSipError {
    final state = helper?.registerState.state;
    return state == RegistrationStateEnum.REGISTRATION_FAILED ||
        state == RegistrationStateEnum.UNREGISTERED;
  }

  String get _statusText {
    final name = helper?.registerState.state?.name ?? '';
    if (name.isEmpty) return 'Disconnected';
    if (name.toLowerCase() == 'registered') return 'Ready';
    return name[0].toUpperCase() + name.substring(1).toLowerCase();
  }

  Color get _statusColor {
    switch (helper?.registerState.state?.name) {
      case 'registered':
        return AppColors.green;
      case 'unregistered':
        return AppColors.red;
      default:
        return AppColors.burntAmber;
    }
  }

  void _handleReconnect() {
    reRegisterWithCurrentUser();
    context.read<AgentService>().reconnect();
  }

  // ------- BUILD -------

  @override
  Widget build(BuildContext context) {
    currentUserCubit = context.watch<SipUserCubit>();
    final historyService = context.watch<CallHistoryService>();
    final contactService = context.watch<ContactService>();
    final tearSheetService = context.watch<TearSheetService>();
    final jobFunctionService = context.watch<JobFunctionService>();
    final icfService = context.watch<InboundCallFlowService>();
    final calendarService = context.watch<CalendarSyncService>();
    final messagingService = context.watch<MessagingService>();
    final width = MediaQuery.of(context).size.width;
    final showPanel = width >= 600;
    final panelWidth = showPanel ? (width * 0.38).clamp(320.0, 440.0) : 0.0;

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Stack(
        children: [
          Column(
            children: [
              const TearSheetStrip(),
              Expanded(
                child: Row(
                  children: [
                    Expanded(
                      child: SafeArea(
                        child: Column(
                          children: [
                            _buildTopBar(context),
                            Expanded(
                              child: _activeCall != null
                                  ? CallScreenWidget(
                                      helper,
                                      _activeCall,
                                      key: ValueKey(
                                          _logicalCallKey ?? _activeCall!.id),
                                      onDismiss: _dismissCallScreen,
                                    )
                                  : Focus(
                                      autofocus: true,
                                      focusNode: _focusNode,
                                      onKeyEvent: (node, event) {
                                        if (event is! KeyDownEvent &&
                                            event is! KeyRepeatEvent) {
                                          return KeyEventResult.ignored;
                                        }
                                        if (!_dropdownOpen ||
                                            _autocompleteMatches.isEmpty) {
                                          return KeyEventResult.ignored;
                                        }
                                        final len =
                                            _autocompleteMatches.length;
                                        final key = event.logicalKey;
                                        if (key ==
                                                LogicalKeyboardKey
                                                    .arrowDown ||
                                            (key ==
                                                    LogicalKeyboardKey
                                                        .tab &&
                                                !HardwareKeyboard.instance
                                                    .isShiftPressed)) {
                                          setState(() {
                                            _highlightedIndex =
                                                (_highlightedIndex + 1) %
                                                    len;
                                          });
                                          return KeyEventResult.handled;
                                        }
                                        if (key ==
                                                LogicalKeyboardKey
                                                    .arrowUp ||
                                            (key ==
                                                    LogicalKeyboardKey
                                                        .tab &&
                                                HardwareKeyboard.instance
                                                    .isShiftPressed)) {
                                          setState(() {
                                            _highlightedIndex =
                                                (_highlightedIndex - 1 +
                                                        len) %
                                                    len;
                                          });
                                          return KeyEventResult.handled;
                                        }
                                        if (key ==
                                                LogicalKeyboardKey.enter &&
                                            _highlightedIndex >= 0) {
                                          _onAutocompleteSelect(
                                              _autocompleteMatches[
                                                  _highlightedIndex]);
                                          return KeyEventResult.handled;
                                        }
                                        return KeyEventResult.ignored;
                                      },
                                      child: _buildDialpadSection(),
                                    ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (showPanel)
                      SizedBox(
                        width: panelWidth,
                        child: const AgentPanel(),
                      ),
                  ],
                ),
              ),
            ],
          ),
          if (historyService.isOpen)
            Positioned(
              top: 0,
              bottom: 0,
              left: 0,
              right: showPanel ? panelWidth : 0,
              child: GestureDetector(
                onTap: historyService.closeHistory,
                child: Container(color: Colors.black54),
              ),
            ),
          if (historyService.isOpen)
            Positioned(
              top: 0,
              bottom: 0,
              left: 0,
              right: panelWidth,
              child: const CallHistoryPanel(),
            ),
          if (contactService.isOpen)
            Positioned(
              top: 0,
              bottom: 0,
              left: 0,
              right: showPanel ? panelWidth : 0,
              child: GestureDetector(
                onTap: contactService.closeContacts,
                child: Container(color: Colors.black54),
              ),
            ),
          if (contactService.isOpen)
            Positioned(
              top: 0,
              bottom: 0,
              left: 0,
              right: panelWidth,
              child: const ContactListPanel(),
            ),
          if (calendarService.isOpen)
            Positioned(
              top: 0,
              bottom: 0,
              left: 0,
              right: showPanel ? panelWidth : 0,
              child: GestureDetector(
                onTap: calendarService.close,
                child: Container(color: Colors.black54),
              ),
            ),
          if (calendarService.isOpen)
            Positioned(
              top: 0,
              bottom: 0,
              left: 0,
              right: panelWidth,
              child: const CalendarPanel(),
            ),
          if (messagingService.isOpen)
            Positioned(
              top: 0,
              bottom: 0,
              left: 0,
              right: showPanel ? panelWidth : 0,
              child: GestureDetector(
                onTap: messagingService.close,
                child: Container(color: Colors.black54),
              ),
            ),
          if (messagingService.isOpen)
            Positioned(
              top: 0,
              bottom: 0,
              left: 0,
              right: panelWidth,
              child: const MessagingPanel(),
            ),
          if (contactService.isQuickAddOpen)
            Positioned(
              top: 0,
              bottom: 0,
              left: 0,
              right: showPanel ? panelWidth : 0,
              child: GestureDetector(
                onTap: contactService.closeQuickAdd,
                child: Container(color: Colors.black38),
              ),
            ),
          if (contactService.isQuickAddOpen)
            Positioned(
              top: 0,
              bottom: 0,
              left: 0,
              right: showPanel ? panelWidth : 0,
              child: const QuickAddOverlay(),
            ),
          if (tearSheetService.isEditorOpen)
            Positioned(
              top: 0,
              bottom: 0,
              left: 0,
              right: showPanel ? panelWidth : 0,
              child: GestureDetector(
                onTap: tearSheetService.closeEditor,
                child: Container(color: Colors.black38),
              ),
            ),
          if (tearSheetService.isEditorOpen)
            Positioned(
              top: 0,
              bottom: 0,
              left: 0,
              right: showPanel ? panelWidth : 0,
              child: const TearSheetEditor(),
            ),
          if (jobFunctionService.isEditorOpen)
            Positioned(
              top: 0,
              bottom: 0,
              left: 0,
              right: showPanel ? panelWidth : 0,
              child: GestureDetector(
                onTap: jobFunctionService.closeEditor,
                child: Container(color: Colors.black38),
              ),
            ),
          if (jobFunctionService.isEditorOpen)
            Positioned(
              top: 0,
              bottom: 0,
              left: 0,
              right: showPanel ? panelWidth : 0,
              child: const JobFunctionEditor(),
            ),
          if (icfService.isEditorOpen)
            Positioned(
              top: 0,
              bottom: 0,
              left: 0,
              right: showPanel ? panelWidth : 0,
              child: GestureDetector(
                onTap: icfService.closeEditor,
                child: Container(color: Colors.black38),
              ),
            ),
          if (icfService.isEditorOpen)
            Positioned(
              top: 0,
              bottom: 0,
              left: 0,
              right: showPanel ? panelWidth : 0,
              child: const InboundCallFlowEditor(),
            ),
        ],
      ),
    );
  }

  void _dismissAutocomplete() {
    if (_dropdownOpen) {
      setState(() {
        _dropdownOpen = false;
        _highlightedIndex = -1;
      });
    }
  }

  Widget _buildDialpadSection() {
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
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 450),
            child: _buildPhoneContent(),
          ),
        ),
      ],
    );
  }

  Widget _buildConferenceBadge() {
    final conf = Provider.of<ConferenceService>(context);
    if (!conf.hasConference && conf.legCount < 2) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(left: 10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: conf.hasConference
              ? AppColors.green.withValues(alpha: 0.12)
              : AppColors.burntAmber.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: conf.hasConference
                ? AppColors.green.withValues(alpha: 0.3)
                : AppColors.burntAmber.withValues(alpha: 0.3),
            width: 0.5,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              conf.hasConference
                  ? Icons.groups_rounded
                  : Icons.call_split_rounded,
              size: 12,
              color:
                  conf.hasConference ? AppColors.green : AppColors.burntAmber,
            ),
            const SizedBox(width: 4),
            Text(
              conf.hasConference
                  ? 'Conference (${conf.legCount})'
                  : '${conf.legCount} calls',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color:
                    conf.hasConference ? AppColors.green : AppColors.burntAmber,
              ),
            ),
          ],
        ),
      ),
    );
  }

  static const double _collapseThreshold = 700;

  Widget _buildTopBar(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= _collapseThreshold;
        return Padding(
          padding:
              const EdgeInsets.only(left: 90, right: 16, top: 18, bottom: 15),
          child: Row(
            children: [
              const PhonegenticLogo(size: 30),
              const SizedBox(width: 10),
              Text(
                'Phonegentic',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(width: 4),
              Text(
                'AI',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: AppColors.accent,
                  letterSpacing: -0.5,
                  shadows: [
                    Shadow(
                      color: AppColors.phosphor.withValues(alpha: 0.4),
                      blurRadius: 6,
                    ),
                  ],
                ),
              ),
              _buildConferenceBadge(),
              const Spacer(),
              HoverButton(
                onTap: _hasSipError ? _handleReconnect : null,
                borderRadius: BorderRadius.circular(20),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: _statusColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                        color: _statusColor.withValues(alpha: 0.25),
                        width: 0.5),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                            shape: BoxShape.circle, color: _statusColor),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        _statusText,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                          color: _statusColor,
                        ),
                      ),
                      if (_hasSipError) ...[
                        const SizedBox(width: 5),
                        Icon(
                          Icons.refresh_rounded,
                          size: 13,
                          color: _statusColor,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _buildRingToggleButton(context),
              const SizedBox(width: 4),
              if (wide) ...[
                _buildMessagesButton(context),
                const SizedBox(width: 4),
                _buildTearSheetButton(context),
                const SizedBox(width: 4),
                _buildContactsButton(context),
                const SizedBox(width: 4),
                _buildCallHistoryButton(context),
                const SizedBox(width: 4),
                _buildAudioDeviceButton(context),
                const SizedBox(width: 4),
              ],
              _buildMenuButton(context, collapsed: !wide),
            ],
          ),
        );
      },
    );
  }

  Widget _buildRingToggleButton(BuildContext context) {
    final ringtone = context.watch<RingtoneService>();
    final icf = context.watch<InboundCallFlowService>();
    final enabled = ringtone.ringEnabled;
    final hasFlow = icf.hasEnabledFlow;
    return Tooltip(
      message: hasFlow
          ? 'Inbound call flow active${enabled ? '' : ' (ring muted)'}'
          : (enabled ? 'Ring on (long-press for settings)' : 'Ring off'),
      child: HoverButton(
        onTap: () => ringtone.toggleRing(),
        onLongPress: () => _showRingSettingsPopover(context),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: enabled
                    ? AppColors.accent.withValues(alpha: 0.12)
                    : AppColors.card,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: enabled
                      ? AppColors.accent.withValues(alpha: 0.4)
                      : AppColors.border.withValues(alpha: 0.5),
                  width: 0.5,
                ),
              ),
              child: Icon(
                enabled
                    ? Icons.notifications_active_rounded
                    : Icons.notifications_off_rounded,
                size: 16,
                color: enabled ? AppColors.accent : AppColors.textTertiary,
              ),
            ),
            if (hasFlow)
              Positioned(
                top: -2,
                right: -2,
                child: Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: AppColors.green,
                    shape: BoxShape.circle,
                    border: Border.all(color: AppColors.bg, width: 1.5),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _showRingSettingsPopover(BuildContext context) {
    final ringtone = context.read<RingtoneService>();
    final icf = context.read<InboundCallFlowService>();
    final jf = context.read<JobFunctionService>();
    final RenderBox button = context.findRenderObject() as RenderBox;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final offset = button.localToGlobal(
      Offset(button.size.width / 2, button.size.height),
      ancestor: overlay,
    );

    showMenu<String>(
      context: context,
      constraints: const BoxConstraints(minWidth: 340, maxWidth: 380),
      position: RelativeRect.fromLTRB(
        offset.dx - 190,
        offset.dy + 4,
        offset.dx + 190,
        0,
      ),
      color: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
            color: AppColors.border.withValues(alpha: 0.5), width: 0.5),
      ),
      elevation: 8,
      items: [
        PopupMenuItem<String>(
          enabled: false,
          height: 28,
          child: Text(
            'RINGTONE',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: AppColors.textTertiary,
              letterSpacing: 0.8,
            ),
          ),
        ),
        ...ringtone.availableRingtones.map((r) => PopupMenuItem<String>(
              height: 36,
              onTap: () => ringtone.setRingtone(r.assetPath),
              child: Row(
                children: [
                  Icon(
                    r.assetPath == ringtone.selectedRingtone
                        ? Icons.radio_button_checked_rounded
                        : Icons.radio_button_off_rounded,
                    size: 14,
                    color: r.assetPath == ringtone.selectedRingtone
                        ? AppColors.accent
                        : AppColors.textTertiary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      r.displayName,
                      style: TextStyle(
                        fontSize: 12,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                  HoverButton(
                    onTap: () => ringtone.preview(r.assetPath),
                    child: Icon(
                      Icons.play_arrow_rounded,
                      size: 16,
                      color: AppColors.textTertiary,
                    ),
                  ),
                ],
              ),
            )),
        PopupMenuItem<String>(
          height: 36,
          onTap: () => ringtone.pickCustomRingtone(),
          child: Row(
            children: [
              Icon(Icons.upload_file_rounded,
                  size: 14, color: AppColors.accent),
              const SizedBox(width: 8),
              Text(
                'Upload custom...',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: AppColors.accent,
                ),
              ),
            ],
          ),
        ),
        const PopupMenuDivider(height: 1),
        PopupMenuItem<String>(
          enabled: false,
          height: 44,
          child: StatefulBuilder(
            builder: (ctx, setMenuState) {
              return Row(
                children: [
                  Expanded(
                    child: Text(
                      'Agent auto-answer',
                      style: TextStyle(
                        fontSize: 12,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                  SizedBox(
                    height: 24,
                    child: Switch(
                      value: ringtone.agentAutoAnswer,
                      activeColor: AppColors.accent,
                      onChanged: (v) {
                        ringtone.toggleAutoAnswer();
                        setMenuState(() {});
                      },
                    ),
                  ),
                ],
              );
            },
          ),
        ),
        if (icf.items.isNotEmpty) ...[
          const PopupMenuDivider(height: 1),
          PopupMenuItem<String>(
            enabled: false,
            height: 28,
            child: Text(
              'INBOUND CALL FLOWS',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                color: AppColors.textTertiary,
                letterSpacing: 0.8,
              ),
            ),
          ),
          ...icf.items.map((flow) {
            final ruleSummary = flow.rules.isEmpty
                ? 'No rules'
                : flow.rules.map((r) {
                    final fn = jf.items
                        .where((j) => j.id == r.jobFunctionId)
                        .firstOrNull;
                    final name = fn?.title ?? '?';
                    final pattern = r.phonePatterns.join(', ');
                    return '$name ($pattern)';
                  }).join(' → ');
            return PopupMenuItem<String>(
              value: 'icf_edit_${flow.id}',
              height: 44,
              child: Row(
                children: [
                  Icon(
                    flow.enabled
                        ? Icons.check_circle_rounded
                        : Icons.circle_outlined,
                    size: 14,
                    color:
                        flow.enabled ? AppColors.green : AppColors.textTertiary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          flow.name,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textPrimary,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          ruleSummary,
                          style: TextStyle(
                            fontSize: 10,
                            color: AppColors.textTertiary,
                          ),
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                        ),
                      ],
                    ),
                  ),
                  Icon(Icons.edit_rounded,
                      size: 14, color: AppColors.textTertiary),
                  const SizedBox(width: 6),
                  HoverButton(
                    onTap: () {
                      Navigator.of(context).pop('icf_delete_${flow.id}');
                    },
                    child: Icon(Icons.delete_outline_rounded,
                        size: 14, color: AppColors.textTertiary),
                  ),
                ],
              ),
            );
          }),
        ],
        const PopupMenuDivider(height: 1),
        PopupMenuItem<String>(
          value: 'icf_new',
          height: 36,
          child: Row(
            children: [
              Icon(Icons.call_received_rounded,
                  size: 14, color: AppColors.accent),
              const SizedBox(width: 8),
              Text(
                icf.items.isEmpty
                    ? 'New inbound call flow...'
                    : 'Add call flow...',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: AppColors.accent,
                ),
              ),
            ],
          ),
        ),
      ],
    ).then((value) {
      if (value == null) return;
      if (value == 'icf_new') {
        icf.openEditor();
      } else if (value.startsWith('icf_delete_')) {
        final id = int.tryParse(value.replaceFirst('icf_delete_', ''));
        if (id != null) _confirmDeleteFlow(context, icf, id);
      } else if (value.startsWith('icf_edit_')) {
        final id = int.tryParse(value.replaceFirst('icf_edit_', ''));
        if (id != null) {
          final flow = icf.items.where((f) => f.id == id).firstOrNull;
          if (flow != null) icf.openEditor(flow);
        }
      }
    });
  }

  Future<void> _confirmDeleteFlow(
      BuildContext context, InboundCallFlowService icf, int id) async {
    final flow = icf.items.where((f) => f.id == id).firstOrNull;
    if (flow == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Text('Delete "${flow.name}"?',
            style: TextStyle(fontSize: 15, color: AppColors.textPrimary)),
        content: Text(
            'This inbound call flow and its rules will be permanently removed.',
            style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child:
                Text('Cancel', style: TextStyle(color: AppColors.textTertiary)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('Delete', style: TextStyle(color: AppColors.red)),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await icf.delete(id);
    }
    if (mounted) _showRingSettingsPopover(context);
  }

  Widget _buildMessagesButton(BuildContext context) {
    final messaging = context.read<MessagingService>();
    final unread = messaging.unreadCount;
    return HoverButton(
      onTap: () => messaging.toggleOpen(),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: messaging.isOpen
                  ? AppColors.accent.withValues(alpha: 0.12)
                  : AppColors.card,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: messaging.isOpen
                    ? AppColors.accent.withValues(alpha: 0.4)
                    : AppColors.border.withValues(alpha: 0.5),
                width: 0.5,
              ),
            ),
            child: Icon(
              Icons.chat_bubble_outline_rounded,
              size: 16,
              color:
                  messaging.isOpen ? AppColors.accent : AppColors.textSecondary,
            ),
          ),
          if (unread > 0)
            Positioned(
              top: -4,
              right: -4,
              child: Container(
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  color: AppColors.red,
                  shape: BoxShape.circle,
                ),
                constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
                child: Text(
                  unread > 99 ? '99+' : '$unread',
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                    color: AppColors.onAccent,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildTearSheetButton(BuildContext context) {
    final tearSheet = context.read<TearSheetService>();
    return HoverButton(
      onTap: () {
        if (tearSheet.isActive) {
          tearSheet.dismissSheet();
        } else {
          tearSheet.openEditor();
        }
      },
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: tearSheet.isActive
              ? AppColors.accent.withValues(alpha: 0.12)
              : AppColors.card,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: tearSheet.isActive
                ? AppColors.accent.withValues(alpha: 0.4)
                : AppColors.border.withValues(alpha: 0.5),
            width: 0.5,
          ),
        ),
        child: Icon(
          Icons.receipt_long_rounded,
          size: 16,
          color:
              tearSheet.isActive ? AppColors.accent : AppColors.textSecondary,
        ),
      ),
    );
  }

  Widget _buildContactsButton(BuildContext context) {
    return HoverButton(
      onTap: () {
        context.read<ContactService>().toggleContacts();
      },
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
              color: AppColors.border.withValues(alpha: 0.5), width: 0.5),
        ),
        child: Icon(Icons.contacts_rounded,
            size: 16, color: AppColors.textSecondary),
      ),
    );
  }

  Widget _buildCallHistoryButton(BuildContext context) {
    return HoverButton(
      onTap: () {
        context.read<CallHistoryService>().toggleHistory();
      },
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
              color: AppColors.border.withValues(alpha: 0.5), width: 0.5),
        ),
        child: Icon(Icons.history_rounded,
            size: 16, color: AppColors.textSecondary),
      ),
    );
  }

  Widget _buildAudioDeviceButton(BuildContext context) {
    return HoverButton(
      onTap: () => showAudioDeviceSheet(context),
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
              color: AppColors.border.withValues(alpha: 0.5), width: 0.5),
        ),
        child: Icon(Icons.headphones_rounded,
            size: 16, color: AppColors.textSecondary),
      ),
    );
  }

  Widget _buildMenuButton(BuildContext context, {bool collapsed = false}) {
    return PopupMenuButton<String>(
      onSelected: (value) {
        switch (value) {
          case 'tear_sheet':
            final ts = context.read<TearSheetService>();
            ts.isActive ? ts.dismissSheet() : ts.openEditor();
            break;
          case 'account':
            Navigator.pushNamed(context, '/register');
            break;
          case 'contacts':
            context.read<ContactService>().toggleContacts();
            break;
          case 'history':
            context.read<CallHistoryService>().toggleHistory();
            break;
          case 'audio':
            showAudioDeviceSheet(context);
            break;
          case 'messages':
            context.read<MessagingService>().toggleOpen();
            break;
          case 'calendar':
            context.read<CalendarSyncService>().toggleOpen();
            break;
        }
      },
      icon: Icon(Icons.more_horiz, color: AppColors.textSecondary, size: 20),
      color: AppColors.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: AppColors.border, width: 0.5),
      ),
      itemBuilder: (_) => [
        if (collapsed) ...[
          PopupMenuItem(
            value: 'history',
            child: Row(
              children: [
                Icon(Icons.history_rounded,
                    size: 18, color: AppColors.textSecondary),
                const SizedBox(width: 10),
                const Text('Call History', style: TextStyle(fontSize: 13)),
              ],
            ),
          ),
          PopupMenuItem(
            value: 'contacts',
            child: Row(
              children: [
                Icon(Icons.contacts_rounded,
                    size: 18, color: AppColors.textSecondary),
                const SizedBox(width: 10),
                const Text('Contacts', style: TextStyle(fontSize: 13)),
              ],
            ),
          ),
          PopupMenuItem(
            value: 'tear_sheet',
            child: Row(
              children: [
                Icon(Icons.receipt_long_rounded,
                    size: 18, color: AppColors.textSecondary),
                const SizedBox(width: 10),
                Text(
                  context.read<TearSheetService>().isActive
                      ? 'Dismiss Tear Sheet'
                      : 'New Tear Sheet',
                  style: const TextStyle(fontSize: 13),
                ),
              ],
            ),
          ),
          const PopupMenuDivider(),
          PopupMenuItem(
            value: 'audio',
            child: Row(
              children: [
                Icon(Icons.headphones_rounded,
                    size: 18, color: AppColors.textSecondary),
                const SizedBox(width: 10),
                const Text('Audio Devices', style: TextStyle(fontSize: 13)),
              ],
            ),
          ),
        ],
        PopupMenuItem(
          value: 'messages',
          child: Row(
            children: [
              Icon(Icons.chat_bubble_outline_rounded,
                  size: 18, color: AppColors.textSecondary),
              const SizedBox(width: 10),
              Text(
                'Messages${context.read<MessagingService>().unreadCount > 0 ? ' (${context.read<MessagingService>().unreadCount})' : ''}',
                style: const TextStyle(fontSize: 13),
              ),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'calendar',
          child: Row(
            children: [
              Icon(Icons.calendar_month_rounded,
                  size: 18, color: AppColors.textSecondary),
              const SizedBox(width: 10),
              const Text('Calendar', style: TextStyle(fontSize: 13)),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'account',
          child: Row(
            children: [
              Icon(Icons.settings_outlined,
                  size: 18, color: AppColors.textSecondary),
              const SizedBox(width: 10),
              const Text('Settings', style: TextStyle(fontSize: 13)),
            ],
          ),
        ),
      ],
    );
  }

  void _onAutocompleteSelect(Map<String, dynamic> contact) {
    final phone = contact['phone_number'] as String? ?? '';
    if (phone.isEmpty) return;
    final digits = phone.replaceAll(RegExp(r'[^\d+]'), '');
    setState(() {
      _selectedContact = contact;
      _textController!.text = digits;
      _dropdownOpen = false;
      _highlightedIndex = -1;
    });
  }

  void _onAutocompleteCall(Map<String, dynamic> contact) {
    final phone = contact['phone_number'] as String? ?? '';
    if (phone.isEmpty) return;
    final digits = phone.replaceAll(RegExp(r'[^\d+]'), '');
    setState(() {
      _textController!.text = digits;
      _dropdownOpen = false;
      _autocompleteMatches = [];
    });
    _handleCall(context);
  }

  void _onAutocompleteMessage(Map<String, dynamic> contact) {
    final phone = contact['phone_number'] as String? ?? '';
    if (phone.isEmpty) return;
    setState(() => _dropdownOpen = false);
    final messaging = context.read<MessagingService>();
    messaging.openToConversation(phone);
  }

  void _onAutocompleteContact(Map<String, dynamic> contact) {
    final phone = contact['phone_number'] as String? ?? '';
    if (phone.isEmpty) return;
    setState(() => _dropdownOpen = false);
    context.read<ContactService>().openContactForPhone(phone);
  }

  Widget _buildPhoneContent() {
    final userPhone = TestCredentials.sipUser.displayName;
    final demoMode = context.watch<DemoModeService>();
    final showDropdown = _dropdownOpen && _autocompleteMatches.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            Text(
              demoMode.maskPhone(userPhone),
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: AppColors.textTertiary,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: 8),
            _buildNumberDisplay(),
            SizedBox(
              width: double.infinity,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(height: 28),
                      _buildNumPad(),
                      const SizedBox(height: 20),
                      _buildCallRow(),
                      const SizedBox(height: 12),
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
                        onContact: _onAutocompleteContact,
                        onDismiss: _dismissAutocomplete,
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

  void _toggleSearchDropdown() {
    final opening = !_dropdownOpen;
    setState(() => _dropdownOpen = opening);
    if (opening) _focusNode.requestFocus();
  }

  void _handleSlashSearch() {
    if (_dropdownOpen) {
      setState(() {
        _dropdownOpen = false;
        _highlightedIndex = -1;
      });
      return;
    }
    if (_autocompleteMatches.isNotEmpty) {
      setState(() => _dropdownOpen = true);
      _focusNode.requestFocus();
      return;
    }
    final text = _textController?.text ?? '';
    final contacts = Provider.of<ContactService>(context, listen: false);
    final matches = text.length >= 2
        ? contacts.autocompleteSearch(text)
        : contacts.contacts.take(8).toList();
    if (matches.isNotEmpty) {
      setState(() {
        _autocompleteMatches = matches;
        _dropdownOpen = true;
      });
      _focusNode.requestFocus();
    }
  }

  Widget _buildNumberDisplay() {
    final raw = _textController?.text ?? '';
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
                                  : _selectedContact!['display_name']
                                      as String,
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
                              fontWeight:
                                  hasLetters ? FontWeight.w400 : FontWeight.w300,
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
                            number: true,
                          ))
                      .toList(),
                ),
              ))
          .toList(),
    );
  }

  Widget _buildCallRow() {
    final hasActiveCall = helper?.activeCall != null;
    final text = _textController?.text ?? '';

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        SizedBox(
          width: 56,
          child: hasActiveCall
              ? ActionButton(
                  icon: _audioMuted ? Icons.mic_off : Icons.mic,
                  checked: _audioMuted,
                  onPressed: _handleMute,
                )
              : const SizedBox.shrink(),
        ),
        _CallButton(onTap: () => _handleCall(context)),
        SizedBox(
          width: 56,
          child: hasActiveCall
              ? ActionButton(
                  icon: _speakerOn ? Icons.volume_up : Icons.volume_off,
                  checked: _speakerOn,
                  onPressed: _handleSpeaker,
                )
              : (text.isNotEmpty
                  ? HoverButton(
                      onTap: _handleBackspace,
                      child: SizedBox(
                        width: 56,
                        height: 56,
                        child: Icon(Icons.backspace_outlined,
                            size: 22, color: AppColors.textTertiary),
                      ),
                    )
                  : const SizedBox.shrink()),
        ),
      ],
    );
  }

  // ------- SIP CALLBACKS -------

  @override
  void registrationStateChanged(RegistrationState state) {
    setState(() {
      _logger.i('Registration state: ${state.state?.name}');
    });
  }

  @override
  void transportStateChanged(TransportState state) {}

  ConferenceService get _confService =>
      Provider.of<ConferenceService>(context, listen: false);

  @override
  void callStateChanged(Call call, CallState callState) {
    final conf = _confService;

    switch (callState.state) {
      case CallStateEnum.CALL_INITIATION:
        final isIncoming = call.direction == Direction.incoming;
        final caller = call.remote_identity ?? '';

        // Fork coalescing: if this is an inbound INVITE from the same caller
        // we're already ringing for (or recently were), adopt it as the same
        // logical call — don't reset UI, don't treat as conference leg.
        final isForkReplacement = isIncoming &&
            _inboundRingCaller != null &&
            _inboundRingCaller == _normalizeCaller(caller) &&
            _inboundRingStart != null;

        if (isForkReplacement) {
          _forkGraceTimer?.cancel();
          _forkGraceTimer = null;
        }

        final isConferenceLeg = _calls.isNotEmpty && !isForkReplacement;
        setState(() {
          _calls[call.id] = call;
          _focusedCall = call;
        });
        conf.addLeg(call, isOutbound: !isIncoming);
        if (isConferenceLeg) {
          _tapChannel.invokeMethod('setConferenceMode', {'active': true});
          _startConferenceTimeout(call.id!);
        }
        if (isIncoming && !isForkReplacement) {
          _inboundRingCaller = _normalizeCaller(caller);
          _inboundRingStart = DateTime.now();
          _logicalCallKey = 'inbound_${DateTime.now().millisecondsSinceEpoch}';
          context.read<AgentService>().forkCoalescing = true;
          _handleInboundRing(call);
        } else if (isForkReplacement) {
          debugPrint('[Dialpad] Fork coalesced for $_inboundRingCaller');
        }
        break;
      case CallStateEnum.CONFIRMED:
        _stopRinging();
        _forkGraceTimer?.cancel();
        _inboundRingCaller = null;
        _forkGraceTimer = null;
        context.read<AgentService>().forkCoalescing = false;
        conf.updateLegState(call.id!, LegState.active);
        _cancelConferenceTimeout(call.id!);
        break;
      case CallStateEnum.HOLD:
        conf.updateLegState(call.id!, LegState.held);
        break;
      case CallStateEnum.UNHOLD:
        conf.updateLegState(call.id!, LegState.active);
        break;
      case CallStateEnum.FAILED:
      case CallStateEnum.ENDED:
        _cancelConferenceTimeout(call.id!);

        // ── Fork coalescing: during an active inbound ring session,
        // DON'T tear down state or rebuild the UI for individual fork
        // deaths. Just silently remove the leg and wait for the
        // replacement fork (or the grace timer to expire).
        if (_inboundRingCaller != null) {
          conf.removeLeg(call.id!);
          _calls.remove(call.id);
          // Don't touch _focusedCall — keep pointing at the (now-dead)
          // call so the widget tree stays stable. The next fork's
          // CALL_INITIATION will update it.
          if (_calls.isEmpty) {
            _forkGraceTimer?.cancel();
            _forkGraceTimer = Timer(
              const Duration(milliseconds: _forkGraceMs),
              () => _endInboundRingSession(),
            );
          }
          debugPrint('[Dialpad] Fork died during ring session '
              '(remaining=${_calls.length}, grace=${_calls.isEmpty})');
          break;
        }

        final wasConferenceLeg = _calls.length > 1;
        conf.removeLeg(call.id!);
        setState(() {
          _calls.remove(call.id);
          if (_focusedCall?.id == call.id && _calls.isNotEmpty) {
            _focusedCall = _calls.values.first;
          }
          if (_calls.isEmpty) {
            _focusedCall = null;
            _logicalCallKey = null;
            _audioMuted = false;
            _speakerOn = false;
            _textController?.text = '';
            _autocompleteMatches = [];
            _dropdownOpen = false;
          }
        });

        if (_calls.isEmpty) {
          context.read<InboundCallFlowService>().clearActiveFlow();
          if (_safetyCallModeForced) {
            _safetyCallModeForced = false;
            Future.delayed(const Duration(milliseconds: 500), () {
              _tapChannel.invokeMethod('exitCallMode');
              debugPrint('[Dialpad] Auto-answer safety: exitCallMode on call end');
            });
          }
        }
        _stopRinging();

        if (_calls.length <= 1) {
          Future.microtask(() =>
              _tapChannel.invokeMethod('setConferenceMode', {'active': false}));
        }
        if (wasConferenceLeg && _calls.length == 1) {
          final remaining = _calls.values.first;
          if (remaining.state == CallStateEnum.HOLD) {
            remaining.unhold();
            debugPrint(
                '[Dialpad] Auto-unhold remaining call after conference leg failed');
          }
          if (callState.state == CallStateEnum.FAILED && mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content:
                    Text('Conference call failed — returned to active call'),
                duration: Duration(seconds: 3),
              ),
            );
          }
        }
        if (callState.state == CallStateEnum.FAILED &&
            _calls.isEmpty &&
            callState.cause?.cause != 'Canceled') {
          reRegisterWithCurrentUser();
        }
        if (_calls.isEmpty) {
          conf.reset();
        }
        break;
      case CallStateEnum.MUTED:
        if (call.id == _focusedCall?.id) {
          setState(() {
            if (callState.audio == true) _audioMuted = true;
          });
        }
        break;
      case CallStateEnum.UNMUTED:
        if (call.id == _focusedCall?.id) {
          setState(() {
            if (callState.audio == true) _audioMuted = false;
          });
        }
        break;
      default:
    }

    // Sync focused call from conference service selection
    if (conf.focusedLegId != null && conf.focusedLegId != _focusedCall?.id) {
      final target = _calls[conf.focusedLegId];
      if (target != null) {
        setState(() => _focusedCall = target);
      }
    }
  }

  void _startConferenceTimeout(String callId) {
    _conferenceTimeout?.cancel();
    _conferenceTimeoutCallId = callId;
    _conferenceTimeout = Timer(const Duration(seconds: 30), () {
      debugPrint('[Dialpad] Conference leg $callId timed out — hanging up');
      final stuckCall = _calls[callId];
      if (stuckCall != null) {
        try {
          stuckCall.hangup({'status_code': 408});
        } catch (e) {
          debugPrint('[Dialpad] Failed to hang up stuck call: $e');
        }
      }
      _conferenceTimeoutCallId = null;
    });
  }

  void _cancelConferenceTimeout(String callId) {
    if (_conferenceTimeoutCallId == callId) {
      _conferenceTimeout?.cancel();
      _conferenceTimeout = null;
      _conferenceTimeoutCallId = null;
    }
  }

  void _dismissCallScreen() {
    setState(() {
      _focusedCall = _calls.values.isNotEmpty ? _calls.values.first : null;
    });
  }

  void _handleInboundRing(Call call) {
    final ringtone = context.read<RingtoneService>();
    final icf = context.read<InboundCallFlowService>();
    final jf = context.read<JobFunctionService>();
    final agent = context.read<AgentService>();

    ringtone.startRinging();

    final caller = call.remote_identity ?? '';
    debugPrint('[Dialpad] Inbound ring from "$caller" '
        '(flows=${icf.items.length}, '
        'enabled=${icf.items.where((f) => f.enabled).length})');

    agent.notifyCallPhase(
      CallPhase.ringing,
      remoteIdentity: call.remote_identity,
      remoteDisplayName: call.remote_display_name,
      localIdentity: call.local_identity,
      outbound: false,
    );

    final matchedId = icf.resolveJobFunctionId(caller);
    debugPrint('[Dialpad] ICF resolved jobFunctionId=$matchedId for "$caller"');

    if (matchedId != null) {
      // Await the job function switch so it completes before auto-answer.
      _applyInboundJobFunction(matchedId, jf, agent);
    }

    if (ringtone.agentAutoAnswer && _calls.length <= 1) {
      Future.delayed(const Duration(milliseconds: 800), () {
        if (!mounted) return;
        if (call.state == CallStateEnum.CALL_INITIATION ||
            call.state == CallStateEnum.PROGRESS) {
          debugPrint('[Dialpad] Auto-answer firing for ${call.remote_identity}');
          CallScreenWidget.acceptCall(call, helper!);
          _scheduleAutoAnswerSafetyCheck(call);
        }
      });
    }
  }

  /// Safety net: if the SIP CONFIRMED/ACCEPTED callback was lost after
  /// auto-answer, directly push the settling phase so the agent starts
  /// the greeting flow. Without this, lost SIP callbacks leave the agent
  /// stuck in ringing with dead silence.
  void _scheduleAutoAnswerSafetyCheck(Call call) {
    Future.delayed(const Duration(seconds: 2), () {
      if (!mounted) return;
      final agent = context.read<AgentService>();
      final needsRecovery = agent.callPhase == CallPhase.ringing ||
          agent.callPhase == CallPhase.connecting;
      if (!needsRecovery) return;

      debugPrint('[Dialpad] Auto-answer safety: agent stuck in '
          '${agent.callPhase.name}, forcing settling');

      _stopRinging();
      _forkGraceTimer?.cancel();
      _inboundRingCaller = null;
      _inboundRingStart = null;
      _forkGraceTimer = null;
      agent.forkCoalescing = false;

      // The CallScreen's SIP listener missed the ACCEPTED/CONFIRMED
      // transitions, so enterCallMode was never called. Route TTS audio
      // through the WebRTC stream so the remote party can hear the agent.
      _safetyCallModeForced = true;
      _tapChannel.invokeMethod('enterCallMode').then((_) {
        _tapChannel.invokeMethod('setRemoteGain', {'gain': 1.5});
        _tapChannel.invokeMethod('setCompressorStrength', {'strength': 0.6});
        debugPrint(
            '[Dialpad] Auto-answer safety: enterCallMode forced');
      }).catchError((e) {
        debugPrint('[Dialpad] Auto-answer safety: enterCallMode failed: $e');
      });

      agent.notifyCallPhase(
        CallPhase.settling,
        partyCount: 2,
        remoteIdentity: call.remote_identity,
        remoteDisplayName: call.remote_display_name,
        localIdentity: call.local_identity,
        outbound: false,
      );
    });
  }

  Future<void> _applyInboundJobFunction(
      int jobFunctionId, JobFunctionService jf, AgentService agent) async {
    await jf.select(jobFunctionId);
    final selected = jf.selected;
    debugPrint('[Dialpad] Job function selected: '
        '${selected?.title ?? "null"} (id=${selected?.id})');
    agent.updateBootContext(
      jf.buildBootContext(),
      jobFunctionName: selected?.title,
      whisperByDefault: selected?.whisperByDefault,
    );
  }

  void _stopRinging() {
    try {
      context.read<RingtoneService>().stopRinging();
    } catch (_) {}
  }

  static String _normalizeCaller(String raw) {
    final digits = raw.replaceAll(RegExp(r'[^\d]'), '');
    return digits.length >= 10 ? digits.substring(digits.length - 10) : digits;
  }

  void _endInboundRingSession() {
    _forkGraceTimer?.cancel();
    _inboundRingCaller = null;
    _inboundRingStart = null;
    _forkGraceTimer = null;
    _logicalCallKey = null;
    try {
      final agent = context.read<AgentService>();
      agent.forkCoalescing = false;
      if (_calls.isEmpty && agent.hasActiveCall) {
        agent.notifyCallPhase(CallPhase.failed);
      }
      context.read<InboundCallFlowService>().clearActiveFlow();
    } catch (_) {}
    if (_calls.isEmpty) {
      _stopRinging();
      // NOW trigger the UI rebuild to clear the dead call screen.
      setState(() {
        _focusedCall = null;
        _audioMuted = false;
        _speakerOn = false;
      });
      _confService.reset();
    }
  }

  void reRegisterWithCurrentUser() async {
    if (currentUserCubit.state == null) return;
    if (helper!.registered) await helper!.unregister();
    _logger.i('Re-registering');
    currentUserCubit.register(currentUserCubit.state!);
  }

  @override
  void onNewMessage(SIPMessageRequest msg) {
    String? msgBody = msg.request.body as String?;
    setState(() {
      receivedMsg = msgBody;
    });
  }

  @override
  void onNewNotify(Notify ntf) {}

  @override
  void onNewReinvite(ReInvite event) {
    if (event.accept == null || event.reject == null) return;

    // Auto-accept audio-only re-INVITEs globally so that conference media
    // redirects, session-timer refreshes, and hold/unhold re-INVITEs are
    // always answered — even when no CallScreen is mounted for that leg.
    // The accept callback is session-specific (bound to the originating SIP
    // dialog), so calling it here is safe for any call.
    if (!(event.hasVideo ?? false)) {
      debugPrint('[Dialpad] Auto-accepting audio re-INVITE');
      event.accept!({});
    }
  }
}

class _CallButton extends StatefulWidget {
  final VoidCallback onTap;
  const _CallButton({required this.onTap});

  @override
  State<_CallButton> createState() => _CallButtonState();
}

class _CallButtonState extends State<_CallButton>
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
    _glowAnim = Tween<double>(begin: 0.25, end: 0.35).animate(
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
                      AppColors.burntAmber,
                    ],
                    stops: const [0.0, 1.0],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.phosphor
                          .withValues(alpha: _hovered ? 0.6 : _glowAnim.value),
                      blurRadius: _hovered ? 6 : 4,
                      spreadRadius: _hovered ? 4 : 2,
                    ),
                  ],
                ),
                child: Icon(Icons.phone, size: 30, color: AppColors.crtBlack),
              );
            },
          ),
        ),
      ),
    );
  }
}
