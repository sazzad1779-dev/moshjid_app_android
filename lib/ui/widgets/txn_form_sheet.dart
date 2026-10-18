import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../config/app_config.dart';
import '../../data/auth/auth_service.dart';
import '../../data/local/local_db.dart';
import '../../data/models/profile.dart';
import '../../data/models/txn.dart';
import 'member_picker.dart';
import 'search_picker.dart';
import 'type_selector.dart';

/// Entry point for recording a transaction, new or edited.
///
/// Layout is driven by the type first: the selector sets whether money is
/// coming in or going out, and everything below it -- category list, whether a
/// member is needed, the colour of the save button -- follows from that. Saving
/// only ever touches the local database; [onSave] decides what happens next,
/// which is what lets the app push straight afterwards while a test can just
/// capture the row.
class AddTxnSheet extends StatefulWidget {
  final Future<void> Function(Txn) onSave;
  final Txn? existing;

  /// Injected by tests; the app leaves this null and gets [LocalDb.instance].
  final LocalDb? local;

  /// Opens the form already set up for this member, so recording their next
  /// Imam Hadiya payment is only an amount. Ignored when [existing] is set,
  /// because an edit has to show the row as it stands.
  final Profile? initialMember;
  final String? initialType;
  final String? initialCategory;

  const AddTxnSheet({
    super.key,
    required this.onSave,
    this.existing,
    this.local,
    this.initialMember,
    this.initialType,
    this.initialCategory,
  });

  @override
  State<AddTxnSheet> createState() => _AddTxnSheetState();
}

class _AddTxnSheetState extends State<AddTxnSheet> {
  final _form = GlobalKey<FormState>();
  final _amount = TextEditingController();
  final _desc = TextEditingController();
  final _receipt = TextEditingController();

  String _type = 'income';
  String _category = AppConfig.seedCategories['income']!.first;
  String _method = 'cash';
  DateTime _date = DateTime.now();
  bool _saving = false;
  bool _showMore = false;
  List<PickerOption> _cats = _categoryOptions('income');

  /// The member this transaction belongs to, when the category takes one.
  Profile? _donor;

  /// Free-text donor name, used only when no [Profile] is linked.
  ///
  /// The two are mutually exclusive by design: a transaction records either a
  /// link to a member in the roster, or a name typed on the spot. Carrying both
  /// would mean the typed text and the linked record could disagree about who
  /// the payment belongs to.
  final _memberText = TextEditingController();

  /// What has been typed into the category box. [SearchPickerField] does not
  /// filter on its own -- the caller supplies the narrowed list -- so this is
  /// what makes typing in the category box do anything.
  String _catQuery = '';

  bool get _isEditing => widget.existing != null;

  LocalDb get _local => widget.local ?? LocalDb.instance;

  static List<PickerOption> _categoryOptions(String type) =>
      (AppConfig.seedCategories[type] ?? const <String>[])
          .map((n) => PickerOption(value: n, label: n))
          .toList();

  /// Whether the member field is offered.
  ///
  /// Every *income* category gets it, not just the ones in
  /// [AppConfig.donorCategories]. That set still exists for a narrower job:
  /// naming the category the Members tab uses for "Record a payment". Filtering
  /// the form by it would leave a collector unable to say who paid a donation
  /// outside Imam Hadiya, which is the case that most needs recording.
  ///
  /// Income only. Money coming in is attributed to whoever handed it over;
  /// money going out is supplies, rent, the imam's payout -- there is nobody on
  /// the other end to name.
  ///
  /// Nothing here forces a member: choosing from the roster, typing a name and
  /// leaving it empty are all valid answers.
  bool get _categoryTakesDonor => _type == 'income';

  /// [SearchPickerField] shows whatever it is handed, so the category list is
  /// narrowed here rather than in the widget. Substring match, case and
  /// whitespace insensitive.
  List<PickerOption> get _visibleCats {
    final q = _catQuery.trim().toLowerCase();
    if (q.isEmpty) return _cats;
    return _cats
        .where((o) => o.label.toLowerCase().replaceAll(RegExp(r'\s+'), ' ')
            .contains(q.replaceAll(RegExp(r'\s+'), ' ')))
        .toList();
  }

