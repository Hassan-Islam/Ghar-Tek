# GharTek — Flutter Delivery App

A full-featured local food & shop delivery platform built with Flutter and Firebase. Supports customer-facing ordering, live location, promos, and a comprehensive admin panel.

---

## Features

### Customer App
- **Home Page**: Firebase-powered ad banners (auto-swipe every 4s, up to 3 ads), search icon opens full-screen search modal with category filters
- **Shop Browsing**: Scroll-down hides search bar (scroll-hide/show animation)
- **Cart**: Live item count badge, 3-second auto-dismiss "Added to cart" toast
- **Checkout**:
  - Auto-fetches live GPS location on page open (mandatory address validation)
  - Functional promo code validation (enabled check, expiry, per-user limit, min order, % or flat discount)
  - Dynamic tax % and delivery fee loaded from Firebase (`settings/fees`)
  - Admin-controlled payment methods loaded from Firebase (`settings/payment-methods`)
- **Order History**: Only delivered orders appear — active orders show inline status only
- **Notifications**: User-specific order status notifications (per UID), plus admin broadcasts

### Admin Panel
- **Dashboard**: Live stats (shops, users, orders, pending, revenue), recent orders list, pending deletion alerts
- **Orders**: Full order details with customer contact info and one-tap call button
- **Cash Management**: Revenue breakdown, order stats, profit/loss report
- **Push Notifications**: Broadcast to all users via Firebase
- **User Management** (`AdminSettingsPage`): Admins, all users, deletion requests (3 tabs)
- **App Settings** (`AdminAppSettingsPage`) — 4 tabs:
  | Tab | What you can manage |
  |-----|---------------------|
  | **Fees** | Delivery fee, tax %, free-delivery threshold |
  | **Promos** | Add/edit/delete promo codes (%, flat, expiry, per-user limits) |
  | **Payment** | Enable/disable payment methods, edit labels |
  | **Ads** | Set image URL, title, subtitle for up to 3 home-page ad banners |

---

## Firebase Realtime Database Paths

| Path | Description |
|------|-------------|
| `settings/fees` | `deliveryFee`, `taxPercent`, `freeDeliveryAbove` |
| `settings/promo-codes/{CODE}` | Promo code data (value, type, expiry, usedBy, …) |
| `settings/payment-methods/{key}` | Payment method enabled/label |
| `settings/ads/{0,1,2}` | Ad banner imageUrl, title, subtitle |
| `notifications/broadcast` | Admin-to-all broadcast notifications |
| `notifications/user/{uid}` | Per-user order status notifications |
| `shop-orders` | All shop orders |
| `custom-orders` | All custom delivery orders |
| `shops` | Shop listings |
| `users` | Registered users |

---

## Tech Stack
- **Flutter** 3.x
- **Firebase** — Authentication, Realtime Database
- **Packages**: `url_launcher`, `geolocator`, `geocoding`, `google_sign_in`, `firebase_messaging`, `flutter_local_notifications`, `fluttertoast`, `shared_preferences`

---

## Build

```bash
# Debug
flutter run

# Release APK
flutter build apk --release

# Release AAB (for Play Store)
flutter build appbundle --release
```

Signed keystore is configured in `android/key.properties`.
