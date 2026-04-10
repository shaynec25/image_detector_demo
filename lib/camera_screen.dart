import 'dart:async';
import 'dart:io' show File, Platform;
import 'dart:math' show max, min;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:camera/camera.dart';
import 'package:google_mlkit_object_detection/google_mlkit_object_detection.dart';
import 'package:image/image.dart' as img;
import 'package:image_cropper/image_cropper.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:image_detector_demo/image_showcase_screen.dart';

class CameraScreen extends StatefulWidget {
  final bool isCustomModel;
  const CameraScreen({super.key, this.isCustomModel = false});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  // —— State ——
  bool _isProcessingImage = false;

  // —— Camera & ML ——
  CameraController? _controller;
  late CameraDescription _cameraDescription;
  late ObjectDetector _objectDetector;
  final ImagePicker _imagePicker = ImagePicker();

  // Rect? _scanHoleRectScreen; // TODO: 對齊框（掃描洞口）
  Size _screenSize = Size.zero;

  /// 除錯：ML Kit 偵測框（全螢幕座標）。
  Rect? _detectedCardRectScreen;

  /// 與 [_detectedCardRectScreen] 同一幀的偵測框（相機串流影像座標，用於拍照後裁切）。
  Rect? _detectedCardRectImage;
  Size _streamImageSize = Size.zero;

  @override
  void initState() {
    super.initState();
    _initDetectorAndCamera();
  }

  Future<void> _initDetectorAndCamera() async {
    await _initializeDetector();
    if (!mounted) {
      return;
    }
    await _initializeCamera();
  }

  Future<void> _initializeCamera() async {
    _cameraDescription = (await availableCameras()).firstWhere((camera) => camera.lensDirection == CameraLensDirection.back);
    final controller = CameraController(_cameraDescription, ResolutionPreset.high);
    await controller.initialize();
    if (!mounted) {
      await controller.dispose();
      return;
    }
    setState(() => _controller = controller);
    _controller?.startImageStream((CameraImage image) {
      if (!_isProcessingImage) {
        _processCameraImage(image);
      }
    });
  }

  Future<String> _getModelPath(String assetKey) async {
    final tempDir = await getTemporaryDirectory();
    final file = File(p.join(tempDir.path, p.basename(assetKey)));
    if (await file.exists()) {
      return file.path;
    }
    final byteData = await rootBundle.load(assetKey);
    await file.writeAsBytes(byteData.buffer.asUint8List());
    return file.path;
  }

  Future<void> _initializeDetector() async {
    if (widget.isCustomModel) {
      final modelPath = await _getModelPath('assets/ml_model/card_detector.tflite');
      _objectDetector = ObjectDetector(
        options: LocalObjectDetectorOptions(
          mode: DetectionMode.stream,
          modelPath: modelPath,
          classifyObjects: true,
          multipleObjects: false,
          confidenceThreshold: 0.7,
        ),
      );
    } else {
      _objectDetector = ObjectDetector(
        options: ObjectDetectorOptions(
          mode: DetectionMode.single,
          classifyObjects: true,
          multipleObjects: false,
        ),
      );
    }
  }

