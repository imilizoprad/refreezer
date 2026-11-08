import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../translations.i18n.dart';
import 'tokens.dart';

/// Editorial section label: uppercase micro type with a hairline rule.
class RfSectionHeader extends StatelessWidget {
  final String title;
  final Widget? trailing;
  final EdgeInsetsGeometry padding;

  const RfSectionHeader(
    this.title, {
    super.key,
    this.trailing,
    this.padding = const EdgeInsets.fromLTRB(
        RfTokens.gutter, RfTokens.s5, RfTokens.gutter, RfTokens.s2),
  });

  @override
  Widget build(BuildContext context) {
    final RfTokens tokens = RfTokens.of(context);
    return Padding(
      padding: padding,
      child: Row(
        children: [
          Text(title.toUpperCase(), style: tokens.overline),
          const SizedBox(width: RfTokens.s3),
          Expanded(child: Container(height: 1, color: tokens.hairline)),
          if (trailing != null) ...[
            const SizedBox(width: RfTokens.s3),
            trailing!,
          ],
        ],
      ),
    );
  }
}

class RfHairline extends StatelessWidget {
  final double indent;
  const RfHairline({super.key, this.indent = 0});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 1,
      margin: EdgeInsets.only(left: indent),
      color: RfTokens.of(context).hairline,
    );
  }
}

/// Square-ish artwork with a hairline edge, a quiet fallback and no bounce.
class RfArtwork extends StatelessWidget {
  final String? url;
  final double size;
  final double radius;

  const RfArtwork({
    super.key,
    required this.url,
    this.size = RfTokens.artworkMd,
    this.radius = RfTokens.rSm,
  });

  @override
  Widget build(BuildContext context) {
    final RfTokens tokens = RfTokens.of(context);
    final Widget fallback = Container(
      width: size,
      height: size,
      color: tokens.surfaceHigh,
      child: Icon(Icons.album_outlined, size: size * 0.4, color: tokens.textTertiary),
    );

    final Widget image = (url == null || url!.isEmpty)
        ? fallback
        : CachedNetworkImage(
            imageUrl: url!,
            width: size,
            height: size,
            fit: BoxFit.cover,
            fadeInDuration: RfTokens.motion(context, RfTokens.fast),
            placeholder: (_, __) => Container(color: tokens.surfaceHigh),
            errorWidget: (_, __, ___) => fallback,
          );

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: tokens.hairline, width: 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: image,
    );
  }
}

/// Thin progress rule. Deliberately not a Material progress bar: 3px, square, calm.
class RfProgress extends StatelessWidget {
  final double value;
  final bool indeterminate;
  final Color? color;
  final double height;

  const RfProgress({
    super.key,
    required this.value,
    this.indeterminate = false,
    this.color,
    this.height = 3,
  });

  @override
  Widget build(BuildContext context) {
    final RfTokens tokens = RfTokens.of(context);
    final Color fill = color ?? tokens.accent;
    final double clamped = value.isNaN ? 0 : value.clamp(0.0, 1.0).toDouble();

    return ClipRRect(
      borderRadius: BorderRadius.circular(1),
      child: SizedBox(
        height: height,
        child: Stack(
          children: [
            Positioned.fill(child: ColoredBox(color: tokens.hairlineStrong)),
            if (indeterminate)
              Positioned.fill(
                child: _IndeterminateBar(color: fill, height: height),
              )
            else
              Positioned.fill(
                child: FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: clamped,
                  child: ColoredBox(color: fill),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _IndeterminateBar extends StatefulWidget {
  final Color color;
  final double height;
  const _IndeterminateBar({required this.color, required this.height});

  @override
  State<_IndeterminateBar> createState() => _IndeterminateBarState();
}

class _IndeterminateBarState extends State<_IndeterminateBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (RfTokens.reducedMotion(context)) {
      return FractionallySizedBox(
        widthFactor: 0.3,
        alignment: Alignment.centerLeft,
        child: ColoredBox(color: widget.color),
      );
    }
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return FractionallySizedBox(
          alignment: Alignment(-1 + 2 * _controller.value, 0),
          widthFactor: 0.28,
          child: ColoredBox(color: widget.color),
        );
      },
    );
  }
}

/// Small dot + label, used for status without a card.
class RfStatus extends StatelessWidget {
  final String label;
  final Color color;
  final bool muted;

  const RfStatus(this.label, {super.key, required this.color, this.muted = false});

  @override
  Widget build(BuildContext context) {
    final RfTokens tokens = RfTokens.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: tokens.caption.copyWith(
            color: muted ? tokens.textTertiary : tokens.textSecondary,
            letterSpacing: 0.1,
          ),
        ),
      ],
    );
  }
}

