import 'package:firebase_auth/firebase_auth.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

import 'db/app_db_client.dart';

enum ImageUploadUseCase { profile, product, shop, ad }

class ImageUploadResult {
  final String url;
  final String? thumbnailUrl;
  final String fileId;
  final String fileName;

  const ImageUploadResult({
    required this.url,
    this.thumbnailUrl,
    required this.fileId,
    required this.fileName,
  });
}

class ImageUploadService {
  static const int maxUploadBytes = 8 * 1024 * 1024;

  /// Keeps URL formatting consistent before save/display.
  static String normalizeImageUrl(String url) {
    return url.trim();
  }

  /// Restrict admin-managed media to trusted image hosts: DigitalOcean Spaces
  /// (current) and Cloudinary (legacy images already stored in the database).
  static bool isCloudinaryUrl(String url) {
    final normalized = normalizeImageUrl(url);
    if (normalized.isEmpty) return false;
    final uri = Uri.tryParse(normalized);
    if (uri == null) return false;
    final host = uri.host.toLowerCase();
    final isTrustedHost = host.contains('digitaloceanspaces.com') ||
        host.contains('cloudinary.com');
    if (!isTrustedHost) return false;
    return normalized.startsWith('http://') || normalized.startsWith('https://');
  }

  /// Uploads an image to the GharTek backend, which stores it on DigitalOcean
  /// Spaces and returns a public URL. Auth is via the Firebase ID token.
  static Future<ImageUploadResult> uploadImage({
    required XFile file,
    required ImageUploadUseCase useCase,
  }) async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        throw Exception('Please login to upload images.');
      }

      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) {
        throw Exception('Selected image is empty.');
      }
      if (bytes.length > maxUploadBytes) {
        throw Exception('Image is too large. Max allowed size is 8MB.');
      }

      final mimeType = _getMimeType(file.name);
      if (mimeType == null) {
        throw Exception('Unsupported image format: ${file.name}');
      }

      final ext = file.name.contains('.')
          ? file.name.toLowerCase().split('.').last
          : 'jpg';
      final fileName =
          '${_useCaseValue(useCase)}_${DateTime.now().millisecondsSinceEpoch}.$ext';

      final base = AppDbClient.instance.httpBase;
      final uploadUri = Uri.parse('$base/v1/upload');

      print('[Spaces] Uploading ${(bytes.length / (1024 * 1024)).toStringAsFixed(2)}MB to $uploadUri');

      final request = http.MultipartRequest('POST', uploadUri);

      final token = await user.getIdToken();
      if (token != null && token.isNotEmpty) {
        request.headers['Authorization'] = 'Bearer $token';
      }

      request.fields['useCase'] = _useCaseValue(useCase);
      request.files.add(
        http.MultipartFile.fromBytes(
          'file',
          bytes,
          filename: fileName,
        ),
      );

      final streamedResponse = await request.send().timeout(
        const Duration(seconds: 45),
        onTimeout: () {
          throw Exception('Upload timeout - server took too long to respond');
        },
      );

      final responseBody = await streamedResponse.stream.bytesToString();
      print('[Spaces] Response ${streamedResponse.statusCode}: ${responseBody.substring(0, responseBody.length > 300 ? 300 : responseBody.length)}');

      if (streamedResponse.statusCode != 200) {
        String detail = responseBody;
        try {
          final err = jsonDecode(responseBody);
          if (err is Map && err['error'] != null) detail = err['error'].toString();
        } catch (_) {}
        throw Exception('Upload failed (${streamedResponse.statusCode}): $detail');
      }

      final jsonResponse = jsonDecode(responseBody) as Map<String, dynamic>;
      final imageUrl =
          (jsonResponse['secureUrl'] ?? jsonResponse['url'])?.toString();
      if (imageUrl == null || imageUrl.isEmpty) {
        throw Exception('Invalid upload response - missing url: $responseBody');
      }

      print('[Spaces] Upload successful: $imageUrl');

      return ImageUploadResult(
        url: imageUrl,
        thumbnailUrl:
            (jsonResponse['thumbnailUrl'] ?? imageUrl).toString(),
        fileId: (jsonResponse['fileId'] ?? fileName).toString(),
        fileName: (jsonResponse['fileName'] ?? fileName).toString(),
      );
    } catch (e) {
      print('[Spaces] Upload error: $e');
      rethrow;
    }
  }

  /// Returns MIME type for supported image formats
  static String? _getMimeType(String fileName) {
    final extension = fileName.toLowerCase().split('.').last;
    const mimeTypes = {
      'jpg': 'image/jpeg',
      'jpeg': 'image/jpeg',
      'png': 'image/png',
      'webp': 'image/webp',
      'heic': 'image/heic',
      'heif': 'image/heif',
      'gif': 'image/gif',
      'bmp': 'image/bmp',
    };
    return mimeTypes[extension];
  }

  static String _useCaseValue(ImageUploadUseCase useCase) {
    switch (useCase) {
      case ImageUploadUseCase.profile:
        return 'profile';
      case ImageUploadUseCase.product:
        return 'product';
      case ImageUploadUseCase.shop:
        return 'shop';
      case ImageUploadUseCase.ad:
        return 'ad';
    }
  }

}
