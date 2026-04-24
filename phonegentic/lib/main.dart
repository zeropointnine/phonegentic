// ignore: unnecessary_import
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:phonegentic/src/agent_config_service.dart';
import 'package:phonegentic/src/log_service.dart';
import 'package:phonegentic/src/agent_service.dart';
import 'package:phonegentic/src/calendar_sync_service.dart';
import 'package:phonegentic/src/manager_presence_service.dart';
import 'package:phonegentic/src/call_history_service.dart';
import 'package:phonegentic/src/chrome/flight_aware_service.dart';
import 'package:phonegentic/src/chrome/gmail_service.dart';
import 'package:phonegentic/src/chrome/google_calendar_service.dart';
import 'package:phonegentic/src/chrome/google_search_service.dart';
import 'package:phonegentic/src/conference/conference_service.dart';
import 'package:phonegentic/src/contact_service.dart';
import 'package:phonegentic/src/db/call_history_db.dart';
import 'package:phonegentic/src/db/pocket_tts_voice_db.dart';
import 'package:phonegentic/src/demo_mode_service.dart';
import 'package:phonegentic/src/inbound_call_flow_service.dart';
import 'package:phonegentic/src/inbound_call_router.dart';
import 'package:phonegentic/src/transfer_rule_service.dart';
import 'package:phonegentic/src/job_function_service.dart';
import 'package:phonegentic/src/messaging/messaging_service.dart';
import 'package:phonegentic/src/comfort_noise_service.dart';
import 'package:phonegentic/src/ringtone_service.dart';
import 'package:phonegentic/src/tear_sheet_service.dart';
import 'package:phonegentic/src/theme_provider.dart';
import 'package:phonegentic/src/user_state/sip_user_cubit.dart';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:logger/logger.dart';
import 'package:provider/provider.dart';
import 'package:sip_ua/sip_ua.dart';

import 'src/dialpad.dart';
import 'src/register.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Suppress known Flutter bug with Caps Lock on macOS:
  // https://github.com/flutter/flutter/issues/136280
  PlatformDispatcher.instance.onError = (error, stack) {
    if (error is AssertionError &&
        error
            .toString()
            .contains('_pressedKeys.containsKey(event.physicalKey)')) {
      return true;
    }
    return false;
  };

  Logger.level = Level.warning;

  final originalDebugPrint = debugPrint;
  debugPrint = (String? message, {int? wrapWidth}) {
    originalDebugPrint(message, wrapWidth: wrapWidth);
    if (message != null) LogService.instance.add(message);
  };

  await CallHistoryDb.initialize();
  await PocketTtsVoiceDb.seedDefaultVoices();
  final confConfig = await AgentConfigService.loadConferenceConfig();
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ThemeProvider()),
        Provider<ConferenceConfigSeed>.value(
            value: ConferenceConfigSeed(confConfig)),
      ],
      child: const MyApp(),
    ),
  );
}

/// Tiny carrier so we can pass the loaded config into the widget tree
/// without making ConferenceService before we have the SIPUAHelper ref.
class ConferenceConfigSeed {
  final dynamic config;
  const ConferenceConfigSeed(this.config);
}

