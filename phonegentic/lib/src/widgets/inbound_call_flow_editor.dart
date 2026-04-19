import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../inbound_call_flow_service.dart';
import '../job_function_service.dart';
import '../models/inbound_call_flow.dart';
import '../models/job_function.dart';
import '../theme_provider.dart';

class InboundCallFlowEditor extends StatefulWidget {
  const InboundCallFlowEditor({super.key});

  @override
  State<InboundCallFlowEditor> createState() => _InboundCallFlowEditorState();
}

class _InboundCallFlowEditorState extends State<InboundCallFlowEditor> {
  final _nameController = TextEditingController();
  final _nameFocus = FocusNode();
  final _scrollController = ScrollController();

  bool _enabled = true;
  bool _saving = false;
  bool _nameValid = false;
  InboundCallFlow? _existing;

  List<_RuleEntry> _rules = [];

  @override
  void initState() {
    super.initState();
    final icfService = context.read<InboundCallFlowService>();
    _existing = icfService.editing;

    if (_existing != null) {
      _nameController.text = _existing!.name;
      _enabled = _existing!.enabled;
      _rules = _existing!.rules
          .map((r) => _RuleEntry(
                jobFunctionId: r.jobFunctionId,
                phoneController:
                    TextEditingController(text: r.phonePatterns.join(', ')),
              ))
          .toList();
    }

    if (_rules.isEmpty) {
      _rules.add(_RuleEntry(
        jobFunctionId: null,
        phoneController: TextEditingController(text: '*'),
      ));
    }

    _nameValid = _nameController.text.trim().isNotEmpty;
    _nameController.addListener(_onNameChanged);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _nameFocus.requestFocus();
    });
  }

  void _onNameChanged() {
    final valid = _nameController.text.trim().isNotEmpty;
    if (valid != _nameValid) setState(() => _nameValid = valid);
  }

  @override
  void dispose() {
    _nameController.dispose();
    _nameFocus.dispose();
    _scrollController.dispose();
    for (final r in _rules) {
      r.phoneController.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    if (name.isEmpty || _saving) return;
    setState(() => _saving = true);

    final rules = _rules
        .where((r) => r.jobFunctionId != null)
        .map((r) => InboundRule(
              jobFunctionId: r.jobFunctionId!,
              phonePatterns: r.phoneController.text
                  .split(RegExp(r'[,;\s]+'))
                  .map((s) => s.trim())
                  .where((s) => s.isNotEmpty)
                  .toList(),
            ))
        .toList();

    final flow = InboundCallFlow(
      id: _existing?.id,
      name: name,
      enabled: _enabled,
      rules: rules,
      createdAt: _existing?.createdAt,
    );

    final service = context.read<InboundCallFlowService>();
    await service.save(flow);

    if (mounted) {
      setState(() => _saving = false);
      service.closeEditor();
    }
  }

  Future<void> _delete() async {
    if (_existing?.id == null) return;
    final service = context.read<InboundCallFlowService>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Text('Delete "${_existing!.name}"?',
            style: TextStyle(fontSize: 15, color: AppColors.textPrimary)),
        content: Text('This cannot be undone.',
            style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child:
                Text('Cancel', style: TextStyle(color: AppColors.textTertiary)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('Delete', style: TextStyle(color: AppColors.red)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await service.delete(_existing!.id!);
    if (mounted) service.closeEditor();
  }

  void _addRule() {
    setState(() {
      _rules.add(_RuleEntry(
        jobFunctionId: null,
        phoneController: TextEditingController(text: '*'),
      ));
    });
  }

  void _removeRule(int index) {
    setState(() {
      _rules[index].phoneController.dispose();
      _rules.removeAt(index);
    });
  }

  void _onReorder(int oldIndex, int newIndex) {
    setState(() {
      if (newIndex > oldIndex) newIndex--;
      final item = _rules.removeAt(oldIndex);
      _rules.insert(newIndex, item);
    });
  }

  @override
  Widget build(BuildContext context) {
    final jobFunctions = context.watch<JobFunctionService>().items;

    return Center(
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: 460,
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.85,
          ),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
                color: AppColors.border.withValues(alpha: 0.5), width: 0.5),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.25),
                blurRadius: 30,
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildHeader(),
              Flexible(
                child: Scrollbar(
                  controller: _scrollController,
                  child: SingleChildScrollView(
                    controller: _scrollController,
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _buildNameField(),
                        const SizedBox(height: 16),
                        _buildEnabledToggle(),
                        const SizedBox(height: 20),
                        _buildSectionLabel('ROUTING RULES'),
                        const SizedBox(height: 8),
                        Text(
                          'Rules are evaluated top-to-bottom. First match wins.',
                          style: TextStyle(
                            fontSize: 11,
                            color: AppColors.textTertiary,
                          ),
                        ),
                        const SizedBox(height: 12),
                        _buildRulesList(jobFunctions),
                        const SizedBox(height: 8),
                        _buildAddRuleButton(),
                        const SizedBox(height: 24),
                        _buildSaveRow(),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    final isEditing = _existing != null;
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 12, 12),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.border, width: 0.5)),
      ),
      child: Row(
        children: [
          Icon(Icons.call_received_rounded, size: 18, color: AppColors.accent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              isEditing ? 'Edit Inbound Call Flow' : 'New Inbound Call Flow',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary,
              ),
            ),
          ),
          if (isEditing)
            HoverButton(
              onTap: _delete,
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: Icon(Icons.delete_outline_rounded,
                    size: 18, color: AppColors.red),
              ),
            ),
          HoverButton(
            onTap: () => context.read<InboundCallFlowService>().closeEditor(),
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Icon(Icons.close_rounded,
                  size: 18, color: AppColors.textTertiary),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNameField() {
    return TextField(
      controller: _nameController,
      focusNode: _nameFocus,
      style: TextStyle(fontSize: 13, color: AppColors.textPrimary),
      decoration: InputDecoration(
        labelText: 'Flow Name',
        labelStyle: TextStyle(fontSize: 12, color: AppColors.textTertiary),
        filled: true,
        fillColor: AppColors.card,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: AppColors.border, width: 0.5),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: AppColors.border, width: 0.5),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: AppColors.accent, width: 1),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      ),
    );
  }

  Widget _buildEnabledToggle() {
    return Row(
      children: [
        Text(
          'Enabled',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: AppColors.textPrimary,
          ),
        ),
        const Spacer(),
        SizedBox(
          height: 28,
          child: Switch(
            value: _enabled,
            activeThumbColor: AppColors.accent,
            onChanged: (v) => setState(() => _enabled = v),
          ),
        ),
      ],
    );
  }

  Widget _buildSectionLabel(String label) {
    return Text(
      label,
      style: TextStyle(
        fontSize: 10,
        fontWeight: FontWeight.w700,
        color: AppColors.textTertiary,
        letterSpacing: 0.8,
      ),
    );
  }

  Widget _buildRulesList(List<JobFunction> jobFunctions) {
    return ReorderableListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      buildDefaultDragHandles: false,
      itemCount: _rules.length,
      onReorder: _onReorder,
      proxyDecorator: (child, index, animation) {
        return AnimatedBuilder(
          animation: animation,
          builder: (ctx, child) => Material(
            color: Colors.transparent,
            elevation: 4,
            shadowColor: Colors.black26,
            borderRadius: BorderRadius.circular(10),
            child: child,
          ),
          child: child,
        );
      },
      itemBuilder: (context, index) {
        final rule = _rules[index];
        return _buildRuleCard(
          key: ValueKey(rule),
          index: index,
          rule: rule,
          jobFunctions: jobFunctions,
        );
      },
    );
  }

  Widget _buildRuleCard({
    required Key key,
    required int index,
    required _RuleEntry rule,
    required List<JobFunction> jobFunctions,
  }) {
    return Container(
      key: key,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
            color: AppColors.border.withValues(alpha: 0.5), width: 0.5),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ReorderableDragStartListener(
            index: index,
            child: Padding(
              padding: const EdgeInsets.only(top: 4, right: 6),
              child: Icon(Icons.drag_indicator_rounded,
                  size: 18, color: AppColors.textTertiary),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildJobFunctionPicker(rule, jobFunctions),
                const SizedBox(height: 8),
                TextField(
                  controller: rule.phoneController,
                  style: TextStyle(fontSize: 12, color: AppColors.textPrimary),
                  decoration: InputDecoration(
                    hintText: '* (all) or +1555..., +1666...',
                    hintStyle:
                        TextStyle(fontSize: 11, color: AppColors.textTertiary),
                    filled: true,
                    fillColor: AppColors.surface,
                    isDense: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide:
                          BorderSide(color: AppColors.border, width: 0.5),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide:
                          BorderSide(color: AppColors.border, width: 0.5),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: AppColors.accent, width: 1),
                    ),
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    prefixIcon: Padding(
                      padding: const EdgeInsets.only(left: 8, right: 4),
                      child: Icon(Icons.phone_rounded,
                          size: 14, color: AppColors.textTertiary),
                    ),
                    prefixIconConstraints:
                        const BoxConstraints(minWidth: 0, minHeight: 0),
                  ),
                ),
              ],
            ),
          ),
          if (_rules.length > 1)
            HoverButton(
              onTap: () => _removeRule(index),
              child: Padding(
                padding: const EdgeInsets.only(left: 4, top: 4),
                child: Icon(Icons.close_rounded,
                    size: 16, color: AppColors.textTertiary),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildJobFunctionPicker(
      _RuleEntry rule, List<JobFunction> jobFunctions) {
    return DropdownButtonFormField<int>(
      initialValue: rule.jobFunctionId,
      isExpanded: true,
      decoration: InputDecoration(
        filled: true,
        fillColor: AppColors.surface,
        isDense: true,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: AppColors.border, width: 0.5),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: AppColors.border, width: 0.5),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: AppColors.accent, width: 1),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      ),
      dropdownColor: AppColors.surface,
      style: TextStyle(fontSize: 12, color: AppColors.textPrimary),
      hint: Text('Select Job Function',
          style: TextStyle(fontSize: 12, color: AppColors.textTertiary)),
      items: jobFunctions
          .map((jf) => DropdownMenuItem<int>(
                value: jf.id,
                child: Text(jf.title, overflow: TextOverflow.ellipsis),
              ))
          .toList(),
      onChanged: (id) {
        setState(() => rule.jobFunctionId = id);
      },
    );
  }

  Widget _buildAddRuleButton() {
    return HoverButton(
      onTap: _addRule,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.add_rounded, size: 16, color: AppColors.accent),
            const SizedBox(width: 6),
            Text(
              'Add Rule',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AppColors.accent,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSaveRow() {
    return Row(
      children: [
        if (_existing != null)
          Expanded(
            child: _buildExistingFlows(),
          ),
        if (_existing != null) const SizedBox(width: 12),
        Expanded(
          child: HoverButton(
            onTap: _nameValid && !_saving ? _save : null,
            child: Container(
              height: 38,
              decoration: BoxDecoration(
                color: _nameValid
                    ? AppColors.accent
                    : AppColors.accent.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(10),
              ),
              alignment: Alignment.center,
              child: _saving
                  ? SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: AppColors.onAccent,
                      ),
                    )
                  : Text(
                      _existing != null ? 'Update' : 'Create',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: AppColors.onAccent,
                      ),
                    ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildExistingFlows() {
    final service = context.watch<InboundCallFlowService>();
    final flows = service.items;
    if (flows.length <= 1) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionLabel('ALL FLOWS'),
        const SizedBox(height: 6),
        ...flows.map((f) => Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: HoverButton(
                onTap: () {
                  service.closeEditor();
                  Future.microtask(() => service.openEditor(f));
                },
                child: Row(
                  children: [
                    Icon(
                      f.enabled
                          ? Icons.check_circle_rounded
                          : Icons.circle_outlined,
                      size: 12,
                      color:
                          f.enabled ? AppColors.green : AppColors.textTertiary,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        f.name,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: f.id == _existing?.id
                              ? AppColors.accent
                              : AppColors.textSecondary,
                          fontWeight: f.id == _existing?.id
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            )),
      ],
    );
  }
}

class _RuleEntry {
  int? jobFunctionId;
  final TextEditingController phoneController;

  _RuleEntry({
    required this.jobFunctionId,
    required this.phoneController,
  });
}
