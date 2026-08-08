import 'dart:async';
import 'package:flutter/material.dart';
import '../widgets/product_detail_bottom_sheet.dart';
import '../services/analytics_service.dart';
import '../services/image_helper.dart';

class GlobalSearchPage extends StatefulWidget {
  final List<Map<String, dynamic>> allItems;
  final List<Map<String, dynamic>> shops;
  final Color primary;
  final String? initialQuery;

  const GlobalSearchPage({
    super.key,
    required this.allItems,
    required this.shops,
    this.primary = const Color(0xFFFF6B00),
    this.initialQuery,
  });

  @override
  State<GlobalSearchPage> createState() => _GlobalSearchPageState();
}

class _GlobalSearchPageState extends State<GlobalSearchPage> {
  late final TextEditingController _searchController;
  final ScrollController _scrollController = ScrollController();
  
  List<Map<String, dynamic>> _filteredResults = [];
  List<Map<String, dynamic>> _displayedResults = [];
  
  bool _isLoading = false;
  bool _isLoadingMore = false;
  Timer? _debounce;
  
  final int _itemsPerPage = 12;
  int _currentPage = 1;

  final List<String> _suggestions = [
    'Biryani',
    'Burger',
    'FastFood',
    'Pizza',
    'Chinese',
    'Sweets',
    'Groceries',
    'Chicken',
  ];

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController(text: widget.initialQuery ?? '');
    _scrollController.addListener(_onScroll);
    if (_searchController.text.isNotEmpty) {
      _performSearch(_searchController.text);
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    _scrollController.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >= _scrollController.position.maxScrollExtent - 100) {
      _loadMore();
    }
  }

  void _onSearchChanged(String query) {
    if (_debounce?.isActive ?? false) _debounce!.cancel();
    
    if (query.trim().isEmpty) {
      setState(() {
        _filteredResults = [];
        _displayedResults = [];
        _isLoading = false;
      });
      return;
    }

    setState(() {
      _isLoading = true;
    });

    _debounce = Timer(const Duration(milliseconds: 600), () {
      _performSearch(query);
    });
  }

  Future<void> _performSearch(String query) async {
    final lowerQuery = query.toLowerCase().trim();
    if (lowerQuery.isEmpty) return;

    AnalyticsService.search(lowerQuery, 0);

    // Filter Items
    final matchedItems = widget.allItems.where((item) {
      final name = (item['name'] ?? '').toString().toLowerCase();
      final category = (item['category'] ?? '').toString().toLowerCase();
      final tags = (item['tags'] as List<dynamic>?)?.map((e) => e.toString().toLowerCase()).toList() ?? [];
      
      return name.contains(lowerQuery) || 
             category.contains(lowerQuery) ||
             tags.any((t) => t.contains(lowerQuery));
    }).map((item) {
      final res = Map<String, dynamic>.from(item);
      res['isShop'] = false;
      return res;
    }).toList();

    // Filter Shops
    final matchedShops = widget.shops.where((shop) {
      final name = (shop['name'] ?? '').toString().toLowerCase();
      final description = (shop['description'] ?? '').toString().toLowerCase();
      final categories = (shop['categories'] as List<dynamic>?)?.map((e) => e.toString().toLowerCase()).toList() ?? [];

      return name.contains(lowerQuery) ||
             description.contains(lowerQuery) ||
             categories.any((c) => c.contains(lowerQuery));
    }).map((shop) {
      final res = Map<String, dynamic>.from(shop);
      res['isShop'] = true;
      return res;
    }).toList();

    // Combine and sort
    final combined = [...matchedShops, ...matchedItems];
    
    combined.sort((a, b) {
      final aIsShop = a['isShop'] == true;
      final bIsShop = b['isShop'] == true;
      if (aIsShop && !bIsShop) return -1;
      if (!aIsShop && bIsShop) return 1;
      return 0;
    });

    // Simulated Loading Delay
    await Future.delayed(const Duration(milliseconds: 400));

    if (mounted) {
      setState(() {
        _filteredResults = combined;
        _currentPage = 1;
        _displayedResults = _filteredResults.take(_itemsPerPage).toList();
        _isLoading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_isLoadingMore || _displayedResults.length >= _filteredResults.length) return;

    setState(() {
      _isLoadingMore = true;
    });

    // Simulate network delay for pagination
    await Future.delayed(const Duration(milliseconds: 600));

    if (mounted) {
      setState(() {
        _currentPage++;
        final nextItems = _filteredResults.take(_currentPage * _itemsPerPage).toList();
        _displayedResults = nextItems;
        _isLoadingMore = false;
      });
    }
  }

  void _openItemDetail(Map<String, dynamic> item) {
    if (item['isShop'] == true) {
      Navigator.pop(context, {'type': 'shop', 'data': item});
    } else {
      showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (ctx) => ProductDetailBottomSheet(
          product: item,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.black87),
          onPressed: () => Navigator.pop(context),
        ),
        titleSpacing: 0,
        title: Padding(
          padding: const EdgeInsets.only(right: 16),
          child: Container(
            height: 44,
            decoration: BoxDecoration(
              color: const Color(0xFFF5F5F5),
              borderRadius: BorderRadius.circular(12),
            ),
            child: TextField(
              controller: _searchController,
              onChanged: _onSearchChanged,
              autofocus: true,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: Colors.black87,
              ),
              decoration: InputDecoration(
                hintText: 'Search Biryani, Burgers, Shops...',
                hintStyle: TextStyle(
                  color: Colors.grey[500],
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                prefixIcon: const Icon(Icons.search_rounded, color: Colors.grey, size: 20),
                suffixIcon: _searchController.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.close_rounded, color: Colors.grey, size: 18),
                        onPressed: () {
                          _searchController.clear();
                          _onSearchChanged('');
                        },
                      )
                    : null,
              ),
            ),
          ),
        ),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_searchController.text.trim().isEmpty) {
      return _buildSuggestions();
    }

    if (_isLoading) {
      return const Center(
        child: CircularProgressIndicator(color: Color(0xFFFF6B00)),
      );
    }

    if (_filteredResults.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.search_off_rounded, size: 80, color: Colors.grey[300]),
            const SizedBox(height: 16),
            const Text(
              'No results found',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: Colors.black87,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Try searching for something else.',
              style: TextStyle(
                fontSize: 14,
                color: Colors.grey[500],
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Text(
                '${_filteredResults.length} Results Found',
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: Colors.black87,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            controller: _scrollController,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 100),
            itemCount: _displayedResults.length + (_isLoadingMore ? 1 : 0),
            itemBuilder: (context, index) {
              if (index == _displayedResults.length) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Center(
                    child: SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFFFF6B00)),
                    ),
                  ),
                );
              }
              final item = _displayedResults[index];
              return _buildResultCard(item);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildResultCard(Map<String, dynamic> item) {
    final isShop = item['isShop'] == true;
    final name = (item['name'] ?? 'Unknown').toString();
    final image = (item['image'] ?? item['imageUrl'] ?? '').toString();
    final desc = (item['description'] ?? '').toString();

    return GestureDetector(
      onTap: () => _openItemDetail(item),
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.grey.shade100),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.02),
              blurRadius: 8,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: Colors.grey[100],
                borderRadius: BorderRadius.circular(12),
              ),
              clipBehavior: Clip.hardEdge,
              child: image.isNotEmpty
                  ? ImageHelper.networkImage(
                      url: image,
                      width: 80,
                      height: 80,
                      fit: BoxFit.cover,
                    )
                  : Icon(isShop ? Icons.storefront_rounded : Icons.fastfood_rounded, color: Colors.grey[400], size: 30),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (isShop)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      margin: const EdgeInsets.only(bottom: 4),
                      decoration: BoxDecoration(
                        color: Colors.blue.shade50,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Text('SHOP', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: Colors.blue)),
                    ),
                  Text(
                    name,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: Colors.black87),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  if (desc.isNotEmpty)
                    Text(
                      desc,
                      style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  if (!isShop && item['price'] != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      'Rs. ${item['price']}',
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: Color(0xFFFF6B00)),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(Icons.arrow_forward_ios_rounded, size: 14, color: Colors.grey[300]),
          ],
        ),
      ),
    );
  }

  Widget _buildSuggestions() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Popular Searches',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              color: Colors.black87,
            ),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 10,
            runSpacing: 12,
            children: _suggestions.map((sug) {
              return InkWell(
                onTap: () {
                  _searchController.text = sug;
                  _onSearchChanged(sug);
                },
                borderRadius: BorderRadius.circular(20),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    border: Border.all(color: Colors.grey.shade200),
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.02),
                        blurRadius: 4,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.trending_up_rounded, size: 16, color: widget.primary),
                      const SizedBox(width: 6),
                      Text(
                        sug,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: Colors.black87,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }
}
