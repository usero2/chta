import 'package:flutter/material.dart';

class CoreStatus extends StatelessWidget {
  const CoreStatus({required this.version, super.key});

  final Future<String> version;

  @override
  Widget build(BuildContext context) => FutureBuilder<String>(
    future: version,
    builder: (context, snapshot) {
      final label = switch (snapshot.connectionState) {
        ConnectionState.done when snapshot.hasData => 'Core ${snapshot.data}',
        ConnectionState.done => 'Core unavailable',
        _ => 'Core loading…',
      };
      return Padding(
        padding: const EdgeInsets.fromLTRB(22, 10, 22, 18),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Color(0xFF8E8E93), fontSize: 11),
        ),
      );
    },
  );
}
