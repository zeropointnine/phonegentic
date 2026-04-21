import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:provider/provider.dart';
import 'package:sip_ua/sip_ua.dart';

import '../contact_service.dart';
import '../demo_mode_service.dart';
import '../messaging/messaging_service.dart';
import '../messaging/phone_numbers.dart';
import '../theme_provider.dart';
import 'contact_card.dart';
import 'contact_merge_card.dart';
import 'dialpad_contact_preview.dart';

class ContactListPanel extends StatefulWidget {
  const ContactListPanel({super.key});

  @override
  State<ContactListPanel> createState() => _ContactListPanelState();
}

class _ContactListPanelState extends State<ContactListPanel> {
  final TextEditingController _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    final service = context.read<ContactService>();
    service.search(_searchController.text);
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ContactService>(
      builder: (context, service, _) {
        if (service.isReviewMode) {
          return Container(
            color: AppColors.bg,
            child: SafeArea(
              child: Column(
                children: [
                  _buildReviewHeader(service),
                  _buildReviewBanner(service),
                  Expanded(
                    child: service.selectedConflict != null
                        ? ContactMergeCard(conflict: service.selectedConflict!)
                        : _buildConflictList(service),
                  ),
                ],
              ),
            ),
          );
        }

        return Container(
          color: AppColors.bg,
          child: SafeArea(
            child: Column(
              children: [
                _buildHeader(service),
                Expanded(
                  child: service.selectedContact != null
                      ? _buildContactDetail(service)
                      : _buildContactList(service),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildHeader(ContactService service) {
    final isDetail = service.selectedContact != null;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 28, 8, 10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border:
            Border(bottom: BorderSide(color: AppColors.border, width: 0.5)),
      ),
      child: Row(
        children: [
          if (isDetail)
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: () => service.selectContact(null),
                child: Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Icon(Icons.arrow_back_rounded,
                      size: 18, color: AppColors.accent),
                ),
              ),
            ),
          Icon(Icons.contacts_rounded, size: 18, color: AppColors.accent),
          const SizedBox(width: 8),
          Text(
            isDetail ? 'Contact' : 'Contacts',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
              letterSpacing: -0.3,
            ),
          ),
          if (!isDetail) ...[
            const SizedBox(width: 10),
            Expanded(
              child: Container(
                height: 34,
                decoration: BoxDecoration(
                  color: AppColors.card,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                      color: AppColors.border.withValues(alpha: 0.4),
                      width: 0.5),
                ),
                child: TextField(
                  controller: _searchController,
                  style: TextStyle(fontSize: 13, color: AppColors.textPrimary),
                  decoration: InputDecoration(
                    hintText: 'Search...',
                    hintStyle:
                        TextStyle(color: AppColors.textTertiary, fontSize: 13),
                    prefixIcon: Icon(Icons.search_rounded,
                        size: 16, color: AppColors.textTertiary),
                    prefixIconConstraints:
                        const BoxConstraints(minWidth: 32, minHeight: 0),
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(vertical: 8),
                  ),
                  onChanged: (_) => _onSearchChanged(),
                ),
              ),
            ),
          ],
          if (isDetail) const Spacer(),
          const SizedBox(width: 8),
          if (!isDetail) ...[
            _ImportButton(),
            const SizedBox(width: 6),
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: service.openQuickAdd,
                child: Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    color: AppColors.accent.withValues(alpha: 0.12),
                    border: Border.all(
                        color: AppColors.accent.withValues(alpha: 0.3), width: 0.5),
                  ),
                  child: Icon(Icons.add_rounded,
                      size: 16, color: AppColors.accent),
                ),
              ),
            ),
            const SizedBox(width: 6),
          ],
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: service.closeContacts,
              child: Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  color: AppColors.card,
                  border: Border.all(
                      color: AppColors.border.withValues(alpha: 0.5), width: 0.5),
                ),
                child: Icon(Icons.close_rounded,
                    size: 16, color: AppColors.textSecondary),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContactList(ContactService service) {
    final contacts = service.contacts;

    if (contacts.isEmpty && !service.isLoading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.contacts_outlined,
                size: 36, color: AppColors.textTertiary.withValues(alpha: 0.4)),
            const SizedBox(height: 12),
            Text(
              'No contacts yet',
              style: TextStyle(
                  fontSize: 14, color: AppColors.textTertiary, height: 1.4),
            ),
            const SizedBox(height: 4),
            Text(
              'Tap + to add your first contact',
              style: TextStyle(
                  fontSize: 12,
                  color: AppColors.textTertiary.withValues(alpha: 0.7)),
            ),
          ],
        ),
      );
    }

    // Group by first letter
    final grouped = <String, List<Map<String, dynamic>>>{};
    for (final c in contacts) {
      final name = c['display_name'] as String? ?? '';
      final letter =
          name.isNotEmpty ? name[0].toUpperCase() : '#';
      final key = RegExp(r'[A-Z]').hasMatch(letter) ? letter : '#';
      grouped.putIfAbsent(key, () => []).add(c);
    }
    final sortedKeys = grouped.keys.toList()..sort();

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 6),
      itemCount: sortedKeys.length,
      itemBuilder: (context, sectionIndex) {
        final letter = sortedKeys[sectionIndex];
        final items = grouped[letter]!;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding:
                  const EdgeInsets.fromLTRB(16, 10, 16, 4),
              child: Text(
                letter,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: AppColors.accent,
                  letterSpacing: 0.5,
                ),
              ),
            ),
            ...items.map((contact) => _ContactTile(
                  contact: contact,
                  onTap: () => service.selectContact(contact),
                )),
          ],
        );
      },
    );
  }

  Widget _buildContactDetail(ContactService service) {
    final contact = service.selectedContact!;
    return LayoutBuilder(
      builder: (context, constraints) {
        final topPad = (constraints.maxHeight * 0.18).clamp(24.0, 120.0);
        return SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Container(
              color: AppColors.surface,
              child: Column(
                children: [
                  if (service.multipleMatchMessage != null)
                    _buildMultipleMatchBanner(service),
                  ContactCard(
                    contact: contact,
                    topPadding: topPad,
                    onFieldChanged: (field, value) {
                      service.updateField(contact['id'] as int, field, value);
                    },
                    onDelete: () {
                      service.deleteContact(contact['id'] as int);
                    },
                    onCall: () => _callContact(contact),
                    onMessage: () => _messageContact(contact),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildMultipleMatchBanner(ContactService service) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.burntAmber.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: AppColors.burntAmber.withValues(alpha: 0.3),
          width: 0.5,
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline_rounded,
              size: 16, color: AppColors.burntAmber),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              service.multipleMatchMessage!,
              style: TextStyle(
                fontSize: 12,
                color: AppColors.burntAmber,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Review mode widgets
  // ---------------------------------------------------------------------------

  Widget _buildReviewHeader(ContactService service) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 28, 8, 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border:
            Border(bottom: BorderSide(color: AppColors.border, width: 0.5)),
      ),
      child: Row(
        children: [
          if (service.selectedConflict != null)
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: service.deselectConflict,
                child: Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Icon(Icons.arrow_back_rounded,
                      size: 18, color: AppColors.accent),
                ),
              ),
            ),
          Icon(Icons.merge_rounded, size: 18, color: AppColors.burntAmber),
          const SizedBox(width: 10),
          Text(
            service.selectedConflict != null ? 'Resolve' : 'Review Imports',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
              letterSpacing: -0.3,
            ),
          ),
          const Spacer(),
          if (service.selectedConflict == null) ...[
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: service.exitReviewMode,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    color: AppColors.textTertiary.withValues(alpha: 0.10),
                    border: Border.all(
                        color: AppColors.border.withValues(alpha: 0.5),
                        width: 0.5),
                  ),
                  child: Text(
                    'Skip All',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 6),
          ],
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: service.closeContacts,
              child: Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  color: AppColors.card,
                  border: Border.all(
                      color: AppColors.border.withValues(alpha: 0.5),
                      width: 0.5),
                ),
                child: Icon(Icons.close_rounded,
                    size: 16, color: AppColors.textSecondary),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReviewBanner(ContactService service) {
    final newCount = service.importedNewCount;
    final updatedCount = service.importedUpdatedCount;
    final conflictsLeft = service.conflicts.length;
    final resolved = service.resolvedCount;

    final parts = <String>[];
    if (newCount > 0) parts.add('$newCount new');
    if (updatedCount > 0) parts.add('$updatedCount updated');
    if (resolved > 0) parts.add('$resolved merged');

    final summary =
        parts.isNotEmpty ? '${parts.join(', ')}. ' : '';

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: AppColors.burntAmber.withValues(alpha: 0.08),
        border:
            Border(bottom: BorderSide(color: AppColors.border, width: 0.5)),
      ),
      child: Row(
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.burntAmber.withValues(alpha: 0.15),
            ),
            child: Center(
              child: Text(
                '$conflictsLeft',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: AppColors.burntAmber,
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '$summary$conflictsLeft conflict${conflictsLeft == 1 ? '' : 's'} to review',
              style: TextStyle(
                fontSize: 12,
                color: AppColors.textSecondary,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildConflictList(ContactService service) {
    final conflicts = service.conflicts;
    if (conflicts.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check_circle_outline_rounded,
                size: 36,
                color: AppColors.green.withValues(alpha: 0.5)),
            const SizedBox(height: 12),
            Text(
              'All conflicts resolved',
              style: TextStyle(
                  fontSize: 14, color: AppColors.textTertiary, height: 1.4),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 6),
      itemCount: conflicts.length,
      itemBuilder: (context, index) {
        return _ConflictTile(
          conflict: conflicts[index],
          onTap: () => service.selectConflict(index),
        );
      },
    );
  }

  void _callContact(Map<String, dynamic> contact) async {
    final number = contact['phone_number'] as String?;
    if (number == null || number.isEmpty) return;
    try {
      final helper = Provider.of<SIPUAHelper>(context, listen: false);
      final mediaConstraints = <String, dynamic>{
        'audio': true,
        'video': false,
      };
      final stream =
          await navigator.mediaDevices.getUserMedia(mediaConstraints);
      context.read<ContactService>().closeContacts();
      helper.call(ensureE164(number), voiceOnly: true, mediaStream: stream);
    } catch (e) {
      debugPrint('[ContactListPanel] Call failed: $e');
    }
  }

  void _messageContact(Map<String, dynamic> contact) {
    final number = contact['phone_number'] as String?;
    if (number == null || number.isEmpty) return;
    final messaging = context.read<MessagingService>();
    context.read<ContactService>().closeContacts();
    if (!messaging.isOpen) messaging.toggleOpen();
    messaging.selectConversation(ensureE164(number));
  }
}

class _ContactTile extends StatelessWidget {
  final Map<String, dynamic> contact;
  final VoidCallback onTap;

  const _ContactTile({required this.contact, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final demo = context.watch<DemoModeService>();
    final rawName = contact['display_name'] as String? ?? 'Unknown';
    final rawPhone = contact['phone_number'] as String? ?? '';
    final name = demo.maskDisplayName(rawName);
    final phone = rawPhone.isNotEmpty ? demo.maskPhone(rawPhone) : '';
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
                color: AppColors.border.withValues(alpha: 0.3), width: 0.5),
          ),
          child: Row(
            children: [
              ContactIdenticon(
                seed: rawName,
                size: 34,
                thumbnailPath: contact['thumbnail_path'] as String?,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary,
                        letterSpacing: -0.2,
                      ),
                    ),
                    if (phone.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        phone,
                        style: TextStyle(
                          fontSize: 11,
                          color: AppColors.textTertiary,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded,
                  size: 18, color: AppColors.textTertiary.withValues(alpha: 0.5)),
            ],
          ),
        ),
      ),
    );
  }
}

