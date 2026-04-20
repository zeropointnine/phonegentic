import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../contact_service.dart';
import '../demo_mode_service.dart';
import '../theme_provider.dart';
import 'dialpad_contact_preview.dart';

/// Detail-pane widget for resolving a single import conflict.
/// Shows local vs macOS values side-by-side with tap-to-select per field.
class ContactMergeCard extends StatefulWidget {
  final ImportConflict conflict;

  const ContactMergeCard({super.key, required this.conflict});

  @override
  State<ContactMergeCard> createState() => _ContactMergeCardState();
}

class _ContactMergeCardState extends State<ContactMergeCard> {
  /// Tracks which source the user picked per field.
  /// true = macOS, false = local. Defaults to the richer value.
  late Map<String, bool> _useMacos;

  @override
  void initState() {
    super.initState();
    _initDefaults();
  }

  @override
  void didUpdateWidget(covariant ContactMergeCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.conflict != widget.conflict) _initDefaults();
  }

  void _initDefaults() {
    _useMacos = {};
    for (final field in _fields) {
      final localVal = _localValue(field);
      final macVal = _macosValue(field);
      // Default to whichever side has more data; prefer macOS on tie.
      _useMacos[field] = macVal.isNotEmpty &&
          (localVal.isEmpty || macVal.length >= localVal.length);
    }
  }

  static const _fields = [
    'display_name',
    'phone_number',
    'email',
    'company',
  ];

  static const _fieldLabels = {
    'display_name': 'Name',
    'phone_number': 'Phone',
    'email': 'Email',
    'company': 'Company',
  };

  static const _fieldIcons = {
    'display_name': Icons.person_outline_rounded,
    'phone_number': Icons.phone_outlined,
    'email': Icons.email_outlined,
    'company': Icons.business_outlined,
  };

  String _localValue(String field) =>
      widget.conflict.localContact[field] as String? ?? '';

  String _macosValue(String field) {
    switch (field) {
      case 'display_name':
        return widget.conflict.macosDisplayName;
      case 'phone_number':
        return widget.conflict.macosPhone;
      case 'email':
        return widget.conflict.macosEmail ?? '';
      case 'company':
        return widget.conflict.macosCompany ?? '';
      default:
        return '';
    }
  }

  Map<String, String?> _buildMergedFields() {
    final result = <String, String?>{};
    for (final field in _fields) {
      final picked = _useMacos[field] == true
          ? _macosValue(field)
          : _localValue(field);
      result[field] = picked.isNotEmpty ? picked : null;
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final demo = context.watch<DemoModeService>();
    final conflict = widget.conflict;
    final localName =
        conflict.localContact['display_name'] as String? ?? 'Unknown';
    final macName = conflict.macosDisplayName;

    return Container(
      color: AppColors.surface,
      child: SingleChildScrollView(
        child: Column(
          children: [
            const SizedBox(height: 20),
            // Header avatars
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _AvatarColumn(
                  label: 'Local',
                  name: demo.maskDisplayName(localName),
                  thumbnailPath:
                      conflict.localContact['thumbnail_path'] as String?,
                  seed: localName,
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Icon(Icons.compare_arrows_rounded,
                      size: 24, color: AppColors.textTertiary),
                ),
                _AvatarColumn(
                  label: 'macOS',
                  name: demo.maskDisplayName(macName),
                  thumbnailPath: conflict.macosThumbnailPath,
                  seed: macName,
                ),
              ],
            ),
            const SizedBox(height: 20),
            // Field comparison rows
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: AppColors.card,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                    color: AppColors.border.withValues(alpha: 0.4),
                    width: 0.5),
              ),
              child: Column(
                children: _fields.map((field) {
                  final localVal = _localValue(field);
                  final macVal = _macosValue(field);
                  final identical = localVal == macVal;

                  String displayLocal = localVal;
                  String displayMac = macVal;
                  if (field == 'phone_number') {
                    if (localVal.isNotEmpty) {
                      displayLocal = demo.maskPhone(localVal);
                    }
                    if (macVal.isNotEmpty) {
                      displayMac = demo.maskPhone(macVal);
                    }
                  } else if (field == 'display_name') {
                    displayLocal = demo.maskDisplayName(localVal);
                    displayMac = demo.maskDisplayName(macVal);
                  }

                  return _FieldRow(
                    label: _fieldLabels[field]!,
                    icon: _fieldIcons[field]!,
                    localValue: displayLocal,
                    macosValue: displayMac,
                    identical: identical,
                    useMacos: _useMacos[field] ?? false,
                    onPickLocal: identical
                        ? null
                        : () => setState(() => _useMacos[field] = false),
                    onPickMacos: identical
                        ? null
                        : () => setState(() => _useMacos[field] = true),
                    isLast: field == _fields.last,
                  );
                }).toList(),
              ),
            ),
            const SizedBox(height: 24),
            // Action buttons
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: _ActionButton(
                          label: 'Use Local',
                          icon: Icons.smartphone_rounded,
                          color: AppColors.accent,
                          onTap: () => context
                              .read<ContactService>()
                              .resolveKeepLocal(conflict),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _ActionButton(
                          label: 'Use macOS',
                          icon: Icons.desktop_mac_rounded,
                          color: AppColors.green,
                          onTap: () => context
                              .read<ContactService>()
                              .resolveUseMacOS(conflict),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: _ActionButton(
                          label: 'Merge',
                          icon: Icons.merge_rounded,
                          color: AppColors.burntAmber,
                          onTap: () => context
                              .read<ContactService>()
                              .resolveMerge(conflict, _buildMergedFields()),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _ActionButton(
                          label: 'Keep Both',
                          icon: Icons.people_outline_rounded,
                          color: AppColors.textSecondary,
                          onTap: () => context
                              .read<ContactService>()
                              .resolveKeepBoth(conflict),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}

class _AvatarColumn extends StatelessWidget {
  final String label;
  final String name;
  final String? thumbnailPath;
  final String seed;

  const _AvatarColumn({
    required this.label,
    required this.name,
    this.thumbnailPath,
    required this.seed,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w600,
            color: AppColors.textTertiary,
            letterSpacing: 0.5,
          ),
        ),
        const SizedBox(height: 8),
        ContactIdenticon(
          seed: seed,
          size: 56,
          thumbnailPath: thumbnailPath,
        ),
        const SizedBox(height: 6),
        SizedBox(
          width: 100,
          child: Text(
            name,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
              letterSpacing: -0.2,
            ),
          ),
        ),
      ],
    );
  }
}