  Future<void> _processCameraImage(CameraImage image) async {
    if (_isProcessingImage) {
      return;
    }

    _isProcessingImage = true;
    try {
      final inputImage = _convertCameraImageToInputImage(image);
      if (inputImage == null) {
        return;
      }

      final objects = await _objectDetector.processImage(inputImage);
      if (!mounted) {
        return;
      }
      if (objects.isEmpty) {
        if (_detectedCardRectScreen != null) {
          setState(() {
            _detectedCardRectScreen = null;
            _detectedCardRectImage = null;
          });
        }
        return;
      }

      bool anyCardDetected = objects.any((object) {
        if (widget.isCustomModel && object.labels.isNotEmpty) {
          return object.labels.any((label) {
            final indexOfLabel = label.index;
            return indexOfLabel == 0 && label.confidence > 0.75;
          });
        }
        return true;
      });
      if (!anyCardDetected) {
        if (_detectedCardRectScreen != null) {
          setState(() {
            _detectedCardRectScreen = null;
            _detectedCardRectImage = null;
          });
        }
        return;
      }

      final rotation = InputImageRotationValue.fromRawValue(_cameraDescription.sensorOrientation);
      if (rotation == null) {
        return;
      }

      final imageSize = Size(image.width.toDouble(), image.height.toDouble());
      final bbox = objects.first.boundingBox;
      final screenCardRect = _mapMlKitBoundingBoxToScreen(
        rect: bbox,
        imageSize: imageSize,
        screenSize: _screenSize,
        rotation: rotation,
        lensDirection: _cameraDescription.lensDirection,
      );

      final detectionChanged = _detectedCardRectScreen != screenCardRect || _detectedCardRectImage != bbox || _streamImageSize != imageSize;
      if (detectionChanged) {
        setState(() {
          _detectedCardRectScreen = screenCardRect;
          _detectedCardRectImage = bbox;
          _streamImageSize = imageSize;
        });
      }
      // _checkAlignment(detectedCardScreen: screenCardRect, scanHoleScreen: hole);
    } finally {
      _isProcessingImage = false;
    }
  }

  InputImage? _convertCameraImageToInputImage(CameraImage image) {
    final rotation = InputImageRotationValue.fromRawValue(_cameraDescription.sensorOrientation);
    if (rotation == null) {
      return null;
    }
    final format = InputImageFormatValue.fromRawValue(image.format.raw);
    if (format == null) {
      return null;
    }

    final WriteBuffer allBytes = WriteBuffer();
    for (final Plane plane in image.planes) {
      allBytes.putUint8List(plane.bytes);
    }
    final bytes = allBytes.done().buffer.asUint8List();

    return InputImage.fromBytes(
      bytes: bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: format,
        bytesPerRow: image.planes[0].bytesPerRow,
      ),
    );
  }

  Rect _mapMlKitBoundingBoxToScreen({
    required Rect rect,
    required Size imageSize,
    required Size screenSize,
    required InputImageRotation rotation,
    required CameraLensDirection lensDirection,
  }) {
    final corners = [rect.topLeft, rect.topRight, rect.bottomLeft, rect.bottomRight];
    double minX = double.infinity;
    double minY = double.infinity;
    double maxX = -double.infinity;
    double maxY = -double.infinity;
    for (final c in corners) {
      final sx = _mlKitTranslateX(c.dx, screenSize, imageSize, rotation, lensDirection);
      final sy = _mlKitTranslateY(c.dy, screenSize, imageSize, rotation, lensDirection);
      minX = min(minX, sx);
      minY = min(minY, sy);
      maxX = max(maxX, sx);
      maxY = max(maxY, sy);
    }
    return Rect.fromLTRB(minX, minY, maxX, maxY);
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  Widget _buildLoadingScaffold() {
    return Scaffold(
      body: const Center(
        child: CircularProgressIndicator(),
      ),
    );
  }

  Widget _buildDebugDetectionOverlay() {
    return Positioned(
      left: _detectedCardRectScreen!.left,
      top: _detectedCardRectScreen!.top,
      width: _detectedCardRectScreen!.width,
      height: _detectedCardRectScreen!.height,
      child: Container(
        color: Colors.red.withOpacity(0.5),
      ),
    );
  }

  Future<void> _pickFromGallery() async {
    final pickedImage = await _imagePicker.pickImage(source: ImageSource.gallery);
    if (pickedImage == null) {
      return;
    }
    final croppedImage = await ImageCropper().cropImage(sourcePath: pickedImage.path);
    if (croppedImage == null || !mounted) {
      return;
    }
    Navigator.push(context, MaterialPageRoute(builder: (context) => ImageShowcaseScreen(imagePath: croppedImage.path)));
  }

  /// 將拍照檔依目前 ML 偵測框（與 [_buildDebugDetectionOverlay] 同一幀的串流座標）等比例對應到實際 JPEG 後裁切。
  Future<String> _cropCaptureToDetectionOverlay(String capturePath) async {
    final imageRect = _detectedCardRectImage;
    final streamSize = _streamImageSize;
    if (imageRect == null || streamSize.width <= 0 || streamSize.height <= 0) {
      return capturePath;
    }

    final bytes = await File(capturePath).readAsBytes();
    final decoded = img.decodeImage(bytes);
    if (decoded == null) {
      return capturePath;
    }

    final sx = decoded.width / streamSize.width;
    final sy = decoded.height / streamSize.height;

    var left = (imageRect.left * sx).round();
    var top = (imageRect.top * sy).round();
    var w = (imageRect.width * sx).round();
    var h = (imageRect.height * sy).round();

    left = left.clamp(0, decoded.width - 1);
    top = top.clamp(0, decoded.height - 1);
    w = w.clamp(1, decoded.width - left);
    h = h.clamp(1, decoded.height - top);

    final cropped = img.copyCrop(decoded, x: left, y: top, width: w, height: h);
    final outBytes = img.encodeJpg(cropped, quality: 92);
    final tempDir = await getTemporaryDirectory();
    final outPath = p.join(tempDir.path, 'crop_${DateTime.now().millisecondsSinceEpoch}.jpg');
    await File(outPath).writeAsBytes(outBytes);
    return outPath;
  }

  Future<void> _capture() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return;
    }
    try {
      final file = await controller.takePicture();
      if (!mounted) {
        return;
      }
      var path = file.path;
      if (_detectedCardRectImage != null) {
        path = await _cropCaptureToDetectionOverlay(path);
      }
      if (!mounted) {
        return;
      }
      Navigator.push(context, MaterialPageRoute(builder: (context) => ImageShowcaseScreen(imagePath: path)));
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    if (_controller == null) {
      return _buildLoadingScaffold();
    }
    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(child: CameraPreview(_controller!)),
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    _screenSize = MediaQuery.sizeOf(context);
                    return Container();
                  },
                ),
              ),
              ColoredBox(
                color: Colors.black,
                child: Padding(
                  padding: EdgeInsets.only(bottom: 20),
                  child: _buildCaptureControls(),
                ),
              ),
            ],
          ),
          if (_detectedCardRectScreen != null) _buildDebugDetectionOverlay(),
        ],
      ),
    );
  }

  Row _buildCaptureControls() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      spacing: 20,
      children: [
        IconButton(
          iconSize: 50,
          onPressed: () {
            _pickFromGallery();
          },
          icon: const Icon(Icons.image),
        ),
        IconButton(
          iconSize: 50,
          onPressed: () {
            _capture();
          },
          icon: const Icon(Icons.camera),
        ),
        SizedBox(width: 50)
      ],
    );
  }
}

