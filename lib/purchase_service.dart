import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_storekit/in_app_purchase_storekit.dart';
import 'package:in_app_purchase_storekit/store_kit_2_wrappers.dart';
import 'package:shared_preferences/shared_preferences.dart';

class PurchaseService {
  static const String monthlyId = 'premium_monthly';
  static const String yearlyId = 'premium_yearly';
  static const String _premiumKey = 'is_premium';

  PurchaseService._();
  static final instance = PurchaseService._();

  bool _isPremium = false;
  bool get isPremium => _isPremium;

  ProductDetails? _monthlyProductDetails;
  ProductDetails? _yearlyProductDetails;
  String? get monthlyPrice => _monthlyProductDetails?.price;
  String? get yearlyPrice => _yearlyProductDetails?.price;

  final _controller = StreamController<bool>.broadcast();
  Stream<bool> get stream => _controller.stream;

  StreamSubscription<List<PurchaseDetails>>? _sub;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _isPremium = prefs.getBool(_premiumKey) ?? false;
    _sub = InAppPurchase.instance.purchaseStream.listen(_onUpdate);
    InAppPurchase.instance.queryProductDetails({monthlyId, yearlyId}).then((r) {
      for (final p in r.productDetails) {
        if (p.id == monthlyId) _monthlyProductDetails = p;
        if (p.id == yearlyId) _yearlyProductDetails = p;
      }
    });
    await refreshEntitlement();
  }

  /// Re-derives premium from the App Store so expired, cancelled or refunded
  /// subscriptions stop unlocking premium. Keeps the cached value if offline.
  Future<void> refreshEntitlement() async {
    if (!Platform.isIOS) return;
    try {
      final transactions = await SK2Transaction.transactions();
      final now = DateTime.now().millisecondsSinceEpoch;
      final active = transactions.any((t) {
        if (t.productId != monthlyId && t.productId != yearlyId) return false;
        final json = t.jsonRepresentation;
        if (json == null) return false;
        final data = jsonDecode(json) as Map<String, dynamic>;
        // Parse epoch millis from the signed JSON; the string date fields follow
        // the device calendar (e.g. Buddhist year 2569) and are unreliable.
        final expires = data['expiresDate'] as num?;
        return data['revocationDate'] == null && expires != null && expires > now;
      });
      await _setPremium(active);
    } catch (_) {}
  }

  Future<void> _setPremium(bool value) async {
    if (_isPremium == value) return;
    _isPremium = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_premiumKey, value);
    _controller.add(value);
  }

  void _onUpdate(List<PurchaseDetails> list) async {
    for (final p in list) {
      if (p.productID != monthlyId && p.productID != yearlyId) continue;
      if (p.status == PurchaseStatus.purchased || p.status == PurchaseStatus.restored) {
        await _setPremium(true);
      }
      if (p.pendingCompletePurchase) {
        await InAppPurchase.instance.completePurchase(p);
      }
    }
  }

  Future<void> buyMonthly() async {
    if (!await InAppPurchase.instance.isAvailable()) {
      throw Exception('Store not available');
    }
    if (_monthlyProductDetails == null) {
      final r = await InAppPurchase.instance.queryProductDetails({monthlyId});
      if (r.productDetails.isEmpty) {
        throw Exception('Product not found: $monthlyId');
      }
      _monthlyProductDetails = r.productDetails.first;
    }
    await InAppPurchase.instance.buyNonConsumable(
      purchaseParam: PurchaseParam(productDetails: _monthlyProductDetails!),
    );
  }

  Future<void> buyYearly() async {
    if (!await InAppPurchase.instance.isAvailable()) {
      throw Exception('Store not available');
    }
    if (_yearlyProductDetails == null) {
      final r = await InAppPurchase.instance.queryProductDetails({yearlyId});
      if (r.productDetails.isEmpty) {
        throw Exception('Product not found: $yearlyId');
      }
      _yearlyProductDetails = r.productDetails.first;
    }
    await InAppPurchase.instance.buyNonConsumable(
      purchaseParam: PurchaseParam(productDetails: _yearlyProductDetails!),
    );
  }

  Future<void> restore() async => InAppPurchase.instance.restorePurchases();

  /// Opens Apple's offer-code redemption sheet (App Store Connect offer codes).
  Future<void> redeemCode() async {
    await InAppPurchase.instance
        .getPlatformAddition<InAppPurchaseStoreKitPlatformAddition>()
        .presentCodeRedemptionSheet();
    await refreshEntitlement();
  }

  void dispose() {
    _sub?.cancel();
    _controller.close();
  }
}
