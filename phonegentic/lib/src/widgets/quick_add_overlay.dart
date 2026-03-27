import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../contact_service.dart';
import '../theme_provider.dart';

class QuickAddOverlay extends StatefulWidget {
  const QuickAddOverlay({Key? key}) : super(key: key);

  @override
  State<QuickAddOverlay> createState() => _QuickAddOverlayState();
}

class _QuickAddOverlayState extends State<QuickAddOverlay> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _saving) return;

    setState(() => _saving = true);
    final service = context.read<ContactService>();
    await service.quickAdd(text);
    if (mounted) {
      service.closeQuickAdd();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: 340,
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
                color: AppColors.border.withOpacity(0.5), width: 0.5),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.2),
                blurRadius: 24,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(Icons.person_add_rounded,
                      size: 18, color: AppColors.accent),
                  const SizedBox(width: 8),
                  Text(
                    'Quick Add Contact',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                      letterSpacing: -0.3,
                    ),
                  ),
                  const Spacer(),
                  GestureDetector(
                    onTap: () =>
                        context.read<ContactService>().closeQuickAdd(),
                    child: Icon(Icons.close_rounded,
                        size: 18, color: AppColors.textTertiary),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                'Enter a phone number, name, or email',
                style: TextStyle(
                  fontSize: 11,
                  color: AppColors.textTertiary,
                ),
              ),
              const SizedBox(height: 16),
              Container(
                decoration: BoxDecoration(
                  color: AppColors.card,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                      color: AppColors.border.withOpacity(0.5), width: 0.5),
                ),
                child: TextField(
                  controller: _controller,
                  focusNode: _focusNode,
                  style: TextStyle(
                      fontSize: 15, color: AppColors.textPrimary),
                  decoration: InputDecoration(
                    hintText: '+1 555 123 4567, John, or john@...',
                    hintStyle: TextStyle(
                        color: AppColors.textTertiary, fontSize: 13),
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 14),
                  ),
                  onSubmitted: (_) => _save(),
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: GestureDetector(
                  onTap: _save,
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    decoration: BoxDecoration(
                      color: _saving
                          ? AppColors.accent.withOpacity(0.5)
                          : AppColors.accent,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Center(
                      child: Text(
                        _saving ? 'Saving...' : 'Add Contact',
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: AppColors.crtBlack,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