// -----------------------------------------------------------------------------
// ML Kit：影像座標 → 預覽畫布（全螢幕）
// 參考 google_ml_kit_flutter coordinates_translator
// -----------------------------------------------------------------------------

double _mlKitTranslateX(
  double x,
  Size canvasSize,
  Size imageSize,
  InputImageRotation rotation,
  CameraLensDirection cameraLensDirection,
) {
  switch (rotation) {
    case InputImageRotation.rotation90deg:
      return x * canvasSize.width / (Platform.isIOS ? imageSize.width : imageSize.height);
    case InputImageRotation.rotation270deg:
      return canvasSize.width - x * canvasSize.width / (Platform.isIOS ? imageSize.width : imageSize.height);
    case InputImageRotation.rotation0deg:
    case InputImageRotation.rotation180deg:
      switch (cameraLensDirection) {
        case CameraLensDirection.back:
          return x * canvasSize.width / imageSize.width;
        default:
          return canvasSize.width - x * canvasSize.width / imageSize.width;
      }
  }
}

double _mlKitTranslateY(
  double y,
  Size canvasSize,
  Size imageSize,
  InputImageRotation rotation,
  CameraLensDirection cameraLensDirection,
) {
  switch (rotation) {
    case InputImageRotation.rotation90deg:
    case InputImageRotation.rotation270deg:
      return y * canvasSize.height / (Platform.isIOS ? imageSize.height : imageSize.width);
    case InputImageRotation.rotation0deg:
    case InputImageRotation.rotation180deg:
      return y * canvasSize.height / imageSize.height;
  }
}
