import 'package:flutter/material.dart';

/// Visual identity for a transaction type.
///
/// Labels and icons live here rather than in the widgets that render them, so
/// the transaction list, the form and the member sheet cannot drift apart.
class TxnTypeStyle {
  final String label;
  final IconData icon;
  final Color color;

  const TxnTypeStyle(this.label, this.icon, this.color);

  static const _income = TxnTypeStyle('Income', Icons.south_west, Color(0xFF1B8E4B));
  static const _expense = TxnTypeStyle('Expense', Icons.north_east, Color(0xFFC0392B));
  static const _other = TxnTypeStyle('Other', Icons.swap_horiz, Color(0xFF5B6770));

  static const _byType = <String, TxnTypeStyle>{
    'income': _income,
    'expense': _expense,
    'other': _other,
  };

  static TxnTypeStyle of(String type) => _byType[type] ?? _other;
}

/// Large three-way switch for income / expense / other.
///
/// This replaces a `DropdownButtonFormField`, which kept showing the type the
/// form was opened with: `initialValue` is only read once, so changing the type
/// updated the state behind the field without the field itself moving. Here the
/// button reads [_selected] directly, so what is highlighted is always what
/// will be saved.
class TypeSelector extends StatelessWidget {
  final String selected;
  final ValueChanged<String> onChanged;

  /// Which types to offer, in order. Kept in step with `AppConfig.txnTypes`;
  /// a test asserts the two agree.
  final List<String> types;

  const TypeSelector({
    super.key,
    required this.selected,
    required this.onChanged,
    this.types = defaultTypes,
  });

  static const defaultTypes = ['income', 'expense', 'other'];

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (final t in types)
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(right: t == types.last ? 0 : 8),
              child: _TypeButton(
                type: t,
                selected: t == selected,
                onTap: () => onChanged(t),
              ),
            ),
          ),
      ],
    );
  }
}

class _TypeButton extends StatelessWidget {
  final String type;
  final bool selected;
  final VoidCallback onTap;

  const _TypeButton({
    required this.type,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final style = TxnTypeStyle.of(type);
    final bg = selected ? style.color.withValues(alpha: 0.12) : Colors.transparent;
    final fg = selected ? style.color : Colors.grey.shade700;

    return Semantics(
      button: true,
      selected: selected,
      label: style.label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected ? style.color : Colors.grey.shade300,
              width: selected ? 1.6 : 1,
            ),
          ),
          child: Column(
            children: [
              Icon(style.icon, color: fg, size: 20),
              const SizedBox(height: 4),
              Text(
                style.label,
                style: TextStyle(
                  color: fg,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}