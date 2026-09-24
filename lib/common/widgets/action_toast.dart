import 'package:PiliPlus/common/widgets/custom_toast.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:material_ui/material_ui.dart';

Future<bool> showActionToast({
  required String msg,
  required String actionText,
  Duration time = const Duration(seconds: 5),
}) async {
  SmartDialog.dismiss();

  final res = await SmartDialog.show<bool>(
    clickMaskDismiss: false,
    usePenetrate: true,
    displayTime: time,
    alignment: Alignment.bottomCenter,
    builder: (context) {
      final colorScheme = ColorScheme.of(context);
      return Container(
        margin: EdgeInsets.only(
          bottom: MediaQuery.viewPaddingOf(context).bottom + 30,
        ),
        padding: const EdgeInsets.only(left: 17, right: 6, top: 2, bottom: 2),
        decoration: BoxDecoration(
          color: colorScheme.primaryContainer.withValues(
            alpha: CustomToast.toastOpacity,
          ),
          borderRadius: const BorderRadius.all(Radius.circular(20)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                msg,
                style: TextStyle(
                  fontSize: 13,
                  color: colorScheme.onPrimaryContainer,
                ),
              ),
            ),
            const SizedBox(width: 4),
            TextButton(
              onPressed: () => SmartDialog.dismiss(result: true),
              style: TextButton.styleFrom(
                foregroundColor: colorScheme.primary,
                minimumSize: Size.zero,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(actionText, style: const TextStyle(fontSize: 13)),
            ),
          ],
        ),
      );
    },
  );

  return res ?? false;
}