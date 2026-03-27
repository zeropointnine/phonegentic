import 'package:flutter/material.dart';

import '../theme_provider.dart';

class ContactCard extends StatefulWidget {
  final Map<String, dynamic> contact;
  final void Function(String field, String value) onFieldChanged;
  final VoidCallback? onDelete;
  final VoidCallback? onCall;

  const ContactCard({
    Key? key,
    required this.contact,
    required this.onFieldChanged,
    this.onDelete,
    this.onCall,
  }) : super(key: key);

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
  }

  @override
  void dispose() {
    _editController.dispose();
    super.dispose();
  }

  String get _displayName =>
      widget.contact['display_name'] as String? ?? 'Unknown';

  String get _initial => _displayName
      .replaceAll(RegExp(r'[^a-zA-Z0-9]'), '')
      .isEmpty
      ? '?'
      : _displayName
          .replaceAll(RegExp(r'[^a-zA-Z0-9]'), '')
          .substring(0, 1)
          .toUpperCase();

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

  Widget _buildField(String label, String field, {IconData? icon}) {
    final value = widget.contact[field] as String? ?? '';
    final isEditing = _editingField == field;

    return GestureDetector(
      onTap: isEditing ? null : () => _startEditing(field, value),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
                color: AppColors.border.withOpacity(0.3), width: 0.5),
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
                            ? AppColors.textTertiary.withOpacity(0.5)
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
    return Container(
      color: AppColors.surface,
      child: Column(
        children: [
          const SizedBox(height: 24),
          // Avatar
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              color: AppColors.accent.withOpacity(0.12),
              border: Border.all(
                  color: AppColors.accent.withOpacity(0.25), width: 0.5),
            ),
            child: Center(
              child: Text(
                _initial,
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w600,
                  color: AppColors.accent,
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          // Name
          GestureDetector(
            onTap: () =>
                _startEditing('display_name', _displayName),
            child: _editingField == 'display_name'
                ? Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 40),
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
                    _displayName,
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                      letterSpacing: -0.3,
                    ),
                  ),
          ),
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
                  color: AppColors.border.withOpacity(0.4), width: 0.5),
            ),
            child: Column(
              children: [
                _buildField('Phone', 'phone_number', icon: Icons.phone_outlined),
                _buildField('Email', 'email', icon: Icons.email_outlined),
                _buildField('Company', 'company',
                    icon: Icons.business_outlined),
                _buildField('Notes', 'notes',
                    icon: Icons.note_outlined),
                _buildField('Tags', 'tags', icon: Icons.label_outlined),
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
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: color.withOpacity(0.12),
              border:
                  Border.all(color: color.withOpacity(0.25), width: 0.5),
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
    );
  }
}
