import 'dart:io';

import 'package:flutter/material.dart';

class ImageShowcaseScreen extends StatelessWidget {
  final String imagePath;
  const ImageShowcaseScreen({super.key, required this.imagePath});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Image Showcase'),
        leading: IconButton(
          onPressed: () {
            Navigator.pop(context);
          },
          icon: Icon(Icons.arrow_back),
        ),
      ),
      body: Center(
        child: Image.file(File(imagePath)),
      ),
    );
  }
}
