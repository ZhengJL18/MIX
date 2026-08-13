import 'dart:async';
import 'package:flutter/material.dart';

import 'package:mix/printnotes/ui/widgets/custom_snackbar.dart';

Color mobileNullColor(BuildContext context) =>
    Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5);

Future<bool> openExplorer(BuildContext context, Uri fileUri) async {
  customSnackBar('Currently not supported on mobile',
          type: 'info', durationMil: 3000)
      .show(context);

  return true;
}