typedef PageContentBuilder = Widget Function(
    [SIPUAHelper? helper, Object? arguments]);

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  static final SIPUAHelper _helper = SIPUAHelper();

  static final Map<String, PageContentBuilder> routes = {
    '/': ([SIPUAHelper? helper, Object? arguments]) => DialPadWidget(helper),
    '/register': ([SIPUAHelper? helper, Object? arguments]) =>
        RegisterWidget(helper),
  };

  Route<dynamic>? _onGenerateRoute(RouteSettings settings) {
    final name = settings.name;
    final builder = routes[name];
    if (builder == null) return null;
    return MaterialPageRoute<Widget>(
      builder: (_) => settings.arguments != null
          ? builder(_helper, settings.arguments)
          : builder(_helper),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<SIPUAHelper>.value(value: _helper),
        Provider<SipUserCubit>(
            create: (context) => SipUserCubit(sipHelper: _helper)),
        ChangeNotifierProvider<CallHistoryService>(
            create: (_) => CallHistoryService()),
        ChangeNotifierProvider<ContactService>(create: (_) => ContactService()),
        ChangeNotifierProvider<JobFunctionService>(
          create: (_) => JobFunctionService()..restoreLastUsed(),
        ),
        ChangeNotifierProvider<DemoModeService>(
          create: (_) => DemoModeService()..load(),
        ),
        ChangeNotifierProvider<RingtoneService>(
          create: (_) => RingtoneService()..load(),
        ),
        ChangeNotifierProvider<ComfortNoiseService>(
          create: (_) => ComfortNoiseService()..load(),
        ),
        ChangeNotifierProvider<InboundCallFlowService>(
          create: (_) => InboundCallFlowService()..loadAll(),
        ),
        ChangeNotifierProvider<TransferRuleService>(
          create: (_) => TransferRuleService()..loadAll(),
        ),
        ChangeNotifierProvider<FlightAwareService>(
          create: (_) => FlightAwareService()..loadConfig(),
        ),
        ChangeNotifierProvider<GmailService>(
          create: (_) => GmailService()..loadConfig(),
        ),
        ChangeNotifierProvider<GoogleCalendarService>(
          create: (_) => GoogleCalendarService()..loadConfig(),
        ),
        ChangeNotifierProvider<GoogleSearchService>(
          create: (_) => GoogleSearchService()..loadConfig(),
        ),
        ChangeNotifierProxyProvider6<
            CallHistoryService,
            ContactService,
            JobFunctionService,
            FlightAwareService,
            GmailService,
            GoogleCalendarService,
            AgentService>(
          create: (_) => AgentService()..registerSipHelper(_helper),
          update: (context, history, contacts, jobFunctions, flight, gmail,
              gcal, agent) {
            history.onAgentSearch = (query) =>
                agent!.sendUserMessage('Search my call history: $query');
            return agent!
              ..callHistory = history
              ..contactService = contacts
              ..jobFunctionService = jobFunctions
              ..flightAwareService = flight
              ..gmailService = gmail
              ..googleCalendarService = gcal
              ..googleSearchService = context.read<GoogleSearchService>()
              ..demoModeService = context.read<DemoModeService>()
              ..comfortNoiseService = context.read<ComfortNoiseService>();
          },
        ),
        ChangeNotifierProxyProvider<ContactService, MessagingService>(
          create: (_) => MessagingService()..start(),
          update: (_, contacts, messaging) {
            messaging!.contactService = contacts;
            return messaging;
          },
        ),
        ChangeNotifierProxyProvider2<AgentService, CallHistoryService,
            TearSheetService>(
          create: (_) => TearSheetService()..sipHelper = _helper,
          update: (context, agent, history, tearSheet) {
            tearSheet!
              ..agentService = agent
              ..callHistory = history;
            agent.tearSheetService = tearSheet;
            return tearSheet;
          },
        ),
        ChangeNotifierProxyProvider2<JobFunctionService, AgentService,
            CalendarSyncService>(
          create: (_) => CalendarSyncService()..start(),
          update: (context, jf, agent, sync) {
            sync!.jobFunctionService = jf;
            agent.calendarSyncService = sync;
            agent.messagingService = context.read<MessagingService>();
            agent.transferRuleService = context.read<TransferRuleService>();
            return sync;
          },
        ),
        ChangeNotifierProxyProvider<AgentService, ManagerPresenceService>(
          lazy: false,
          create: (_) => ManagerPresenceService()..start(),
          update: (_, agent, presence) {
            presence!.agent = agent;
            agent.managerPresenceService = presence;
            return presence;
          },
        ),
        ChangeNotifierProxyProvider<AgentService, ConferenceService>(
          create: (ctx) {
            final seed = ctx.read<ConferenceConfigSeed>();
            return ConferenceService()
              ..sipHelper = _helper
              ..applyConfig(seed.config);
          },
          update: (_, agent, conf) {
            agent.conferenceService = conf;
            return conf!;
          },
        ),
        ChangeNotifierProvider<InboundCallRouter>(
          create: (_) => InboundCallRouter(),
        ),
      ],
      child: MaterialApp(
        title: 'Phonegentic AI',
        debugShowCheckedModeBanner: false,
        theme: Provider.of<ThemeProvider>(context).currentTheme,
        initialRoute: '/',
        onGenerateRoute: _onGenerateRoute,
      ),
    );
  }
}
