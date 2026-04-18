import 'package:flutter/material.dart';

import '../settings_port_service.dart';
import '../theme_provider.dart';

class SettingsExportImportCard extends StatefulWidget {
  final SettingsSection section;

  /// Called after a successful import so the parent can reload state.
  final VoidCallback? onImported;

  const SettingsExportImportCard({
    super.key,
    required this.section,
    this.onImported,
  });

  @override
  State<SettingsExportImportCard> createState() =>
      _SettingsExportImportCardState();
}

class _SettingsExportImportCardState extends State<SettingsExportImportCard> {
  ExportFormat _format = ExportFormat.json;
  bool _busy = false;

  Future<void> _export() async {
    setState(() => _busy = true);
    try {
      await SettingsPortService.exportSection(
          widget.section, _format, context);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _import() async {
    setState(() => _busy = true);
    try {
      final ok =
          await SettingsPortService.importSection(widget.section, context);
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
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.border, width: 0.5),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.section.displayName,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 12),
              _buildFormatToggle(),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(child: _buildButton('Export', Icons.upload_rounded, _export)),
                  const SizedBox(width: 10),
                  Expanded(child: _buildButton('Import', Icons.download_rounded, _import)),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildFormatToggle() {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(8),
        border:
            Border.all(color: AppColors.border.withValues(alpha: 0.5), width: 0.5),
      ),
      child: Row(
        children: ExportFormat.values.map((f) {
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
                    _formatLabel(f),
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
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

  Widget _buildButton(String label, IconData icon, VoidCallback onTap) {
    return GestureDetector(
      onTap: _busy ? null : onTap,
      child: Container(
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
                  Icon(icon, size: 14, color: AppColors.textSecondary),
                  const SizedBox(width: 6),
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                      letterSpacing: -0.2,
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  static String _formatLabel(ExportFormat f) {
    switch (f) {
      case ExportFormat.json:
        return 'JSON';
      case ExportFormat.zip:
        return 'ZIP';
      case ExportFormat.tar:
        return 'TAR';
    }
  }
}

/// Exports/imports **all** settings sections as a single archive.
class FullBackupExportImportCard extends StatefulWidget {
  /// Called after a successful full import so the parent can reload services.
  final VoidCallback? onImported;

  const FullBackupExportImportCard({super.key, this.onImported});

  @override
  State<FullBackupExportImportCard> createState() =>
      _FullBackupExportImportCardState();
}

class _FullBackupExportImportCardState
    extends State<FullBackupExportImportCard> {
  ExportFormat _format = ExportFormat.zip;
  bool _busy = false;

  Future<void> _export() async {
    setState(() => _busy = true);
    try {
      await SettingsPortService.exportAll(_format, context);
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
          'FULL BACKUP',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: AppColors.textTertiary,
            letterSpacing: 0.5,
          ),
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.border, width: 0.5),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'All Settings',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'SIP, agent config, job functions & inbound workflows. '
                'Does not include contacts or call history.',
                style: TextStyle(
                  fontSize: 11,
                  color: AppColors.textTertiary,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 12),
              _buildFormatToggle(),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                      child: _buildButton(
                          'Export', Icons.upload_rounded, _export)),
                  const SizedBox(width: 10),
                  Expanded(
                      child: _buildButton(
                          'Import', Icons.download_rounded, _import)),
                ],
              ),
            ],
          ),
        ),
      ],
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

  Widget _buildButton(String label, IconData icon, VoidCallback onTap) {
    return GestureDetector(
      onTap: _busy ? null : onTap,
      child: Container(
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
                  Icon(icon, size: 14, color: AppColors.textSecondary),
                  const SizedBox(width: 6),
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                      letterSpacing: -0.2,
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