  @override
  void initState() {
    super.initState();
    final ex = widget.existing;
    if (ex != null) {
      _type = ex.type;
      _category = ex.category;
      _method = ex.paymentMethod;
      _date = ex.date;
      _amount.text = ex.amount.toString();
      _desc.text = ex.description ?? '';
      _receipt.text = ex.receiptNumber ?? '';
      _cats = _categoryOptions(_type);
      if (!_cats.any((o) => o.value == _category)) {
        _cats.add(PickerOption(value: _category, label: _category));
      }
      _showMore = (ex.description ?? '').isNotEmpty ||
          (ex.receiptNumber ?? '').isNotEmpty;
    } else if (widget.initialType != null || widget.initialCategory != null) {
      _type = widget.initialType ?? _type;
      _cats = _categoryOptions(_type);
      _category = widget.initialCategory ??
          (_cats.isEmpty ? _category : _cats.first.value);
      _cats = [
        if (!_cats.any((o) => o.value == _category))
          PickerOption(value: _category, label: _category),
        ..._cats,
      ];
      if (widget.initialMember != null) _donor = widget.initialMember;
      if (_donor != null) _memberText.text = _donor!.displayName;
    }
    _loadCats();
    _loadDonor();
  }

  @override
  void dispose() {
    _amount.dispose();
    _desc.dispose();
    _receipt.dispose();
    _memberText.dispose();
    super.dispose();
  }

  Future<void> _loadCats() async {
    // Prefer cached Supabase categories; fall back to seed.
    try {
      final cached = await _local.cachedCategories(_type);
      if (cached.isNotEmpty && mounted) {
        setState(() {
          _cats = cached
              .map((e) => PickerOption(value: e['name'] as String, label: e['name'] as String))
              .toList();
          // Never drop the row's own category (e.g. renamed remotely).
          if (!_cats.any((o) => o.value == _category)) {
            _cats.add(PickerOption(value: _category, label: _category));
          }
        });
      }
    } catch (_) {}
  }

  /// Restores the member on an existing transaction. Editing one whose member was
  /// pulled off this device leaves the field empty rather than guessing.
  Future<void> _loadDonor() async {
    final memberId = widget.existing?.memberId;
    if (memberId == null) return;
    try {
      final profile = await _local.findProfileById(memberId);
      if (profile != null && mounted) setState(() => _donor = profile);
    } catch (_) {}
  }

  void _onType(String type) {
    if (type == _type) return;
    setState(() {
      _type = type;
      _cats = _categoryOptions(type);
      _category = _cats.isEmpty ? _category : _cats.first.value;
      _catQuery = '';
      // Switching to a type with no member field must not carry a member the
      // collector can no longer see or change. Changing category is different:
      // the field stays put across income categories, so the member stays too.
      if (!_categoryTakesDonor) _clearMember();
    });
    _loadCats();
  }

  void _onCategory(PickerOption option) {
    setState(() {
      _category = option.value;
      _catQuery = '';
    });
  }

  /// Opens the roster. A pick replaces the current member; the add button inside
  /// writes the new person to the local database and selects them straight away,
  /// which is the collection flow: type the name once, it is a member from then
  /// on, on this device and in the cloud after the next sync.
  Future<void> _pickMember() async {
    final picked = await showMemberPicker(context, local: _local, initial: _donor);
    if (picked == null || !mounted) return;
    // Picking takes over the field; whatever free text was there is replaced so
    // the transaction can never name one person and link another.
    setState(() {
      _donor = picked;
      _memberText.text = picked.displayName;
    });
  }

  /// Typing switches the field into free-text mode.
  ///
  /// Editing the text of a linked member is how the user says "this is not that
  /// person any more", so the link is dropped rather than left contradicting the
  /// text sitting in the box.
  void _onMemberTyped(String value) {
    if (_donor != null) setState(() => _donor = null);
  }

  void _clearMember() {
    setState(() {
      _donor = null;
      _memberText.clear();
    });
  }

  /// The name recorded on the transaction: the linked member, or the typed text.
  String? get _donorName {
    if (_donor != null) return _donor!.displayName;
    final t = _memberText.text.trim();
    return t.isEmpty ? null : t;
  }

  bool get _hasMember => _donor != null || _memberText.text.trim().isNotEmpty;

