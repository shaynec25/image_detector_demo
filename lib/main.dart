import 'package:flutter/material.dart';

import 'package:image_detector_demo/camera_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MainApp());
}

class MainApp extends StatelessWidget {
  const MainApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Builder(
        builder: (context) {
          return Scaffold(
            body: Center(
              child: Column(
                spacing: 32,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  ElevatedButton(
                    child: const Text('Default Model'),
                    onPressed: () {
                      Navigator.push(context, MaterialPageRoute(builder: (context) => const CameraScreen()));
                    },
                  ),
                  ElevatedButton(
                    child: const Text('Custom Trained Model'),
                    onPressed: () {
                      Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (context) => const CameraScreen(
                                    isCustomModel: true,
                                  )));
                    },
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
