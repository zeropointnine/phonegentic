import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../demo_mode_service.dart';
import '../phone_formatter.dart';
import '../theme_provider.dart';
import 'dialpad_contact_preview.dart';

/// Autocomplete results dropdown for the dialpad.
///
/// Renders as an absolutely-positioned panel that floats over the content
/// beneath the number display. Uses a [Stack] internally so nothing in
/// the normal layout flow is displaced.
class DialpadAutocompleteDropdown extends StatefulWidget {
  final List<Map<String, dynamic>> matches;
  final int highlightedIndex;
  final void Function(Map<String, dynamic> contact) onSelect;
  final void Function(Map<String, dynamic> contact) onCall;
  final void Function(Map<String, dynamic> contact) onMessage;
  final void Function(Map<String, dynamic> contact)? onContact;
  final VoidCallback onDismiss;

  const DialpadAutocompleteDropdown({
    super.key,
    required this.matches,
    this.highlightedIndex = -1,
    required this.onSelect,
    required this.onCall,
    required this.onMessage,
    this.onContact,
    required this.onDismiss,
  });

  @override
  State<DialpadAutocompleteDropdown> createState() =>
      _DialpadAutocompleteDropdownState();
}

class _DialpadAutocompleteDropdownState
    extends State<DialpadAutocompleteDropdown>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _fadeAnim;
  final ScrollController _scrollController = ScrollController();

  static const double _estimatedItemHeight = 52.0;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _fadeAnim = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeIn,
    );
    if (widget.matches.isNotEmpty) _controller.forward();
  }

  @override
  void didUpdateWidget(covariant DialpadAutocompleteDropdown old) {
    super.didUpdateWidget(old);
    if (widget.matches.isNotEmpty) {
      if (_controller.status == AnimationStatus.reverse ||
          !_controller.isCompleted) {
        _controller.forward();
      }
    } else if (widget.matches.isEmpty && _controller.value > 0) {
      _controller.reverse();
    }
    if (widget.highlightedIndex != old.highlightedIndex &&
        widget.highlightedIndex >= 0) {
      _scrollToHighlighted();
    }
  }

  void _scrollToHighlighted() {
    if (!_scrollController.hasClients) return;
    final targetTop = widget.highlightedIndex * _estimatedItemHeight;
    final targetBottom = targetTop + _estimatedItemHeight;
    final viewportTop = _scrollController.offset;
    final viewportBottom =
        viewportTop + _scrollController.position.viewportDimension;

    if (targetTop < viewportTop) {
      _scrollController.animateTo(
        targetTop,
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOutCubic,
      );
    } else if (targetBottom > viewportBottom) {
      _scrollController.animateTo(
        targetBottom - _scrollController.position.viewportDimension,
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOutCubic,
      );
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _fadeAnim,
      builder: (context, _) {
        final t = _fadeAnim.value;
        if (t < 0.01) return const SizedBox.shrink();

        return GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: widget.onDismiss,
          child: Container(
            decoration: BoxDecoration(
              color: AppColors.surface.withValues(alpha: 0.96),
              borderRadius: const BorderRadius.only(
                bottomLeft: Radius.circular(14),
                bottomRight: Radius.circular(14),
              ),
              border: Border(
                left: BorderSide(
                    color: AppColors.border.withValues(alpha: 0.5),
                    width: 0.5),
                right: BorderSide(
                    color: AppColors.border.withValues(alpha: 0.5),
                    width: 0.5),
                bottom: BorderSide(
                    color: AppColors.border.withValues(alpha: 0.5),
                    width: 0.5),
              ),
              boxShadow: [
                BoxShadow(
                  color: AppColors.crtBlack.withValues(alpha: 0.3 * t),
                  blurRadius: 28,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            clipBehavior: Clip.antiAlias,
            child: Opacity(
              opacity: t,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Divider(
                    height: 1,
                    thickness: 0.5,
                    color: AppColors.border.withValues(alpha: 0.4),
                  ),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 300),
                    child: ListView.builder(
                      controller: _scrollController,
                      shrinkWrap: true,
                      physics: const ClampingScrollPhysics(),
                      padding: const EdgeInsets.symmetric(
                          vertical: 6, horizontal: 4),
                      itemCount: widget.matches.length,
                      itemBuilder: (context, index) {
                        final contact = widget.matches[index];
                        return _AutocompleteRow(
                          key: ValueKey(contact['id']),
                          contact: contact,
                          index: index,
                          highlighted: index == widget.highlightedIndex,
                          onTap: () => widget.onSelect(contact),
                          onCall: () => widget.onCall(contact),
                          onMessage: () => widget.onMessage(contact),
                          onContact: widget.onContact != null
                              ? () => widget.onContact!(contact)
                              : null,
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------

class _AutocompleteRow extends StatefulWidget {
  final Map<String, dynamic> contact;
  final int index;
  final bool highlighted;
  final VoidCallback onTap;
  final VoidCallback onCall;
  final VoidCallback onMessage;
  final VoidCallback? onContact;

  const _AutocompleteRow({
    super.key,
    required this.contact,
    required this.index,
    this.highlighted = false,
    required this.onTap,
    required this.onCall,
    required this.onMessage,
    this.onContact,
  });

  @override
  State<_AutocompleteRow> createState() => _AutocompleteRowState();
}

class _AutocompleteRowState extends State<_AutocompleteRow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _rowController;
  late final Animation<double> _rowFade;
  late final Animation<Offset> _rowSlide;

  @override
  void initState() {
    super.initState();
    _rowController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _rowFade = CurvedAnimation(
      parent: _rowController,
      curve: Curves.easeOut,
    );
    _rowSlide = Tween<Offset>(
      begin: const Offset(0, 0.12),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _rowController,
      curve: Curves.easeOutCubic,
    ));

    Future.delayed(Duration(milliseconds: 30 * widget.index), () {
      if (mounted) _rowController.forward();
    });
  }

  @override
  void dispose() {
    _rowController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final demo = context.watch<DemoModeService>();
    final name = widget.contact['display_name'] as String? ?? '';
    final phone = widget.contact['phone_number'] as String? ?? '';
    final company = widget.contact['company'] as String? ?? '';
    final nameIsPhone = _looksLikePhone(name);
    final displayName = nameIsPhone ? '' : demo.maskDisplayName(name);
    final displayPhone = phone.isNotEmpty
        ? PhoneFormatter.format(demo.maskPhone(phone))
        : '';

    return FadeTransition(
      opacity: _rowFade,
      child: SlideTransition(
        position: _rowSlide,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          decoration: BoxDecoration(
            color: widget.highlighted
                ? AppColors.burntAmber.withValues(alpha: 0.12)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: InkWell(
            onTap: widget.onTap,
            borderRadius: BorderRadius.circular(10),
            hoverColor: AppColors.accent.withValues(alpha: 0.06),
            splashColor: AppColors.accent.withValues(alpha: 0.10),
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                ContactIdenticon(
                  seed: name.isEmpty ? phone : name,
                  size: 36,
                  thumbnailPath:
                      widget.contact['thumbnail_path'] as String?,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        displayName.isNotEmpty ? displayName : displayPhone,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textPrimary,
                          letterSpacing: -0.2,
                        ),
                      ),
                      if (company.isNotEmpty ||
                          (displayName.isNotEmpty &&
                              displayPhone.isNotEmpty))
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            [
                              if (displayPhone.isNotEmpty &&
                                  displayName.isNotEmpty)
                                displayPhone,
                              if (company.isNotEmpty) company,
                            ].join('  ·  '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              color: AppColors.textTertiary,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                _ActionIcon(
                  icon: Icons.phone_rounded,
                  color: AppColors.green,
                  onTap: widget.onCall,
                  tooltip: 'Call',
                ),
                const SizedBox(width: 2),
                _ActionIcon(
                  icon: Icons.chat_bubble_outline_rounded,
                  color: AppColors.accent,
                  onTap: widget.onMessage,
                  tooltip: 'Message',
                ),
                if (widget.onContact != null) ...[
                  const SizedBox(width: 2),
                  _ActionIcon(
                    icon: Icons.person_outline_rounded,
                    color: AppColors.accent,
                    onTap: widget.onContact!,
                    tooltip: 'Contact',
                  ),
                ],
              ],
            ),
          ),
        ),
        ),
      ),
    );
  }

  static bool _looksLikePhone(String s) {
    final digits = s.replaceAll(RegExp(r'[^\d]'), '');
    return digits.length >= 7 && RegExp(r'^[\d\s\+\-\(\)\.]+$').hasMatch(s);
  }
}

// ---------------------------------------------------------------------------

class _ActionIcon extends StatefulWidget {
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  final String tooltip;

  const _ActionIcon({
    required this.icon,
    required this.color,
    required this.onTap,
    required this.tooltip,
  });

  @override
  State<_ActionIcon> createState() => _ActionIconState();
}

class _ActionIconState extends State<_ActionIcon> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              color: _hovered
                  ? widget.color.withValues(alpha: 0.15)
                  : Colors.transparent,
            ),
            child: Icon(
              widget.icon,
              size: 16,
              color: widget.color.withValues(alpha: _hovered ? 1.0 : 0.65),
            ),
          ),
        ),
      ),
    );
  }
}
