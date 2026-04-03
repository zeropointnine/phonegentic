import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../calendar_sync_service.dart';
import '../calendly_service.dart';
import '../demo_mode_service.dart';
import '../messaging/messaging_config.dart';
import '../messaging/messaging_service.dart';
import '../messaging/telnyx_messaging_provider.dart';
import '../theme_provider.dart';
import '../user_config_service.dart';

class UserSettingsTab extends StatefulWidget {
  const UserSettingsTab({Key? key}) : super(key: key);

  @override
  State<UserSettingsTab> createState() => _UserSettingsTabState();
}

class _UserSettingsTabState extends State<UserSettingsTab> {
  CalendlyConfig _calendly = const CalendlyConfig();
  DemoModeConfig _demo = const DemoModeConfig();
  TelnyxMessagingConfig _telnyxMsg = const TelnyxMessagingConfig();
  bool _loaded = false;
  bool _calendlyExpanded = false;
  bool _telnyxMsgExpanded = false;
  bool _testingConnection = false;
  String? _connectionStatus;
  bool _testingTelnyxMsg = false;
  String? _telnyxMsgStatus;

  final _calendlyKeyCtrl = TextEditingController();
  final _fakeNumberCtrl = TextEditingController();
  final _telnyxMsgKeyCtrl = TextEditingController();
  final _telnyxMsgFromCtrl = TextEditingController();
  final _telnyxMsgProfileCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _calendlyKeyCtrl.dispose();
    _fakeNumberCtrl.dispose();
    _telnyxMsgKeyCtrl.dispose();
    _telnyxMsgFromCtrl.dispose();
    _telnyxMsgProfileCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final c = await UserConfigService.loadCalendlyConfig();
    final d = await UserConfigService.loadDemoModeConfig();
    final t = await TelnyxMessagingConfig.load();
    if (!mounted) return;
    setState(() {
      _calendly = c;
      _demo = d;
      _telnyxMsg = t;
      _calendlyKeyCtrl.text = c.apiKey;
      _fakeNumberCtrl.text = d.fakeNumber;
      _telnyxMsgKeyCtrl.text = t.apiKey;
      _telnyxMsgFromCtrl.text = t.fromNumber;
      _telnyxMsgProfileCtrl.text = t.messagingProfileId;
      _loaded = true;
    });
  }

  void _updateCalendly(CalendlyConfig c) {
    setState(() => _calendly = c);
    UserConfigService.saveCalendlyConfig(c);
    if (c.apiKey.isNotEmpty) {
      context.read<CalendarSyncService>().syncNow();
    }
  }

  void _updateDemo(DemoModeConfig d) {
    setState(() => _demo = d);
    UserConfigService.saveDemoModeConfig(d);
    final demoService = context.read<DemoModeService>();
    demoService.setEnabled(d.enabled);
    if (d.fakeNumber != demoService.fakeNumber) {
      demoService.setFakeNumber(d.fakeNumber);
    }
  }

  void _updateTelnyxMsg(TelnyxMessagingConfig t) {
    setState(() => _telnyxMsg = t);
    t.save();
    if (t.isConfigured) {
      context.read<MessagingService>().reconfigure();
    }
  }

  Future<void> _testTelnyxMsgConnection() async {
    if (_telnyxMsg.apiKey.isEmpty) {
      setState(() => _telnyxMsgStatus = 'Enter an API key first');
      return;
    }
    setState(() {
      _testingTelnyxMsg = true;
      _telnyxMsgStatus = null;
    });
    try {
      final provider = TelnyxMessagingProvider(
        apiKey: _telnyxMsg.apiKey,
        fromNumber: _telnyxMsg.fromNumber,
      );
      final ok = await provider.testConnection();
      if (!mounted) return;
      setState(() {
        _telnyxMsgStatus =
            ok ? 'Connected to Telnyx Messaging' : 'Invalid API key';
        _testingTelnyxMsg = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _telnyxMsgStatus = 'Network error — check your connection';
        _testingTelnyxMsg = false;
      });
    }
  }

  Future<void> _testConnection() async {
    if (_calendly.apiKey.isEmpty) {
      setState(() => _connectionStatus = 'Enter an API key first');
      return;
    }
    setState(() {
      _testingConnection = true;
      _connectionStatus = null;
    });
    try {
      final service = CalendlyService(_calendly.apiKey);
      final user = await service.testConnection();
      if (!mounted) return;
      if (user != null) {
        setState(() {
          _connectionStatus = 'Connected as ${user.name} (${user.email})';
          _testingConnection = false;
        });
        context.read<CalendarSyncService>().syncNow();
      } else {
        setState(() {
          _connectionStatus = 'Invalid token — check your API key';
          _testingConnection = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _connectionStatus = 'Network error — check your connection';
        _testingConnection = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Center(
        child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          children: [
            const SizedBox(height: 8),
            _buildIntegrationsCard(),
            const SizedBox(height: 16),
            _buildDemoModeCard(),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  // ───── 3rd Party Integrations ─────

  Widget _buildIntegrationsCard() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '3RD PARTY INTEGRATIONS',
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
              _buildCalendlyHeader(),
              if (_calendlyExpanded) ...[
                Divider(
                    height: 0.5,
                    color: AppColors.border.withOpacity(0.5)),
                _buildKeyField('API Key', _calendlyKeyCtrl, (val) {
                  _updateCalendly(_calendly.copyWith(apiKey: val));
                  setState(() => _connectionStatus = null);
                }),
                _buildTestConnectionRow(),
                _divider(),
                _buildSyncMacToggle(),
              ],
              Divider(
                  height: 0.5, color: AppColors.border.withOpacity(0.5)),
              _buildTelnyxMsgHeader(),
              if (_telnyxMsgExpanded) ...[
                Divider(
                    height: 0.5,
                    color: AppColors.border.withOpacity(0.5)),
                _buildKeyField('API Key', _telnyxMsgKeyCtrl, (val) {
                  _updateTelnyxMsg(_telnyxMsg.copyWith(apiKey: val));
                  setState(() => _telnyxMsgStatus = null);
                }),
                _divider(),
                _buildPlainField('From Number', _telnyxMsgFromCtrl,
                    '+18005551234', (val) {
                  _updateTelnyxMsg(_telnyxMsg.copyWith(fromNumber: val));
                }),
                _divider(),
                _buildPlainField('Profile ID', _telnyxMsgProfileCtrl,
                    'Optional', (val) {
                  _updateTelnyxMsg(
                      _telnyxMsg.copyWith(messagingProfileId: val));
                }),
                _buildTelnyxMsgTestRow(),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildCalendlyHeader() {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => setState(() => _calendlyExpanded = !_calendlyExpanded),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                color: _calendly.isConfigured
                    ? AppColors.accent.withOpacity(0.12)
                    : AppColors.card,
              ),
              child: Icon(Icons.calendar_month_rounded,
                  size: 17,
                  color: _calendly.isConfigured
                      ? AppColors.accent
                      : AppColors.textTertiary),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Calendly',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                      letterSpacing: -0.2,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Text(
                        'Calendar sync & scheduling',
                        style: TextStyle(
                            fontSize: 11, color: AppColors.textTertiary),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: _calendly.isConfigured
                              ? AppColors.green.withOpacity(0.12)
                              : AppColors.orange.withOpacity(0.12),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          _calendly.isConfigured ? 'Configured' : 'Not Set',
                          style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.w600,
                            color: _calendly.isConfigured
                                ? AppColors.green
                                : AppColors.orange,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Icon(
              _calendlyExpanded
                  ? Icons.expand_less_rounded
                  : Icons.expand_more_rounded,
              size: 20,
              color: AppColors.textTertiary,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTestConnectionRow() {
    final isSuccess = _connectionStatus != null &&
        _connectionStatus!.startsWith('Connected');
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
      child: Row(
        children: [
          GestureDetector(
            onTap: _testingConnection ? null : _testConnection,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: AppColors.accent.withOpacity(0.12),
                borderRadius: BorderRadius.circular(6),
              ),
              child: _testingConnection
                  ? SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.5,
                        color: AppColors.accent,
                      ),
                    )
                  : Text(
                      'Test Connection',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: AppColors.accent,
                      ),
                    ),
            ),
          ),
          if (_connectionStatus != null) ...[
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                _connectionStatus!,
                style: TextStyle(
                  fontSize: 11,
                  color: isSuccess ? AppColors.green : AppColors.red,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSyncMacToggle() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          SizedBox(
            width: 100,
            child: Text('macOS Calendar',
                style:
                    TextStyle(fontSize: 13, color: AppColors.textSecondary)),
          ),
          const Spacer(),
          SizedBox(
            height: 28,
            child: Switch.adaptive(
              value: _calendly.syncToMacOS,
              onChanged: (v) =>
                  _updateCalendly(_calendly.copyWith(syncToMacOS: v)),
              activeColor: AppColors.accent,
            ),
          ),
        ],
      ),
    );
  }

  // ───── Demo Mode ─────

  Widget _buildDemoModeCard() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'DEMO MODE',
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
                        color: _demo.enabled
                            ? AppColors.accent.withOpacity(0.12)
                            : AppColors.card,
                      ),
                      child: Icon(Icons.visibility_off_rounded,
                          size: 17,
                          color: _demo.enabled
                              ? AppColors.accent
                              : AppColors.textTertiary),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Hide PII Data',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: AppColors.textPrimary,
                              letterSpacing: -0.2,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Mask phone numbers and last names for demo videos',
                            style: TextStyle(
                                fontSize: 11, color: AppColors.textTertiary),
                          ),
                        ],
                      ),
                    ),
                    SizedBox(
                      height: 28,
                      child: Switch.adaptive(
                        value: _demo.enabled,
                        onChanged: (v) =>
                            _updateDemo(_demo.copyWith(enabled: v)),
                        activeColor: AppColors.accent,
                      ),
                    ),
                  ],
                ),
              ),
              if (_demo.enabled) ...[
                Divider(
                    height: 0.5,
                    color: AppColors.border.withOpacity(0.5)),
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 100,
                        child: Text('Display Number',
                            style: TextStyle(
                                fontSize: 13,
                                color: AppColors.textSecondary)),
                      ),
                      Expanded(
                        child: TextField(
                          controller: _fakeNumberCtrl,
                          autocorrect: false,
                          style: TextStyle(
                              fontSize: 14, color: AppColors.textPrimary),
                          decoration: InputDecoration(
                            hintText: '(555) 000-0000',
                            hintStyle: TextStyle(
                                fontSize: 13,
                                color: AppColors.textTertiary),
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            filled: false,
                            contentPadding:
                                const EdgeInsets.symmetric(vertical: 12),
                          ),
                          onChanged: (val) =>
                              _updateDemo(_demo.copyWith(fakeNumber: val)),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  // ───── Telnyx Messaging ─────

  Widget _buildTelnyxMsgHeader() {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => setState(() => _telnyxMsgExpanded = !_telnyxMsgExpanded),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                color: _telnyxMsg.isConfigured
                    ? AppColors.accent.withOpacity(0.12)
                    : AppColors.card,
              ),
              child: Icon(Icons.sms_rounded,
                  size: 17,
                  color: _telnyxMsg.isConfigured
                      ? AppColors.accent
                      : AppColors.textTertiary),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Telnyx Messaging',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                      letterSpacing: -0.2,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Text(
                        'SMS & MMS messaging',
                        style: TextStyle(
                            fontSize: 11, color: AppColors.textTertiary),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: _telnyxMsg.isConfigured
                              ? AppColors.green.withOpacity(0.12)
                              : AppColors.orange.withOpacity(0.12),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          _telnyxMsg.isConfigured ? 'Configured' : 'Not Set',
                          style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.w600,
                            color: _telnyxMsg.isConfigured
                                ? AppColors.green
                                : AppColors.orange,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Icon(
              _telnyxMsgExpanded
                  ? Icons.expand_less_rounded
                  : Icons.expand_more_rounded,
              size: 20,
              color: AppColors.textTertiary,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTelnyxMsgTestRow() {
    final isSuccess =
        _telnyxMsgStatus != null && _telnyxMsgStatus!.startsWith('Connected');
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
      child: Row(
        children: [
          GestureDetector(
            onTap: _testingTelnyxMsg ? null : _testTelnyxMsgConnection,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: AppColors.accent.withOpacity(0.12),
                borderRadius: BorderRadius.circular(6),
              ),
              child: _testingTelnyxMsg
                  ? SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.5,
                        color: AppColors.accent,
                      ),
                    )
                  : Text(
                      'Test Connection',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: AppColors.accent,
                      ),
                    ),
            ),
          ),
          if (_telnyxMsgStatus != null) ...[
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                _telnyxMsgStatus!,
                style: TextStyle(
                  fontSize: 11,
                  color: isSuccess ? AppColors.green : AppColors.red,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ───── Shared helpers ─────

  Widget _buildPlainField(String label, TextEditingController ctrl,
      String hint, ValueChanged<String> onChanged) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 100,
            child: Text(label,
                style:
                    TextStyle(fontSize: 13, color: AppColors.textSecondary)),
          ),
          Expanded(
            child: TextField(
              controller: ctrl,
              autocorrect: false,
              style: TextStyle(fontSize: 14, color: AppColors.textPrimary),
              decoration: InputDecoration(
                hintText: hint,
                hintStyle:
                    TextStyle(fontSize: 13, color: AppColors.textTertiary),
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                filled: false,
                contentPadding: const EdgeInsets.symmetric(vertical: 12),
              ),
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildKeyField(
      String label, TextEditingController ctrl, ValueChanged<String> onChanged) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 100,
            child: Text(label,
                style:
                    TextStyle(fontSize: 13, color: AppColors.textSecondary)),
          ),
          Expanded(
            child: TextField(
              controller: ctrl,
              obscureText: true,
              autocorrect: false,
              style: TextStyle(fontSize: 14, color: AppColors.textPrimary),
              decoration: InputDecoration(
                hintText: 'Bearer token...',
                hintStyle:
                    TextStyle(fontSize: 13, color: AppColors.textTertiary),
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                filled: false,
                contentPadding: const EdgeInsets.symmetric(vertical: 12),
              ),
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }

  Widget _divider() => Divider(
      height: 0.5, indent: 16, color: AppColors.border.withOpacity(0.5));
}
