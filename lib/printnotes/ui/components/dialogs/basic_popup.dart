import 'package:flutter/material.dart';

Future<bool> showBasicPopup(
    BuildContext context, String title, String content) async {
  return await showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(content),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(
                '取消',
                style:
                    TextStyle(color: Theme.of(context).colorScheme.secondary),
              ),
            ),
            TextButton(
              style: TextButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.secondary,
                foregroundColor: Theme.of(context).colorScheme.onSecondary,
              ),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('确定'),
            ),
          ],
        ),
      ) ??
      false;
}
