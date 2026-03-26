import 'package:phonegnetic/src/agent_service.dart';
import 'package:phonegnetic/src/call_history_service.dart';
import 'package:phonegnetic/src/db/call_history_db.dart';
import 'package:phonegnetic/src/theme_provider.dart';
import 'package:phonegnetic/src/user_state/sip_user_cubit.dart';
import 'package:flutter/material.dart';
import 'package:logger/logger.dart';
import 'package:provider/provider.dart';
import 'package:sip_ua/sip_ua.dart';

import 'src/dialpad.dart';
import 'src/register.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  Logger.level = Level.warning;
  await CallHistoryDb.initialize();
  runApp(
    MultiProvider(
      providers: [ChangeNotifierProvider(create: (_) => ThemeProvider())],
      child: const MyApp(),
    ),
  );
}

typedef PageContentBuilder = Widget Function([SIPUAHelper? helper, Object? arguments]);

class MyApp extends StatelessWidget {
  const MyApp({Key? key}) : super(key: key);

  static final SIPUAHelper _helper = SIPUAHelper();

  static final Map<String, PageContentBuilder> routes = {
    '/': ([SIPUAHelper? helper, Object? arguments]) => DialPadWidget(helper),
    '/register': ([SIPUAHelper? helper, Object? arguments]) => RegisterWidget(helper),
  };

  Route<dynamic>? _onGenerateRoute(RouteSettings settings) {
    final name = settings.name;
    final builder = routes[name];
    if (builder == null) return null;
    return MaterialPageRoute<Widget>(
      builder: (_) => settings.arguments != null ? builder(_helper, settings.arguments) : builder(_helper),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<SIPUAHelper>.value(value: _helper),
        Provider<SipUserCubit>(create: (context) => SipUserCubit(sipHelper: _helper)),
        ChangeNotifierProvider<CallHistoryService>(create: (_) => CallHistoryService()),
        ChangeNotifierProxyProvider<CallHistoryService, AgentService>(
          create: (_) => AgentService()..sipHelper = _helper,
          update: (_, history, agent) => agent!..callHistory = history,
        ),
      ],
      child: MaterialApp(
        title: 'Phonegnetic AI',
        debugShowCheckedModeBanner: false,
        theme: Provider.of<ThemeProvider>(context).currentTheme,
        initialRoute: '/',
        onGenerateRoute: _onGenerateRoute,
      ),
    );
  }
}
