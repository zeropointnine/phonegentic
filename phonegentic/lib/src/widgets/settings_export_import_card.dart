import 'package:flutter/material.dart';

import '../settings_port_service.dart';
import '../theme_provider.dart';

/// Consolidated import/export panel with section checkboxes and a Select All
/// toggle. Replaces the old per-section cards and full-backup card.
class SettingsExportImportPanel extends StatefulWidget {
  /// Called after a successful import so the parent can reload state.
  final VoidCallback? onImported;

  const SettingsExportImportPanel({super.key, this.onImported});

  @override
  State<SettingsExportImportPanel> createState() =>
      _SettingsExportImportPanelState();
}

class _SettingsExportImportPanelState extends State<SettingsExportImportPanel> {
  final Set<SettingsSection> _selected = Set.of(SettingsSection.values);
  ExportFormat _format = ExportFormat.zip;
  bool _busy = false;

  bool get _allSelected => _selected.length == SettingsSection.values.length;

  void _toggleAll(bool value) {
    setState(() {
      if (value) {
        _selected.addAll(SettingsSection.values);
      } else {
        _selected.clear();
      }
    });
  }

  void _toggleSection(SettingsSection section) {
    setState(() {
      if (_selected.contains(section)) {
        _selected.remove(section);
      } else {
        _selected.add(section);
      }
    });
  }

  Future<void> _export() async {
    if (_selected.isEmpty) return;
    setState(() => _busy = true);
    try {
      if (_allSelected) {
        await SettingsPortService.exportAll(_format, context);
      } else {
        await SettingsPortService.exportSelected(_selected, _format, context);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _import() async {
    setState(() => _busy = true);
    try {
      final ok = await SettingsPortService.importAll(context);
      if (ok) widget.onImported?.call();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'IMPORT / EXPORT',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: AppColors.textTertiary,
            letterSpacing: 0.5,
          ),
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.border, width: 0.5),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildSelectAllRow(),
              Divider(
                color: AppColors.border.withValues(alpha: 0.4),
                height: 16,
                thickness: 0.5,
              ),
              ...SettingsSection.values.map(_buildSectionRow),
              const SizedBox(height: 16),
              _buildFormatToggle(),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: _buildButton(
                        'Export', Icons.upload_rounded, _export,
                        enabled: _selected.isNotEmpty),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child:
                        _buildButton('Import', Icons.download_rounded, _import),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Center(
                child: Text(
                  'Does not include contacts or call history.',
                  style: TextStyle(
                    fontSize: 10,
                    color: AppColors.textTertiary,
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSelectAllRow() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _toggleAll(!_allSelected),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            _buildCheckbox(_allSelected),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Select All',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionRow(SettingsSection section) {
    final checked = _selected.contains(section);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _toggleSection(section),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(
          children: [
            const SizedBox(width: 20),
            _buildCheckbox(checked),
            const SizedBox(width: 10),
            Icon(section.icon, size: 14, color: AppColors.textSecondary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                section.displayName,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: checked
                      ? AppColors.textPrimary
                      : AppColors.textTertiary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCheckbox(bool checked) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      width: 16,
      height: 16,
      decoration: BoxDecoration(
        color: checked ? AppColors.accent : Colors.transparent,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
          color: checked ? AppColors.accent : AppColors.border,
          width: 1.5,
        ),
        boxShadow: checked
            ? [
                BoxShadow(
                  color: AppColors.accent.withValues(alpha: 0.3),
                  blurRadius: 4,
                  offset: const Offset(0, 1),
                ),
              ]
            : null,
      ),
      child: checked
          ? Icon(Icons.check_rounded, size: 12, color: AppColors.onAccent)
          : null,
    );
  }

  Widget _buildFormatToggle() {
    final formats = [ExportFormat.zip, ExportFormat.tar];
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
            color: AppColors.border.withValues(alpha: 0.5), width: 0.5),
      ),
      child: Row(
        children: formats.map((f) {
          final selected = f == _format;
          return Expanded(
            child: GestureDetector(
              onTap: () => setState(() => _format = f),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                padding: const EdgeInsets.symmetric(vertical: 6),
                decoration: BoxDecoration(
                  color: selected ? AppColors.accent : Colors.transparent,
                  borderRadius: BorderRadius.circular(6),
                  boxShadow: selected
                      ? [
                          BoxShadow(
                            color: AppColors.accent.withValues(alpha: 0.3),
                            blurRadius: 6,
                            offset: const Offset(0, 2),
                          )
                        ]
                      : null,
                ),
                child: Center(
                  child: Text(
                    f == ExportFormat.zip ? 'ZIP' : 'TAR',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight:
                          selected ? FontWeight.w600 : FontWeight.w500,
                      letterSpacing: -0.2,
                      color: selected
                          ? AppColors.onAccent
                          : AppColors.textSecondary,
                    ),
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildButton(String label, IconData icon, VoidCallback onTap,
      {bool enabled = true}) {
    final isEnabled = enabled && !_busy;
    return GestureDetector(
      onTap: isEnabled ? onTap : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.border, width: 0.5),
        ),
        child: _busy
            ? Center(
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.textSecondary,
                  ),
                ),
              )
            : Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon,
                      size: 14,
                      color: isEnabled
                          ? AppColors.textSecondary
                          : AppColors.textTertiary.withValues(alpha: 0.4)),
                  const SizedBox(width: 6),
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: isEnabled
                          ? AppColors.textPrimary
                          : AppColors.textTertiary.withValues(alpha: 0.4),
                      letterSpacing: -0.2,
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
