import 'package:phonegentic/src/test_credentials.dart';
import 'package:phonegentic/src/user_state/sip_user.dart';
import 'package:phonegentic/src/user_state/sip_user_cubit.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sip_ua/sip_ua.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

import 'agent_config_service.dart';
import 'conference/conference_config.dart';
import 'conference/conference_service.dart';
import 'theme_provider.dart';
import 'tone_service.dart';
import 'widgets/agent_settings_tab.dart';
import 'widgets/user_settings_tab.dart';

class RegisterWidget extends StatefulWidget {
  final SIPUAHelper? _helper;
  RegisterWidget(this._helper, {super.key});

  @override
  State<RegisterWidget> createState() => _MyRegisterWidget();
}

class _MyRegisterWidget extends State<RegisterWidget>
    with SingleTickerProviderStateMixin
    implements SipUaHelperListener {
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _portController = TextEditingController();
  final TextEditingController _wsUriController = TextEditingController();
  final TextEditingController _sipUriController = TextEditingController();
  final TextEditingController _displayNameController = TextEditingController();
  final TextEditingController _authorizationUserController =
      TextEditingController();
  final Map<String, String> _wsExtraHeaders = {};

  ConferenceConfig _conf = const ConferenceConfig();
  CallRecordingConfig _recording = const CallRecordingConfig();
  bool _requireHdCodecs = false;

  late SharedPreferences _preferences;
  late RegistrationState _registerState;
  TransportType _selectedTransport = TransportType.TCP;
  late final TabController _tabController;

  SIPUAHelper? get helper => widget._helper;
  late SipUserCubit currentUser;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this, initialIndex: 1);
    _registerState = helper!.registerState;
    helper!.addSipUaHelperListener(this);
    _loadSettings();
    if (kIsWeb) _selectedTransport = TransportType.WS;
  }

  @override
  void dispose() {
    _tabController.dispose();
    _passwordController.dispose();
    _wsUriController.dispose();
    _sipUriController.dispose();
    _displayNameController.dispose();
    _authorizationUserController.dispose();
    super.dispose();
  }

  @override
  void deactivate() {
    super.deactivate();
    helper!.removeSipUaHelperListener(this);
    _saveSettings();
  }

  void _loadSettings() async {
    _preferences = await SharedPreferences.getInstance();
    final defaultUser = TestCredentials.sipUser;

    final cachedSipUri = _preferences.getString('sip_uri');
    if (cachedSipUri != null && cachedSipUri.contains('://')) {
      await _preferences.remove('sip_uri');
      await _preferences.remove('ws_uri');
      await _preferences.remove('port');
    }

    setState(() {
      _portController.text = _preferences.getString('port') ?? defaultUser.port;
      _wsUriController.text =
          _preferences.getString('ws_uri') ?? defaultUser.wsUrl ?? '';
      _sipUriController.text =
          _preferences.getString('sip_uri') ?? defaultUser.sipUri ?? '';
      _displayNameController.text =
          _preferences.getString('display_name') ?? defaultUser.displayName;
      _passwordController.text =
          _preferences.getString('password') ?? defaultUser.password;
      _authorizationUserController.text =
          _preferences.getString('auth_user') ?? defaultUser.authUser;
      if (defaultUser.selectedTransport == TransportType.WS) {
        _selectedTransport = TransportType.WS;
      }
      _requireHdCodecs = _preferences.getBool('require_hd_codecs') ?? false;
    });
    _loadConferenceConfig();
  }

  Future<void> _loadConferenceConfig() async {
    final conf = await AgentConfigService.loadConferenceConfig();
    final rec = await AgentConfigService.loadCallRecordingConfig();
    if (!mounted) return;
    setState(() {
      _conf = conf;
      _recording = rec;
    });
  }

  void _updateConference(ConferenceConfig c) {
    setState(() => _conf = c);
    AgentConfigService.saveConferenceConfig(c);
    context.read<ConferenceService>().applyConfig(c);
  }

  void _updateRecording(CallRecordingConfig r) {
    setState(() => _recording = r);
    AgentConfigService.saveCallRecordingConfig(r);
  }

  void _saveSettings() {
    _preferences.setString('port', _portController.text);
    _preferences.setString('ws_uri', _wsUriController.text);
    _preferences.setString('sip_uri', _sipUriController.text);
    _preferences.setString('display_name', _displayNameController.text);
    _preferences.setString('password', _passwordController.text);
    _preferences.setString('auth_user', _authorizationUserController.text);
    _preferences.setBool('require_hd_codecs', _requireHdCodecs);
  }

  @override
  void registrationStateChanged(RegistrationState state) {
    setState(() => _registerState = state);
  }

  void _alert(BuildContext context, String field) {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Text('$field is empty'),
        content: Text('Please enter $field.'),
        actions: [
          TextButton(
              child: const Text('OK'),
              onPressed: () => Navigator.of(context).pop()),
        ],
      ),
    );
  }

  void _register(BuildContext context) {
    if (_wsUriController.text.trim().isEmpty) {
      _alert(context, 'WebSocket URL');
      return;
    }
    if (_sipUriController.text.trim().isEmpty) {
      _alert(context, 'SIP URI');
      return;
    }
    _saveSettings();
    currentUser.register(SipUser(
      host: '',
      wsUrl: _wsUriController.text,
      selectedTransport: _selectedTransport,
      wsExtraHeaders: _wsExtraHeaders,
      sipUri: _sipUriController.text,
      port: _portController.text,
      displayName: _displayNameController.text,
      password: _passwordController.text,
      authUser: _authorizationUserController.text,
      requireHdCodecs: _requireHdCodecs,
    ));
  }

  String get _statusText {
    final name = _registerState.state?.name ?? '';
    if (name.isEmpty) return 'Disconnected';
    return name[0].toUpperCase() + name.substring(1).toLowerCase();
  }

  Color get _statusColor {
    switch (_registerState.state?.name) {
      case 'registered':
        return AppColors.green;
      case 'unregistered':
        return AppColors.red;
      default:
        return AppColors.burntAmber;
    }
  }

  @override
  Widget build(BuildContext context) {
    currentUser = context.watch<SipUserCubit>();

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        toolbarHeight: 52,
        leadingWidth: 100,
        leading: Align(
          alignment: Alignment.bottomLeft,
          child: Padding(
            padding: const EdgeInsets.only(left: 80),
            child: IconButton(
              icon: Icon(Icons.arrow_back_ios_new,
                  size: 18, color: AppColors.textSecondary),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
        ),
        title: Text(
          'Settings',
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w600,
            color: AppColors.textPrimary,
            letterSpacing: -0.3,
          ),
        ),
        centerTitle: true,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(44),
          child: _buildTabBar(),
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildPhoneTab(),
          const AgentSettingsTab(),
          const UserSettingsTab(),
        ],
      ),
    );
  }

  Widget _buildTabBar() {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 20),
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
                color: AppColors.border.withValues(alpha: 0.5), width: 0.5),
          ),
          child: TabBar(
            controller: _tabController,
            indicator: BoxDecoration(
              color: AppColors.accent,
              borderRadius: BorderRadius.circular(7),
              boxShadow: [
                BoxShadow(
                  color: AppColors.accent.withValues(alpha: 0.3),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            indicatorSize: TabBarIndicatorSize.tab,
            dividerHeight: 0,
            labelColor: AppColors.onAccent,
            unselectedLabelColor: AppColors.textSecondary,
            labelStyle: const TextStyle(
                fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: -0.2),
            unselectedLabelStyle: const TextStyle(
                fontSize: 12, fontWeight: FontWeight.w500, letterSpacing: -0.2),
            tabs: const [
              Tab(
                height: 32,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.phone_rounded, size: 14),
                    SizedBox(width: 6),
                    Text('Phone'),
                  ],
                ),
              ),
              Tab(
                height: 32,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.auto_awesome, size: 14),
                    SizedBox(width: 6),
                    Text('Agents'),
                  ],
                ),
              ),
              Tab(
                height: 32,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.widgets_rounded, size: 14),
                    SizedBox(width: 6),
                    Text('App'),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPhoneTab() {
    return ListView(
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: Column(
                children: [
                  const SizedBox(height: 8),
                  _buildStatusCard(),
                  const SizedBox(height: 20),
                  _buildSection('Connection', [
                    if (!kIsWeb) _buildTransportRow(),
                    if (_selectedTransport == TransportType.WS)
                      _buildField('WebSocket URL', _wsUriController,
                          placeholder: 'wss://sip.example.com:7443'),
                    if (_selectedTransport == TransportType.TCP)
                      _buildField('Port', _portController, placeholder: '5060'),
                    _buildField('SIP URI', _sipUriController,
                        placeholder: 'user@sip.example.com'),
                    _buildTestConnectionRow(),
                  ]),
                  const SizedBox(height: 16),
                  _buildSection('Authentication', [
                    _buildField('Auth User', _authorizationUserController,
                        placeholder: 'Username'),
                    _buildField('Password', _passwordController,
                        placeholder: 'Password', obscure: true),
                    _buildField('Display Name', _displayNameController,
                        placeholder: '+1234567890'),
                  ]),
                  const SizedBox(height: 16),
                  _buildConferenceCard(),
                  const SizedBox(height: 16),
                  _buildHdCodecCard(),
                  const SizedBox(height: 16),
                  _buildCallRecordingCard(),
                  const SizedBox(height: 16),
                  _buildTonesCard(),
                  const SizedBox(height: 40),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildConferenceCard() {
    final isBasic = _conf.provider == ConferenceProviderType.basic;
    final isOnDevice = _conf.provider == ConferenceProviderType.onDevice;
    final isActive = isBasic || isOnDevice;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'CONFERENCE CALLING',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: AppColors.textTertiary,
            letterSpacing: 0.5,
          ),
        ),
        const SizedBox(height: 8),
        Container(
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.border, width: 0.5),
          ),
          child: Column(
            children: [
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  children: [
                    Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        color: isActive
                            ? AppColors.accent.withValues(alpha: 0.12)
                            : AppColors.card,
                      ),
                      child: Icon(Icons.groups_rounded,
                          size: 17,
                          color: isActive
                              ? AppColors.accent
                              : AppColors.textTertiary),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'SIP Conference Provider',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: AppColors.textPrimary,
                              letterSpacing: -0.2,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            isOnDevice
                                ? 'Mix audio locally across SIP calls'
                                : isBasic
                                    ? 'Merge calls via SIP REFER'
                                    : 'Conference calling disabled',
                            style: TextStyle(
                                fontSize: 11, color: AppColors.textTertiary),
                          ),
                        ],
                      ),
                    ),
                    DropdownButton<ConferenceProviderType>(
                      value: _conf.provider,
                      dropdownColor: AppColors.card,
                      underline: const SizedBox.shrink(),
                      style:
                          TextStyle(fontSize: 13, color: AppColors.textPrimary),
                      items: const [
                        DropdownMenuItem(
                          value: ConferenceProviderType.none,
                          child: Text('Off'),
                        ),
                        DropdownMenuItem(
                          value: ConferenceProviderType.basic,
                          child: Text('Basic'),
                        ),
                        DropdownMenuItem(
                          value: ConferenceProviderType.onDevice,
                          child: Text('On Device'),
                        ),
                      ],
                      onChanged: (v) {
                        if (v == null) return;
                        _updateConference(_conf.copyWith(provider: v));
                      },
                    ),
                  ],
                ),
              ),
              if (isActive) ...[
                Divider(
                    height: 1, color: AppColors.border.withValues(alpha: 0.4)),
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Max participants',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                                color: AppColors.textPrimary,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              isBasic
                                  ? 'SIP REFER limited to 2'
                                  : 'Remote call legs in conference',
                              style: TextStyle(
                                  fontSize: 11, color: AppColors.textTertiary),
                            ),
                          ],
                        ),
                      ),
                      DropdownButton<int>(
                        value: _conf.effectiveMaxParticipants,
                        dropdownColor: AppColors.card,
                        underline: const SizedBox.shrink(),
                        style: TextStyle(
                            fontSize: 13, color: AppColors.textPrimary),
                        items: [
                          for (int n = 2; n <= (isBasic ? 2 : 10); n++)
                            DropdownMenuItem(
                              value: n,
                              child: Text('$n'),
                            ),
                        ],
                        onChanged: isBasic
                            ? null
                            : (v) {
                                if (v == null) return;
                                _updateConference(
                                    _conf.copyWith(maxParticipants: v));
                              },
                      ),
                    ],
                  ),
                ),
              ],
              if (isBasic) ...[
                Divider(
                    height: 1, color: AppColors.border.withValues(alpha: 0.4)),
                _buildBasicConfToggle(
                  label: 'Platform supports sending Updates',
                  subtitle: 'Use SIP UPDATE for hold; otherwise re-INVITE',
                  value: _conf.basicSupportsUpdate,
                  onChanged: (v) =>
                      _updateConference(_conf.copyWith(basicSupportsUpdate: v)),
                ),
                _buildBasicConfToggle(
                  label: 'Renegotiate media after merge',
                  subtitle: 'Send a full SDP re-INVITE after REFER completes',
                  value: _conf.basicRenegotiateMedia,
                  onChanged: (v) => _updateConference(
                      _conf.copyWith(basicRenegotiateMedia: v)),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildBasicConfToggle({
    required String label,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(fontSize: 10, color: AppColors.textTertiary),
                ),
              ],
            ),
          ),
          Switch.adaptive(
            value: value,
            activeTrackColor: AppColors.accent,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }

  Widget _buildStatusCard() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border, width: 0.5),
      ),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration:
                BoxDecoration(shape: BoxShape.circle, color: _statusColor),
          ),
          const SizedBox(width: 10),
          Text(
            _statusText,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: _statusColor,
            ),
          ),
          const Spacer(),
          Text(
            _selectedTransport == TransportType.WS ? 'WebSocket' : 'TCP',
            style: TextStyle(fontSize: 12, color: AppColors.textTertiary),
          ),
        ],
      ),
    );
  }

  Widget _buildSection(String title, List<Widget> children) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: AppColors.textTertiary,
            letterSpacing: 0.5,
          ),
        ),
        const SizedBox(height: 8),
        Container(
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.border, width: 0.5),
          ),
          child: Column(
            children: [
              for (int i = 0; i < children.length; i++) ...[
                children[i],
                if (i < children.length - 1)
                  const Divider(height: 0.5, indent: 16),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildField(String label, TextEditingController controller,
      {String? placeholder, bool obscure = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 100,
            child: Text(
              label,
              style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
            ),
          ),
          Expanded(
            child: TextField(
              controller: controller,
              obscureText: obscure,
              autocorrect: false,
              style: TextStyle(fontSize: 14, color: AppColors.textPrimary),
              decoration: InputDecoration(
                hintText: placeholder,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                filled: false,
                contentPadding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHdCodecCard() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'AUDIO QUALITY',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: AppColors.textTertiary,
            letterSpacing: 0.5,
          ),
        ),
        const SizedBox(height: 8),
        Container(
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.border, width: 0.5),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    color: _requireHdCodecs
                        ? AppColors.accent.withValues(alpha: 0.12)
                        : AppColors.card,
                  ),
                  child: Icon(Icons.graphic_eq_rounded,
                      size: 17,
                      color: _requireHdCodecs
                          ? AppColors.accent
                          : AppColors.textTertiary),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Require HD Codecs',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textPrimary,
                          letterSpacing: -0.2,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _requireHdCodecs
                            ? 'Opus / G722 only — calls fail if unsupported'
                            : 'Allow narrowband fallback (PCMU / PCMA)',
                        style: TextStyle(
                            fontSize: 11, color: AppColors.textTertiary),
                      ),
                    ],
                  ),
                ),
                Switch.adaptive(
                  value: _requireHdCodecs,
                  activeTrackColor: AppColors.accent,
                  onChanged: (v) {
                    setState(() => _requireHdCodecs = v);
                    _preferences.setBool('require_hd_codecs', v);
                  },
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildCallRecordingCard() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'CALL RECORDING',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: AppColors.textTertiary,
            letterSpacing: 0.5,
          ),
        ),
        const SizedBox(height: 8),
        Container(
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.border, width: 0.5),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    color: _recording.autoRecord
                        ? AppColors.red.withValues(alpha: 0.12)
                        : AppColors.card,
                  ),
                  child: Icon(Icons.fiber_manual_record,
                      size: 17,
                      color: _recording.autoRecord
                          ? AppColors.red
                          : AppColors.textTertiary),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Auto-record calls',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textPrimary,
                          letterSpacing: -0.2,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Automatically start recording when a call connects',
                        style: TextStyle(
                            fontSize: 11, color: AppColors.textTertiary),
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  height: 28,
                  child: Switch.adaptive(
                    value: _recording.autoRecord,
                    onChanged: (v) =>
                        _updateRecording(_recording.copyWith(autoRecord: v)),
                    activeTrackColor: AppColors.red,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ───── Tones (touchtones / call-waiting / call-ended) ─────

  Widget _buildTonesCard() {
    final ToneService tones = context.watch<ToneService>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'TONES',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: AppColors.textTertiary,
            letterSpacing: 0.5,
          ),
        ),
        const SizedBox(height: 8),
        Container(
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.border, width: 0.5),
          ),
          child: Column(
            children: [
              _buildTonesHeaderRow(),
              Divider(
                  height: 0.5,
                  color: AppColors.border.withValues(alpha: 0.5)),
              _buildToneToggleRow(
                title: 'Touchtone playback',
                subtitle:
                    'Plays a tone when you press a digit on the dialer keypad.',
                value: tones.touchTonesEnabled,
                onChanged: (v) => tones.setTouchTonesEnabled(v),
              ),
              if (tones.touchTonesEnabled) ...[
                Divider(
                    height: 0.5,
                    color: AppColors.border.withValues(alpha: 0.5)),
                _buildTouchToneStyleRow(tones),
              ],
              Divider(
                  height: 0.5,
                  color: AppColors.border.withValues(alpha: 0.5)),
              _buildToneToggleRow(
                title: 'Call-waiting tone',
                subtitle:
                    'Two short beeps when an inbound call arrives during another call.',
                value: tones.callWaitingEnabled,
                onChanged: (v) => tones.setCallWaitingEnabled(v),
              ),
              _buildToneAnnounceRow(
                enabled: tones.callWaitingEnabled,
                value: tones.callWaitingAnnounce,
                onChanged: (v) => tones.setCallWaitingAnnounce(v),
              ),
              Divider(
                  height: 0.5,
                  color: AppColors.border.withValues(alpha: 0.5)),
              _buildToneToggleRow(
                title: 'Call-ended tone',
                subtitle:
                    'Three short beeps when the remote party hangs up the only active call.',
                value: tones.callEndedEnabled,
                onChanged: (v) => tones.setCallEndedEnabled(v),
              ),
              _buildToneAnnounceRow(
                enabled: tones.callEndedEnabled,
                value: tones.callEndedAnnounce,
                onChanged: (v) => tones.setCallEndedAnnounce(v),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildTonesHeaderRow() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              color: AppColors.accent.withValues(alpha: 0.12),
            ),
            child: Icon(Icons.dialpad_rounded,
                size: 17, color: AppColors.accent),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Phone Tones',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                    letterSpacing: -0.2,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Local cue sounds — never mixed into the outbound call audio.',
                  style: TextStyle(
                      fontSize: 11, color: AppColors.textTertiary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildToneToggleRow({
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(
                      fontSize: 11, color: AppColors.textTertiary),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            height: 24,
            child: Switch(
              value: value,
              activeThumbColor: AppColors.accent,
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTouchToneStyleRow(ToneService tones) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
      child: Row(
        children: [
          SizedBox(
            width: 100,
            child: Text(
              'Style',
              style: TextStyle(
                fontSize: 12,
                color: AppColors.textSecondary,
              ),
            ),
          ),
          Expanded(
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                _toneStyleChoice(
                  label: 'DTMF',
                  selected: tones.touchToneStyle == TouchToneStyle.dtmf,
                  onTap: () => tones.setTouchToneStyle(TouchToneStyle.dtmf),
                ),
                _toneStyleChoice(
                  label: 'Blue Box (MF)',
                  selected: tones.touchToneStyle == TouchToneStyle.blue,
                  onTap: () => tones.setTouchToneStyle(TouchToneStyle.blue),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _toneStyleChoice({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.accent.withValues(alpha: 0.15)
              : AppColors.card,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: selected
                ? AppColors.accent.withValues(alpha: 0.6)
                : AppColors.border.withValues(alpha: 0.5),
            width: 0.5,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w500,
            color: selected ? AppColors.accent : AppColors.textPrimary,
          ),
        ),
      ),
    );
  }

  Widget _buildToneAnnounceRow({
    required bool enabled,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(36, 0, 16, 8),
      child: Row(
        children: [
          SizedBox(
            height: 22,
            width: 22,
            child: Checkbox(
              value: value,
              onChanged: enabled ? (v) => onChanged(v ?? false) : null,
              activeColor: AppColors.accent,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Allow Agent to announce',
              style: TextStyle(
                fontSize: 12,
                color: enabled
                    ? AppColors.textSecondary
                    : AppColors.textTertiary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTransportRow() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          SizedBox(
            width: 100,
            child: Text(
              'Transport',
              style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
            ),
          ),
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: AppColors.card,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                    color: AppColors.border.withValues(alpha: 0.5),
                    width: 0.5),
              ),
              padding: const EdgeInsets.all(3),
              child: Row(
                children: [
                  _transportChip('TCP', TransportType.TCP),
                  _transportChip('WebSocket', TransportType.WS),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _transportChip(String label, TransportType type) {
    final selected = _selectedTransport == type;
    return Expanded(
      child: HoverButton(
        onTap: () => setState(() => _selectedTransport = type),
        borderRadius: BorderRadius.circular(7),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 7),
          decoration: BoxDecoration(
            color: selected ? AppColors.accent : Colors.transparent,
            borderRadius: BorderRadius.circular(7),
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: AppColors.accent.withValues(alpha: 0.3),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ]
                : null,
          ),
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                letterSpacing: -0.2,
                color: selected ? AppColors.onAccent : AppColors.textTertiary,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTestConnectionRow() {
    final isRegistered = _registerState.state == RegistrationStateEnum.REGISTERED;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Test Connection',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  isRegistered
                      ? 'Re-register with the current settings to verify.'
                      : 'Apply these settings and register with the SIP server.',
                  style: TextStyle(
                      fontSize: 11, color: AppColors.textTertiary),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            height: 32,
            child: ElevatedButton(
              onPressed: () => _register(context),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.accent,
                foregroundColor: AppColors.onAccent,
                elevation: 0,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
              ),
              child: Text(
                isRegistered ? 'Retest' : 'Test',
                style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.2),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void callStateChanged(Call call, CallState state) {}

  @override
  void transportStateChanged(TransportState state) {}

  @override
  void onNewMessage(SIPMessageRequest msg) {}

  @override
  void onNewNotify(Notify ntf) {}

  @override
  void onNewReinvite(ReInvite event) {}
}
