import 'package:phonegentic/src/test_credentials.dart';
import 'package:phonegentic/src/user_state/sip_user.dart';
import 'package:phonegentic/src/user_state/sip_user_cubit.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sip_ua/sip_ua.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

import 'theme_provider.dart';
import 'widgets/agent_settings_tab.dart';
import 'widgets/user_settings_tab.dart';

class RegisterWidget extends StatefulWidget {
  final SIPUAHelper? _helper;
  RegisterWidget(this._helper, {Key? key}) : super(key: key);

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

  late SharedPreferences _preferences;
  late RegistrationState _registerState;
  TransportType _selectedTransport = TransportType.TCP;
  late final TabController _tabController;

  SIPUAHelper? get helper => widget._helper;
  late SipUserCubit currentUser;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
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
      _portController.text =
          _preferences.getString('port') ?? defaultUser.port;
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
    });
  }

  void _saveSettings() {
    _preferences.setString('port', _portController.text);
    _preferences.setString('ws_uri', _wsUriController.text);
    _preferences.setString('sip_uri', _sipUriController.text);
    _preferences.setString('display_name', _displayNameController.text);
    _preferences.setString('password', _passwordController.text);
    _preferences.setString('auth_user', _authorizationUserController.text);
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
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios_new,
              size: 18, color: AppColors.textSecondary),
          onPressed: () => Navigator.of(context).pop(),
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
                color: AppColors.border.withOpacity(0.5), width: 0.5),
          ),
          child: TabBar(
            controller: _tabController,
            indicator: BoxDecoration(
              color: AppColors.accent,
              borderRadius: BorderRadius.circular(7),
              boxShadow: [
                BoxShadow(
                  color: AppColors.accent.withOpacity(0.3),
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
                fontSize: 12,
                fontWeight: FontWeight.w600,
                letterSpacing: -0.2),
            unselectedLabelStyle: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                letterSpacing: -0.2),
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
                    Icon(Icons.person_rounded, size: 14),
                    SizedBox(width: 6),
                    Text('User'),
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
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          children: [
            const SizedBox(height: 8),
            _buildStatusCard(),
            const SizedBox(height: 20),
            _buildSection('Connection', [
              if (_selectedTransport == TransportType.WS)
                _buildField('WebSocket URL', _wsUriController,
                    placeholder: 'wss://sip.example.com:7443'),
              if (_selectedTransport == TransportType.TCP)
                _buildField('Port', _portController, placeholder: '5060'),
              _buildField('SIP URI', _sipUriController,
                  placeholder: 'user@sip.example.com'),
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
            if (!kIsWeb) ...[
              const SizedBox(height: 16),
              _buildTransportSelector(),
            ],
            const SizedBox(height: 24),
            _buildRegisterButton(),
            const SizedBox(height: 40),
          ],
        ),
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
              style: TextStyle(
                  fontSize: 13, color: AppColors.textSecondary),
            ),
          ),
          Expanded(
            child: TextField(
              controller: controller,
              obscureText: obscure,
              autocorrect: false,
              style: TextStyle(
                  fontSize: 14, color: AppColors.textPrimary),
              decoration: InputDecoration(
                hintText: placeholder,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                filled: false,
                contentPadding:
                    const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTransportSelector() {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border, width: 0.5),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: Row(
        children: [
          _transportChip('TCP', TransportType.TCP),
          _transportChip('WebSocket', TransportType.WS),
        ],
      ),
    );
  }

  Widget _transportChip(String label, TransportType type) {
    final selected = _selectedTransport == type;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _selectedTransport = type),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: selected ? AppColors.accent : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color:
                    selected ? AppColors.onAccent : AppColors.textTertiary,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRegisterButton() {
    return SizedBox(
      height: 48,
      child: ElevatedButton(
        onPressed: () => _register(context),
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.accent,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        child: const Text(
          'Register',
          style: TextStyle(
              fontSize: 15, fontWeight: FontWeight.w600, color: AppColors.onAccent),
        ),
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
