import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// One choice in a [SearchPickerField].
class PickerOption {
  final String value;
  final String label;
  final String? subtitle;

  /// Rendered at the end of the row, e.g. a "monthly" badge.
  final Widget? trailing;

  /// Drawn in the accent colour with a leading +, and reads as an action
  /// rather than an existing choice. Only meaningful when the field was given
  /// an [SearchPickerField.addLabelBuilder].
  final bool isAction;

  const PickerOption({
    required this.value,
    required this.label,
    this.subtitle,
    this.trailing,
    this.isAction = false,
  });

  static const newValue = '';

  /// The row a user taps to create [label] rather than pick something existing.
  factory PickerOption.action(String label) =>
      PickerOption(value: newValue, label: label, isAction: true);
}

/// A text field with a filtered list of suggestions beneath it.
///
/// Replaces `DropdownButtonFormField` for anything longer than about five
/// entries. The list is inline rather than an overlay so it scrolls with the
/// form instead of being clipped by the bottom sheet, and it is capped in
/// height so it never takes over the screen.
///
/// Filtering is the caller's job: pass [options] already narrowed, and react to
/// [onQueryChanged]. That lets the donor picker search the local database
/// asynchronously while the category picker filters a list it already holds.
class SearchPickerField extends StatefulWidget {
  final String label;
  final String? hint;

  /// Currently selected value, or null when nothing is chosen yet.
  final String? value;

  /// Already-filtered options for the current [onQueryChanged] value.
  final List<PickerOption> options;

  /// Called when a row is tapped, or when the user submits a query that exactly
  /// matches an option.
  final ValueChanged<PickerOption> onSelected;

  final ValueChanged<String>? onQueryChanged;

  /// Return an error string to reject [value]; null accepts it.
  final String? Function(String? value)? validator;

  /// Builds the "create this" row. Return null to hide it -- for a category
  /// list, a typo should be an error, not a new category.
  final String? Function(String query)? addLabelBuilder;

  final TextInputType keyboardType;
  final List<TextInputFormatter>? inputFormatters;
  final bool enabled;
  final String? helperText;

  /// Rows visible before the list starts scrolling.
  final int maxVisibleRows;

  const SearchPickerField({
    super.key,
    required this.label,
    required this.options,
    required this.onSelected,
    this.hint,
    this.value,
    this.onQueryChanged,
    this.validator,
    this.addLabelBuilder,
    this.keyboardType = TextInputType.text,
    this.inputFormatters,
    this.enabled = true,
    this.helperText,
    this.maxVisibleRows = 6,
  });

  @override
  State<SearchPickerField> createState() => _SearchPickerFieldState();
}

class _SearchPickerFieldState extends State<SearchPickerField> {
  final _controller = TextEditingController();
  final _focus = FocusNode();

  /// What the user has actually typed, which is not the same as the selected
  /// label once they start editing.
  String _query = '';

  bool _open = false;

  /// Stops the dropdown from closing the instant a row is tapped, which on
  /// Android would otherwise beat the setState that opens the new-donor dialog.
  bool _selecting = false;

  @override
  void initState() {
    super.initState();
    _controller.text = widget.value ?? '';
    _focus.addListener(() {
      if (_focus.hasFocus && !_open) setState(() => _open = true);
      if (!_focus.hasFocus && !_selecting) setState(() => _open = false);
    });
  }

  @override
  void didUpdateWidget(SearchPickerField old) {
    super.didUpdateWidget(old);
    // Keep the text in step when the selection is changed from elsewhere, e.g.
    // switching category resets it. Do not fight the user while they type.
    if (widget.value != old.value && widget.value != _controller.text) {
      _controller.text = widget.value ?? '';
      if (_query != (widget.value ?? '')) _query = widget.value ?? '';
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onChanged(String text) {
    setState(() {
      _query = text;
      _open = true;
    });
    widget.onQueryChanged?.call(text);
  }

  void _pick(PickerOption option) {
    setState(() {
      _selecting = true;
      _open = false;
      _query = option.label;
      _controller
        ..text = option.label
        ..selection = TextSelection.collapsed(offset: option.label.length);
    });
    // Let the focus listener settle before allowing another tap.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _selecting = false);
    });
    widget.onQueryChanged?.call(option.label);
    widget.onSelected(option);
    if (!option.isAction) _focus.unfocus();
  }

  List<PickerOption> get _visibleOptions {
    final label = widget.addLabelBuilder?.call(_query);
    if (label == null) return widget.options;
    return [
      ...widget.options,
      PickerOption.action(label),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final error = widget.validator?.call(widget.value);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _controller,
          focusNode: _focus,
          enabled: widget.enabled,
          keyboardType: widget.keyboardType,
          inputFormatters: widget.inputFormatters,
          onChanged: _onChanged,
          onSubmitted: (_) {
            // Submitting picks the exact match, if there is one. Silently
            // choosing a prefix match would save the wrong donor.
            for (final o in widget.options) {
              if (!o.isAction && o.label.toLowerCase() == _query.toLowerCase()) {
                _pick(o);
                return;
              }
            }
          },
          decoration: InputDecoration(
            labelText: widget.label,
            hintText: widget.hint,
            helperText: error ?? widget.helperText,
            errorText: error,
            border: const OutlineInputBorder(),
            suffixIcon: _controller.text.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Clear',
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () {
                      _controller.clear();
                      _onChanged('');
                    },
                  ),
          ),
        ),
        if (_open && widget.enabled) ...[
          const SizedBox(height: 4),
          _OptionsList(
            options: _visibleOptions,
            query: _query,
            accent: theme.colorScheme.primary,
            border: theme.colorScheme.outlineVariant,
            maxHeight: widget.maxVisibleRows * 48.0,
            onPick: _pick,
          ),
        ],
      ],
    );
  }
}

class _OptionsList extends StatelessWidget {
  final List<PickerOption> options;
  final String query;
  final Color accent;
  final Color border;
  final double maxHeight;
  final ValueChanged<PickerOption> onPick;

  const _OptionsList({
    required this.options,
    required this.query,
    required this.accent,
    required this.border,
    required this.maxHeight,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final rows = <Widget>[
      if (options.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
          child: Text(
            query.trim().isEmpty
                ? 'Nothing available yet'
                : 'No match for "$query"',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        )
      else
        ...options.map(
          (o) => ListTile(
            dense: true,
            visualDensity: VisualDensity.compact,
            leading: o.isAction ? Icon(Icons.add, size: 20, color: accent) : null,
            title: Text(
              o.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: o.isAction
                  ? theme.textTheme.bodyMedium?.copyWith(color: accent)
                  : null,
            ),
            subtitle: o.subtitle == null
                ? null
                : Text(o.subtitle!, maxLines: 1, overflow: TextOverflow.ellipsis),
            trailing: o.trailing,
            onTap: () => onPick(o),
          ),
        ),
    ];

    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: Material(
        color: theme.colorScheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: border),
        ),
        clipBehavior: Clip.antiAlias,
        child: Scrollbar(
          child: ListView(
            padding: EdgeInsets.zero,
            shrinkWrap: true,
            children: rows,
          ),
        ),
      ),
    );
  }
}