import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../agent_service.dart';
import '../tear_sheet_service.dart';
import '../theme_provider.dart';

class TearSheetEditor extends StatefulWidget {
  const TearSheetEditor({super.key});

  @override
  State<TearSheetEditor> createState() => _TearSheetEditorState();
}

class _TearSheetEditorState extends State<TearSheetEditor> {
  final TextEditingController _promptController = TextEditingController();
  final FocusNode _promptFocus = FocusNode();
  bool _sending = false;

  static const _suggestions = [
    'Contacts not called in 2 weeks',
    'All contacts tagged "lead"',
    'Missed calls from this week',
    'Contacts with no completed calls',
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _promptFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _promptController.dispose();
    _promptFocus.dispose();
    super.dispose();
  }

  void _send() {
    final text = _promptController.text.trim();
    if (text.isEmpty || _sending) return;

    setState(() => _sending = true);

    final agent = context.read<AgentService>();
    final tearSheet = context.read<TearSheetService>();

    agent.sendUserMessage(
      'Build a tear sheet: $text. '
      'Search my contacts, then create the tear sheet with create_tear_sheet.',
    );

    tearSheet.closeEditor();
  }

  void _useSuggestion(String suggestion) {
    _promptController.text = suggestion;
    _send();
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: 440,
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
                color: AppColors.border.withValues(alpha: 0.5), width: 0.5),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.2),
                blurRadius: 24,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.receipt_long_rounded,
                      size: 18, color: AppColors.accent),
                  const SizedBox(width: 8),
                  Text(
                    'New Tear Sheet',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                      letterSpacing: -0.3,
                    ),
                  ),
                  const Spacer(),
                  HoverButton(
                    onTap: () =>
                        context.read<TearSheetService>().closeEditor(),
                    child: Icon(Icons.close_rounded,
                        size: 18, color: AppColors.textTertiary),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                'Describe who you want to call. The agent will search your '
                'contacts and build the queue.',
                style: TextStyle(
                  fontSize: 12,
                  color: AppColors.textTertiary,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 14),
              Container(
                decoration: BoxDecoration(
                  color: AppColors.card,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                      color: AppColors.border.withValues(alpha: 0.5), width: 0.5),
                ),
                child: TextField(
                  controller: _promptController,
                  focusNode: _promptFocus,
                  maxLines: 2,
                  minLines: 1,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _send(),
                  style: TextStyle(
                      fontSize: 13, color: AppColors.textPrimary),
                  decoration: InputDecoration(
                    hintText: 'e.g. "Contacts not called in 2 weeks"',
                    hintStyle: TextStyle(
                        color: AppColors.textTertiary.withValues(alpha: 0.6),
                        fontSize: 13),
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 12),
                    prefixIcon: Icon(Icons.search_rounded,
                        size: 18, color: AppColors.textTertiary),
                    suffixIcon: _sending
                        ? const Padding(
                            padding: EdgeInsets.all(12),
                            child: SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2),
                            ),
                          )
                        : HoverButton(
                            onTap: _send,
                            child: Icon(Icons.send_rounded,
                                size: 18, color: AppColors.accent),
                          ),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Text(
                'Suggestions',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textTertiary,
                  letterSpacing: 0.3,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: _suggestions
                    .map((s) => _SuggestionChip(
                          label: s,
                          onTap: () => _useSuggestion(s),
                        ))
                    .toList(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SuggestionChip extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _SuggestionChip({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return HoverButton(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: AppColors.accent.withValues(alpha: 0.08),
          border: Border.all(
              color: AppColors.accent.withValues(alpha: 0.2), width: 0.5),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            color: AppColors.accent,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
}
