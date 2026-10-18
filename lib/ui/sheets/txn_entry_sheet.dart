import 'package:flutter/material.dart';

import '../../config/app_config.dart';
import '../../data/auth/auth_service.dart';
import '../../data/models/txn.dart';
import '../../data/repositories/txn_repository.dart';
import '../app_scope.dart';
import '../format.dart';

/// Opens the transaction editor. Returns the saved [Txn] (or null when the
/// user backs out) so callers can offer "repeat last entry".
Future<Txn?> showTxnEntrySheet(BuildContext context, {Txn? existing}) {
  return showModalBottomSheet<Txn>(
    context: context,
    isScrollControlled: true,
    builder: (_) => TxnEntrySheet(existing: existing),
  );
}

/// Create/edit form. Saves to the local store first and never blocks on the
/// network, so it stays usable with no connectivity.
class TxnEntrySheet extends StatefulWidget {
  final Txn? existing;
  const TxnEntrySheet({super.key, this.existing});

  @override
  State<TxnEntrySheet> createState() => _TxnEntrySheetState();
}

class _TxnEntrySheetState extends State<TxnEntrySheet> {
  final _form = GlobalKey<FormState>();
  final _amount = TextEditingController();
  final _desc = TextEditingController();
  final _receipt = TextEditingController();

  String _type = AppConfig.txnTypes.first;
  String _category = AppCategories.namesFor(AppConfig.txnTypes.first).first;
  String _method = AppConfig.paymentMethods.first;
  DateTime _date = DateTime.now();
  bool _saving = false;
  List<String> _cats = AppCategories.namesFor(AppConfig.txnTypes.first);

  bool get _isEditing => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final ex = widget.existing;
    if (ex != null) {
      _type = ex.type;
      _category = ex.category;
      _method = ex.paymentMethod;
      _date = ex.date;
      _amount.text = ex.amount.toStringAsFixed(ex.amount % 1 == 0 ? 0 : 2);
      _desc.text = ex.description ?? '';
      _receipt.text = ex.receiptNumber ?? '';
      _cats = AppCategories.namesFor(_type);
      if (!_cats.contains(_category)) _cats = [_category, ..._cats];
    }
    _loadCats();
  }

  @override
  void dispose() {
    _amount.dispose();
    _desc.dispose();
    _receipt.dispose();
    super.dispose();
  }

  Future<void> _loadCats() async {
    // Prefer the categories cached from `transaction_categories`; fall back
    // to the built-in list when offline.
    try {
      final names = await AppScope.read(context).categoryNames(_type);
      if (names.isNotEmpty && mounted) {
        setState(() {
          _cats = [if (!_cats.contains(_category)) _category, ...names];
        });
      }
    } catch (_) {
      // offline — keep seeds
    }
  }

  void _onType(String? v) {
    if (v == null || v == _type) return;
    setState(() {
      _type = v;
      _cats = AppCategories.namesFor(v);
      _category = _cats.first;
    });
    _loadCats();
  }

  Future<void> _save() async {
    if (!(_form.currentState?.validate() ?? false)) return;
    setState(() => _saving = true);
    final repo = AppScope.of(context);
    final enteredBy = await _resolveEnteredBy();
    final amount = Txn.parseAmount(_amount.text) ?? 0;
    final ex = widget.existing;
    final t = ex == null
        ? Txn.create(
            type: _type,
            category: _category,
            amount: amount,
            paymentMethod: _method,
            enteredBy: enteredBy,
            status: AppConfig.defaultStatus,
            description: _desc.text,
            receiptNumber: _receipt.text.trim().isEmpty
                ? null
                : _receipt.text.trim(),
            date: _date,
          )
        : ex.applyEdit(
            type: _type,
            category: _category,
            amount: amount,
            paymentMethod: _method,
            status: ex.status,
            description: _desc.text,
            receiptNumber: _receipt.text,
            date: _date,
            enteredBy: enteredBy,
          );

    try {
      await repo.save(t);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not save: $e')));
      return;
    }
    if (!mounted) return;
    Navigator.pop(context, t);
  }

  Future<String> _resolveEnteredBy() async {
    try {
      return await AuthService().resolveEnteredById();
    } catch (_) {
      return AppConfig.enteredById;
    }
  }

  Future<void> _pickDate() async {
    final d = await showDatePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 1)),
      initialDate: _date,
    );
    if (d != null && mounted) setState(() => _date = d);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: Form(
        key: _form,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                _isEditing ? 'Edit transaction' : 'New transaction',
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _type,
                decoration: const InputDecoration(
                  labelText: 'Type',
                  border: OutlineInputBorder(),
                ),
                items: AppConfig.txnTypes
                    .map((e) => DropdownMenuItem(value: e, child: Text(e)))
                    .toList(),
                onChanged: _onType,
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                initialValue: _category,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Category',
                  border: OutlineInputBorder(),
                ),
                items: _cats
                    .map((e) => DropdownMenuItem(value: e, child: Text(e)))
                    .toList(),
                onChanged: (v) => setState(() => _category = v ?? _category),
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: _amount,
                autofocus: !_isEditing,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: 'Amount',
                  border: OutlineInputBorder(),
                ),
                validator: Txn.validateAmount,
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                initialValue: _method,
                decoration: const InputDecoration(
                  labelText: 'Payment method',
                  border: OutlineInputBorder(),
                ),
                items: AppConfig.paymentMethods
                    .map((e) => DropdownMenuItem(value: e, child: Text(e)))
                    .toList(),
                onChanged: (v) => setState(() => _method = v ?? _method),
              ),
              const SizedBox(height: 8),
              InkWell(
                onTap: _pickDate,
                child: InputDecorator(
                  decoration: const InputDecoration(
                    labelText: 'Date',
                    border: OutlineInputBorder(),
                  ),
                  child: Text(Fmt.date(_date)),
                ),
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: _desc,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: 'Description (optional)',
                  border: OutlineInputBorder(),
                ),
                maxLines: 2,
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: _receipt,
                decoration: const InputDecoration(
                  labelText: 'Receipt no (optional, auto if empty)',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: _saving ? null : _save,
                child: Text(
                  _saving
                      ? 'Saving...'
                      : (_isEditing ? 'Save changes' : 'Save offline'),
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'Saves locally first, syncs when online.',
                style: TextStyle(fontSize: 12, color: Colors.grey),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
