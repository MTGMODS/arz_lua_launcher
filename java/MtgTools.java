package com.arizona.launcher;

import android.annotation.SuppressLint;
import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.net.ConnectivityManager;
import android.net.LinkProperties;
import android.net.Network;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.provider.Settings;
import android.util.Log;
import android.util.Pair;
import android.view.Gravity;
import android.widget.EditText;
import android.widget.Toast;
import android.app.AlertDialog;
import org.json.JSONObject;
import java.io.BufferedReader;
import java.io.File;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.URL;
import java.net.UnknownHostException;
import java.nio.charset.StandardCharsets;
import java.util.UUID;
import javax.net.ssl.HttpsURLConnection;
import javax.net.ssl.SSLContext;
import javax.net.ssl.TrustManager;
import javax.net.ssl.X509TrustManager;

public class MtgTools {

    private static boolean forceVip = false;
    private static boolean isInitialized = false;

    @SuppressLint("HardwareIds")
    public static String getDeviceId(Context context) {
        return Settings.Secure.getString(
                context.getContentResolver(),
                Settings.Secure.ANDROID_ID
        );
    }

    private static Pair<Integer, String> postRequest(String urlStr, String key, String device) throws Exception {
        HttpsURLConnection c = null;

        try {
            c = (HttpsURLConnection) new URL(urlStr).openConnection();
            c.setRequestMethod("POST");
            c.setConnectTimeout(5000);
            c.setReadTimeout(5000);
            c.setDoOutput(true);

            JSONObject json = new JSONObject();
            json.put("key", key != null ? key : "");
            json.put("device", device != null ? device : "");
            byte[] out = json.toString().getBytes(StandardCharsets.UTF_8);

            c.setRequestProperty("Content-Type", "application/json; charset=UTF-8");
            c.setFixedLengthStreamingMode(out.length);

            try (OutputStream os = c.getOutputStream()) {
                os.write(out);
            }

            int code = c.getResponseCode();
            Log.i("MtgTools", "HTTP code: " + code + " from " + urlStr);

            InputStream is = code >= 400 ? c.getErrorStream() : c.getInputStream();
            StringBuilder sb = new StringBuilder();

            if (is != null) {
                try (BufferedReader in = new BufferedReader(new InputStreamReader(is, StandardCharsets.UTF_8))) {
                    String line;
                    while ((line = in.readLine()) != null) {
                        sb.append(line);
                    }
                }
            }

            return new Pair<>(code, sb.toString());
        } finally {
            if (c != null) c.disconnect();
        }
    }

    public static boolean isValidKey(String key, Context context) {
        Handler handler = new Handler(Looper.getMainLooper());
        Pair<Integer, String> response;

        try {
            response = postRequest("https://api.mtgmods.com/v1/license/check", key, getDeviceId(context));
        } catch (Exception e) {
            Log.e("MtgTools", "License connection failed", e);
            String message = "[MTG MODS]\n🌐 Смените Wi-Fi/LTE или VPN 🌐";
            handler.post(() -> Toast.makeText(context, message, Toast.LENGTH_LONG).show());
            return false;
        }

        int code = response.first;
        JSONObject json;

        try {
            json = new JSONObject(response.second);
        } catch (org.json.JSONException e) {
            json = new JSONObject();
        }

        if (code == 200 && Boolean.TRUE.equals(json.opt("valid"))) {
            String username = json.optString("user", "MTGVIP");
            handler.post(() -> Toast.makeText(context, "[MTG MODS]\n👑 " + username + " 👑", Toast.LENGTH_SHORT).show());
            return true;
        }

        String errorCode = json.optString("error_code", "");
        String message;

        if (code == 404) {
            if ("LICENSE_NOT_FOUND".equals(errorCode)) {
                message = "❌ Ключ не найден ❌";
            } else {
                message = "❗️ Сервер недоступен ❗️";
            }
        } else if (code >= 500) {
            message = "❗️ Cервер упал:  " + code + " ❗️";
        } else if (code == 429) {
            message = "⏳ Слишком много запросов";
        } else if (code == 422) {
            message = "⚠️ Ваши данные некорректные";
        } else if (code == 403) {
            switch (errorCode) {
                case "LICENSE_BANNED":
                    message = "🚫 Ключ заблокирован 🚫";
                    break;
                case "LICENSE_EXPIRED":
                    message = "⌛ Срок подписки истёк ⌛";
                    break;
                case "LICENSE_NOT_ACTIVATED":
                    message = "👉 Активируйте ключ в кабинете";
                    break;
                case "HWID_LIMIT_REACHED":
                    message = "📱 Достигнут лимит устройств 📱";
                    break;
                default:
                    message = "⚠️ HTTP 403 ⚠️";
                    break;
            }
        } else {
            message = "⚠️ Ошибка: HTTP " + code;
        }

        final String toastMessage = "[MTG MODS]\n" + message;
        handler.post(() -> Toast.makeText(context, toastMessage, Toast.LENGTH_LONG).show());
        return false;
    }

