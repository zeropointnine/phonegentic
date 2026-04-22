# Consolidate Import/Export Into Single Panel

## Problem

The import/export UI is spread across 3 separate cards on the User tab (Full Backup, Job Functions, Inbound Workflows) plus a 4th card on the Phone tab (SIP Settings). Each has its own format toggle and export/import buttons. This is cluttered and makes it hard to do selective exports.

## Solution

Replace all individual export/import cards with a single consolidated panel on the (renamed) App Settings tab. The panel features:

- **Select All toggle** — quickly enable/disable all sections
- **Individual checkboxes** for each section: Phone Settings, Agent Settings, Agent Job Functions, Inbound Call Workflows, App Settings
- **Format toggle** (ZIP / TAR) — always archive format since multi-section
- **Export / Import buttons** — exports only the checked sections, import auto-detects

Also:
- Rename "User" tab → "App" with `Icons.widgets_rounded` icon
- Add new `appSettings` section to `SettingsSection` covering theme, calendly, demo mode, away return config
- Update display names to match the user-facing labels

## Files

- `phonegentic/lib/src/settings_port_service.dart` — add `appSettings` enum value + gather/apply
- `phonegentic/lib/src/widgets/settings_export_import_card.dart` — rewrite to consolidated panel
- `phonegentic/lib/src/widgets/user_settings_tab.dart` — swap 3 cards for 1 consolidated panel
- `phonegentic/lib/src/register.dart` — remove SIP export card from Phone tab, rename User → App tab
