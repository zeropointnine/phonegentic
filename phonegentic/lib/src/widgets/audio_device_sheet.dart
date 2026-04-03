import 'package:flutter/material.dart';
import '../audio_device_service.dart';
import '../theme_provider.dart';

IconData _iconForTransport(String transportType, String deviceType) {
  switch (transportType) {
    case 'built-in':
      return deviceType == 'input'
          ? Icons.mic_rounded
          : Icons.laptop_mac_rounded;
    case 'bluetooth':
    case 'bluetooth-le':
      return Icons.bluetooth_audio_rounded;
    case 'usb':
      return Icons.usb_rounded;
    case 'hdmi':
    case 'displayport':
      return Icons.tv_rounded;
    case 'aggregate':
    case 'virtual':
      return Icons.tune_rounded;
    default:
      return Icons.headphones_rounded;
  }
}

typedef OnAudioDeviceSelected = Future<void> Function(AudioDevice device, bool isOutput);

Future<void> showAudioDeviceSheet(
  BuildContext context, {
  OnAudioDeviceSelected? onDeviceSelected,
}) {
  return showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => _AudioDeviceSheet(onDeviceSelected: onDeviceSelected),
  );
}

class _AudioDeviceSheet extends StatefulWidget {
  final OnAudioDeviceSelected? onDeviceSelected;
  const _AudioDeviceSheet({this.onDeviceSelected});

  @override
  State<_AudioDeviceSheet> createState() => _AudioDeviceSheetState();
}

class _AudioDeviceSheetState extends State<_AudioDeviceSheet>
    with SingleTickerProviderStateMixin {
  List<AudioDevice>? _devices;
  String? _error;
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _loadDevices();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadDevices() async {
    try {
      final devices = await AudioDeviceService.getAudioDevices();
      if (mounted) setState(() => _devices = devices);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _selectOutput(AudioDevice device) async {
    await AudioDeviceService.setDefaultOutputDevice(device.id);
    await widget.onDeviceSelected?.call(device, true);
    await _loadDevices();
  }

  Future<void> _selectInput(AudioDevice device) async {
    await AudioDeviceService.setDefaultInputDevice(device.id);
    await widget.onDeviceSelected?.call(device, false);
    await _loadDevices();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.55,
      ),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        border: Border(
          top: BorderSide(color: AppColors.border.withOpacity(0.5)),
          left: BorderSide(color: AppColors.border.withOpacity(0.5)),
          right: BorderSide(color: AppColors.border.withOpacity(0.5)),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.3),
            blurRadius: 30,
            offset: const Offset(0, -8),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildHandle(),
          _buildHeader(),
          _buildTabs(),
          const Divider(height: 0.5, thickness: 0.5),
          Flexible(child: _buildBody()),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Widget _buildHandle() {
    return Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 4),
      child: Container(
        width: 36,
        height: 4,
        decoration: BoxDecoration(
          color: AppColors.textTertiary.withOpacity(0.4),
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              color: AppColors.accent.withOpacity(0.12),
            ),
            child: Icon(
              Icons.headphones_rounded,
              size: 18,
              color: AppColors.accent,
            ),
          ),
          const SizedBox(width: 12),
          Text(
            'Audio Devices',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
              letterSpacing: -0.3,
            ),
          ),
          const Spacer(),
          GestureDetector(
            onTap: _loadDevices,
            child: Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: AppColors.card,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                    color: AppColors.border.withOpacity(0.5), width: 0.5),
              ),
              child: Icon(Icons.refresh_rounded,
                  size: 16, color: AppColors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTabs() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20),
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(10),
        border:
            Border.all(color: AppColors.border.withOpacity(0.5), width: 0.5),
      ),
      child: TabBar(
        controller: _tabController,
        indicator: BoxDecoration(
          color: AppColors.accent,
          borderRadius: BorderRadius.circular(7),
          boxShadow: [
            BoxShadow(
              color: AppColors.accent.withOpacity(0.3),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        indicatorSize: TabBarIndicatorSize.tab,
        dividerHeight: 0,
        labelColor: AppColors.onAccent,
        unselectedLabelColor: AppColors.textSecondary,
        labelStyle: const TextStyle(
            fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: -0.2),
        unselectedLabelStyle: const TextStyle(
            fontSize: 12, fontWeight: FontWeight.w500, letterSpacing: -0.2),
        tabs: const [
          Tab(
            height: 32,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.volume_up_rounded, size: 14),
                SizedBox(width: 6),
                Text('Output'),
              ],
            ),
          ),
          Tab(
            height: 32,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.mic_rounded, size: 14),
                SizedBox(width: 6),
                Text('Input'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline_rounded,
                  size: 32, color: AppColors.red.withOpacity(0.7)),
              const SizedBox(height: 12),
              Text(
                'Could not load audio devices',
                style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 13,
                    fontWeight: FontWeight.w500),
              ),
            ],
          ),
        ),
      );
    }

    if (_devices == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }

    return TabBarView(
      controller: _tabController,
      children: [
        _buildDeviceList(
          devices: _devices!.where((d) => d.isOutput).toList(),
          isOutput: true,
        ),
        _buildDeviceList(
          devices: _devices!.where((d) => d.isInput).toList(),
          isOutput: false,
        ),
      ],
    );
  }

  Widget _buildDeviceList({
    required List<AudioDevice> devices,
    required bool isOutput,
  }) {
    if (devices.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isOutput ? Icons.volume_off_rounded : Icons.mic_off_rounded,
              size: 28,
              color: AppColors.textTertiary.withOpacity(0.5),
            ),
            const SizedBox(height: 10),
            Text(
              'No ${isOutput ? "output" : "input"} devices found',
              style: TextStyle(
                color: AppColors.textTertiary,
                fontSize: 13,
              ),
            ),
          ],
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
      shrinkWrap: true,
      itemCount: devices.length,
      separatorBuilder: (_, __) => const SizedBox(height: 6),
      itemBuilder: (_, i) => _DeviceTile(
        device: devices[i],
        isSelected:
            isOutput ? devices[i].isDefaultOutput : devices[i].isDefaultInput,
        onTap: () =>
            isOutput ? _selectOutput(devices[i]) : _selectInput(devices[i]),
      ),
    );
  }
}

