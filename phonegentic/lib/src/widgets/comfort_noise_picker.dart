import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../comfort_noise_service.dart';
import '../theme_provider.dart';

/// Reusable widget for managing comfort noise files.
/// Used in both AgentSettingsTab and JobFunctionEditor.
class ComfortNoisePicker extends StatefulWidget {
  /// Currently selected file path (null if none selected).
  final String? selectedPath;

  /// Called when the user selects a file.
  final ValueChanged<String?> onSelected;

  /// If true, shows a "Use global setting" option at the top.
  final bool showGlobalOption;

  const ComfortNoisePicker({
    super.key,
    required this.selectedPath,
    required this.onSelected,
    this.showGlobalOption = false,
  });

  @override
  State<ComfortNoisePicker> createState() => _ComfortNoisePickerState();
}

class _ComfortNoisePickerState extends State<ComfortNoisePicker> {
  String? _previewingPath;
  ComfortNoiseService? _svc;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _svc = context.read<ComfortNoiseService>();
  }

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<ComfortNoiseService>();
    final files = svc.files;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (files.isEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              'No comfort noise files uploaded yet.',
              style: TextStyle(fontSize: 12, color: AppColors.textTertiary),
            ),
          ),
        for (final file in files) _buildFileRow(svc, file),
        const SizedBox(height: 8),
        SizedBox(
          height: 32,
          child: TextButton.icon(
            onPressed: () async {
              final path = await svc.pickAndUpload();
              if (path != null) widget.onSelected(path);
            },
            icon: Icon(Icons.upload_file, size: 16, color: AppColors.accent),
            label: Text(
              'Upload audio file',
              style: TextStyle(fontSize: 12, color: AppColors.accent),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildFileRow(ComfortNoiseService svc, ComfortNoiseFileInfo file) {
    final isSelected = widget.selectedPath == file.path;
    final isPreviewing = _previewingPath == file.path;

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Container(
        decoration: BoxDecoration(
          color: isSelected
              ? AppColors.accent.withValues(alpha: 0.08)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: isSelected
              ? Border.all(color: AppColors.accent.withValues(alpha: 0.3))
              : null,
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => widget.onSelected(file.path),
          child: Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Row(
              children: [
                Icon(
                  isSelected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  size: 18,
                  color: isSelected
                      ? AppColors.accent
                      : AppColors.textTertiary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    file.displayName,
                    style: TextStyle(
                      fontSize: 13,
                      color: AppColors.textPrimary,
                      fontWeight:
                          isSelected ? FontWeight.w600 : FontWeight.normal,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                // Preview button
                SizedBox(
                  width: 28,
                  height: 28,
                  child: IconButton(
                    padding: EdgeInsets.zero,
                    iconSize: 16,
                    icon: Icon(
                      isPreviewing ? Icons.stop : Icons.play_arrow,
                      color: AppColors.textSecondary,
                    ),
                    onPressed: () {
                      if (isPreviewing) {
                        svc.stopPreview();
                        setState(() => _previewingPath = null);
                      } else {
                        svc.preview(file.path);
                        setState(() => _previewingPath = file.path);
                      }
                    },
                  ),
                ),
                // Delete button
                SizedBox(
                  width: 28,
                  height: 28,
                  child: IconButton(
                    padding: EdgeInsets.zero,
                    iconSize: 16,
                    icon: Icon(Icons.delete_outline,
                        color: AppColors.textTertiary),
                    onPressed: () async {
                      if (isPreviewing) {
                        svc.stopPreview();
                        setState(() => _previewingPath = null);
                      }
                      await svc.deleteFile(file.path);
                      if (isSelected) {
                        widget.onSelected(null);
                      }
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _svc?.stopPreview();
    super.dispose();
  }
}
