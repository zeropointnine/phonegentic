import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:provider/provider.dart';
import 'package:sip_ua/sip_ua.dart';

import '../contact_service.dart';
import '../demo_mode_service.dart';
import '../messaging/phone_numbers.dart';
import '../theme_provider.dart';
import 'contact_card.dart';

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
        return Container(
          color: AppColors.bg,
          child: SafeArea(
            child: Column(
              children: [
                _buildHeader(service),
                _buildSearchBar(service),
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
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 28, 8, 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border:
            Border(bottom: BorderSide(color: AppColors.border, width: 0.5)),
      ),
      child: Row(
        children: [
          if (service.selectedContact != null)
            GestureDetector(
              onTap: () => service.selectContact(null),
              child: Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Icon(Icons.arrow_back_rounded,
                    size: 18, color: AppColors.accent),
              ),
            ),
          Icon(Icons.contacts_rounded, size: 18, color: AppColors.accent),
          const SizedBox(width: 10),
          Text(
            service.selectedContact != null ? 'Contact' : 'Contacts',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
              letterSpacing: -0.3,
            ),
          ),
          const Spacer(),
          if (service.selectedContact == null) ...[
            _ImportButton(),
            const SizedBox(width: 6),
            GestureDetector(
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
          ],
          const SizedBox(width: 8),
          GestureDetector(
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
        ],
      ),
    );
  }

  Widget _buildSearchBar(ContactService service) {
    if (service.selectedContact != null) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border:
            Border(bottom: BorderSide(color: AppColors.border, width: 0.5)),
      ),
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
              color: AppColors.border.withValues(alpha: 0.5), width: 0.5),
        ),
        child: TextField(
          controller: _searchController,
          style: TextStyle(fontSize: 13, color: AppColors.textPrimary),
          decoration: InputDecoration(
            hintText: 'Search contacts...',
            hintStyle:
                TextStyle(color: AppColors.textTertiary, fontSize: 13),
            prefixIcon: Icon(Icons.search_rounded,
                size: 18, color: AppColors.textTertiary),
            border: InputBorder.none,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          ),
          onChanged: (_) => _onSearchChanged(),
        ),
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
    return SingleChildScrollView(
      child: ContactCard(
        contact: contact,
        onFieldChanged: (field, value) {
          service.updateField(contact['id'] as int, field, value);
        },
        onDelete: () {
          service.deleteContact(contact['id'] as int);
        },
        onCall: () => _callContact(contact),
      ),
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
    final cleaned = name.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '');
    final initial =
        cleaned.isEmpty ? '?' : cleaned.substring(0, 1).toUpperCase();

    return GestureDetector(
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
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(9),
                color: AppColors.accent.withValues(alpha: 0.12),
                border: Border.all(
                    color: AppColors.accent.withValues(alpha: 0.25), width: 0.5),
              ),
              child: Center(
                child: Text(
                  initial,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppColors.accent,
                  ),
                ),
              ),
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
    );
  }
}

class _ImportButton extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final service = context.watch<ContactService>();
    return Tooltip(
      message: 'Import from macOS Contacts',
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
    );
  }

  Future<void> _handleImport(BuildContext context) async {
    final service = context.read<ContactService>();
    final count = await service.importFromMacOS();
    if (!context.mounted) return;

    if (count >= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Imported $count contacts from macOS'),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 3),
        ),
      );
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
