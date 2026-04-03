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
import 'contact_service.dart';
import 'demo_mode_service.dart';
import 'messaging/messaging_service.dart';
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
import 'widgets/phonegentic_logo.dart';
import 'widgets/quick_add_overlay.dart';
import 'widgets/tear_sheet_editor.dart';
import 'widgets/tear_sheet_strip.dart';

class DialPadWidget extends StatefulWidget {
  final SIPUAHelper? _helper;
  DialPadWidget(this._helper, {Key? key}) : super(key: key);

  @override
  State<DialPadWidget> createState() => _MyDialPadWidget();
}

class _MyDialPadWidget extends State<DialPadWidget> implements SipUaHelperListener {
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
  Call? _activeCall;

  @override
  void initState() {
    super.initState();
    receivedMsg = '';
    _bindEventListeners();
    _loadSettings();
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
    _focusNode.dispose();
    _textController?.dispose();
    super.dispose();
  }

  void _loadSettings() {
    _dest = '';
    _textController = TextEditingController(text: _dest);
    _textController!.text = _dest ?? '';
    setState(() {});
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.backspace) {
      final text = _textController!.text;
      if (text.isNotEmpty) {
        setState(() {
          _textController!.text = text.substring(0, text.length - 1);
        });
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    final character = event.character;
    if (character == null || character.isEmpty) return KeyEventResult.ignored;

    const dialChars = '0123456789*#+';
    if (dialChars.contains(character)) {
      setState(() {
        _textController!.text += character;
      });
      return KeyEventResult.handled;
    }

    // Letters → redirect focus to the agent panel text input.
    if (RegExp(r'^[a-zA-Z]$').hasMatch(character)) {
      final agentFocus = AgentPanel.inputFocusNode;
      final agentCtrl = AgentPanel.inputController;
      if (agentFocus != null && agentCtrl != null) {
        agentCtrl.text += character;
        agentCtrl.selection = TextSelection.collapsed(
          offset: agentCtrl.text.length,
        );
        agentFocus.requestFocus();
        return KeyEventResult.handled;
      }
    }

    return KeyEventResult.ignored;
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
    final dest = _textController?.text;
    if (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS) {
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
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
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
    final mediaStream = await navigator.mediaDevices.getUserMedia(mediaConstraints);
    helper!.call(dest, voiceOnly: true, mediaStream: mediaStream);
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
                              onDismiss: _dismissCallScreen,
                            )
                          : Focus(
                              autofocus: true,
                              focusNode: _focusNode,
                              onKeyEvent: _handleKeyEvent,
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

  static const double _collapseThreshold = 700;

  Widget _buildTopBar(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= _collapseThreshold;
        return Padding(
          padding: const EdgeInsets.only(
              left: 90, right: 16, top: 18, bottom: 15),
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
                      color: AppColors.phosphor.withOpacity(0.4),
                      blurRadius: 6,
                    ),
                  ],
                ),
              ),
              const Spacer(),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: _statusColor.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                      color: _statusColor.withOpacity(0.25), width: 0.5),
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
                  ],
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
    return GestureDetector(
      onTap: () => messaging.toggleOpen(),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: messaging.isOpen
                  ? AppColors.accent.withOpacity(0.12)
                  : AppColors.card,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: messaging.isOpen
                    ? AppColors.accent.withOpacity(0.4)
                    : AppColors.border.withOpacity(0.5),
                width: 0.5,
              ),
            ),
            child: Icon(
              Icons.chat_bubble_outline_rounded,
              size: 16,
              color: messaging.isOpen
                  ? AppColors.accent
                  : AppColors.textSecondary,
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
    return GestureDetector(
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
              ? AppColors.accent.withOpacity(0.12)
              : AppColors.card,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: tearSheet.isActive
                ? AppColors.accent.withOpacity(0.4)
                : AppColors.border.withOpacity(0.5),
            width: 0.5,
          ),
        ),
        child: Icon(
          Icons.receipt_long_rounded,
          size: 16,
          color: tearSheet.isActive
              ? AppColors.accent
              : AppColors.textSecondary,
        ),
      ),
    );
  }

  Widget _buildContactsButton(BuildContext context) {
    return GestureDetector(
      onTap: () {
        context.read<ContactService>().toggleContacts();
      },
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.border.withOpacity(0.5), width: 0.5),
        ),
        child: Icon(Icons.contacts_rounded, size: 16, color: AppColors.textSecondary),
      ),
    );
  }

  Widget _buildCallHistoryButton(BuildContext context) {
    return GestureDetector(
      onTap: () {
        context.read<CallHistoryService>().toggleHistory();
      },
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.border.withOpacity(0.5), width: 0.5),
        ),
        child: Icon(Icons.history_rounded, size: 16, color: AppColors.textSecondary),
      ),
    );
  }

  Widget _buildAudioDeviceButton(BuildContext context) {
    return GestureDetector(
      onTap: () => showAudioDeviceSheet(context),
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.border.withOpacity(0.5), width: 0.5),
        ),
        child: Icon(Icons.headphones_rounded, size: 16, color: AppColors.textSecondary),
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
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
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
                          color: AppColors.phosphor.withOpacity(0.35),
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
        // Left action: mute (during call) or empty space
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
        // Right action: backspace or speaker
        SizedBox(
          width: 56,
          child: hasActiveCall
              ? ActionButton(
                  icon: _speakerOn ? Icons.volume_up : Icons.volume_off,
                  checked: _speakerOn,
                  onPressed: _handleSpeaker,
                )
              : (text.isNotEmpty
                  ? GestureDetector(
                      onTap: _handleBackspace,
                      child: SizedBox(
                        width: 56,
                        height: 56,
                        child: Icon(Icons.backspace_outlined, size: 22, color: AppColors.textTertiary),
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

  @override
  void callStateChanged(Call call, CallState callState) {
    switch (callState.state) {
      case CallStateEnum.CALL_INITIATION:
        setState(() => _activeCall = call);
        break;
      case CallStateEnum.FAILED:
      case CallStateEnum.ENDED:
        setState(() {
          _audioMuted = false;
          _speakerOn = false;
        });
        if (callState.state == CallStateEnum.FAILED) {
          reRegisterWithCurrentUser();
        }
        break;
      case CallStateEnum.MUTED:
        setState(() {
          if (callState.audio == true) _audioMuted = true;
        });
        break;
      case CallStateEnum.UNMUTED:
        setState(() {
          if (callState.audio == true) _audioMuted = false;
        });
        break;
      default:
    }
  }

  void _dismissCallScreen() {
    setState(() => _activeCall = null);
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
  void onNewReinvite(ReInvite event) {}
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
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      AppColors.hotSignal,
                      AppColors.phosphor,
                      AppColors.burntAmber,
                    ],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.phosphor
                          .withOpacity(_hovered ? 0.6 : _glowAnim.value),
                      blurRadius: _hovered ? 28 : 20,
                      spreadRadius: _hovered ? 4 : 2,
                    ),
                    if (_hovered)
                      BoxShadow(
                        color: AppColors.hotSignal.withOpacity(0.3),
                        blurRadius: 40,
                        spreadRadius: 6,
                      ),
                  ],
                ),
                child: const Icon(
                    Icons.phone, size: 30, color: AppColors.crtBlack),
              );
            },
          ),
        ),
      ),
    );
  }
}
