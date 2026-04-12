import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../demo_mode_service.dart';
import '../theme_provider.dart';
import 'dialpad_contact_preview.dart';

class ContactCard extends StatefulWidget {
  final Map<String, dynamic> contact;
  final void Function(String field, String value) onFieldChanged;
  final VoidCallback? onDelete;
  final VoidCallback? onCall;
  final bool autoFocusName;

  const ContactCard({
    super.key,
    required this.contact,
    required this.onFieldChanged,
    this.onDelete,
    this.onCall,
    this.autoFocusName = false,
  });

  @override
  State<ContactCard> createState() => _ContactCardState();
}

class _ContactCardState extends State<ContactCard> {
  String? _editingField;
  late TextEditingController _editController;

  @override
  void initState() {
    super.initState();
    _editController = TextEditingController();
    if (widget.autoFocusName) {
      _editingField = 'display_name';
      _editController.text = _rawDisplayName;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _editController.selection = TextSelection(
          baseOffset: 0,
          extentOffset: _editController.text.length,
        );
      });
    }
  }

  @override
  void dispose() {
    _editController.dispose();
    super.dispose();
  }

  String get _rawDisplayName =>
      widget.contact['display_name'] as String? ?? 'Unknown';

  String _displayName(DemoModeService demo) =>
      demo.maskDisplayName(_rawDisplayName);

  void _startEditing(String field, String currentValue) {
    setState(() {
      _editingField = field;
      _editController.text = currentValue;
    });
  }

  void _finishEditing() {
    if (_editingField != null) {
      final newValue = _editController.text.trim();
      final oldValue = widget.contact[_editingField] as String? ?? '';
      if (newValue != oldValue) {
        widget.onFieldChanged(_editingField!, newValue);
      }
      setState(() => _editingField = null);
    }
  }

  Widget _buildField(String label, String field,
      {IconData? icon, required DemoModeService demo}) {
    final rawValue = widget.contact[field] as String? ?? '';
    final isEditing = _editingField == field;
    String value;
    if (field == 'phone_number' && rawValue.isNotEmpty) {
      value = demo.maskPhone(rawValue);
    } else if (field == 'display_name') {
      value = demo.maskDisplayName(rawValue);
    } else {
      value = rawValue;
    }

    return HoverButton(
      onTap: isEditing ? null : () => _startEditing(field, value),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
                color: AppColors.border.withValues(alpha: 0.3), width: 0.5),
          ),
        ),
        child: Row(
          children: [
            if (icon != null) ...[
              Icon(icon, size: 16, color: AppColors.textTertiary),
              const SizedBox(width: 12),
            ],
            SizedBox(
              width: 70,
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  color: AppColors.textTertiary,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            Expanded(
              child: isEditing
                  ? TextField(
                      controller: _editController,
                      autofocus: true,
                      style: TextStyle(
                          fontSize: 13, color: AppColors.textPrimary),
                      decoration: const InputDecoration(
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding: EdgeInsets.zero,
                      ),
                      onSubmitted: (_) => _finishEditing(),
                      onTapOutside: (_) => _finishEditing(),
                    )
                  : Text(
                      value.isEmpty ? 'Add $label' : value,
                      style: TextStyle(
                        fontSize: 13,
                        color: value.isEmpty
                            ? AppColors.textTertiary.withValues(alpha: 0.5)
                            : AppColors.textPrimary,
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final demo = context.watch<DemoModeService>();
    return Container(
      color: AppColors.surface,
      child: Column(
        children: [
          const SizedBox(height: 24),
          // Avatar
          ContactIdenticon(seed: _rawDisplayName, size: 72),
          const SizedBox(height: 12),
          // Name
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: HoverButton(
              onTap: () =>
                  _startEditing('display_name', _rawDisplayName),
              child: _editingField == 'display_name'
                    ? Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: TextField(
                          controller: _editController,
                          autofocus: true,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textPrimary,
                          ),
                          decoration: const InputDecoration(
                            border: InputBorder.none,
                            isDense: true,
                          ),
                          onSubmitted: (_) => _finishEditing(),
                          onTapOutside: (_) => _finishEditing(),
                        ),
                      )
                    : Text(
                        _displayName(demo),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textPrimary,
                          letterSpacing: -0.3,
                        ),
                      ),
            ),
          ),
          if ((widget.contact['phone_number'] as String? ?? '').isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              demo.maskPhone(widget.contact['phone_number'] as String),
              style: TextStyle(
                fontSize: 14,
                color: AppColors.textSecondary,
              ),
            ),
          ],
          const SizedBox(height: 20),
          // Action buttons
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (widget.onCall != null)
                _CardAction(
                  icon: Icons.phone_rounded,
                  label: 'Call',
                  color: AppColors.green,
                  onTap: widget.onCall!,
                ),
              if (widget.onCall != null) const SizedBox(width: 16),
              if (widget.onDelete != null)
                _CardAction(
                  icon: Icons.delete_outline_rounded,
                  label: 'Delete',
                  color: AppColors.red,
                  onTap: widget.onDelete!,
                ),
            ],
          ),
          const SizedBox(height: 20),
          // Fields
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: AppColors.card,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                  color: AppColors.border.withValues(alpha: 0.4), width: 0.5),
            ),
            child: Column(
              children: [
                _buildField('Phone', 'phone_number',
                    icon: Icons.phone_outlined, demo: demo),
                _buildField('Email', 'email',
                    icon: Icons.email_outlined, demo: demo),
                _buildField('Company', 'company',
                    icon: Icons.business_outlined, demo: demo),
                _buildField('Notes', 'notes',
                    icon: Icons.note_outlined, demo: demo),
                _buildField('Tags', 'tags',
                    icon: Icons.label_outlined, demo: demo),
              ],
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

class _CardAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _CardAction({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                color: color.withValues(alpha: 0.12),
                border:
                    Border.all(color: color.withValues(alpha: 0.25), width: 0.5),
              ),
              child: Icon(icon, size: 20, color: color),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 10,
                color: color,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
