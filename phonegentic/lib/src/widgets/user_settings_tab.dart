import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../calendar_sync_service.dart';
import '../calendly_service.dart';
import '../chrome/flight_aware_config.dart';
import '../chrome/flight_aware_service.dart';
import '../chrome/gmail_config.dart';
import '../chrome/gmail_service.dart';
import '../chrome/google_calendar_config.dart';
import '../chrome/google_calendar_service.dart';
import '../chrome/google_search_config.dart';
import '../chrome/google_search_service.dart';
import '../demo_mode_service.dart';
import '../inbound_call_flow_service.dart';
import '../job_function_service.dart';
import '../messaging/messaging_config.dart';
import '../messaging/messaging_service.dart';
import '../messaging/telnyx_messaging_provider.dart';
import '../messaging/twilio_messaging_provider.dart';
import '../settings_port_service.dart';
import '../theme_provider.dart';
import '../user_config_service.dart';
import 'settings_export_import_card.dart';

/// Shows a modal dialog prompting the user to start Chrome with remote
/// debugging. Returns `true` if the connection was established via retry.
Future<bool> showChromeLaunchDialog(
  BuildContext context, {
  required String launchCommand,
  required VoidCallback onCopy,
  required Future<bool> Function() onTest,
}) async {
  return await showDialog<bool>(
        context: context,
        barrierDismissible: true,
        builder: (ctx) => _ChromeLaunchDialog(
          launchCommand: launchCommand,
          onCopy: onCopy,
          onTest: onTest,
        ),
      ) ??
      false;
}

class _ChromeLaunchDialog extends StatefulWidget {
  final String launchCommand;
  final VoidCallback onCopy;
  final Future<bool> Function() onTest;

  const _ChromeLaunchDialog({
    required this.launchCommand,
    required this.onCopy,
    required this.onTest,
  });

  @override
  State<_ChromeLaunchDialog> createState() => _ChromeLaunchDialogState();
}

class _ChromeLaunchDialogState extends State<_ChromeLaunchDialog> {
  bool _testing = false;
  bool? _result;

  Future<void> _retry() async {
    setState(() {
      _testing = true;
      _result = null;
    });
    final ok = await widget.onTest();
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        _testing = false;
        _result = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Row(
        children: [
          Icon(Icons.terminal_rounded, color: AppColors.accent, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Start Chrome with Remote Debugging',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary,
              ),
            ),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'This integration requires Chrome running with a debug port. '
            'Open Terminal and paste the command below:',
            style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 12),
          HoverButton(
            onTap: () {
              widget.onCopy();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Copied to clipboard'),
                  duration: Duration(seconds: 2),
                ),
              );
            },
            borderRadius: BorderRadius.circular(8),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
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
                      widget.launchCommand,
                      style: TextStyle(
                        fontSize: 10,
                        color: AppColors.textSecondary,
                        fontFamily: 'Courier',
                        height: 1.4,
                      ),
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(Icons.copy_rounded,
                      size: 14, color: AppColors.textTertiary),
                ],
              ),
            ),
          ),
          if (_result == false) ...[
            const SizedBox(height: 10),
            Text(
              'Chrome not detected. Make sure it is running and try again.',
              style: TextStyle(fontSize: 11, color: AppColors.red),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text('Cancel',
              style: TextStyle(color: AppColors.textTertiary, fontSize: 13)),
        ),
        ElevatedButton.icon(
          onPressed: _testing ? null : _retry,
          icon: _testing
              ? SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white))
              : const Icon(Icons.refresh_rounded, size: 16),
          label: Text(_testing ? 'Testing...' : 'Test Connection',
              style: const TextStyle(fontSize: 12)),
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.accent,
            foregroundColor: Colors.white,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
        ),
      ],
    );
  }
}

class UserSettingsTab extends StatefulWidget {
  const UserSettingsTab({super.key});

  @override
  State<UserSettingsTab> createState() => _UserSettingsTabState();
}

class _UserSettingsTabState extends State<UserSettingsTab> {
  CalendlyConfig _calendly = const CalendlyConfig();
  DemoModeConfig _demo = const DemoModeConfig();
  AgentManagerConfig _agentManager = const AgentManagerConfig();
  TelnyxMessagingConfig _telnyxMsg = const TelnyxMessagingConfig();
  TwilioMessagingConfig _twilioMsg = const TwilioMessagingConfig();
  MessagingBackend _messagingBackend = MessagingBackend.telnyx;
  bool _loaded = false;
  bool _calendlyExpanded = false;
  bool _smsExpanded = false;
  bool _testingConnection = false;
  String? _connectionStatus;
  bool _testingTelnyxMsg = false;
  String? _telnyxMsgStatus;
  bool _testingTwilioMsg = false;
  String? _twilioMsgStatus;

  FlightAwareConfig _flightAware = const FlightAwareConfig();
  bool _flightAwareExpanded = false;

  GmailConfig _gmail = const GmailConfig();
  bool _gmailExpanded = false;
  final _gmailSearchCtrl = TextEditingController();
  final _gmailAllowPhoneCtrl = TextEditingController();

  GoogleCalendarConfig _gcal = const GoogleCalendarConfig();
  bool _gcalExpanded = false;
  final _gcalDateCtrl = TextEditingController();
  final _gcalAllowPhoneCtrl = TextEditingController();

  GoogleSearchConfig _googleSearch = const GoogleSearchConfig();
  bool _googleSearchExpanded = false;
  final _googleSearchCtrl = TextEditingController();

  final _calendlyKeyCtrl = TextEditingController();
  final _fakeNumberCtrl = TextEditingController();
  final _telnyxMsgKeyCtrl = TextEditingController();
  final _telnyxMsgFromCtrl = TextEditingController();
  final _telnyxMsgProfileCtrl = TextEditingController();
  final _twilioSidCtrl = TextEditingController();
  final _twilioTokenCtrl = TextEditingController();
  final _twilioFromCtrl = TextEditingController();

  final _agentManagerPhoneCtrl = TextEditingController();
  final _agentManagerNameCtrl = TextEditingController();