    public static boolean isActiveAdBlocker(Activity activity, Context context) {
        ConnectivityManager cm = (ConnectivityManager) context.getSystemService(Context.CONNECTIVITY_SERVICE);
        if (cm != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            Network activeNetwork = cm.getActiveNetwork();
            if (activeNetwork != null) {
                LinkProperties linkProperties = cm.getLinkProperties(activeNetwork);
                if (linkProperties != null) {
                    String privateDnsHost = linkProperties.getPrivateDnsServerName();
                    if (privateDnsHost != null) {
                        String dns = privateDnsHost.toLowerCase();
                        String[] adBlockers = new String[] {
                            "adguard",
                            "nextdns",
                            "controld",
                            "blokada",
                            "rethinkdns",
                            "comss",
                            "mullvad",
                            "dns0.eu",
                            "dns4eu",
                            "ahadns",
                            "dnsforge",
                            "dnswarden",
                            "dnsbunker",
                            "blahdns",
                            "ublock",
                            "pihole",
                            "pi-hole",
                            "pi-dns",
                            "adaway",
                            "hagezi",
                            "oisd", 
                            "adblock",
                            "adfree",
                            "blocker"
                        };
                        for (String blocker : adBlockers) {
                            if (dns.contains(blocker)) {
                                Log.w("MtgTools", "Detected AD blocker: " + privateDnsHost);
                                return true;
                            }
                        }
                    }
                }
            }
        }
        return false;
    }

    public static boolean isShowAd(Context context) {
        SharedPreferences sp = context.getSharedPreferences("mtg", Context.MODE_PRIVATE);
        if (!sp.getBoolean("check", false)) {
            sp.edit().putBoolean("check", true).apply();
            return false;
        }
        String savedKey = sp.getString("key", "");
        return savedKey.isEmpty() || !isValidKey(savedKey, context);
    }

    public static void showVipDialog(Activity activity, Context context) {
        final EditText input = new EditText(context);
        input.setHint("Укажите ключ MTGVIP, который вы приобрели");
        input.setGravity(Gravity.CENTER);
        new AlertDialog.Builder(context)
                .setMessage("Узнать про MTGVIP можно на сайте https://mtgmods.com/vip\n\nЕсли вы уже купили MTGVIP, то введите ваш ключ ниже")
                .setView(input)
                .setPositiveButton("Проверить ключ", (dialog2, which) -> {
                    String key = input.getText().toString().trim();
                    new Thread(() -> {
                        if (isValidKey(key, context)) {
                            context.getSharedPreferences("mtg", Context.MODE_PRIVATE).edit().putString("key", key).apply();
                            new Handler(Looper.getMainLooper()).post(() -> Toast.makeText(context, "[MTG MODS]\n✅ Реклама отключена ✅", Toast.LENGTH_LONG).show());
                        } else if (MtgTools.forceVip) {
                            activity.finishAffinity();
                        };
                    }).start();
                })
                .setNegativeButton("Закрыть", (dialog, which) -> {
                    if (MtgTools.forceVip) {
                        Toast.makeText(context, "[MTG MODS]\n👉 Отключите DNS 👈", Toast.LENGTH_LONG).show();
                        activity.finishAffinity();
                    } else {
                        dialog.dismiss();
                    }
                })
                .setCancelable(false)
                .show();
    }

    public static synchronized void initialize(Activity activity, Context context) {

        if (isInitialized) { return; }
        isInitialized = true;

        new Thread(() -> {
            try {
                if (isShowAd(context)) {
                    new Handler(Looper.getMainLooper()).post(() -> {
                        if (isActiveAdBlocker(activity, context)) {
                            forceVip = true;
                            new AlertDialog.Builder(context)
                                    .setTitle("ℹ️ Обнаружен AD Blocker (Private DNS) ℹ️")
                                    .setMessage(
                                            "Данный Lua лаунчер распространяется бесплатно, а реклама при запуске (в игре её нету) помогает поддерживать лаунчер 💖\n\n"
                                                    + "Вы же используете Private DNS, который блокирует показ рекламы 🥺\n\n"
                                                    + "ℹ️ Для продолжения, вам нужно решить данную проблему:\n"
                                                    + "👉 Либо отключить частный DNS в настройках, для загрузки рекламы\n"
                                                    + "👉 Либо иметь подписку MTGVIP (для скриптов и лаунчера)"
                                    )
                                    .setPositiveButton("Открыть настройки", (dialog, which) -> {
                                        try {
                                            Intent intent = new Intent("android.settings.PRIVATE_DNS_SETTINGS");
                                            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                                            context.startActivity(intent);
                                        } catch (Exception e) {
                                            try {
                                                Intent intent = new Intent(Settings.ACTION_WIRELESS_SETTINGS);
                                                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                                                context.startActivity(intent);
                                            } catch (Exception ex) {
                                                Toast.makeText(context, "Настройки -> Сеть -> DNS", Toast.LENGTH_LONG).show();
                                            }
                                        }
                                        activity.finishAffinity();
                                    })
                                    .setNegativeButton("Убрать рекламу", (dialog, which) -> showVipDialog(activity, context))
                                    .setCancelable(false)
                                    .show();
                        } else {
                            com.arizona.launcher.Ads.initializeAds(activity, context);
                            new AlertDialog.Builder(context)
                                    .setTitle("ℹ️ Просмотр рекламы перед началом игры ℹ️")
                                    .setMessage("Этим действием вы поддерживаете MTG MODS ❤️\nРекламы в игре нету, она только при запуске лаунчера\n\nЕсли вы хотите отключить рекламу, приобретите VIP")
                                    .setPositiveButton("Играть", (dialog, which) -> dialog.dismiss())
                                    .setNegativeButton("Убрать рекламу", (dialog, which) -> showVipDialog(activity, context))
                                    .setCancelable(true)
                                    .show();
                        }
                    });
                }
            } catch (Exception e) {
                Log.e("MtgTools", "Error init ad: ", e);
            }
        }).start();

        new Thread(() -> {
            try {
                if (!com.arizona.launcher.CheckUpdate.isNeedUpdate(activity, context)) {
                    com.arizona.launcher.AssetExtractor.unpackAssets(activity, context);
                }
            } catch (Exception e) {
                Log.e("MtgTools", "Error update/assets: ", e);
            }
        }).start();

    }

}