class _DeviceTile extends StatefulWidget {
  final AudioDevice device;
  final bool isSelected;
  final VoidCallback onTap;

  const _DeviceTile({
    required this.device,
    required this.isSelected,
    required this.onTap,
  });

  @override
  State<_DeviceTile> createState() => _DeviceTileState();
}

class _DeviceTileState extends State<_DeviceTile> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final accent = AppColors.accent;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: widget.isSelected
                ? accent.withOpacity(0.08)
                : (_hovering ? AppColors.card : Colors.transparent),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: widget.isSelected
                  ? accent.withOpacity(0.3)
                  : (_hovering
                      ? AppColors.border
                      : AppColors.border.withOpacity(0.3)),
              width: 0.5,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: widget.isSelected
                      ? accent.withOpacity(0.12)
                      : AppColors.card,
                  borderRadius: BorderRadius.circular(10),
                  border: widget.isSelected
                      ? null
                      : Border.all(
                          color: AppColors.border.withOpacity(0.5),
                          width: 0.5),
                ),
                child: Icon(
                  _iconForTransport(
                      widget.device.transportType, widget.device.type),
                  size: 18,
                  color:
                      widget.isSelected ? accent : AppColors.textSecondary,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.device.name,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: widget.isSelected
                            ? FontWeight.w600
                            : FontWeight.w500,
                        color: widget.isSelected
                            ? AppColors.textPrimary
                            : AppColors.textSecondary,
                        letterSpacing: -0.2,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (widget.device.manufacturer.isNotEmpty)
                      Text(
                        widget.device.manufacturer,
                        style: TextStyle(
                          fontSize: 11,
                          color: AppColors.textTertiary,
                          letterSpacing: -0.1,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
              if (widget.device.transportType != 'built-in')
                Container(
                  margin: const EdgeInsets.only(right: 8),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: AppColors.card,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    widget.device.transportType.toUpperCase(),
                    style: TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textTertiary,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: 20,
                height: 20,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: widget.isSelected
                      ? accent
                      : Colors.transparent,
                  border: Border.all(
                    color: widget.isSelected
                        ? accent
                        : AppColors.border,
                    width: widget.isSelected ? 0 : 1.5,
                  ),
                ),
                child: widget.isSelected
                    ? Icon(Icons.check_rounded,
                        size: 14, color: AppColors.onAccent)
                    : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
