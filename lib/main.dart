import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image/image.dart' as img_pkg;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_email_sender/flutter_email_sender.dart';

void main() {
  runApp(const OCRApp());
}

class OCRApp extends StatelessWidget {
  const OCRApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'OCR Albarán',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const OCRHomePage(),
    );
  }
}

class OCRHomePage extends StatefulWidget {
  const OCRHomePage({super.key});

  @override
  State<OCRHomePage> createState() => _OCRHomePageState();
}

class _OCRHomePageState extends State<OCRHomePage> {
  File? _imageFile;
  String recognizedFullText = '';
  String pedido = '';
  String albaran = '';
  String emailTo = '';
  bool drawing = false;
  Offset? dragStart;
  Offset? dragCurrent;
  final ImagePicker picker = ImagePicker();
  final textRecognizer = TextRecognizer(script: TextRecognitionScript.latin);

  @override
  void initState() {
    super.initState();
    _loadEmail();
  }

  Future<void> _loadEmail() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      emailTo = prefs.getString('ocr_email') ?? '';
    });
  }

  Future<void> _saveEmail(String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('ocr_email', value);
    setState(() {
      emailTo = value;
    });
  }

  Future<void> _captureImage() async {
    try {
      final XFile? picked = await picker.pickImage(source: ImageSource.camera, imageQuality: 85);
      if (picked == null) return;
      setState(() {
        _imageFile = File(picked.path);
        pedido = '';
        albaran = '';
        recognizedFullText = '';
      });
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error cámara: $e')));
    }
  }

  Future<void> _detectAll() async {
    if (_imageFile == null) return;
    final input = InputImage.fromFile(_imageFile!);
    final result = await textRecognizer.processImage(input);
    final blocks = result.blocks;
    recognizedFullText = result.text;
    // Resetea
    String foundPedido = '';
    String foundAlbaran = '';
    final keysPedido = ['pedido', 'pedido:'];
    final keysAlbaran = ['albaran', 'albarán', 'albarán:', 'albaran:'];

    // Scan lines for keywords and pick the token immediately after keyword
    for (final block in blocks) {
      for (final line in block.lines) {
        final lineText = line.text;
        final lower = lineText.toLowerCase();
        // PEDIDO
        for (final k in keysPedido) {
          if (lower.contains(k)) {
            final idx = lower.indexOf(k);
            final after = lineText.substring(idx + k.length).trim();
            final m = RegExp(r'([A-Za-z0-9\-\_/]{3,})').firstMatch(after);
            if (m != null) {
              foundPedido = m.group(0) ?? '';
            } else {
              // try split fallback
              final parts = after.split(RegExp(r'[\s:]+')).where((s) => s.isNotEmpty).toList();
              if (parts.isNotEmpty) foundPedido = parts.first;
            }
          }
        }
        // ALBARAN
        for (final k in keysAlbaran) {
          if (lower.contains(k)) {
            final idx = lower.indexOf(k);
            final after = lineText.substring(idx + k.length).trim();
            final m = RegExp(r'([A-Za-z0-9\-\_/]{3,})').firstMatch(after);
            if (m != null) {
              foundAlbaran = m.group(0) ?? '';
            } else {
              final parts = after.split(RegExp(r'[\s:]+')).where((s) => s.isNotEmpty).toList();
              if (parts.isNotEmpty) foundAlbaran = parts.first;
            }
          }
        }
      }
    }

    // Fallbacks: if not found, search for first long number-like tokens in whole text
    if (foundPedido.isEmpty) {
      final m = RegExp(r'\b([0-9A-Za-z\-/]{4,})\b').firstMatch(result.text);
      if (m != null) foundPedido = m.group(0) ?? '';
    }
    if (foundAlbaran.isEmpty) {
      final matches = RegExp(r'\b([0-9A-Za-z\-/]{4,})\b').allMatches(result.text).toList();
      if (matches.length >= 2) {
        foundAlbaran = matches.length >= 2 ? matches[1].group(0) ?? '' : (matches.isNotEmpty ? matches.first.group(0) ?? '' : '');
      } else if (matches.isNotEmpty) {
        foundAlbaran = matches.first.group(0) ?? '';
      }
    }

    setState(() {
      pedido = foundPedido;
      albaran = foundAlbaran;
    });

    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Detección automática completada. Revise y corrija si hace falta.')));
  }

  Rect? getSelectedRect() {
    if (dragStart == null || dragCurrent == null) return null;
    return Rect.fromPoints(dragStart!, dragCurrent!);
  }

  Future<void> _ocrSelectionFor(String target) async {
    if (_imageFile == null) return;
    final sel = getSelectedRect();
    if (sel == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Dibuja primero un rectángulo sobre la imagen.')));
      return;
    }

    // Decode actual image size
    final bytes = await _imageFile!.readAsBytes();
    final uiImage = await decodeImageFromList(bytes);
    final imgW = uiImage.width.toDouble();
    final imgH = uiImage.height.toDouble();

    // Determine how image is displayed in widget (we used BoxFit.contain)
    // We'll compute mapping from widget coords to image pixel coords.
    // First we need widget size where image is shown: obtain via context using a GlobalKey
    // For simplicity, use MediaQuery to get max width allowed and assume image displays scaled to fit
    final RenderBox? box = _imageKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Error al mapear coordenadas (widget no disponible).')));
      return;
    }
    final widgetSize = box.size;
    final widgetW = widgetSize.width;
    final widgetH = widgetSize.height;

    // Calculate scale for BoxFit.contain
    final scale = min(widgetW / imgW, widgetH / imgH);
    final dispW = imgW * scale;
    final dispH = imgH * scale;
    final offsetX = (widgetW - dispW) / 2;
    final offsetY = (widgetH - dispH) / 2;

    // Map selection rect from widget coords to image pixel coords
    final left = ((sel.left - offsetX) / scale).clamp(0.0, imgW).toInt();
    final top = ((sel.top - offsetY) / scale).clamp(0.0, imgH).toInt();
    final right = ((sel.right - offsetX) / scale).clamp(0.0, imgW).toInt();
    final bottom = ((sel.bottom - offsetY) / scale).clamp(0.0, imgH).toInt();
    final width = max(1, right - left);
    final height = max(1, bottom - top);

    // Crop using package:image
    final decoded = img_pkg.decodeImage(bytes);
    if (decoded == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Error decodificando imagen para recorte.')));
      return;
    }
    final crop = img_pkg.copyCrop(decoded, left, top, width, height);
    final tempDir = await getTemporaryDirectory();
    final croppedFile = File('${tempDir.path}/ocr_crop_${DateTime.now().millisecondsSinceEpoch}.jpg');
    await croppedFile.writeAsBytes(img_pkg.encodeJpg(crop, quality: 90));

    // Run MLKit on cropped file
    final input = InputImage.fromFile(croppedFile);
    final res = await textRecognizer.processImage(input);
    final text = res.text.trim();

    // Simple extraction: take first token that looks like number/ID
    final m = RegExp(r'([A-Za-z0-9\-/]{3,})').firstMatch(text);

    setState(() {
      if (target == 'pedido') {
        pedido = m?.group(0) ?? text;
      } else {
        albaran = m?.group(0) ?? text;
      }
    });

    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('OCR de selección completado')));
  }

  // Key to read widget size
  final GlobalKey _imageKey = GlobalKey();

  Future<void> _sendEmailWithData() async {
    if (_imageFile == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No hay imagen para enviar.')));
      return;
    }
    if (emailTo.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Configura un email en ajustes.')));
      return;
    }

    final body = 'Albarán: $albaran\nPedido: $pedido';
    final Email em = Email(
      body: body,
      subject: 'Albarán y Pedido detectados',
      recipients: [emailTo],
      attachmentPaths: [_imageFile!.path],
      isHTML: false,
    );

    try {
      await FlutterEmailSender.send(em);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Email enviado (o abierto el cliente de correo).')));
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error al enviar email: $e')));
    }
  }

  void _editEmailDialog() {
    final controller = TextEditingController(text: emailTo);
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Configurar email destino'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.emailAddress,
          decoration: const InputDecoration(hintText: 'destino@dominio.com'),
        ),
        actions: [
          TextButton(
            onPressed: () {
              _saveEmail(controller.text.trim());
              Navigator.of(context).pop();
            },
            child: const Text('Guardar'),
          )
        ],
      ),
    );
  }

  @override
  void dispose() {
    textRecognizer.close();
    super.dispose();
  }

  Widget _buildImageArea() {
    if (_imageFile == null) return const SizedBox.shrink();
    return GestureDetector(
      onPanStart: (details) {
        setState(() {
          drawing = true;
          final box = _imageKey.currentContext?.findRenderObject() as RenderBox?;
          dragStart = box?.globalToLocal(details.globalPosition);
          dragCurrent = dragStart;
        });
      },
      onPanUpdate: (details) {
        setState(() {
          final box = _imageKey.currentContext?.findRenderObject() as RenderBox?;
          dragCurrent = box?.globalToLocal(details.globalPosition);
        });
      },
      onPanEnd: (details) {
        setState(() {
          drawing = false;
        });
      },
      child: Container(
        color: Colors.black12,
        child: Center(
          child: LayoutBuilder(
            builder: (context, constraints) {
              return SizedBox(
                width: constraints.maxWidth,
                height: min(constraints.maxHeight, 480),
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: Image.file(
                        _imageFile!,
                        key: _imageKey,
                        fit: BoxFit.contain,
                      ),
                    ),
                    if (dragStart != null && dragCurrent != null)
                      CustomPaint(
                        painter: _RectPainter(rect: Rect.fromPoints(dragStart!, dragCurrent!)),
                        size: Size.infinite,
                      ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pedidoController = TextEditingController(text: pedido);
    final albaranController = TextEditingController(text: albaran);

    return Scaffold(
      appBar: AppBar(
        title: const Text('OCR Albarán'),
        actions: [
          IconButton(icon: const Icon(Icons.settings), onPressed: _editEmailDialog),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            ElevatedButton.icon(
              icon: const Icon(Icons.camera_alt),
              label: const Text('Tomar foto'),
              onPressed: _captureImage,
            ),
            const SizedBox(height: 12),
            _buildImageArea(),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(child: ElevatedButton(onPressed: _detectAll, child: const Text('Detección automática'))),
                const SizedBox(width: 8),
                Expanded(child: ElevatedButton(onPressed: () => _ocrSelectionFor('pedido'), child: const Text('OCR selección → Pedido'))),
                const SizedBox(width: 8),
                Expanded(child: ElevatedButton(onPressed: () => _ocrSelectionFor('albaran'), child: const Text('OCR selección → Albarán'))),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: pedidoController,
              decoration: const InputDecoration(labelText: 'Pedido (editar si hace falta)'),
              onChanged: (v) => pedido = v,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: albaranController,
              decoration: const InputDecoration(labelText: 'Albarán (editar si hace falta)'),
              onChanged: (v) => albaran = v,
            ),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              icon: const Icon(Icons.send),
              label: const Text('Enviar por correo (imagen + texto)'),
              onPressed: _sendEmailWithData,
            ),
            const SizedBox(height: 12),
            Text('Email destino guardado: $emailTo'),
            const SizedBox(height: 16),
            ExpansionTile(
              title: const Text('Texto OCR completo (diagnóstico)'),
              children: [SelectableText(recognizedFullText.isEmpty ? '--- vacío ---' : recognizedFullText)],
            ),
          ],
        ),
      ),
    );
  }
}

class _RectPainter extends CustomPainter {
  final Rect rect;
  _RectPainter({required this.rect});
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.yellow.withOpacity(0.4)
      ..style = PaintingStyle.fill;
    final border = Paint()
      ..color = Colors.red
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    canvas.drawRect(rect, paint);
    canvas.drawRect(rect, border);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
