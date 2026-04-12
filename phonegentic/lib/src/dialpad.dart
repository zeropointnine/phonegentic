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
import 'conference/telnyx_conference_provider.dart';
import 'contact_service.dart';
import 'demo_mode_service.dart';
import 'messaging/messaging_service.dart';
import 'messaging/phone_numbers.dart';
import 'phone_formatter.dart';
import 'job_function_service.dart';
import 'tear_sheet_service.dart';
import 'widgets/action_button.dart';
import 'widgets/agent_panel.dart';
import 'widgets/audio_device_sheet.dart';
import 'widgets/calendar_panel.dart';
import 'widgets/call_history_panel.dart';
import 'widgets/contact_list_panel.dart';
import 'widgets/messaging_panel.dart';
import 'widgets/job_function_editor.dart';
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

  Map<String, dynamic>? _matchedContact;

  static const _tapChannel = MethodChannel('com.agentic_ai/audio_tap_control');
  Timer? _conferenceTimeout;
  String? _conferenceTimeoutCallId;

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
    final digits = _textController?.text ?? '';
    if (digits.length < 3) {
      if (_matchedContact != null) setState(() => _matchedContact = null);
      return;
    }
    final contacts = Provider.of<ContactService>(context, listen: false);
    final match = contacts.lookupByPhone(digits);
    if (match != _matchedContact) {
      setState(() => _matchedContact = match);
    }
  }

  bool _handleGlobalKeyEvent(KeyEvent event) {
    if (!mounted) return false;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;
    if (_activeCall != null) return false;

    final FocusNode? primary = FocusManager.instance.primaryFocus;
    if (primary != null && primary.context != null) {
      if (primary.context!
              .findAncestorWidgetOfExactType<EditableText>() !=
          null) {
        return false;
      }
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

    final String? character = event.character;
    if (character == null || character.isEmpty) return false;

    const String dialChars = '0123456789*#+';
    if (dialChars.contains(character)) {
      setState(() {
        _textController!.text += character;
      });
      return true;
    }

    if (RegExp(r'^[a-zA-Z]$').hasMatch(character)) {
      final FocusNode? agentFocus = AgentPanel.inputFocusNode;
      final TextEditingController? agentCtrl = AgentPanel.inputController;
      if (agentFocus != null && agentCtrl != null) {
        agentCtrl.text += character;
        agentCtrl.selection = TextSelection.collapsed(
          offset: agentCtrl.text.length,
        );
        agentFocus.requestFocus();
        return true;
      }
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
    // Wire Telnyx call control webhook events to the conference service so
    // B-leg call_control_ids are captured for conference merging.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _wireCallControlWebhook();
    });
  }

  void _wireCallControlWebhook() {
    if (!mounted) return;
    final messaging =
        Provider.of<MessagingService>(context, listen: false);
    final conf = _confService;
    messaging.callControlHandler = (json) {
      final bLegCcid =
          TelnyxConferenceProvider.extractBLegFromWebhook(json);
      if (bLegCcid != null) {
        conf.onBLegDetected(bLegCcid);
      }
    };
  }

  Future<Widget?> _handleCall(BuildContext context) async {
    final dest = _textController?.text;
    if (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS) {
      await Permission.microphone.request();
      await Permission.camera.request();
    }
    if (dest == null || dest.isEmpty) {
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
                      child: _activeCall != null
                          ? CallScreenWidget(
                              helper,
                              _activeCall,
                              key: ValueKey(_activeCall!.id),
                              onDismiss: _dismissCallScreen,
                            )
                          : Focus(
                              autofocus: true,
                              focusNode: _focusNode,
                              child: _buildPhoneSection(context),
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
        ],
      ),
    );
  }

  Widget _buildPhoneSection(BuildContext context) {
    return SafeArea(
      child: Column(
        children: [
          _buildTopBar(context),
          Expanded(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 380),
                child: _buildPhoneContent(),
              ),
            ),
          ),
        ],
      ),
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

  Widget _buildPhoneContent() {
    final userPhone = TestCredentials.sipUser.displayName;
    final demoMode = context.watch<DemoModeService>();
    final bool showCard = _matchedContact != null;

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
            SizedBox(
              height: 56,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 320),
                switchInCurve: Curves.easeOut,
                switchOutCurve: Curves.easeIn,
                transitionBuilder: (child, animation) {
                  return FadeTransition(
                    opacity: animation,
                    child: SlideTransition(
                      position: Tween<Offset>(
                        begin: const Offset(0, 0.08),
                        end: Offset.zero,
                      ).animate(animation),
                      child: child,
                    ),
                  );
                },
                child: showCard
                    ? Padding(
                        key: ValueKey(_matchedContact!['id']),
                        padding: const EdgeInsets.only(bottom: 8),
                        child: DialpadContactPreview(
                            contact: _matchedContact!),
                      )
                    : const SizedBox.shrink(key: ValueKey('empty')),
              ),
            ),
            _buildNumberDisplay(),
            const SizedBox(height: 28),
            _buildNumPad(),
            const SizedBox(height: 20),
            _buildCallRow(),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  Widget _buildNumberDisplay() {
    final raw = _textController?.text ?? '';
    final demoMode = context.watch<DemoModeService>();
    final display = raw.isEmpty
        ? ''
        : demoMode.enabled
            ? demoMode.maskPhone(raw)
            : PhoneFormatter.format(raw);
    return Column(
      children: [
        SizedBox(
          height: 48,
          child: raw.isEmpty
              ? Text(
                  'Enter number',
                  style: TextStyle(
                    fontSize: 30,
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
                      fontSize: 34,
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
        final isConferenceLeg = _calls.isNotEmpty;
        setState(() {
          _calls[call.id] = call;
          _focusedCall = call;
        });
        conf.addLeg(call, isOutbound: true);
        if (isConferenceLeg) {
          _tapChannel.invokeMethod('setConferenceMode', {'active': true});
          _startConferenceTimeout(call.id!);
        }
        break;
      case CallStateEnum.CONFIRMED:
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
        final wasConferenceLeg = _calls.length > 1;
        conf.removeLeg(call.id!);
        setState(() {
          _calls.remove(call.id);
          if (_focusedCall?.id == call.id && _calls.isNotEmpty) {
            _focusedCall = _calls.values.first;
          }
          if (_calls.isEmpty) {
            _audioMuted = false;
            _speakerOn = false;
          }
        });
        if (_calls.length <= 1) {
          _tapChannel.invokeMethod('setConferenceMode', {'active': false});
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
        if (callState.state == CallStateEnum.FAILED && _calls.isEmpty) {
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