/// Icon action with a 44px touch target and no ripple-heavy decoration.
class RfIconAction extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final Color? color;

  const RfIconAction({
    super.key,
    required this.icon,
    required this.tooltip,
    this.onPressed,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final RfTokens tokens = RfTokens.of(context);
    return Tooltip(
      message: tooltip,
      child: InkResponse(
        onTap: onPressed,
        radius: 22,
        child: SizedBox(
          width: 44,
          height: 44,
          child: Icon(
            icon,
            size: 19,
            color: onPressed == null ? tokens.textTertiary : (color ?? tokens.textSecondary),
          ),
        ),
      ),
    );
  }
}

class RfPrimaryButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final bool expand;

  const RfPrimaryButton({
    super.key,
    required this.label,
    this.icon,
    this.onPressed,
    this.expand = false,
  });

  @override
  Widget build(BuildContext context) {
    final RfTokens tokens = RfTokens.of(context);
    final Widget child = Row(
      mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 18, color: tokens.background),
          const SizedBox(width: RfTokens.s2),
        ],
        Text(
          label,
          style: TextStyle(
            color: tokens.background,
            fontWeight: FontWeight.w600,
            fontSize: 14,
            letterSpacing: 0.2,
          ),
        ),
      ],
    );

    return SizedBox(
      height: 44,
      child: TextButton(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          backgroundColor: tokens.accent,
          foregroundColor: tokens.background,
          padding: const EdgeInsets.symmetric(horizontal: RfTokens.s4),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(RfTokens.rSm),
          ),
        ),
        child: child,
      ),
    );
  }
}

class RfSecondaryButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;

  const RfSecondaryButton({
    super.key,
    required this.label,
    this.icon,
    this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final RfTokens tokens = RfTokens.of(context);
    return SizedBox(
      height: 44,
      child: OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          foregroundColor: tokens.textPrimary,
          side: BorderSide(color: tokens.hairlineStrong),
          padding: const EdgeInsets.symmetric(horizontal: RfTokens.s4),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(RfTokens.rSm),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 18, color: tokens.textSecondary),
              const SizedBox(width: RfTokens.s2),
            ],
            Text(label, style: const TextStyle(fontWeight: FontWeight.w500)),
          ],
        ),
      ),
    );
  }
}

