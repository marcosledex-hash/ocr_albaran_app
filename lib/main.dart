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
import 'mailer_helper.dart';

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
  // -------------------------
  // Variables (3.2)
  // -------------------------
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

  final GlobalKey _imageKey = GlobalKey();

  // Controllers for editable fields (so they remain after rebuilds)
  final TextEditingController pedidoController = TextEditingController();
  final TextEditingController albaranController = TextEditingController();
  final TextEditingController emailController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadEmail();
    // keep controllers in sync with variables
    pedidoController.addListener(() {
      pedido = pedidoController.text;
    });
    albaranController.addListener(() {
      albaran = albaranController.text;
    });
    emailController.addListener(() {
      // don't save continuously here, use explicit save or when editing complete
    });
  }

  @override
  void dispose() {
    pedidoController.dispose();
    albaranController.dispose();
    emailController.dispose();
    textRecognizer.close();
    super.dispose();
  }

  // -------------------------
  // 3.3 / 3.4 Persistencia del email usando SharedPreferences
  // -------------------------
  Future<void> _loadEmail() async {
    final prefs = await SharedPreferences.getInstance();
    final e = prefs.getString('ocr_email') ?? '';
    setState(() {
      emailTo = e;
      emailController.text = e;
    });
  }

  Future<void> _saveEmail(String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('ocr_email', value);
    setState(() {
      emailTo = value;
    });
  }

  // -------------------------
  // Tomar foto / seleccionar
  // -------------------------
  Future<void> _captureImage() async {
    try {
      final XFile? selected = await picker.pickImage(source: ImageSource.camera, imageQuality: 85);
      if (selected == null) return;
      setState(() {
        _imageFile = File(selected.path);
        pedido = '';
        albaran = '';
        recognizedFullText = '';
        pedidoController.text = '';
        albaranController.text = '';
        dragStart = null;
        dragCurrent = null;
      });
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error al tomar foto: $e')));
    }
  }

  // -------------------------
  // Detectar todo (opción B)
  // -------------------------
  String _normalize(String s) {
    var t = s.toLowerCase();
    // reemplazos simples de acentos (básico)
    const withDiacritics = 'áéíóúàèìòùäëïöüñ';
    const without = 'aeiouaeiouaeioun';
    for (int i = 0; i < withDiacritics.length; i++) {
      t = t.replaceAll(withDiacritics[i], without[i]);
    }
    return t;
  }

  Future<void> _detectAll() async {
    if (_imageFile == null) return;
    final input = InputImage.fromFilePath(_imageFile!.path);
    final result = await textRecognizer.processImage(input);
    recognizedFullText = result.text;

    String foundPedido = '';
    String foundAlbaran = '';

    final keysPedido = ['pedido', 'pedido:'];
    final keysAlbaran = ['albaran', 'albarán', 'albaran:', 'albarán:'];

    for (final block in result.blocks) {
      for (final line in block.lines) {
        final lineText = line.text;
        final lower = _normalize(lineText);

        // PEDIDO
        for (final k in keysPedido) {
          if (lower.contains(k)) {
            final idx = lower.indexOf(k);
            final after = lineText.substring(idx + k.length).trim();
            final m = RegExp(r'([A-Za-z0-9\-\_/]{3,})').firstMatch(after);
            if (m != null) {
              foundPedido = m.group(0) ?? '';
            } else {
              final parts = after.split(RegExp(r'[\s:]+')).where((s) => s.isNotEmpty);
              if (parts.isNotEmpty) foundPedido = parts.first;
            }
          }
        }

        // ALBARÁN
        for (final k in keysAlbaran) {
          if (lower.contains(k)) {
            final idx = lower.indexOf(k);
            final after = lineText.substring(idx + k.length).trim();
            final m = RegExp(r'([A-Za-z0-9\-\_/]{3,})').firstMatch(after);
            if (m != null) {
              foundAlbaran = m.group(0) ?? '';
            } else {
              final parts = after.split(RegExp(r'[\s:]+')).where((s) => s.isNotEmpty);
              if (parts.isNotEmpty) foundAlbaran = parts.first;
            }
          }
        }
      }
    }

    // Backups: si no se encuentran intentar por tokens globales
    if (foundPedido.isEmpty) {
      final m = RegExp(r'\b([0-9A-Za-z\-/]{4,})\b').firstMatch(result.text);
      if (m != null) foundPedido = m.group(0) ?? '';
    }
    if (foundAlbaran.isEmpty) {
      final matches = RegExp(r'\b([0-9A-Za-z\-/]{4,})\b').allMatches(result.text).toList();
      if (matches.length >= 2) {
        foundAlbaran = matches[1].group(0) ?? '';
      } else if (matches.isNotEmpty) {
        foundAlbaran = matches[0].group(0) ?? '';
      }
    }

    setState(() {
      pedido = foundPedido;
      albaran = foundAlbaran;
      pedidoController.text = pedido;
      albaranController.text = albaran;
    });

    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Detección completada')));
  }

  // -------------------------
  // Helper: retorna Rect con la selección si existe
  // -------------------------
  Rect? getSelectedRect() {
    if (dragStart == null || dragCurrent == null) return null;
    return Rect.fromPoints(dragStart!, dragCurrent!);
  }

  // -------------------------
  // 3.4 OCR dentro de la selección (recorte + MLKit)
  // -------------------------
  Future<void> _ocrSelectionFor(String target) async {
    if (_imageFile == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No hay imagen')));
      return;
    }
    final sel = getSelectedRect();
    if (sel == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No hay selección')));
      return;
    }

    // Leer bytes y dimensiones reales
    final bytes = await _imageFile!.readAsBytes();
    final uiImage = await decodeImageFromList(bytes);
    final imgW = uiImage.width.toDouble();
    final imgH = uiImage.height.toDouble();

    // Obtener tamaño del widget donde se muestra la imagen
    final box = _imageKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Error: sin contexto de imagen')));
      return;
    }
    final widgetSize = box.size;
    final widgetW = widgetSize.width;
    final widgetH = widgetSize.height;

    // Cálculo BoxFit.contain (asumimos que la imagen se muestra con contain)
    final usedScale = min(widgetW / imgW, widgetH / imgH);
    final dispW = imgW * usedScale;
    final dispH = imgH * usedScale;
    final offsetX = (widgetW - dispW) / 2;
    final offsetY = (widgetH - dispH) / 2;

    // Mapeo de coordenadas widget -> pixeles imagen
    final left = ((sel.left - offsetX) / usedScale).clamp(0.0, imgW).toInt();
    final top = ((sel.top - offsetY) / usedScale).clamp(0.0, imgH).toInt();
    final right = ((sel.right - offsetX) / usedScale).clamp(0.0, imgW).toInt();
    final bottom = ((sel.bottom - offsetY) / usedScale).clamp(0.0, imgH).toInt();

    final width = max(1, right - left);
    final height = max(1, bottom - top);

    // Recortar usando package:image (usa named params para compatibilidad con versiones recientes)
    final decoded = img_pkg.decodeImage(bytes);
    if (decoded == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Error decodificando imagen')));
      return;
    }

    final crop = img_pkg.copyCrop(decoded, x: left, y: top, width: width, height: height);

    final tempDir = await getTemporaryDirectory();
    final croppedFile = File('${tempDir.path}/ocr_crop_${DateTime.now().millisecondsSinceEpoch}.jpg');
    await croppedFile.writeAsBytes(img_pkg.encodeJpg(crop, quality: 90));

    // Ejecutar MLKit sobre el recorte
    final input = InputImage.fromFilePath(croppedFile.path);
    final res = await textRecognizer.processImage(input);
    final text = res.text.trim();

    final m = RegExp(r'([A-Za-z0-9\-/]{3,})').firstMatch(text);

    setState(() {
      if (target == 'pedido') {
        pedido = m?.group(0) ?? text;
        pedidoController.text = pedido;
      } else {
        albaran = m?.group(0) ?? text;
        albaranController.text = albaran;
      }
    });

    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('OCR en selección completado')));
  }

  // -------------------------
  // 3.5 Enviar email con flutter_email_sender
  // -------------------------
  Future<void> _sendEmailWithData() async {
  if (_imageFile == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('No hay imagen capturada')),
    );
    return;
  }
  if (emailTo.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Configura primero un correo destino')),
    );
    return;
  }

  final body = 'Albarán: $albaran\nPedido: $pedido';

