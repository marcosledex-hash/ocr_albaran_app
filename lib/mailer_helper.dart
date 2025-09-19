// lib/mailer_helper.dart
import 'dart:io';
import 'package:mailer/mailer.dart';
import 'package:mailer/smtp_server.dart';

class MailerHelper {
  /// Envía un email usando SMTP (Gmail) y opcionalmente adjunta un fichero.
  /// smtpUser, smtpPass: credenciales (recomendado: contraseña de aplicación)
  static Future<void> sendSmtpMail({
    required String smtpUser,
    required String smtpPass,
    required String toEmail,
    required String subject,
    required String body,
    String? attachmentPath,
  }) async {
    final smtpServer = gmail(smtpUser, smtpPass);

    final message = Message()
      ..from = Address(smtpUser, 'OCR Albarán App')
      ..recipients.add(toEmail)
      ..subject = subject
      ..text = body;

    if (attachmentPath != null && attachmentPath.isNotEmpty) {
      final f = File(attachmentPath);
      if (await f.exists()) {
        message.attachments.add(FileAttachment(f));
      } else {
        print('MailerHelper: adjunto no existe: $attachmentPath');
      }
    }

    try {
      final sendReport = await send(message, smtpServer);
      print('MailerHelper: email enviado: $sendReport');
    } on MailerException catch (e) {
      print('MailerHelper: MailerException: $e');
      for (var p in e.problems) {
        print('MailerHelper: problema: ${p.code} - ${p.msg}');
      }
      rethrow;
    } catch (e) {
      print('MailerHelper: error no esperado: $e');
      rethrow;
    }
  }
}