class _FieldRow extends StatelessWidget {
  final String label;
  final IconData icon;
  final String localValue;
  final String macosValue;
  final bool identical;
  final bool useMacos;
  final VoidCallback? onPickLocal;
  final VoidCallback? onPickMacos;
  final bool isLast;

  const _FieldRow({
    required this.label,
    required this.icon,
    required this.localValue,
    required this.macosValue,
    required this.identical,
    required this.useMacos,
    this.onPickLocal,
    this.onPickMacos,
    this.isLast = false,
  });

  @override
  Widget build(BuildContext context) {
    final accent = AppColors.accent;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        border: isLast
            ? null
            : Border(
                bottom: BorderSide(
                    color: AppColors.border.withValues(alpha: 0.3),
                    width: 0.5),
              ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 14, color: AppColors.textTertiary),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textTertiary,
                  letterSpacing: 0.3,
                ),
              ),
              if (identical) ...[
                const Spacer(),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: AppColors.green.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    'SAME',
                    style: TextStyle(
                      fontSize: 8,
                      fontWeight: FontWeight.w700,
                      color: AppColors.green,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
              ],
            ],
          ),
          if (!identical) ...[
            const SizedBox(height: 6),
            _ValuePill(
              label: 'Local',
              value: localValue,
              selected: !useMacos,
              accent: accent,
              onTap: onPickLocal,
            ),
            const SizedBox(height: 4),
            _ValuePill(
              label: 'macOS',
              value: macosValue,
              selected: useMacos,
              accent: accent,
              onTap: onPickMacos,
            ),
          ] else ...[
            const SizedBox(height: 4),
            Text(
              localValue.isEmpty ? '—' : localValue,
              style: TextStyle(
                fontSize: 13,
                color: localValue.isEmpty
                    ? AppColors.textTertiary.withValues(alpha: 0.5)
                    : AppColors.textPrimary,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ValuePill extends StatelessWidget {
  final String label;
  final String value;
  final bool selected;
  final Color accent;
  final VoidCallback? onTap;

  const _ValuePill({
    required this.label,
    required this.value,
    required this.selected,
    required this.accent,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: onTap != null ? SystemMouseCursors.click : MouseCursor.defer,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: selected
                ? accent.withValues(alpha: 0.10)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected
                  ? accent.withValues(alpha: 0.4)
                  : AppColors.border.withValues(alpha: 0.3),
              width: selected ? 1.0 : 0.5,
            ),
          ),
          child: Row(
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                  color: AppColors.textTertiary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 8,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textTertiary,
                    letterSpacing: 0.3,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  value.isEmpty ? '—' : value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: value.isEmpty
                        ? AppColors.textTertiary.withValues(alpha: 0.5)
                        : AppColors.textPrimary,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
              if (selected)
                Icon(Icons.check_circle_rounded,
                    size: 14, color: accent),
            ],
          ),
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  const _ActionButton({
    required this.label,
    required this.icon,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
                color: color.withValues(alpha: 0.25), width: 0.5),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 16, color: color),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: color,
                  letterSpacing: -0.2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