  Future<void> _save() async {
    if (!(_form.currentState?.validate() ?? false)) return;

    // Income with nobody attached to it is usually a slip, and the amount is then
    // unattributable on the server. Ask rather than silently saving.
    if (_categoryTakesDonor && !_hasMember) {
      final proceed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('No member'),
          content: const Text(
              'Income is normally recorded against a member. Choose one, or '
              'type a name, or save without either?'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Go back')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Save anyway')),
          ],
        ),
      );
      if (proceed != true || !mounted) return;
    }

    setState(() => _saving = true);
    String enteredBy;
    try {
      enteredBy = await AuthService().resolveEnteredById();
    } catch (_) {
      enteredBy = AppConfig.enteredById;
    }
    final amount = double.parse(_amount.text.trim());
    final ex = widget.existing;

    // Resolve the category uuid now rather than at sync time, so an offline or
    // failed sync still leaves the row pointing at a real category. The lookup
    // is keyed on (name, type) because names like "Other" and "Imam Hadiya"
    // exist under both types.
    String? categoryId = ex?.categoryId;
    try {
      categoryId = await _local.resolveCategoryId(_category, _type) ?? categoryId;
    } catch (_) {}

    final t = ex == null
        ? Txn.create(
            type: _type,
            category: _category,
            categoryId: categoryId,
            amount: amount,
            paymentMethod: _method,
            enteredBy: enteredBy,
            status: AppConfig.defaultStatus,
            description: _desc.text,
            receiptNumber: _receipt.text.trim().isEmpty
                ? null
                : _receipt.text.trim(),
            date: _date,
            memberId: _donor?.id,
            donorName: _donorName,
            donorPhone: _donor?.phone,
          )
        : ex.applyEdit(
            type: _type,
            category: _category,
            categoryId: categoryId,
            amount: amount,
            paymentMethod: _method,
            status: ex.status,
            description: _desc.text,
            receiptNumber: _receipt.text.trim(),
            date: _date,
            enteredBy: enteredBy,
            memberId: _donor?.id,
            donorName: _donorName,
            donorPhone: _donor?.phone,
          );
    await widget.onSave(t);
    if (!mounted) return;
    setState(() => _saving = false);
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = TxnTypeStyle.of(_type);

    return Padding(
      padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 12,
          bottom: MediaQuery.of(context).viewInsets.bottom + 16),
      child: Form(
        key: _form,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _SheetHeader(editing: _isEditing),
              const SizedBox(height: 16),
              const _FieldLabel('Type'),
              const SizedBox(height: 6),
              TypeSelector(selected: _type, onChanged: _onType),
              const SizedBox(height: 16),
              const _FieldLabel('Category'),
              SearchPickerField(
                label: 'Category',
                options: _visibleCats,
                value: _category,
                validator: (v) =>
                    (v == null || v.isEmpty) ? 'Category required' : null,
                onQueryChanged: (q) => setState(() => _catQuery = q),
                onSelected: _onCategory,
              ),
              if (_categoryTakesDonor) ...[
                const SizedBox(height: 16),
                const _FieldLabel('Member'),
                _MemberField(
                  member: _donor,
                  controller: _memberText,
                  onChanged: _onMemberTyped,
                  onTap: _pickMember,
                  onClear: _clearMember,
                ),
              ],
              const SizedBox(height: 16),
              const _FieldLabel('Amount'),
              TextFormField(
                controller: _amount,
                autofocus: !_isEditing,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                ],
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w700,
                  color: style.color,
                ),
                decoration: const InputDecoration(
                  hintText: '0',
                  prefixText: '৳ ',
                  prefixStyle: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
                  border: OutlineInputBorder(),
                ),
                validator: Txn.validateAmount,
              ),
              const SizedBox(height: 16),
              const _FieldLabel('Payment method'),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final m in AppConfig.paymentMethods)
                    ChoiceChip(
                      label: Text(_methodLabel(m)),
                      selected: _method == m,
                      onSelected: (_) => setState(() => _method = m),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              _DateRow(
                date: _date,
                onPick: () async {
                  final d = await showDatePicker(
                    context: context,
                    firstDate: DateTime(2020),
                    lastDate: DateTime.now().add(const Duration(days: 1)),
                    initialDate: _date,
                  );
                  if (d != null) setState(() => _date = d);
                },
              ),
              const SizedBox(height: 4),
              if (_showMore || _desc.text.isNotEmpty || _receipt.text.isNotEmpty)
                _MoreDetails(
                  description: _desc,
                  receipt: _receipt,
                  receiptFromServer: widget.existing?.receiptNumber,
                ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => setState(() => _showMore = !_showMore),
                  icon: Icon(_showMore ? Icons.expand_less : Icons.more_horiz),
                  label: Text(_showMore ? 'Hide details' : 'Add note or receipt'),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: style.color,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  onPressed: _saving ? null : _save,
                  icon: _saving
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : Icon(style.icon),
                  label: Text(
                    _saving
                        ? 'Saving…'
                        : (_isEditing
                            ? 'Save changes'
                            : 'Save ${style.label.toLowerCase()}'),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Center(
                child: Text(
                  'Saved on this device first — syncs to the cloud when online.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// `cash` -> `Cash`. The stored value stays lowercase for the server; only the
  /// label on screen is capitalised.
  static String _methodLabel(String m) =>
      m.isEmpty ? m : m[0].toUpperCase() + m.substring(1);
}

class _SheetHeader extends StatelessWidget {
  final bool editing;
  const _SheetHeader({required this.editing});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(
          child: Text(
            editing ? 'Edit transaction' : 'New transaction',
            style: theme.textTheme.titleLarge
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
        ),
        IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.pop(context),
        ),
      ],
    );
  }
}

class _FieldLabel extends StatelessWidget {
  final String text;
  const _FieldLabel(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(
          text,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
      );
}

/// The member slot: a tappable row that opens the roster, or the member that is
/// already chosen.
///
/// Deliberately not a search box here. The full list lives one screen away and
/// searching happens there, which keeps this sheet short on a phone and gives
/// the roster somewhere to actually be visible -- which is what was missing
/// before: the member existed only as a dropdown nobody could browse.
class _MemberField extends StatelessWidget {
  final Profile? member;
  final TextEditingController? controller;
  final ValueChanged<String>? onChanged;
  final VoidCallback onTap;
  final VoidCallback onClear;

  const _MemberField({
    required this.member,
    required this.onTap,
    required this.onClear,
    this.controller,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final m = member;
    final typed = controller?.text.trim() ?? '';

    // Linked and free-text are mutually exclusive, so there are only two states
    // to draw. A picked member shows their record; anything else is free text,
    // which is recorded on the transaction and creates no profile.
    final subtitle = m != null
        ? (m.isPending
            ? 'New on this device — syncs later'
            : (m.phone ?? 'Member'))
        : (typed.isEmpty ? 'Choose a member or type a name' : 'Name only — not saved as a member');

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (m != null) ...[
          CircleAvatar(
            radius: 18,
            backgroundColor: m.isPending
                ? theme.colorScheme.tertiaryContainer
                : theme.colorScheme.primaryContainer,
            child: Text(initialsOf(m.displayName),
                style: const TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w600)),
          ),
          const SizedBox(width: 10),
        ],
        Expanded(
          child: TextFormField(
            controller: controller,
            onChanged: onChanged,
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(
              hintText: 'Choose a member or type a name',
              helperText: subtitle,
              helperMaxLines: 2,
              helperStyle: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              suffixIcon: m != null
                  ? IconButton(
                      tooltip: 'Clear member',
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: onClear,
                    )
                  : null,
              border: const OutlineInputBorder(),
            ),
          ),
        ),
        const SizedBox(width: 4),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: IconButton(
            tooltip: 'Choose from members',
            icon: const Icon(Icons.person_search),
            onPressed: onTap,
          ),
        ),
      ],
    );
  }
}