/// Editorial empty state: no giant illustration, just type and one action.
class RfEmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  const RfEmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    final RfTokens tokens = RfTokens.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(RfTokens.s6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 26, color: tokens.textTertiary),
            const SizedBox(height: RfTokens.s4),
            Text(title, style: tokens.title),
            const SizedBox(height: RfTokens.s2),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: Text(message, style: tokens.body),
            ),
            if (action != null) ...[
              const SizedBox(height: RfTokens.s5),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

class RfErrorState extends StatelessWidget {
  final String message;
  final VoidCallback? onRetry;

  const RfErrorState({super.key, required this.message, this.onRetry});

  @override
  Widget build(BuildContext context) {
    final RfTokens tokens = RfTokens.of(context);
    return RfEmptyState(
      icon: Icons.error_outline,
      title: 'Something went wrong'.i18n,
      message: message,
      action: onRetry == null
          ? null
          : RfSecondaryButton(
              label: 'Retry'.i18n,
              icon: Icons.refresh,
              onPressed: onRetry,
            ),
    );
  }
}

/// Loading placeholder that keeps the layout stable.
class RfSkeletonRow extends StatelessWidget {
  const RfSkeletonRow({super.key});

  @override
  Widget build(BuildContext context) {
    final RfTokens tokens = RfTokens.of(context);
    Widget bar(double widthFactor, double height) => FractionallySizedBox(
          alignment: Alignment.centerLeft,
          widthFactor: widthFactor,
          child: Container(
            height: height,
            decoration: BoxDecoration(
              color: tokens.surfaceHigh,
              borderRadius: BorderRadius.circular(RfTokens.rXs),
            ),
          ),
        );
    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: RfTokens.gutter, vertical: RfTokens.s3),
      child: Row(
        children: [
          Container(
            width: RfTokens.artworkSm,
            height: RfTokens.artworkSm,
            decoration: BoxDecoration(
              color: tokens.surfaceHigh,
              borderRadius: BorderRadius.circular(RfTokens.rSm),
            ),
          ),
          const SizedBox(width: RfTokens.s3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                bar(0.6, 12),
                const SizedBox(height: RfTokens.s2),
                bar(0.35, 10),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Confirmation dialog with an explicit destructive action.
Future<bool> rfConfirm(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  String? cancelLabel,
  bool destructive = false,
}) async {
  final RfTokens tokens = RfTokens.of(context);
  final bool? result = await showDialog<bool>(
    context: context,
    builder: (BuildContext context) {
      return AlertDialog(
        backgroundColor: tokens.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(RfTokens.rMd),
          side: BorderSide(color: tokens.hairline),
        ),
        title: Text(title, style: tokens.title),
        content: Text(message, style: tokens.body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text((cancelLabel ?? 'Cancel').i18n,
                style: TextStyle(color: tokens.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(
              confirmLabel,
              style: TextStyle(
                color: destructive ? tokens.danger : tokens.accent,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      );
    },
  );
  return result ?? false;
}

/// Bottom sheet with a consistent, quiet chrome.
Future<T?> rfSheet<T>(BuildContext context, Widget child, {double? maxHeight}) {
  final RfTokens tokens = RfTokens.of(context);
  final double limit =
      maxHeight ?? MediaQuery.of(context).size.height * 0.82;
  return showModalBottomSheet<T>(
    context: context,
    backgroundColor: tokens.surface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(RfTokens.rLg)),
    ),
    builder: (BuildContext context) {
      return ConstrainedBox(
        constraints: BoxConstraints(maxHeight: limit),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.only(
                    top: RfTokens.s2, bottom: RfTokens.s1),
                child: Container(
                  width: 36,
                  height: 2,
                  decoration: BoxDecoration(
                    color: tokens.hairlineStrong,
                    borderRadius: BorderRadius.circular(1),
                  ),
                ),
              ),
              Flexible(child: child),
            ],
          ),
        ),
      );
    },
  );
}

/// Underline-style filter row with counts. Scrolls horizontally, never truncates labels.
class RfFilterBar<T> extends StatelessWidget {
  final List<T> items;
  final T selected;
  final String Function(T) labelBuilder;
  final int Function(T)? countBuilder;
  final ValueChanged<T> onSelected;

  const RfFilterBar({
    super.key,
    required this.items,
    required this.selected,
    required this.labelBuilder,
    required this.onSelected,
    this.countBuilder,
  });

  @override
  Widget build(BuildContext context) {
    final RfTokens tokens = RfTokens.of(context);
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: RfTokens.gutter),
        itemCount: items.length,
        separatorBuilder: (_, __) => const SizedBox(width: RfTokens.s5),
        itemBuilder: (BuildContext context, int index) {
          final T item = items[index];
          final bool isSelected = item == selected;
          final int? count = countBuilder?.call(item);
          final String label = labelBuilder(item);
          return InkWell(
            onTap: () => onSelected(item),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Row(
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                        color: isSelected ? tokens.textPrimary : tokens.textTertiary,
                        letterSpacing: 0.1,
                      ),
                    ),
                    if (count != null && count > 0) ...[
                      const SizedBox(width: 6),
                      Text(
                        '$count',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                          color: isSelected ? tokens.accent : tokens.textTertiary,
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 6),
                AnimatedContainer(
                  duration: RfTokens.motion(context, RfTokens.fast),
                  height: 1.5,
                  width: isSelected ? null : 0,
                  color: tokens.accent,
                  // The underline spans the label width.
                  child: const SizedBox(width: 18),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Search field with a hairline underline instead of a filled pill.
class RfSearchField extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onClear;

  const RfSearchField({
    super.key,
    required this.controller,
    required this.hint,
    this.onChanged,
    this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    final RfTokens tokens = RfTokens.of(context);
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (BuildContext context, TextEditingValue value, Widget? child) {
        return Container(
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: value.text.isEmpty ? tokens.hairline : tokens.hairlineStrong,
              ),
            ),
          ),
          child: Row(
            children: [
              Icon(Icons.search, size: 18, color: tokens.textTertiary),
              const SizedBox(width: RfTokens.s2),
              Expanded(
                child: TextField(
                  controller: controller,
                  onChanged: onChanged,
                  style: TextStyle(fontSize: 14, color: tokens.textPrimary),
                  cursorColor: tokens.accent,
                  decoration: InputDecoration(
                    isDense: true,
                    border: InputBorder.none,
                    hintText: hint.i18n,
                    hintStyle: TextStyle(fontSize: 14, color: tokens.textTertiary),
                    contentPadding:
                        const EdgeInsets.symmetric(vertical: RfTokens.s3),
                  ),
                ),
              ),
              if (value.text.isNotEmpty)
                IconButton(
                  onPressed: onClear ??
                      () {
                        controller.clear();
                        onChanged?.call('');
                      },
                  icon: Icon(Icons.close, size: 16, color: tokens.textTertiary),
                  tooltip: 'Clear'.i18n,
                ),
            ],
          ),
        );
      },
    );
  }
}
