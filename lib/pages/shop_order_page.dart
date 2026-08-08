import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:ghartek_flutter_app/services/db/app_database.dart';
import '../services/city_scope_service.dart';
import '../services/location_service.dart';

class ShopOrderPage extends StatefulWidget {
  final Map<String, dynamic> shop;

  const ShopOrderPage({super.key, required this.shop});

  @override
  State<ShopOrderPage> createState() => _ShopOrderPageState();
}

class _ShopOrderPageState extends State<ShopOrderPage> {
  final _formKey = GlobalKey<FormState>();
  final _database = FirebaseDatabase.instance.ref();
  String _tenantPath(String path) => CityScopeService.tenantPath(path);
  
  // Controllers
  final _itemsController = TextEditingController();
  final _addressController = TextEditingController();
  final _contactController = TextEditingController();
  final _specialInstructionsController = TextEditingController();
  final _budgetController = TextEditingController();
  
  String _urgency = 'Normal';
  String _paymentMethod = 'Cash on Delivery';
  bool _isLoading = false;
  List<Map<String, dynamic>> _menuItems = [];
  bool _isLoadingMenu = true;
  
  // Location coordinates
  double? _latitude;
  double? _longitude;
  
  // Delivery pricing
  final Map<String, Map<String, dynamic>> _deliveryOptions = {
    'Normal': {'price': 50, 'time': 40},
    'Fast': {'price': 70, 'time': 20},
  };

  @override
  void initState() {
    super.initState();
    CityScopeService.ensureLoaded();
    _loadUserInfo();
    _loadMenuItems();
  }