class _DateRow extends StatelessWidget {
  final DateTime date;
  final VoidCallback onPick;

  const _DateRow({required this.date, required this.onPick});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onPick,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            Icon(Icons.calendar_today_outlined,
                size: 18, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 10),
            Text(DateFormat('EEEE, d MMMM yyyy').format(date),
                style: const TextStyle(fontWeight: FontWeight.w600)),
            const Spacer(),
            Text('Change',
                style: TextStyle(color: theme.colorScheme.primary, fontSize: 13)),
          ],
        ),
      ),
    );
  }
}

/// Note and receipt, hidden behind a disclosure because most entries do not need
/// either.
class _MoreDetails extends StatelessWidget {
  final TextEditingController description;
  final TextEditingController receipt;
  final String? receiptFromServer;

  const _MoreDetails({
    required this.description,
    required this.receipt,
    this.receiptFromServer,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TextFormField(
          controller: description,
          decoration: const InputDecoration(
              labelText: 'Note (optional)', border: OutlineInputBorder()),
          maxLines: 2,
        ),
        const SizedBox(height: 10),
        TextFormField(
          controller: receipt,
          decoration: InputDecoration(
            labelText: 'Receipt no (optional, auto if empty)',
            border: const OutlineInputBorder(),
            helperText: receiptFromServer == null
                ? null
                : 'Currently $receiptFromServer',
          ),
        ),
      ],
    );
  }
}