import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

class LocationService {
  static Future<bool> _checkPermissions() async {
    bool serviceEnabled;
    LocationPermission permission;

    // Check if location services are enabled
    serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      Fluttertoast.showToast(
        msg: 'Location services are disabled. Please enable them in settings.',
        toastLength: Toast.LENGTH_LONG,
        gravity: ToastGravity.BOTTOM,
        backgroundColor: Colors.red,
        textColor: Colors.white,
      );
      return false;
    }

    // Check location permissions
    permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        Fluttertoast.showToast(
          msg: 'Location permission denied.',
          toastLength: Toast.LENGTH_SHORT,
          gravity: ToastGravity.BOTTOM,
          backgroundColor: Colors.red,
          textColor: Colors.white,
        );
        return false;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      Fluttertoast.showToast(
        msg: 'Location permissions are permanently denied. Please enable them in app settings.',
        toastLength: Toast.LENGTH_LONG,
        gravity: ToastGravity.BOTTOM,
        backgroundColor: Colors.red,
        textColor: Colors.white,
      );
      await Geolocator.openAppSettings();
      return false;
    }

    return true;
  }

  static Future<String?> getCurrentLocationAddress() async {
    try {
      // Show loading toast
      Fluttertoast.showToast(
        msg: 'Fetching your location...',
        toastLength: Toast.LENGTH_SHORT,
        gravity: ToastGravity.BOTTOM,
        backgroundColor: const Color(0xFFFF6B00),
        textColor: Colors.white,
      );

      // Check permissions first
      bool hasPermission = await _checkPermissions();
      if (!hasPermission) {
        return null;
      }

      // Get current position with highest accuracy
      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.bestForNavigation,
        timeLimit: Duration(seconds: 20),
      );

      // Use free Nominatim API for reverse geocoding
      String address = await _getAddressFromCoordinates(
        position.latitude,
        position.longitude,
      );
      
      if (address.isNotEmpty && address != 'Unable to fetch address') {
        Fluttertoast.showToast(
          msg: 'Location fetched successfully!',
          toastLength: Toast.LENGTH_SHORT,
          gravity: ToastGravity.BOTTOM,
          backgroundColor: Colors.green,
          textColor: Colors.white,
        );
        return address;
      } else {
        throw Exception('Could not fetch address');
      }
      
    } catch (e) {
      String errorMessage = 'Failed to fetch location';
      
      if (e is TimeoutException) {
        errorMessage = 'Location request timed out. Please try again.';
      } else if (e is LocationServiceDisabledException) {
        errorMessage = 'Location services are disabled.';
      } else if (e is PermissionDeniedException) {
        errorMessage = 'Location permission denied.';
      }
      
      Fluttertoast.showToast(
        msg: errorMessage,
        toastLength: Toast.LENGTH_LONG,
        gravity: ToastGravity.BOTTOM,
        backgroundColor: Colors.red,
        textColor: Colors.white,
      );
      
      return null;
    }
  }

  static Future<String> _getAddressFromCoordinates(double lat, double lng) async {
    try {
      // Using free Nominatim API with higher zoom for more precision
      final url = 'https://nominatim.openstreetmap.org/reverse?format=json&lat=$lat&lon=$lng&zoom=20&addressdetails=1&extratags=1';
      
      final response = await http.get(
        Uri.parse(url),
        headers: {
          'User-Agent': 'GharTek-Flutter-App',
          'Accept-Language': 'en',
        },
      ).timeout(Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        
        if (data != null && data['display_name'] != null) {
          // Try to format the address better with more details
          if (data['address'] != null) {
            final address = data['address'];
            List<String> addressParts = [];
            
            // Add building/house details first
            if (address['building'] != null) {
              addressParts.add(address['building']);
            }
            
            // Add house number and road
            if (address['house_number'] != null && address['road'] != null) {
              String roadPart = '${address['house_number']} ${address['road']}';
              addressParts.add(roadPart);
            } else if (address['road'] != null) {
              addressParts.add(address['road']);
            } else if (address['pedestrian'] != null) {
              addressParts.add(address['pedestrian']);
            }
            
            // Add more specific area details
            if (address['neighbourhood'] != null) {
              addressParts.add(address['neighbourhood']);
            } else if (address['suburb'] != null) {
              addressParts.add(address['suburb']);
            } else if (address['quarter'] != null) {
              addressParts.add(address['quarter']);
            } else if (address['residential'] != null) {
              addressParts.add(address['residential']);
            }
            
            // Add postal code if available
            if (address['postcode'] != null) {
              addressParts.add('Postal Code: ${address['postcode']}');
            }
            
            // Add city/town
            if (address['city'] != null) {
              addressParts.add(address['city']);
            } else if (address['town'] != null) {
              addressParts.add(address['town']);
            } else if (address['village'] != null) {
              addressParts.add(address['village']);
            } else if (address['municipality'] != null) {
              addressParts.add(address['municipality']);
            }
            
            // Add state/province
            if (address['state'] != null) {
              addressParts.add(address['state']);
            } else if (address['province'] != null) {
              addressParts.add(address['province']);
            }
            
            // Add country
            if (address['country'] != null) {
              addressParts.add(address['country']);
            }
            
            if (addressParts.isNotEmpty) {
              return addressParts.join(', ');
            }
          }
          
          return data['display_name'];
        }
      }
      
      // Try alternative API for better Pakistani addresses
      return await _getAddressFromAlternativeAPI(lat, lng);
      
    } catch (e) {
      // Fallback: try alternative API
      return await _getAddressFromAlternativeAPI(lat, lng);
    }
  }

  static Future<String> _getAddressFromAlternativeAPI(double lat, double lng) async {
    try {
      // Using LocationIQ which might have better Pakistani address data
      final url = 'https://us1.locationiq.com/v1/reverse.php?key=pk.0123456789abcdef&lat=$lat&lon=$lng&format=json&addressdetails=1&normalizecity=1';
      
      final response = await http.get(Uri.parse(url)).timeout(Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data != null && data['display_name'] != null) {
          return data['display_name'];
        }
      }
    } catch (e) {
      // If all APIs fail, return a formatted coordinate string
      return 'Near coordinates: ${lat.toStringAsFixed(6)}, ${lng.toStringAsFixed(6)}';
    }
    
    return 'Coordinates: ${lat.toStringAsFixed(4)}, ${lng.toStringAsFixed(4)}';
  }

  static Future<Map<String, dynamic>?> getCurrentLocationWithCoordinates() async {
    try {
      // Show loading toast
      Fluttertoast.showToast(
        msg: 'Fetching your location...',
        toastLength: Toast.LENGTH_SHORT,
        gravity: ToastGravity.BOTTOM,
        backgroundColor: const Color(0xFFFF6B00),
        textColor: Colors.white,
      );

      // Check permissions first
      bool hasPermission = await _checkPermissions();
      if (!hasPermission) {
        return null;
      }

      // Get current position with highest accuracy
      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.bestForNavigation,
        timeLimit: Duration(seconds: 20),
      );

      // Get address
      String address = await _getAddressFromCoordinates(
        position.latitude,
        position.longitude,
      );
      
      if (address.isNotEmpty && address != 'Unable to fetch address') {
        Fluttertoast.showToast(
          msg: 'Location fetched successfully!',
          toastLength: Toast.LENGTH_SHORT,
          gravity: ToastGravity.BOTTOM,
          backgroundColor: Colors.green,
          textColor: Colors.white,
        );
        
        return {
          'address': address,
          'latitude': position.latitude,
          'longitude': position.longitude,
        };
      } else {
        throw Exception('Could not fetch address');
      }
      
    } catch (e) {
      String errorMessage = 'Failed to fetch location';
      
      if (e is TimeoutException) {
        errorMessage = 'Location request timed out. Please try again.';
      } else if (e is LocationServiceDisabledException) {
        errorMessage = 'Location services are disabled.';
      } else if (e is PermissionDeniedException) {
        errorMessage = 'Location permission denied.';
      }
      
      Fluttertoast.showToast(
        msg: errorMessage,
        toastLength: Toast.LENGTH_LONG,
        gravity: ToastGravity.BOTTOM,
        backgroundColor: Colors.red,
        textColor: Colors.white,
      );
      
      return null;
    }
  }

  /// Silently fetch location — no toasts or error messages, system permission dialog only.
  /// Returns {address, latitude, longitude} or null on failure.
  static Future<Map<String, dynamic>?> getCurrentLocationSilently() async {
    try {
      LocationPermission perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.deniedForever ||
          perm == LocationPermission.denied) {
        return null;
      }

      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        // Open system location settings so the user can enable GPS.
        // This is a system-level navigation, not an app-level dialog.
        await Geolocator.openLocationSettings();
        return null;
      }

      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.bestForNavigation,
        timeLimit: const Duration(seconds: 20),
      );

      final address = await _getAddressFromCoordinates(
          position.latitude, position.longitude);
      return {
        'address': address,
        'latitude': position.latitude,
        'longitude': position.longitude,
      };
    } catch (_) {
      return null;
    }
  }

  // Function to open location in maps
  static Future<void> openLocationInMaps(double latitude, double longitude,
      {String? label, String? searchQuery}) async {
    try {
      final Uri uri;
      if (searchQuery != null && searchQuery.isNotEmpty) {
        final encodedQuery = Uri.encodeComponent(searchQuery);
        uri = Uri.parse(
            'https://www.google.com/maps/search/?api=1&query=$encodedQuery');
      } else {
        uri = Uri.parse(
            'https://www.google.com/maps/search/?api=1&query=$latitude,$longitude');
      }

      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } else {
        // Fallback
        final Uri fallback = searchQuery != null && searchQuery.isNotEmpty
            ? Uri.parse(
                'https://maps.google.com/?q=${Uri.encodeComponent(searchQuery)}')
            : Uri.parse('https://maps.google.com/?q=$latitude,$longitude');

        if (await canLaunchUrl(fallback)) {
          await launchUrl(fallback, mode: LaunchMode.externalApplication);
        } else {
          Fluttertoast.showToast(
            msg: 'Cannot open maps application',
            backgroundColor: Colors.red,
            textColor: Colors.white,
          );
        }
      }
    } catch (e) {
      Fluttertoast.showToast(
        msg: 'Error opening maps: $e',
        backgroundColor: Colors.red,
        textColor: Colors.white,
      );
    }
  }

  // Widget for admin to view location on map
  static Widget buildMapViewButton({
    required double latitude,
    required double longitude,
    String? label,
    Color? backgroundColor,
    Color? iconColor,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: backgroundColor ?? Colors.green,
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.1),
            blurRadius: 4,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => openLocationInMaps(latitude, longitude, label: label),
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: EdgeInsets.all(8),
            child: Tooltip(
              message: 'View location on map',
              child: Icon(
                Icons.map,
                color: iconColor ?? Colors.white,
                size: 20,
              ),
            ),
          ),
        ),
      ),
    );
  }

  static Widget buildLocationButton({
    required VoidCallback onPressed,
    Color? backgroundColor,
    Color? iconColor,
    double? iconSize,
    String? tooltip,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: backgroundColor ?? Color(0xFFFF6B00),
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.1),
            blurRadius: 4,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: EdgeInsets.all(8),
            child: Tooltip(
              message: tooltip ?? 'Fetch current location',
              child: Icon(
                Icons.my_location,
                color: iconColor ?? Colors.white,
                size: iconSize ?? 20,
              ),
            ),
          ),
        ),
      ),
    );
  }
}