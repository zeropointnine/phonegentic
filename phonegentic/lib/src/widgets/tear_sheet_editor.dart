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
  final ScrollController _scrollController = ScrollController();
  bool _sending = false;
  bool _promptValid = false;

  static const List<String> _suggestions = <String>[
    'Contacts not called in 2 weeks',
    'All contacts tagged "lead"',
    'Missed calls from this week',
    'Contacts with no completed calls',
  ];

  @override
  void initState() {
    super.initState();
    _promptController.addListener(_onPromptChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _promptFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _promptController.dispose();
    _promptFocus.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onPromptChanged() {
    final bool valid = _promptController.text.trim().isNotEmpty;
    if (valid != _promptValid) setState(() => _promptValid = valid);
  }

  void _send() {
    final String text = _promptController.text.trim();
    if (text.isEmpty || _sending) return;

    setState(() => _sending = true);

    final AgentService agent = context.read<AgentService>();
    final TearSheetService tearSheet = context.read<TearSheetService>();

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
          width: 460,
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.85,
          ),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
                color: AppColors.border.withValues(alpha: 0.5), width: 0.5),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.25),
                blurRadius: 30,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              _buildHeader(),
              Flexible(
                child: Scrollbar(
                  controller: _scrollController,
                  child: SingleChildScrollView(
                    controller: _scrollController,
                    padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          'Describe who you want to call. The agent will '
                          'search your contacts and build the queue.',
                          style: TextStyle(
                            fontSize: 12,
                            color: AppColors.textTertiary,
                            height: 1.4,
                          ),
                        ),
                        const SizedBox(height: 14),
                        _buildSectionLabel('Prompt'),
                        _buildPromptField(),
                        const SizedBox(height: 16),
                        _buildSectionLabel('Suggestions'),
                        const SizedBox(height: 4),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: _suggestions
                              .map((String s) => _SuggestionChip(
                                    label: s,
                                    onTap: () => _useSuggestion(s),
                                  ))
                              .toList(),
                        ),
                        const SizedBox(height: 6),
                      ],
                    ),
                  ),
                ),
              ),
              _buildActionBar(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 16, 12),
      decoration: BoxDecoration(
        border:
            Border(bottom: BorderSide(color: AppColors.border, width: 0.5)),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.receipt_long_rounded,
              size: 18, color: AppColors.accent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'New Tear Sheet',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
                letterSpacing: -0.3,
              ),
            ),
          ),
          HoverButton(
            onTap: context.read<TearSheetService>().closeEditor,
            borderRadius: BorderRadius.circular(7),
            child: Container(
              width: 26,
              height: 26,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(7),
                color: AppColors.card,
              ),
              child: Icon(Icons.close_rounded,
                  size: 14, color: AppColors.textTertiary),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionLabel(String label) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6, top: 2),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: AppColors.textTertiary,
          letterSpacing: 0.3,
        ),
      ),
    );
  }

  Widget _buildPromptField() {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
            color: AppColors.border.withValues(alpha: 0.5), width: 0.5),
      ),
      child: TextField(
        controller: _promptController,
        focusNode: _promptFocus,
        maxLines: 3,
        minLines: 2,
        textInputAction: TextInputAction.send,
        onSubmitted: (_) => _send(),
        style: TextStyle(
            fontSize: 13, color: AppColors.textPrimary, height: 1.5),
        decoration: InputDecoration(
          hintText: 'e.g. "Contacts not called in 2 weeks"',
          hintStyle: TextStyle(
              color: AppColors.textTertiary, fontSize: 12),
          border: InputBorder.none,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          prefixIcon: Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Icon(Icons.search_rounded,
                size: 16, color: AppColors.textTertiary),
          ),
          prefixIconConstraints:
              const BoxConstraints(minWidth: 28, minHeight: 16),
        ),
      ),
    );
  }

  Widget _buildActionBar() {
    final bool canSend = _promptValid && !_sending;
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: AppColors.border, width: 0.5)),
      ),
      child: Row(
        children: <Widget>[
          const Spacer(),
          HoverButton(
            onTap: context.read<TearSheetService>().closeEditor,
            borderRadius: BorderRadius.circular(10),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                color: AppColors.card,
                border: Border.all(
                    color: AppColors.border.withValues(alpha: 0.5),
                    width: 0.5),
              ),
              child: Text(
                'Cancel',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: AppColors.textSecondary,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          HoverButton(
            onTap: canSend ? _send : null,
            borderRadius: BorderRadius.circular(10),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              padding:
                  const EdgeInsets.symmetric(horizontal: 20, vertical: 9),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                color: canSend
                    ? AppColors.accent
                    : AppColors.accent.withValues(alpha: 0.3),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  if (_sending) ...<Widget>[
                    SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.5,
                        valueColor: AlwaysStoppedAnimation<Color>(
                            AppColors.crtBlack.withValues(alpha: 0.7)),
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  Text(
                    _sending ? 'Building...' : 'Build Queue',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: canSend
                          ? AppColors.crtBlack
                          : AppColors.crtBlack.withValues(alpha: 0.5),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
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