  final _flightNumberCtrl = TextEditingController();
  final _originCtrl = TextEditingController();
  final _destCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _calendlyKeyCtrl.dispose();
    _fakeNumberCtrl.dispose();
    _agentManagerPhoneCtrl.dispose();
    _agentManagerNameCtrl.dispose();
    _telnyxMsgKeyCtrl.dispose();
    _telnyxMsgFromCtrl.dispose();
    _telnyxMsgProfileCtrl.dispose();
    _twilioSidCtrl.dispose();
    _twilioTokenCtrl.dispose();
    _twilioFromCtrl.dispose();
    _flightNumberCtrl.dispose();
    _originCtrl.dispose();
    _destCtrl.dispose();
    _gmailSearchCtrl.dispose();
    _gmailAllowPhoneCtrl.dispose();
    _gcalDateCtrl.dispose();
    _gcalAllowPhoneCtrl.dispose();
    _googleSearchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final c = await UserConfigService.loadCalendlyConfig();
    final d = await UserConfigService.loadDemoModeConfig();
    final t = await TelnyxMessagingConfig.load();
    final tw = await TwilioMessagingConfig.load();
    final backend = await MessagingSettings.loadBackend();
    final fa = await FlightAwareConfig.load();
    final gm = await GmailConfig.load();
    final gc = await GoogleCalendarConfig.load();
    final gs = await GoogleSearchConfig.load();
    final am = await UserConfigService.loadAgentManagerConfig();
    if (!mounted) return;
    setState(() {
      _calendly = c;
      _demo = d;
      _agentManager = am;
      _telnyxMsg = t;
      _twilioMsg = tw;
      _messagingBackend = backend;
      _flightAware = fa;
      _gmail = gm;
      _gcal = gc;
      _googleSearch = gs;
      _calendlyKeyCtrl.text = c.apiKey;
      _fakeNumberCtrl.text = d.fakeNumber;
      _agentManagerPhoneCtrl.text = am.phoneNumber;
      _agentManagerNameCtrl.text = am.name;
      _telnyxMsgKeyCtrl.text = t.apiKey;
      _telnyxMsgFromCtrl.text = t.fromNumber;
      _telnyxMsgProfileCtrl.text = t.messagingProfileId;
      _twilioSidCtrl.text = tw.accountSid;
      _twilioTokenCtrl.text = tw.authToken;
      _twilioFromCtrl.text = tw.fromNumber;
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

  void _updateAgentManager(AgentManagerConfig am) {
    setState(() => _agentManager = am);
    UserConfigService.saveAgentManagerConfig(am);
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
    context.read<MessagingService>().reconfigure();
  }

  void _updateTwilioMsg(TwilioMessagingConfig t) {
    setState(() => _twilioMsg = t);
    t.save();
    context.read<MessagingService>().reconfigure();
  }

  Future<void> _setMessagingBackend(MessagingBackend b) async {
    setState(() => _messagingBackend = b);
    await MessagingSettings.saveBackend(b);
    if (!mounted) return;
    context.read<MessagingService>().reconfigure();
  }

  Future<void> _updateFlightAware(FlightAwareConfig fa) async {
    final wasEnabled = _flightAware.enabled;
    setState(() => _flightAware = fa);
    fa.save();
    final svc = context.read<FlightAwareService>();
    await svc.updateConfig(fa);
    if (fa.enabled && !wasEnabled) {
      final ok = await svc.testConnection();
      if (!ok && mounted) {
        showChromeLaunchDialog(
          context,
          launchCommand: svc.chrome.launchCommand,
          onCopy: svc.copyLaunchCommand,
          onTest: svc.testConnection,
        );
      }
    }
  }

  Future<void> _updateGmail(GmailConfig gm) async {
    final wasEnabled = _gmail.enabled;
    setState(() => _gmail = gm);
    gm.save();
    final svc = context.read<GmailService>();
    await svc.updateConfig(gm);
    if (gm.enabled && !wasEnabled) {
      final ok = await svc.testConnection();
      if (!ok && mounted) {
        showChromeLaunchDialog(
          context,
          launchCommand: svc.chrome.launchCommand,
          onCopy: svc.copyLaunchCommand,
          onTest: svc.testConnection,
        );
      }
    }
  }

  Future<void> _updateGcal(GoogleCalendarConfig gc) async {
    final wasEnabled = _gcal.enabled;
    setState(() => _gcal = gc);
    gc.save();
    final svc = context.read<GoogleCalendarService>();
    await svc.updateConfig(gc);
    if (gc.enabled && !wasEnabled) {
      final ok = await svc.testConnection();
      if (!ok && mounted) {
        showChromeLaunchDialog(
          context,
          launchCommand: svc.chrome.launchCommand,
          onCopy: svc.copyLaunchCommand,
          onTest: svc.testConnection,
        );
      }
    }
  }

  Future<void> _updateGoogleSearch(GoogleSearchConfig gs) async {
    final wasEnabled = _googleSearch.enabled;
    setState(() => _googleSearch = gs);
    gs.save();
    final svc = context.read<GoogleSearchService>();
    await svc.updateConfig(gs);
    if (gs.enabled && !wasEnabled) {
      final ok = await svc.testConnection();
      if (!ok && mounted) {
        showChromeLaunchDialog(
          context,
          launchCommand: svc.chrome.launchCommand,
          onCopy: svc.copyLaunchCommand,
          onTest: svc.testConnection,
        );
      }
    }
  }

  Future<void> _lookupFlight() async {
    final svc = context.read<FlightAwareService>();
    await svc.lookupFlight(_flightNumberCtrl.text);
  }

  Future<void> _searchRoute() async {
    final svc = context.read<FlightAwareService>();
    await svc.searchRoute(_originCtrl.text, _destCtrl.text);
  }

  Future<void> _testTwilioMsgConnection() async {
    if (_twilioMsg.accountSid.isEmpty || _twilioMsg.authToken.isEmpty) {
      setState(() => _twilioMsgStatus = 'Enter Account SID and Auth Token');
      return;
    }
    setState(() {
      _testingTwilioMsg = true;
      _twilioMsgStatus = null;
    });
    try {
      final provider = TwilioMessagingProvider(
        accountSid: _twilioMsg.accountSid,
        authToken: _twilioMsg.authToken,
        fromNumber: _twilioMsg.fromNumber.isEmpty ? '+10000000000' : _twilioMsg.fromNumber,
      );
      final ok = await provider.testConnection();
      if (!mounted) return;
      setState(() {
        _twilioMsgStatus =
            ok ? 'Connected to Twilio' : 'Invalid credentials or network error';
        _testingTwilioMsg = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _twilioMsgStatus = 'Network error — check your connection';
        _testingTwilioMsg = false;
      });
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
                  _buildAppearanceCard(),
                  const SizedBox(height: 16),
                  _buildIntegrationsCard(),
                  const SizedBox(height: 16),
                  _buildAgentManagerCard(),
                  const SizedBox(height: 16),
                  _buildDemoModeCard(),
                  const SizedBox(height: 24),
                  FullBackupExportImportCard(
                    onImported: () {
                      _load();
                      context.read<JobFunctionService>().restoreLastUsed();
                      context.read<InboundCallFlowService>().loadAll();
                    },
                  ),
                  const SizedBox(height: 16),
                  SettingsExportImportCard(
                    section: SettingsSection.jobFunctions,
                    onImported: () {
                      context.read<JobFunctionService>().restoreLastUsed();
                    },
                  ),
                  const SizedBox(height: 16),
                  SettingsExportImportCard(
                    section: SettingsSection.inboundWorkflows,
                    onImported: () {
                      context.read<InboundCallFlowService>().loadAll();
                    },
                  ),
                  const SizedBox(height: 40),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ───── Appearance ─────

  Widget _buildAppearanceCard() {
    final themeProvider = context.watch<ThemeProvider>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'APPEARANCE',
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
              _buildThemeRow(
                theme: AppTheme.amberVt100,
                label: 'Amber VT-100',
                subtitle: 'Warm CRT phosphor on dark',
                icon: Icons.terminal_rounded,
                selected: themeProvider.appTheme == AppTheme.amberVt100,
                onTap: () => themeProvider.setTheme(AppTheme.amberVt100),
              ),
              Divider(
                  height: 0.5,
                  color: AppColors.border.withValues(alpha: 0.5)),
              _buildThemeRow(
                theme: AppTheme.miamiVice,
                label: 'Miami Vice',
                subtitle: 'Cyan & hot pink on midnight',
                icon: Icons.nightlife_rounded,
                selected: themeProvider.appTheme == AppTheme.miamiVice,
                onTap: () => themeProvider.setTheme(AppTheme.miamiVice),
              ),
              Divider(
                  height: 0.5,
                  color: AppColors.border.withValues(alpha: 0.5)),
              _buildThemeRow(
                theme: AppTheme.light,
                label: 'Pedestrian Neutral',
                subtitle: 'Warm parchment light',
                icon: Icons.light_mode_rounded,
                selected: themeProvider.appTheme == AppTheme.light,
                onTap: () => themeProvider.setTheme(AppTheme.light),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildThemeRow({
    required AppTheme theme,
    required String label,
    required String subtitle,
    required IconData icon,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                color: selected
                    ? AppColors.accent.withValues(alpha: 0.12)
                    : AppColors.card,
              ),
              child: Icon(icon,
                  size: 17,
                  color: selected
                      ? AppColors.accent
                      : AppColors.textTertiary),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                      letterSpacing: -0.2,
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
            if (selected)
              Icon(Icons.check_rounded,
                  size: 18, color: AppColors.accent),
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
                    color: AppColors.border.withValues(alpha: 0.5)),
                _buildKeyField('API Key', _calendlyKeyCtrl, (val) {
                  _updateCalendly(_calendly.copyWith(apiKey: val));
                  setState(() => _connectionStatus = null);
                }),
                _buildTestConnectionRow(),
                _divider(),
                _buildSyncMacToggle(),
              ],
              Divider(
                  height: 0.5, color: AppColors.border.withValues(alpha: 0.5)),
              _buildSmsHeader(),
              if (_smsExpanded) ...[
                Divider(
                    height: 0.5,
                    color: AppColors.border.withValues(alpha: 0.5)),
                _buildMessagingBackendRow(),
                if (_messagingBackend == MessagingBackend.none) ...[
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    child: Text(
                      'Messaging is disabled. Existing credentials are preserved.',
                      style: TextStyle(
                        fontSize: 12,
                        color: AppColors.textTertiary,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ),
                ] else if (_messagingBackend == MessagingBackend.telnyx) ...[
                  _divider(),
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
                ] else ...[
                  _divider(),
                  _buildPlainField('Account SID', _twilioSidCtrl, 'AC…', (val) {
                    _updateTwilioMsg(_twilioMsg.copyWith(accountSid: val));
                    setState(() => _twilioMsgStatus = null);
                  }),
                  _divider(),
                  _buildKeyField('Auth Token', _twilioTokenCtrl, (val) {
                    _updateTwilioMsg(_twilioMsg.copyWith(authToken: val));
                    setState(() => _twilioMsgStatus = null);
                  }),
                  _divider(),
                  _buildPlainField('From Number', _twilioFromCtrl,
                      '+18005551234', (val) {
                    _updateTwilioMsg(_twilioMsg.copyWith(fromNumber: val));
                  }),
                  _buildTwilioMsgTestRow(),
                ],
              ],
              Divider(
                  height: 0.5, color: AppColors.border.withValues(alpha: 0.5)),
              _buildFlightAwareHeader(),
              if (_flightAwareExpanded) ...[
                Divider(
                    height: 0.5,
                    color: AppColors.border.withValues(alpha: 0.5)),
                _buildFlightAwareEnableToggle(),
                if (_flightAware.enabled) ...[
                  _divider(),
                  Builder(builder: (ctx) {
                    final svc = ctx.watch<FlightAwareService>();
                    return Column(children: [
                      _buildChromeCommandRow(
                        launchCommand: svc.chrome.launchCommand,
                        onCopy: svc.copyLaunchCommand,
                      ),
                      _divider(),
                      _buildChromeTestRow(
                        isLoading: svc.loading,
                        connected: svc.connected,
                        onTest: svc.testConnection,
                      ),
                    ]);
                  }),
                  _divider(),
                  _buildFlightLookupRow(),
                  _buildFlightResultsArea(),
                  _divider(),
                  _buildRouteLookupRow(),
                  _buildRouteResultsArea(),
                ],
              ],
              Divider(
                  height: 0.5, color: AppColors.border.withValues(alpha: 0.5)),
              _buildGmailHeader(),
              if (_gmailExpanded) ...[
                Divider(
                    height: 0.5,
                    color: AppColors.border.withValues(alpha: 0.5)),
                _buildGmailEnableToggle(),
                if (_gmail.enabled) ...[
                  _divider(),
                  Builder(builder: (ctx) {
                    final svc = ctx.watch<GmailService>();
                    return Column(children: [
                      _buildChromeCommandRow(
                        launchCommand: svc.chrome.launchCommand,
                        onCopy: svc.copyLaunchCommand,
                      ),
                      _divider(),
                      _buildChromeTestRow(
                        isLoading: svc.loading,
                        connected: svc.connected,
                        onTest: svc.testConnection,
                      ),
                    ]);
                  }),
                  _divider(),
                  _buildGmailReadAccessRow(),
                  if (_gmail.readAccessMode == GmailReadAccess.allowList) ...[
                    _divider(),
                    _buildGmailAllowListRow(),
                  ],
                  _divider(),
                  _buildGmailSearchTestRow(),
                  _buildGmailSearchResultsArea(),
                ],
              ],
              Divider(
                  height: 0.5, color: AppColors.border.withValues(alpha: 0.5)),
              _buildGcalHeader(),
              if (_gcalExpanded) ...[
                Divider(
                    height: 0.5,
                    color: AppColors.border.withValues(alpha: 0.5)),
                _buildGcalEnableToggle(),
                if (_gcal.enabled) ...[
                  _divider(),
                  Builder(builder: (ctx) {
                    final svc = ctx.watch<GoogleCalendarService>();
                    return Column(children: [
                      _buildChromeCommandRow(
                        launchCommand: svc.chrome.launchCommand,
                        onCopy: svc.copyLaunchCommand,
                      ),
                      _divider(),
                      _buildChromeTestRow(
                        isLoading: svc.loading,
                        connected: svc.connected,
                        onTest: svc.testConnection,
                      ),
                    ]);
                  }),
                  _divider(),
                  _buildGcalReadAccessRow(),
                  if (_gcal.readAccessMode == CalendarReadAccess.allowList) ...[
                    _divider(),
                    _buildGcalAllowListRow(),
                  ],
                  _divider(),
                  _buildGcalSyncToggle(),
                  _divider(),
                  _buildGcalReadTestRow(),
                  _buildGcalReadResultsArea(),
                ],
              ],
              Divider(
                  height: 0.5, color: AppColors.border.withValues(alpha: 0.5)),
              _buildGoogleSearchHeader(),
              if (_googleSearchExpanded) ...[
                Divider(
                    height: 0.5,
                    color: AppColors.border.withValues(alpha: 0.5)),
                _buildGoogleSearchEnableToggle(),
                if (_googleSearch.enabled) ...[
                  _divider(),
                  Builder(builder: (ctx) {
                    final svc = ctx.watch<GoogleSearchService>();
                    return Column(children: [
                      _buildChromeCommandRow(
                        launchCommand: svc.chrome.launchCommand,
                        onCopy: svc.copyLaunchCommand,
                      ),
                      _divider(),
                      _buildChromeTestRow(
                        isLoading: svc.loading,
                        connected: svc.connected,
                        onTest: svc.testConnection,
                      ),
                    ]);
                  }),
                  _divider(),
                  _buildGoogleSearchTestRow(),
                  _buildGoogleSearchResultsArea(),
                ],
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
                    ? AppColors.accent.withValues(alpha: 0.12)
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
                              ? AppColors.green.withValues(alpha: 0.12)
                              : AppColors.orange.withValues(alpha: 0.12),
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
          HoverButton(
            onTap: _testingConnection ? null : _testConnection,
            borderRadius: BorderRadius.circular(6),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: AppColors.accent.withValues(alpha: 0.12),
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
              activeTrackColor: AppColors.accent,
            ),
          ),
        ],
      ),
    );
  }

  // ───── Agent Manager ─────

  Widget _buildAgentManagerCard() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'AGENT MANAGER',
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
                        color: _agentManager.isConfigured
                            ? AppColors.accent.withValues(alpha: 0.12)
                            : AppColors.card,
                      ),
                      child: Icon(Icons.admin_panel_settings_rounded,
                          size: 17,
                          color: _agentManager.isConfigured
                              ? AppColors.accent
                              : AppColors.textTertiary),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Manager Phone Number',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: AppColors.textPrimary,
                              letterSpacing: -0.2,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'This caller gets host-level privileges on inbound calls',
                            style: TextStyle(
                                fontSize: 11, color: AppColors.textTertiary),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Divider(
                  height: 0.5,
                  color: AppColors.border.withValues(alpha: 0.5)),
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Row(
                  children: [
                    SizedBox(
                      width: 100,
                      child: Text('Name',
                          style: TextStyle(
                              fontSize: 13, color: AppColors.textSecondary)),
                    ),
                    Expanded(
                      child: TextField(
                        controller: _agentManagerNameCtrl,
                        autocorrect: false,
                        textCapitalization: TextCapitalization.words,
                        style: TextStyle(
                            fontSize: 14, color: AppColors.textPrimary),
                        decoration: InputDecoration(
                          hintText: 'Your name',
                          hintStyle: TextStyle(
                              fontSize: 13, color: AppColors.textTertiary),
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          filled: false,
                          contentPadding:
                              const EdgeInsets.symmetric(vertical: 12),
                        ),
                        onChanged: (val) => _updateAgentManager(
                            _agentManager.copyWith(name: val)),
                      ),
                    ),
                  ],
                ),
              ),
              Divider(
                  height: 0.5,
                  color: AppColors.border.withValues(alpha: 0.5)),
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Row(
                  children: [
                    SizedBox(
                      width: 100,
                      child: Text('Phone',
                          style: TextStyle(
                              fontSize: 13, color: AppColors.textSecondary)),
                    ),
                    Expanded(
                      child: TextField(
                        controller: _agentManagerPhoneCtrl,
                        autocorrect: false,
                        keyboardType: TextInputType.phone,
                        style: TextStyle(
                            fontSize: 14, color: AppColors.textPrimary),
                        decoration: InputDecoration(
                          hintText: '+1 (555) 123-4567',
                          hintStyle: TextStyle(
                              fontSize: 13, color: AppColors.textTertiary),
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          filled: false,
                          contentPadding:
                              const EdgeInsets.symmetric(vertical: 12),
                        ),
                        onChanged: (val) => _updateAgentManager(
                            _agentManager.copyWith(phoneNumber: val)),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
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
                            ? AppColors.accent.withValues(alpha: 0.12)
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
                        activeTrackColor: AppColors.accent,
                      ),
                    ),
                  ],
                ),
              ),
              if (_demo.enabled) ...[
                Divider(
                    height: 0.5,
                    color: AppColors.border.withValues(alpha: 0.5)),
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

  // ───── SMS / MMS (Telnyx or Twilio) ─────

  bool get _smsConfiguredForBackend {
    if (_messagingBackend == MessagingBackend.none) return false;
    if (_messagingBackend == MessagingBackend.twilio) {
      return _twilioMsg.isConfigured;
    }
    return _telnyxMsg.isConfigured;
  }

  Widget _buildSmsHeader() {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => setState(() => _smsExpanded = !_smsExpanded),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                color: _smsConfiguredForBackend
                    ? AppColors.accent.withValues(alpha: 0.12)
                    : AppColors.card,
              ),
              child: Icon(Icons.sms_rounded,
                  size: 17,
                  color: _smsConfiguredForBackend
                      ? AppColors.accent
                      : AppColors.textTertiary),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'SMS & MMS',
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
                        _messagingBackend == MessagingBackend.none
                            ? 'Disabled'
                            : _messagingBackend == MessagingBackend.twilio
                                ? 'Twilio'
                                : 'Telnyx',
                        style: TextStyle(
                            fontSize: 11, color: AppColors.textTertiary),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: _messagingBackend == MessagingBackend.none
                              ? AppColors.textTertiary.withValues(alpha: 0.12)
                              : _smsConfiguredForBackend
                                  ? AppColors.green.withValues(alpha: 0.12)
                                  : AppColors.orange.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          _messagingBackend == MessagingBackend.none
                              ? 'Disabled'
                              : _smsConfiguredForBackend
                                  ? 'Configured'
                                  : 'Not Set',
                          style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.w600,
                            color: _messagingBackend == MessagingBackend.none
                                ? AppColors.textTertiary
                                : _smsConfiguredForBackend
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
              _smsExpanded
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

  Widget _buildMessagingBackendRow() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          SizedBox(
            width: 100,
            child: Text('Provider',
                style:
                    TextStyle(fontSize: 13, color: AppColors.textSecondary)),
          ),
          Expanded(
            child: DropdownButtonHideUnderline(
              child: DropdownButton<MessagingBackend>(
                value: _messagingBackend,
                isExpanded: true,
                style: TextStyle(fontSize: 14, color: AppColors.textPrimary),
                dropdownColor: AppColors.surface,
                items: const [
                  DropdownMenuItem(
                    value: MessagingBackend.none,
                    child: Text('None'),
                  ),
                  DropdownMenuItem(
                    value: MessagingBackend.telnyx,
                    child: Text('Telnyx'),
                  ),
                  DropdownMenuItem(
                    value: MessagingBackend.twilio,
                    child: Text('Twilio'),
                  ),
                ],
                onChanged: (v) {
                  if (v == null) return;
                  _setMessagingBackend(v);
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTwilioMsgTestRow() {
    final isSuccess =
        _twilioMsgStatus != null && _twilioMsgStatus!.startsWith('Connected');
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
      child: Row(
        children: [
          HoverButton(
            onTap: _testingTwilioMsg ? null : _testTwilioMsgConnection,
            borderRadius: BorderRadius.circular(6),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: AppColors.accent.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(6),
              ),
              child: _testingTwilioMsg
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
          if (_twilioMsgStatus != null) ...[
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                _twilioMsgStatus!,
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

  Widget _buildTelnyxMsgTestRow() {
    final isSuccess =
        _telnyxMsgStatus != null && _telnyxMsgStatus!.startsWith('Connected');
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
      child: Row(
        children: [
          HoverButton(
            onTap: _testingTelnyxMsg ? null : _testTelnyxMsgConnection,
            borderRadius: BorderRadius.circular(6),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: AppColors.accent.withValues(alpha: 0.12),
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

  // ───── FlightAware ─────

  Widget _buildFlightAwareHeader() {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () =>
          setState(() => _flightAwareExpanded = !_flightAwareExpanded),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                color: _flightAware.isConfigured
                    ? AppColors.accent.withValues(alpha: 0.12)
                    : AppColors.card,
              ),
              child: Icon(Icons.flight_rounded,
                  size: 17,
                  color: _flightAware.isConfigured
                      ? AppColors.accent
                      : AppColors.textTertiary),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'FlightAware',
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
                        'Flight tracking via Chrome CDP',
                        style: TextStyle(
                            fontSize: 11, color: AppColors.textTertiary),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: _flightAware.isConfigured
                              ? AppColors.green.withValues(alpha: 0.12)
                              : AppColors.orange.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          _flightAware.isConfigured ? 'Enabled' : 'Disabled',
                          style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.w600,
                            color: _flightAware.isConfigured
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
              _flightAwareExpanded
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

  Widget _buildFlightAwareEnableToggle() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          SizedBox(
            width: 100,
            child: Text('Enabled',
                style:
                    TextStyle(fontSize: 13, color: AppColors.textSecondary)),
          ),
          const Spacer(),
          SizedBox(
            height: 28,
            child: Switch.adaptive(
              value: _flightAware.enabled,
              onChanged: (v) =>
                  _updateFlightAware(_flightAware.copyWith(enabled: v)),
              activeTrackColor: AppColors.accent,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChromeCommandRow({
    required String launchCommand,
    required VoidCallback onCopy,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Paste in Terminal to start debug Chrome:',
            style: TextStyle(fontSize: 11, color: AppColors.textTertiary),
          ),
          const SizedBox(height: 6),
          HoverButton(
            onTap: () {
              onCopy();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Copied to clipboard'),
                  duration: Duration(seconds: 2),
                ),
              );
            },
            borderRadius: BorderRadius.circular(6),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.card,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      launchCommand,
                      style: TextStyle(
                        fontSize: 10,
                        color: AppColors.textSecondary,
                        fontFamily: 'Courier',
                        height: 1.4,
                      ),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(Icons.copy_rounded,
                      size: 14, color: AppColors.textTertiary),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChromeTestRow({
    required bool isLoading,
    required bool? connected,
    required VoidCallback onTest,
  }) {
    final isSuccess = connected == true;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
      child: Row(
        children: [
          HoverButton(
            onTap: isLoading ? null : onTest,
            borderRadius: BorderRadius.circular(6),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: AppColors.accent.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(6),
              ),
              child: isLoading
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
          if (connected != null) ...[
            const SizedBox(width: 10),
            Icon(
              isSuccess ? Icons.check_circle_rounded : Icons.cancel_rounded,
              size: 14,
              color: isSuccess ? AppColors.green : AppColors.red,
            ),
            const SizedBox(width: 4),
            Text(
              isSuccess ? 'Connected' : 'Not found',
              style: TextStyle(
                fontSize: 11,
                color: isSuccess ? AppColors.green : AppColors.red,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildFlightLookupRow() {
    final svc = context.watch<FlightAwareService>();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _flightNumberCtrl,
              autocorrect: false,
              textCapitalization: TextCapitalization.characters,
              style: TextStyle(fontSize: 14, color: AppColors.textPrimary),
              decoration: InputDecoration(
                hintText: 'UA100 or UAL100',
                hintStyle:
                    TextStyle(fontSize: 13, color: AppColors.textTertiary),
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                filled: false,
                contentPadding: const EdgeInsets.symmetric(vertical: 12),
              ),
              onSubmitted: (_) => _lookupFlight(),
            ),
          ),
          const SizedBox(width: 8),
          HoverButton(
            onTap: svc.loading ? null : _lookupFlight,
            borderRadius: BorderRadius.circular(6),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: AppColors.accent.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(6),
              ),
              child: svc.loading
                  ? SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.5,
                        color: AppColors.accent,
                      ),
                    )
                  : Text(
                      'Look Up',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: AppColors.accent,
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFlightResultsArea() {
    final svc = context.watch<FlightAwareService>();
    final info = svc.lastFlight;
    final error = svc.error;

    if (info == null && error == null) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (error != null)
            Text(
              error,
              style: TextStyle(fontSize: 11, color: AppColors.red),
            ),
          if (info != null) ...[
            _flightDetailRow('Flight', info.flightNumber),
            if (info.airline.isNotEmpty)
              _flightDetailRow('Airline', info.airline),
            if (info.origin.isNotEmpty)
              _flightDetailRow('Origin', info.origin),
            if (info.destination.isNotEmpty)
              _flightDetailRow('Destination', info.destination),
            if (info.departureTime != null)
              _flightDetailRow('Departure', info.departureTime!),
            if (info.arrivalTime != null)
              _flightDetailRow('Arrival', info.arrivalTime!),
            if (info.status != null)
              _flightDetailRow('Status', info.status!),
            if (info.aircraft != null)
              _flightDetailRow('Aircraft', info.aircraft!),
            if (info.gate != null)
              _flightDetailRow('Gate', info.gate!),
          ],
        ],
      ),
    );
  }

  Widget _flightDetailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: AppColors.textTertiary,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(fontSize: 11, color: AppColors.textPrimary),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRouteLookupRow() {
    final svc = context.watch<FlightAwareService>();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _originCtrl,
              autocorrect: false,
              textCapitalization: TextCapitalization.characters,
              style: TextStyle(fontSize: 14, color: AppColors.textPrimary),
              decoration: InputDecoration(
                hintText: 'KSFO',
                hintStyle:
                    TextStyle(fontSize: 13, color: AppColors.textTertiary),
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                filled: false,
                contentPadding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Icon(Icons.arrow_forward_rounded,
                size: 14, color: AppColors.textTertiary),
          ),
          Expanded(
            child: TextField(
              controller: _destCtrl,
              autocorrect: false,
              textCapitalization: TextCapitalization.characters,
              style: TextStyle(fontSize: 14, color: AppColors.textPrimary),
              decoration: InputDecoration(
                hintText: 'KJFK',
                hintStyle:
                    TextStyle(fontSize: 13, color: AppColors.textTertiary),
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                filled: false,
                contentPadding: const EdgeInsets.symmetric(vertical: 12),
              ),
              onSubmitted: (_) => _searchRoute(),
            ),
          ),
          const SizedBox(width: 8),
          HoverButton(
            onTap: svc.loading ? null : _searchRoute,
            borderRadius: BorderRadius.circular(6),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: AppColors.accent.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(6),
              ),
              child: svc.loading
                  ? SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.5,
                        color: AppColors.accent,
                      ),
                    )
                  : Text(
                      'Search',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: AppColors.accent,
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRouteResultsArea() {
    final svc = context.watch<FlightAwareService>();
    final route = svc.lastRoute;
    if (route == null) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${route.origin} → ${route.destination}  '
            '(${route.flights.length} flights)',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 6),
          for (final f in route.flights.take(15))
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 60,
                    child: Text(
                      f.flightNumber,
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: AppColors.accent,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${f.airline}  ${f.aircraft ?? ""}',
                          style: TextStyle(
                            fontSize: 10,
                            color: AppColors.textPrimary,
                          ),
                        ),
                        Text(
                          '${f.status ?? ""}'
                          '${f.departureTime != null ? "  Dep ${f.departureTime}" : ""}'
                          '${f.arrivalTime != null ? "  Arr ${f.arrivalTime}" : ""}',
                          style: TextStyle(
                            fontSize: 10,
                            color: AppColors.textTertiary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  // ───── Gmail ─────

  Widget _buildGmailHeader() {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => setState(() => _gmailExpanded = !_gmailExpanded),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                color: _gmail.isConfigured
                    ? AppColors.accent.withValues(alpha: 0.12)
                    : AppColors.card,
              ),
              child: Icon(Icons.email_rounded,
                  size: 17,
                  color: _gmail.isConfigured
                      ? AppColors.accent
                      : AppColors.textTertiary),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Gmail',
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
                        'Email via Chrome CDP',
                        style: TextStyle(
                            fontSize: 11, color: AppColors.textTertiary),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: _gmail.isConfigured
                              ? AppColors.green.withValues(alpha: 0.12)
                              : AppColors.orange.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          _gmail.isConfigured ? 'Enabled' : 'Disabled',
                          style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.w600,
                            color: _gmail.isConfigured
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
              _gmailExpanded
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

  Widget _buildGmailEnableToggle() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          SizedBox(
            width: 100,
            child: Text('Enabled',
                style:
                    TextStyle(fontSize: 13, color: AppColors.textSecondary)),
          ),
          Expanded(
            child: Switch(
              value: _gmail.enabled,
              onChanged: (v) => _updateGmail(_gmail.copyWith(enabled: v)),
              activeTrackColor: AppColors.accent,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGmailReadAccessRow() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          SizedBox(
            width: 100,
            child: Text('Read Access',
                style:
                    TextStyle(fontSize: 13, color: AppColors.textSecondary)),
          ),
          Expanded(
            child: DropdownButton<GmailReadAccess>(
              value: _gmail.readAccessMode,
              isExpanded: true,
              dropdownColor: AppColors.card,
              style: TextStyle(fontSize: 13, color: AppColors.textPrimary),
              underline: const SizedBox.shrink(),
              items: const [
                DropdownMenuItem(
                    value: GmailReadAccess.unrestricted,
                    child: Text('Unrestricted')),
                DropdownMenuItem(
                    value: GmailReadAccess.hostOnly,
                    child: Text('Host Only')),
                DropdownMenuItem(
                    value: GmailReadAccess.allowList,
                    child: Text('Allow List')),
              ],
              onChanged: (v) {
                if (v != null) {
                  _updateGmail(_gmail.copyWith(readAccessMode: v));
                }
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGmailAllowListRow() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Allowed Phone Numbers',
              style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              for (final phone in _gmail.allowedPhoneNumbers)
                Chip(
                  label: Text(phone,
                      style: TextStyle(
                          fontSize: 11, color: AppColors.textPrimary)),
                  deleteIcon: Icon(Icons.close, size: 14),
                  onDeleted: () {
                    final updated = List<String>.from(_gmail.allowedPhoneNumbers)
                      ..remove(phone);
                    _updateGmail(
                        _gmail.copyWith(allowedPhoneNumbers: updated));
                  },
                  backgroundColor: AppColors.card,
                  side: BorderSide(
                      color: AppColors.border.withValues(alpha: 0.5)),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _gmailAllowPhoneCtrl,
                  style:
                      TextStyle(fontSize: 13, color: AppColors.textPrimary),
                  decoration: InputDecoration(
                    hintText: '+1234567890',
                    hintStyle: TextStyle(
                        fontSize: 12, color: AppColors.textTertiary),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8)),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 8),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: () {
                  final phone = _gmailAllowPhoneCtrl.text.trim();
                  if (phone.isEmpty) return;
                  final updated =
                      List<String>.from(_gmail.allowedPhoneNumbers)
                        ..add(phone);
                  _updateGmail(
                      _gmail.copyWith(allowedPhoneNumbers: updated));
                  _gmailAllowPhoneCtrl.clear();
                },
                child: Text('Add',
                    style:
                        TextStyle(fontSize: 12, color: AppColors.accent)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildGmailSearchTestRow() {
    final svc = context.watch<GmailService>();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _gmailSearchCtrl,
              style: TextStyle(fontSize: 13, color: AppColors.textPrimary),
              decoration: InputDecoration(
                hintText: 'Search emails...',
                hintStyle:
                    TextStyle(fontSize: 12, color: AppColors.textTertiary),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8)),
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 8),
                isDense: true,
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 70,
            height: 30,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                padding: EdgeInsets.zero,
                backgroundColor: AppColors.accent,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(6)),
                textStyle: const TextStyle(fontSize: 11),
              ),
              onPressed: svc.loading
                  ? null
                  : () => svc.searchEmails(_gmailSearchCtrl.text),
              child: svc.loading
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Text('Search'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGmailSearchResultsArea() {
    final svc = context.watch<GmailService>();
    final result = svc.lastSearch;
    final error = svc.error;

    if (result == null && error == null) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (error != null)
            Text(error,
                style: TextStyle(fontSize: 11, color: AppColors.red)),
          if (result != null)
            for (final e in result.emails.take(5))
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (e.isUnread)
                      Container(
                        width: 6,
                        height: 6,
                        margin: const EdgeInsets.only(top: 4, right: 6),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: AppColors.accent,
                        ),
                      ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            e.subject.isNotEmpty ? e.subject : '(no subject)',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: AppColors.textPrimary,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            '${e.sender}  ${e.date}',
                            style: TextStyle(
                                fontSize: 10, color: AppColors.textTertiary),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (e.snippet.isNotEmpty)
                            Text(
                              e.snippet,
                              style: TextStyle(
                                  fontSize: 10, color: AppColors.textSecondary),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
  }

  // ───── Google Calendar ─────

  Widget _buildGcalHeader() {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => setState(() => _gcalExpanded = !_gcalExpanded),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                color: _gcal.isConfigured
                    ? AppColors.accent.withValues(alpha: 0.12)
                    : AppColors.card,
              ),
              child: Icon(Icons.calendar_month_rounded,
                  size: 17,
                  color: _gcal.isConfigured
                      ? AppColors.accent
                      : AppColors.textTertiary),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Google Calendar',
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
                        'Calendar via Chrome CDP',
                        style: TextStyle(
                            fontSize: 11, color: AppColors.textTertiary),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: _gcal.isConfigured
                              ? AppColors.green.withValues(alpha: 0.12)
                              : AppColors.orange.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          _gcal.isConfigured ? 'Enabled' : 'Disabled',
                          style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.w600,
                            color: _gcal.isConfigured
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
              _gcalExpanded
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

  Widget _buildGcalEnableToggle() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          SizedBox(
            width: 100,
            child: Text('Enabled',
                style:
                    TextStyle(fontSize: 13, color: AppColors.textSecondary)),
          ),
          Expanded(
            child: Switch(
              value: _gcal.enabled,
              onChanged: (v) => _updateGcal(_gcal.copyWith(enabled: v)),
              activeTrackColor: AppColors.accent,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGcalReadAccessRow() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          SizedBox(
            width: 100,
            child: Text('Read Access',
                style:
                    TextStyle(fontSize: 13, color: AppColors.textSecondary)),
          ),
          Expanded(
            child: DropdownButton<CalendarReadAccess>(
              value: _gcal.readAccessMode,
              isExpanded: true,
              dropdownColor: AppColors.card,
              style: TextStyle(fontSize: 13, color: AppColors.textPrimary),
              underline: const SizedBox.shrink(),
              items: const [
                DropdownMenuItem(
                    value: CalendarReadAccess.unrestricted,
                    child: Text('Unrestricted')),
                DropdownMenuItem(
                    value: CalendarReadAccess.hostOnly,
                    child: Text('Host Only')),
                DropdownMenuItem(
                    value: CalendarReadAccess.allowList,
                    child: Text('Allow List')),
              ],
              onChanged: (v) {
                if (v != null) {
                  _updateGcal(_gcal.copyWith(readAccessMode: v));
                }
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGcalAllowListRow() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Allowed Phone Numbers',
              style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              for (final phone in _gcal.allowedPhoneNumbers)
                Chip(
                  label: Text(phone,
                      style: TextStyle(
                          fontSize: 11, color: AppColors.textPrimary)),
                  deleteIcon: Icon(Icons.close, size: 14),
                  onDeleted: () {
                    final updated =
                        List<String>.from(_gcal.allowedPhoneNumbers)
                          ..remove(phone);
                    _updateGcal(
                        _gcal.copyWith(allowedPhoneNumbers: updated));
                  },
                  backgroundColor: AppColors.card,
                  side: BorderSide(
                      color: AppColors.border.withValues(alpha: 0.5)),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _gcalAllowPhoneCtrl,
                  style:
                      TextStyle(fontSize: 13, color: AppColors.textPrimary),
                  decoration: InputDecoration(
                    hintText: '+1234567890',
                    hintStyle: TextStyle(
                        fontSize: 12, color: AppColors.textTertiary),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8)),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 8),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: () {
                  final phone = _gcalAllowPhoneCtrl.text.trim();
                  if (phone.isEmpty) return;
                  final updated =
                      List<String>.from(_gcal.allowedPhoneNumbers)
                        ..add(phone);
                  _updateGcal(
                      _gcal.copyWith(allowedPhoneNumbers: updated));
                  _gcalAllowPhoneCtrl.clear();
                },
                child: Text('Add',
                    style:
                        TextStyle(fontSize: 12, color: AppColors.accent)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildGcalSyncToggle() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          SizedBox(
            width: 100,
            child: Text('Sync',
                style:
                    TextStyle(fontSize: 13, color: AppColors.textSecondary)),
          ),
          Expanded(
            child: Switch(
              value: _gcal.syncEnabled,
              onChanged: (v) =>
                  _updateGcal(_gcal.copyWith(syncEnabled: v)),
              activeTrackColor: AppColors.accent,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGcalReadTestRow() {
    final svc = context.watch<GoogleCalendarService>();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _gcalDateCtrl,
              style: TextStyle(fontSize: 13, color: AppColors.textPrimary),
              decoration: InputDecoration(
                hintText: 'YYYY-MM-DD',
                hintStyle:
                    TextStyle(fontSize: 12, color: AppColors.textTertiary),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8)),
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 8),
                isDense: true,
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 80,
            height: 30,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                padding: EdgeInsets.zero,
                backgroundColor: AppColors.accent,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(6)),
                textStyle: const TextStyle(fontSize: 11),
              ),
              onPressed: svc.loading
                  ? null
                  : () => svc.readEvents(_gcalDateCtrl.text),
              child: svc.loading
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Text('Read Day'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGcalReadResultsArea() {
    final svc = context.watch<GoogleCalendarService>();
    final events = svc.lastEvents;
    final error = svc.error;

    if (events == null && error == null) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (error != null)
            Text(error,
                style: TextStyle(fontSize: 11, color: AppColors.red)),
          if (events != null)
            for (final e in events.take(10))
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      e.title.isNotEmpty ? e.title : '(no title)',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (e.startTime.isNotEmpty || e.endTime.isNotEmpty)
                      Text(
                        '${e.startTime} – ${e.endTime}',
                        style: TextStyle(
                            fontSize: 10, color: AppColors.textTertiary),
                      ),
                    if (e.location.isNotEmpty)
                      Text(
                        e.location,
                        style: TextStyle(
                            fontSize: 10, color: AppColors.textSecondary),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
        ],
      ),
    );
  }

  // ───── Google Search ─────

  Widget _buildGoogleSearchHeader() {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () =>
          setState(() => _googleSearchExpanded = !_googleSearchExpanded),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                color: _googleSearch.isConfigured
                    ? AppColors.accent.withValues(alpha: 0.12)
                    : AppColors.card,
              ),
              child: Icon(Icons.search_rounded,
                  size: 17,
                  color: _googleSearch.isConfigured
                      ? AppColors.accent
                      : AppColors.textTertiary),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Google Search',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                      color: _googleSearch.isConfigured
                          ? AppColors.green.withValues(alpha: 0.12)
                          : AppColors.card,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      _googleSearch.isConfigured ? 'Enabled' : 'Disabled',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: _googleSearch.isConfigured
                            ? AppColors.green
                            : AppColors.textTertiary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              _googleSearchExpanded
                  ? Icons.expand_less_rounded
                  : Icons.expand_more_rounded,
              color: AppColors.textTertiary,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGoogleSearchEnableToggle() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text('Enabled',
              style: TextStyle(fontSize: 13, color: AppColors.textPrimary)),
          Switch(
            value: _googleSearch.enabled,
            onChanged: (v) =>
                _updateGoogleSearch(_googleSearch.copyWith(enabled: v)),
            activeTrackColor: AppColors.accent,
          ),
        ],
      ),
    );
  }

  Widget _buildGoogleSearchTestRow() {
    final svc = context.watch<GoogleSearchService>();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _googleSearchCtrl,
              style: TextStyle(fontSize: 13, color: AppColors.textPrimary),
              decoration: InputDecoration(
                hintText: 'Search Google...',
                hintStyle:
                    TextStyle(fontSize: 12, color: AppColors.textTertiary),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8)),
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 8),
                isDense: true,
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 70,
            height: 30,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                padding: EdgeInsets.zero,
                backgroundColor: AppColors.accent,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(6)),
                textStyle: const TextStyle(fontSize: 11),
              ),
              onPressed: svc.loading
                  ? null
                  : () => svc.searchGoogle(_googleSearchCtrl.text),
              child: svc.loading
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Text('Search'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGoogleSearchResultsArea() {
    final svc = context.watch<GoogleSearchService>();
    final result = svc.lastSearch;
    final error = svc.error;

    if (result == null && error == null) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (error != null)
            Text(error,
                style: TextStyle(fontSize: 11, color: AppColors.red)),
          if (result != null)
            for (final item in result.items.take(5))
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title.isNotEmpty ? item.title : '(no title)',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (item.url.isNotEmpty)
                      Text(
                        item.url,
                        style: TextStyle(
                            fontSize: 10, color: AppColors.accent),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    if (item.snippet.isNotEmpty)
                      Text(
                        item.snippet,
                        style: TextStyle(
                            fontSize: 10, color: AppColors.textSecondary),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
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
      height: 0.5, indent: 16, color: AppColors.border.withValues(alpha: 0.5));
}
