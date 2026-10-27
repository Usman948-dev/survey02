package com.example.survey_app

import android.content.Context
import android.telephony.SubscriptionManager
import android.telephony.TelephonyManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// Reports which carrier SIM currently carries mobile data and its network generation (2G/3G/4G/5G).
class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "survey/carrier").setMethodCallHandler { call, result ->
            if (call.method != "info") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            try {
                var tm = getSystemService(Context.TELEPHONY_SERVICE) as TelephonyManager
                val id = SubscriptionManager.getDefaultDataSubscriptionId()
                if (id != SubscriptionManager.INVALID_SUBSCRIPTION_ID) tm = tm.createForSubscriptionId(id)
                val gen = when (tm.dataNetworkType) {
                    TelephonyManager.NETWORK_TYPE_GPRS, TelephonyManager.NETWORK_TYPE_EDGE,
                    TelephonyManager.NETWORK_TYPE_CDMA, TelephonyManager.NETWORK_TYPE_1xRTT,
                    TelephonyManager.NETWORK_TYPE_IDEN, 16 -> "2G"
                    TelephonyManager.NETWORK_TYPE_UMTS, TelephonyManager.NETWORK_TYPE_EVDO_0,
                    TelephonyManager.NETWORK_TYPE_EVDO_A, TelephonyManager.NETWORK_TYPE_EVDO_B,
                    TelephonyManager.NETWORK_TYPE_HSDPA, TelephonyManager.NETWORK_TYPE_HSUPA,
                    TelephonyManager.NETWORK_TYPE_HSPA, TelephonyManager.NETWORK_TYPE_HSPAP,
                    TelephonyManager.NETWORK_TYPE_EHRPD, 17 -> "3G"
                    TelephonyManager.NETWORK_TYPE_LTE -> "4G"
                    20 -> "5G"
                    else -> "NONE"
                }
                result.success(mapOf("carrier" to tm.networkOperatorName, "gen" to gen))
            } catch (e: Exception) {
                result.error("SIM", e.message, null)
            }
        }
    }
}