try {
  print("📨 Enviando con mailer (SMTP)...");
  await MailerHelper.sendSmtpMail(
    smtpUser: const String.fromEnvironment('SMTP_USER'),
    smtpPass: const String.fromEnvironment('SMTP_PASS'),
    toEmail: emailTo.trim(),
    subject: 'Albarán y Pedido detectados',
    body: body,
    attachmentPath: _imageFile!.path,
  );
  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(content: Text('Se envió el correo ✅')),
  );
 } catch (e) {
   ScaffoldMessenger.of(context).showSnackBar(
     SnackBar(content: Text('Error al enviar: $e')),
  );
 }
}

  // -------------------------  // Construcción UI
  // -------------------------
  Widget _buildImageArea() {
    if (_imageFile == null) return const SizedBox.shrink();
    return GestureDetector(
      onPanStart: (details) {
        final box = _imageKey.currentContext?.findRenderObject() as RenderBox?;
        if (box == null) return;
        setState(() {
          drawing = true;
          dragStart = box.globalToLocal(details.globalPosition);
          dragCurrent = dragStart;
        });
      },
      onPanUpdate: (details) {
        final box = _imageKey.currentContext?.findRenderObject() as RenderBox?;
        if (box == null) return;
        setState(() {
          dragCurrent = box.globalToLocal(details.globalPosition);
        });
      },
      onPanEnd: (_) {
        setState(() {
          drawing = false;
        });
      },
      child: Container(
        color: Colors.black12,
        child: Center(
          child: SizedBox(
            // height constrained to avoid overflows
            height: 480,
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
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _RectPainter(rect: Rect.fromPoints(dragStart!, dragCurrent!)),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _editEmailDialog() {
    final controller = TextEditingController(text: emailTo);
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Configurar correo electrónico destino'),
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
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Update controllers content in build in case variables changed elsewhere
    pedidoController.text = pedido;
    albaranController.text = albaran;
    emailController.text = emailTo;

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
                Expanded(child: ElevatedButton(onPressed: _detectAll, child: const Text('Detectar (auto)'))),
                const SizedBox(width: 8),
                Expanded(child: ElevatedButton(onPressed: () => _ocrSelectionFor('pedido'), child: const Text('OCR selección → Pedido'))),
                const SizedBox(width: 8),
                Expanded(child: ElevatedButton(onPressed: () => _ocrSelectionFor('albaran'), child: const Text('OCR selección → Albarán'))),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: pedidoController,
              decoration: const InputDecoration(labelText: 'Pedido (editar si necesario)'),
              onChanged: (v) => pedido = v,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: albaranController,
              decoration: const InputDecoration(labelText: 'Albarán (editar si necesario)'),
              onChanged: (v) => albaran = v,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: emailController,
              decoration: const InputDecoration(labelText: 'Email destino (se guarda)'),
              keyboardType: TextInputType.emailAddress,
              onChanged: (v) => emailTo = v,
              onEditingComplete: () {
                _saveEmail(emailTo.trim());
                FocusScope.of(context).unfocus();
              },
            ),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              icon: const Icon(Icons.send),
              label: const Text('Enviar por correo (imagen + texto)'),
              onPressed: _sendEmailWithData,
            ),
            const SizedBox(height: 12),
            Text('Correo destino guardado: $emailTo'),
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
  bool shouldRepaint(covariant _RectPainter oldDelegate) => oldDelegate.rect != rect;
}
