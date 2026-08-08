import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';

/// Helpers for rendering remote images.
/// Uses [CachedNetworkImage] so images are stored on-device and load instantly
/// after the first download.
class ImageHelper {
  /// Normalize URLs before rendering.
  static String getDirectImageUrl(String url) {
    var value = url.trim();
    if (value.isEmpty || value.toLowerCase() == 'null') return '';

    if ((value.startsWith('"') && value.endsWith('"')) ||
        (value.startsWith("'") && value.endsWith("'"))) {
      value = value.substring(1, value.length - 1).trim();
    }

    // Handle escaped strings from JSON payloads (for example: https:\/\/...)
    value = value
        .replaceAll(r'\\/', '/')
        .replaceAll(r'\/', '/')
        .replaceAll(r'\u002F', '/')
        .replaceAll('&amp;', '&');

    // Some payloads keep the full URL encoded.
    if (!value.startsWith('http://') &&
        !value.startsWith('https://') &&
        (value.contains('%3A%2F%2F') || value.contains('%3a%2f%2f'))) {
      try {
        value = Uri.decodeFull(value);
      } catch (_) {}
    }

    final hasDirectPrefix = value.startsWith('http://') ||
        value.startsWith('https://') ||
        value.startsWith('//') ||
        value.startsWith('res.cloudinary.com/') ||
        value.startsWith('cloudinary.com/') ||
        value.startsWith('firebasestorage.googleapis.com/');

    // Legacy payloads can store URL objects as stringified maps.
    if (!hasDirectPrefix) {
      final embeddedUrlMatch = RegExp(
        r'(https?:\/\/[^\s,}\]"\\]+|\/\/[^\s,}\]"\\]+|(?:res\.cloudinary\.com|firebasestorage\.googleapis\.com)\/[^\s,}\]"\\]+)',
      ).firstMatch(value);
      if (embeddedUrlMatch != null) {
        value = embeddedUrlMatch.group(0)?.trim() ?? value;
      }
    }

    if (value.startsWith('gs://')) {
      final raw = value.substring(5);
      final sep = raw.indexOf('/');
      if (sep > 0 && sep < raw.length - 1) {
        final bucket = raw.substring(0, sep);
        final objectPath = raw.substring(sep + 1);
        final encodedPath = Uri.encodeComponent(objectPath);
        value =
            'https://firebasestorage.googleapis.com/v0/b/$bucket/o/$encodedPath?alt=media';
      }
    }

    if (value.startsWith('//')) {
      value = 'https:$value';
    }

    if (value.startsWith('http://res.cloudinary.com') ||
        value.startsWith('http://cloudinary.com')) {
      value = 'https://${value.substring('http://'.length)}';
    }

    if (!value.startsWith('http://') && !value.startsWith('https://')) {
      if (value.startsWith('res.cloudinary.com/') ||
          value.startsWith('cloudinary.com/') ||
          value.startsWith('firebasestorage.googleapis.com/')) {
        value = 'https://$value';
      } else {
        final looksLikeHost =
            RegExp(r'^[A-Za-z0-9.-]+\.[A-Za-z]{2,}([/:?#].*)?$').hasMatch(value);
        if (looksLikeHost) {
          value = 'https://$value';
        }
      }
    }

    // Spaces in Firebase strings commonly break URI parsing.
    value = value.replaceAll(' ', '%20');

    final parsed = Uri.tryParse(value);
    if (parsed == null) return '';
    final scheme = parsed.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') return '';
    if (parsed.host.isEmpty) return '';
    return parsed.toString();
  }

  /// Build a network image widget with caching and fallback.
  /// Images are cached on-device after the first download — subsequent loads are instant.
  static Widget networkImage({
    required String url,
    double? width,
    double? height,
    BoxFit fit = BoxFit.cover,
    Alignment alignment = Alignment.center,
    BorderRadius? borderRadius,
    Widget? placeholder,
    Widget? errorWidget,
  }) {
    final directUrl = getDirectImageUrl(url);
    final safeWidth = (width != null && width.isFinite && width > 0) ? width : null;
    final safeHeight = (height != null && height.isFinite && height > 0) ? height : null;

    if (directUrl.isEmpty) {
      return errorWidget ??
          Container(
            width: safeWidth,
            height: safeHeight,
            color: Colors.orange[50],
            child: const Center(
              child: Icon(Icons.image_outlined, color: Colors.orange, size: 32),
            ),
          );
    }

    final cacheWidth = safeWidth != null ? (safeWidth * 2).round() : null;
    final cacheHeight = safeHeight != null ? (safeHeight * 2).round() : null;

    Widget image = CachedNetworkImage(
      imageUrl: directUrl,
      width: safeWidth,
      height: safeHeight,
      fit: fit,
      alignment: alignment,
      memCacheWidth: cacheWidth,
      memCacheHeight: cacheHeight,
      maxWidthDiskCache: cacheWidth,
      maxHeightDiskCache: cacheHeight,
      fadeInDuration: const Duration(milliseconds: 180),
      placeholder: (context, url) =>
          placeholder ??
          Container(
            width: safeWidth,
            height: safeHeight,
            color: Colors.orange[50],
            child: const Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Color(0xFFFF6B00),
                ),
              ),
            ),
          ),
      errorWidget: (context, url, error) =>
          errorWidget ??
          Container(
            width: safeWidth,
            height: safeHeight,
            color: Colors.orange[50],
            child: const Center(
              child: Icon(Icons.broken_image_outlined,
                  color: Colors.orange, size: 32),
            ),
          ),
    );

    if (borderRadius != null) {
      image = ClipRRect(borderRadius: borderRadius, child: image);
    }

    return image;
  }

  /// Warm-up top image URLs so first app-open feels faster.
  static Future<void> precacheImageUrls(
    BuildContext context,
    Iterable<String> urls, {
    int limit = 12,
  }) async {
    var count = 0;
    for (final rawUrl in urls) {
      final directUrl = getDirectImageUrl(rawUrl);
      if (directUrl.isEmpty) continue;
      try {
        await precacheImage(CachedNetworkImageProvider(directUrl), context);
      } catch (_) {}
      count++;
      if (count >= limit) break;
    }
  }
}