class _ConflictTile extends StatelessWidget {
  final ImportConflict conflict;
  final VoidCallback onTap;

  const _ConflictTile({required this.conflict, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final demo = context.watch<DemoModeService>();
    final localName =
        conflict.localContact['display_name'] as String? ?? 'Unknown';
    final localPhone =
        conflict.localContact['phone_number'] as String? ?? '';
    final macName = conflict.macosDisplayName;
    final macPhone = conflict.macosPhone;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          decoration: BoxDecoration(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
                color: AppColors.burntAmber.withValues(alpha: 0.25),
                width: 0.5),
          ),
          child: Column(
            children: [
              // Local row
              Padding(
                padding:
                    const EdgeInsets.fromLTRB(12, 10, 12, 0),
                child: Row(
                  children: [
                    ContactIdenticon(
                      seed: localName,
                      size: 28,
                      thumbnailPath:
                          conflict.localContact['thumbnail_path'] as String?,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            demo.maskDisplayName(localName),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: AppColors.textPrimary,
                              letterSpacing: -0.2,
                            ),
                          ),
                          if (localPhone.isNotEmpty)
                            Text(
                              demo.maskPhone(localPhone),
                              style: TextStyle(
                                fontSize: 10,
                                color: AppColors.textTertiary,
                              ),
                            ),
                        ],
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 5, vertical: 2),
                      decoration: BoxDecoration(
                        color: AppColors.accent.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        'LOCAL',
                        style: TextStyle(
                          fontSize: 8,
                          fontWeight: FontWeight.w700,
                          color: AppColors.accent,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Divider(
                  height: 8,
                  thickness: 0.5,
                  color: AppColors.border.withValues(alpha: 0.3),
                ),
              ),
              // macOS row
              Padding(
                padding:
                    const EdgeInsets.fromLTRB(12, 0, 12, 10),
                child: Row(
                  children: [
                    ContactIdenticon(
                      seed: macName,
                      size: 28,
                      thumbnailPath: conflict.macosThumbnailPath,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            demo.maskDisplayName(macName),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: AppColors.textPrimary,
                              letterSpacing: -0.2,
                            ),
                          ),
                          if (macPhone.isNotEmpty)
                            Text(
                              demo.maskPhone(macPhone),
                              style: TextStyle(
                                fontSize: 10,
                                color: AppColors.textTertiary,
                              ),
                            ),
                        ],
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 5, vertical: 2),
                      decoration: BoxDecoration(
                        color: AppColors.green.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        'macOS',
                        style: TextStyle(
                          fontSize: 8,
                          fontWeight: FontWeight.w700,
                          color: AppColors.green,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ImportButton extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final service = context.watch<ContactService>();
    return Tooltip(
      message: 'Import from macOS Contacts',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: service.isImporting ? null : () => _handleImport(context),
          child: Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              color: AppColors.accent.withValues(alpha: 0.12),
              border: Border.all(
                  color: AppColors.accent.withValues(alpha: 0.3), width: 0.5),
            ),
            child: service.isImporting
                ? Padding(
                    padding: const EdgeInsets.all(7),
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppColors.accent,
                    ),
                  )
                : Icon(Icons.import_contacts_rounded,
                    size: 16, color: AppColors.accent),
          ),
        ),
      ),
    );
  }

  Future<void> _handleImport(BuildContext context) async {
    final service = context.read<ContactService>();
    final result = await service.importFromMacOS();
    if (!context.mounted) return;

    if (result != null) {
      if (result.conflictCount == 0) {
        final parts = <String>[];
        if (result.newCount > 0) parts.add('${result.newCount} new');
        if (result.updatedCount > 0) {
          parts.add('${result.updatedCount} updated');
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(parts.isEmpty
                ? 'Contacts are up to date'
                : 'Imported: ${parts.join(', ')}'),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 3),
          ),
        );
      }
      // When conflicts exist, the service enters review mode automatically.
    } else if (service.importError != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(service.importError!),
          behavior: SnackBarBehavior.floating,
          backgroundColor: Colors.red.shade700,
          duration: const Duration(seconds: 5),
        ),
      );
      service.clearImportError();
    }
  }
}