  Future<void> _loadUserInfo() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      try {
        final userSnapshot = await _database.child('users').child(user.uid).get();
        if (userSnapshot.exists) {
          final userData = userSnapshot.value as Map<dynamic, dynamic>;
          setState(() {
            _contactController.text = userData['phone'] ?? '';
            final address = (userData['address'] ?? '').toString().trim();
            if (address.isNotEmpty) {
              _addressController.text = address;
            }
          });
        }
      } catch (e) {
        print('Error loading user info: $e');
      }
    }
  }

  Future<void> _loadMenuItems() async {
    try {
      await CityScopeService.ensureLoaded();
      final menuSnapshot = await _database
          .child(_tenantPath('shops'))
          .child(widget.shop['id'])
          .child('menu')
          .get();
      
      if (menuSnapshot.exists) {
        final menuData = menuSnapshot.value as Map<dynamic, dynamic>;
        List<Map<String, dynamic>> items = [];
        
        menuData.forEach((key, value) {
          Map<String, dynamic> item = Map<String, dynamic>.from(value);
          item['id'] = key;
          items.add(item);
        });
        
        setState(() {
          _menuItems = items;
          _isLoadingMenu = false;
        });
      } else {
        setState(() {
          _isLoadingMenu = false;
        });
      }
    } catch (e) {
      print('Error loading menu: $e');
      setState(() {
        _isLoadingMenu = false;
      });
    }
  }

  Future<String> _generateOrderId() async {
    final now = DateTime.now();
    final year = now.year.toString().substring(2);
    final dateKey = '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}';
    await CityScopeService.ensureLoaded();
    final counterRef = _database.child(_tenantPath('meta/orderCounters/$dateKey'));

    final result = await counterRef.runTransaction((current) {
      final currentValue = current is int ? current : 0;
      return Transaction.success(currentValue + 1);
    });

    final counter = (result.snapshot.value as int?) ?? 1;
    final counterStr = counter.toString().padLeft(4, '0');
    return 'GT$year$counterStr';
  }

  Future<void> _submitOrder() async {

    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        throw Exception('User not logged in');
      }

      final orderCode = await _generateOrderId();
      await CityScopeService.ensureLoaded();
      final createdAtClient = DateTime.now().millisecondsSinceEpoch;

      // Create order data
      final orderData = {
        'userId': user.uid,
        'userEmail': user.email,
        'userName': user.displayName ?? user.email?.split('@')[0] ?? 'Unknown User',
        'shopId': widget.shop['id'],
        'shopName': widget.shop['name'],
        'items': _itemsController.text.trim(),
        'address': _addressController.text.trim(),
        'contact': _contactController.text.trim(),
        'specialInstructions': _specialInstructionsController.text.trim(),
        'budget': _budgetController.text.trim(),
        'urgency': _urgency,
        'deliveryPrice': _deliveryOptions[_urgency]!['price'],
        'estimatedTime': _deliveryOptions[_urgency]!['time'],
        'paymentMethod': _paymentMethod,
        'customOrderId': orderCode,
        'status': 'available',
        'adminApprovalStatus': 'approved',
        'merchantDecision': 'auto_approved_by_admin',
        'customerStatusMessage': 'Order placed. Waiting for rider pickup.',
        'adminApprovedAt': createdAtClient,
        'availableAt': createdAtClient,
        'createdAt': ServerValue.timestamp,
        'createdAtClient': createdAtClient,
        'orderType': 'shop',
      };

      // Add coordinates if available
      if (_latitude != null && _longitude != null) {
        orderData['latitude'] = _latitude;
        orderData['longitude'] = _longitude;
        orderData['autoLatitude'] = _latitude;
        orderData['autoLongitude'] = _longitude;
        orderData['autoAddress'] = _addressController.text.trim();
        print('Shop Order - Saving with coordinates: Lat: $_latitude, Long: $_longitude');
      } else {
        print('Shop Order - No coordinates to save');
      }

      // Save to Firebase
      final orderRef = _database.child(_tenantPath('shop-orders')).push();
      await orderRef.set(orderData);

      final details = {
        'orderId': orderRef.key,
        'orderCode': orderCode,
        'shopId': widget.shop['id'],
        'shopName': widget.shop['name'],
        'customerName': orderData['userName'],
        'status': 'available',
        'budget': _budgetController.text.trim(),
      };

      await _database.child(_tenantPath('notifications/user/${user.uid}')).push().set({
        'title': 'Order Placed Successfully',
        'body': 'Order $orderCode from ${(widget.shop['name'] ?? 'Shop').toString()} is submitted and now visible to riders.',
        'details': details,
        'createdAt': ServerValue.timestamp,
        'read': false,
      });

      await _database.child(_tenantPath('notifications/admin/inbox')).push().set({
        'title': 'New Shop Order',
        'body': 'Order $orderCode received and sent to rider queue.',
        'details': details,
        'createdAt': ServerValue.timestamp,
        'read': false,
      });

      // Debug: Print entire order data
      print('Shop Order saved to Firebase: $orderData');

      // Clear the form
      _clearForm();

      // Show success message
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Order placed successfully! Form cleared for new order.'),
            backgroundColor: Colors.green,
          ),
        );
        Navigator.pop(context, true); // Return true to indicate success
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error placing order: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _fetchCurrentLocation() async {
    final locationData = await LocationService.getCurrentLocationWithCoordinates();
    if (locationData != null && mounted) {
      setState(() {
        _addressController.text = locationData['address'] ?? '';
        _latitude = locationData['latitude'];
        _longitude = locationData['longitude'];
      });
      
      // Debug print to verify coordinates are saved
      print('Shop Order - Location fetched: ${locationData['address']}');
      print('Shop Order - Latitude: $_latitude, Longitude: $_longitude');
      
      // Show confirmation with coordinates
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Location saved: ${_latitude?.toStringAsFixed(6)}, ${_longitude?.toStringAsFixed(6)}'),
          backgroundColor: Colors.green,
          duration: Duration(seconds: 2),
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to fetch location. Please try again.'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  void _clearForm() {
    _itemsController.clear();
    _addressController.clear();
    _contactController.clear();
    _specialInstructionsController.clear();
    _budgetController.clear();
    setState(() {
      _urgency = 'Normal';
      _paymentMethod = 'Cash on Delivery';
      _latitude = null;
      _longitude = null;
    });
  }

  @override
  void dispose() {
    _itemsController.dispose();
    _addressController.dispose();
    _contactController.dispose();
    _specialInstructionsController.dispose();
    _budgetController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Order from ${widget.shop['name'] ?? 'Shop'}'),
        backgroundColor: Color(0xFFFF6B00),
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Shop Info Card
            Card(
              elevation: 3,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Container(
                      width: 60,
                      height: 60,
                      decoration: BoxDecoration(
                        color: Color(0xFFFF6B00).withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(
                        Icons.restaurant,
                        color: Color(0xFFFF6B00),
                        size: 30,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.shop['name'] ?? 'Unknown Shop',
                            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          if (widget.shop['description'] != null) ...[
                            const SizedBox(height: 4),
                            Text(
                              widget.shop['description'],
                              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                color: Colors.grey[600],
                              ),
                            ),
                          ],
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              if (widget.shop['rating'] != null) ...[
                                Icon(Icons.star, color: Colors.amber, size: 16),
                                const SizedBox(width: 4),
                                Text(widget.shop['rating'].toString()),
                                const SizedBox(width: 16),
                              ],
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: (widget.shop['isOpen'] == true) ? Colors.green : Colors.red,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Text(
                                  (widget.shop['isOpen'] == true) ? 'Open' : 'Closed',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 24),

            // Menu Section (if available)
            if (!_isLoadingMenu && _menuItems.isNotEmpty) ...[
              Text(
                'Menu Items',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: 120,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  itemCount: _menuItems.length,
                  itemBuilder: (context, index) {
                    final item = _menuItems[index];
                    return Card(
                      margin: const EdgeInsets.only(right: 12),
                      child: Container(
                        width: 150,
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              item['name'] ?? 'Item',
                              style: const TextStyle(fontWeight: FontWeight.bold),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 4),
                            if (item['price'] != null)
                              Text(
                                'Rs. ${item['price']}',
                                style: TextStyle(
                                  color: Color(0xFFFF6B00),
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            const Spacer(),
                            ElevatedButton(
                              onPressed: () {
                                if (_itemsController.text.isNotEmpty) {
                                  _itemsController.text += ', ${item['name']}';
                                } else {
                                  _itemsController.text = item['name'];
                                }
                              },
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Color(0xFFFF6B00),
                                foregroundColor: Colors.white,
                                minimumSize: const Size(double.infinity, 30),
                              ),
                              child: const Text('Add', style: TextStyle(fontSize: 12)),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 24),
            ],

            // Order Form
            Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Order Details',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 16),

                  _buildTextField(
                    controller: _itemsController,
                    label: 'Items to Order',
                    hint: 'What would you like to order from this shop?',
                    icon: Icons.shopping_cart,
                    maxLines: 3,
                    required: true,
                  ),

                  const SizedBox(height: 16),

                  // Address field with location requirements
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildTextField(
                        controller: _addressController,
                        label: 'Delivery Address',
                        hint: 'Click location button for exact address',
                        icon: Icons.location_on,
                        maxLines: 2,
                        required: true,
                        suffixIcon: LocationService.buildLocationButton(
                          onPressed: _fetchCurrentLocation,
                          tooltip: 'Fetch exact location',
                        ),
                      ),
                      if (_latitude != null && _longitude != null) ...[
                        Container(
                          margin: EdgeInsets.only(top: 8),
                          padding: EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: Colors.green.shade50,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.green.shade200),
                          ),
                          child: Row(
                            children: [
                              Icon(Icons.check_circle, color: Colors.green, size: 16),
                              SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'Exact location saved: ${_latitude!.toStringAsFixed(6)}, ${_longitude!.toStringAsFixed(6)}',
                                  style: TextStyle(color: Colors.green.shade700, fontSize: 12),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ] else ...[
                        Container(
                          margin: EdgeInsets.only(top: 8),
                          padding: EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: Colors.orange.shade50,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.orange.shade200),
                          ),
                          child: Row(
                            children: [
                              Icon(Icons.warning, color: Colors.orange, size: 16),
                              SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'For exact location, please click the location button (📍)',
                                  style: TextStyle(color: Colors.orange.shade700, fontSize: 12),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),

                  const SizedBox(height: 16),

                  _buildTextField(
                    controller: _contactController,
                    label: 'Contact Number',
                    hint: 'Your phone number',
                    icon: Icons.phone,
                    keyboardType: TextInputType.phone,
                    required: true,
                  ),

                  const SizedBox(height: 16),

                  _buildTextField(
                    controller: _budgetController,
                    label: 'Budget (Optional)',
                    hint: 'Your budget for this order',
                    icon: Icons.attach_money,
                    keyboardType: TextInputType.number,
                  ),

                  const SizedBox(height: 16),

                  _buildTextField(
                    controller: _specialInstructionsController,
                    label: 'Special Instructions',
                    hint: 'Any special instructions for the delivery',
                    icon: Icons.note,
                    maxLines: 2,
                  ),

                  const SizedBox(height: 24),

                  // Preferences
                  Text(
                    'Delivery Options',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 16),

                  _buildDeliveryOptions(),

                  const SizedBox(height: 16),

                  _buildDropdownField(
                    label: 'Payment Method',
                    value: _paymentMethod,
                    icon: Icons.payment,
                    items: ['Cash on Delivery', 'Online Payment', 'Bank Transfer'],
                    onChanged: (value) => setState(() => _paymentMethod = value!),
                  ),

                  const SizedBox(height: 32),

                  // Submit Button
                  SizedBox(
                    width: double.infinity,
                    height: 56,
                    child: ElevatedButton(
                      onPressed: _isLoading ? null : _submitOrder,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Color(0xFFFF6B00),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        elevation: 2,
                      ),
                      child: _isLoading
                          ? const CircularProgressIndicator(color: Colors.white)
                          : Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.shopping_bag),
                                const SizedBox(width: 8),
                                Text(
                                  'Place Order',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                    ),
                  ),

                  const SizedBox(height: 24),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    required String hint,
    required IconData icon,
    int maxLines = 1,
    TextInputType? keyboardType,
    bool required = false,
    Widget? suffixIcon,
  }) {
    return TextFormField(
      controller: controller,
      decoration: InputDecoration(
        labelText: label + (required ? ' *' : ''),
        hintText: hint,
        prefixIcon: Icon(icon, color: Color(0xFFFF6B00)),
        suffixIcon: suffixIcon,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Color(0xFFFF6B00), width: 2),
        ),
        filled: true,
        fillColor: Colors.grey[50]!,
      ),
      maxLines: maxLines,
      keyboardType: keyboardType,
      maxLength: keyboardType == TextInputType.phone ? 11 : null,
      inputFormatters: keyboardType == TextInputType.phone ? [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(11)] : null,
      validator: required
          ? (value) {
              if (value == null || value.trim().isEmpty) {
                return 'This field is required';
              }
              return null;
            }
          : null,
    );
  }

  Widget _buildDeliveryOptions() {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: _buildDeliveryOptionCard(
                'Normal',
                'Rs. 50',
                '40 minutes',
                Icons.local_shipping,
                Color(0xFFFF6B00), // Teal
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _buildDeliveryOptionCard(
                'Fast',
                'Rs. 70',
                '20 minutes',
                Icons.flash_on,
                Color(0xFFFF6B00), // Light blue
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildDeliveryOptionCard(
    String type,
    String price,
    String time,
    IconData icon,
    Color color,
  ) {
    final isSelected = _urgency == type;
    
    return GestureDetector(
      onTap: () => setState(() => _urgency = type),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: isSelected ? color.withValues(alpha: 0.1) : const Color(0xFFF5EFFF), // Very light cyan
          border: Border.all(
            color: isSelected ? color : Colors.grey[300]!,
            width: isSelected ? 2 : 1,
          ),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          children: [
            Icon(
              icon,
              color: isSelected ? color : Colors.grey[600]!,
              size: 32,
            ),
            const SizedBox(height: 8),
            Text(
              type,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 16,
                color: isSelected ? color : Colors.grey[800]!,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              price,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 18,
                color: isSelected ? color : Colors.grey[700]!,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              time,
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey[600]!,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDropdownField({
    required String label,
    required String value,
    required IconData icon,
    required List<String> items,
    required ValueChanged<String?> onChanged,
  }) {
    return DropdownButtonFormField<String>(
      initialValue: value,
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon, color: Color(0xFFFF6B00)),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Color(0xFFFF6B00), width: 2),
        ),
        filled: true,
        fillColor: Colors.grey[50]!,
      ),
      items: items.map((String item) {
        return DropdownMenuItem<String>(
          value: item,
          child: Text(item),
        );
      }).toList(),
      onChanged: onChanged,
    );
  }
}
