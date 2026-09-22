import 'package:flutter/material.dart';
import 'package:fast_share/ui/home_screen.dart';

void main() {
  runApp(const FastShareApp());
}

class FastShareApp extends StatelessWidget {
  const FastShareApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FastShare',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorSchemeSeed: Colors.deepPurple,
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}
