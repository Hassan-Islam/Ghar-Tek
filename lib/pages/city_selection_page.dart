import 'package:flutter/material.dart';
import 'package:ghartek_flutter_app/pages/splash_screen.dart';
import 'package:ghartek_flutter_app/services/city_scope_service.dart';
import 'package:ghartek_flutter_app/services/tenant_data_migration_service.dart';

class CitySelectionPage extends StatefulWidget {
  const CitySelectionPage({super.key});

  @override
  State<CitySelectionPage> createState() => _CitySelectionPageState();
}

class _CitySelectionPageState extends State<CitySelectionPage> {
  String _selectedCity = CityScopeService.defaultCity;
  bool _saving = false;

  static const List<Map<String, String>> _cities = [
    {'key': CityScopeService.vehari, 'label': 'Vehari'},
    {'key': CityScopeService.islamabad, 'label': 'Islamabad (QAU)'},
  ];

  @override
  void initState() {
    super.initState();
    CityScopeService.loadFixedCities();
    _load();
  }

  Future<void> _load() async {
    final city = await CityScopeService.getSelectedCity();
    if (!mounted) return;
    final exists = _cities.any((c) => c['key'] == city);
    setState(() {
      _selectedCity = exists ? city : CityScopeService.defaultCity;
    });
  }

  Future<void> _continue() async {
    setState(() => _saving = true);
    await CityScopeService.setSelectedCity(_selectedCity);
    try {
      await TenantDataMigrationService.migrateLegacyDataForCity(
        city: _selectedCity,
      );
    } catch (_) {}
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const SplashScreen()),
    );
  }

  Widget _cityOptionTile({required String city, required String label}) {
    final isSelected = _selectedCity == city;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      enabled: !_saving,
      leading: Icon(
        isSelected
            ? Icons.radio_button_checked_rounded
            : Icons.radio_button_off_rounded,
        color: isSelected ? const Color(0xFFFF6B00) : Colors.grey[500],
      ),
      title: Text(label),
      onTap: _saving ? null : () => setState(() => _selectedCity = city),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color(0xFFFFF8E1),
              Color(0xFFFBE9E7),
            ],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Card(
                margin: const EdgeInsets.all(20),
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.location_city, size: 44, color: Colors.brown),
                      const SizedBox(height: 12),
                      Text(
                        'Select Your City',
                        style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Choose Vehari or Islamabad (QAU).',
                        style: theme.textTheme.bodyMedium,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 16),
                      ..._cities.map((entry) => _cityOptionTile(
                            city: entry['key']!,
                            label: entry['label']!,
                          )),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: _saving ? null : _continue,
                          icon: _saving
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Icon(Icons.arrow_forward),
                          label: Text(_saving ? 'Saving & Syncing...' : 'Continue'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
