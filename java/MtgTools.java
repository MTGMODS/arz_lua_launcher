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

    private static String postRequest(String urlStr, String key, String device) {
        HttpsURLConnection c = null;
        try {
            c = (HttpsURLConnection) new URL(urlStr).openConnection();
            c.setRequestMethod("POST");
            c.setConnectTimeout(5000);
            c.setReadTimeout(5000);
            c.setDoOutput(true);

            String json = String.format("{\"key\":\"%s\",\"device\":\"%s\"}", key, device != null ? device : "");
            byte[] out = json.getBytes(StandardCharsets.UTF_8);

            c.setRequestProperty("Content-Type", "application/json");
            c.setFixedLengthStreamingMode(out.length);

            try (OutputStream os = c.getOutputStream()) {
                os.write(out);
            }

            int code = c.getResponseCode();
            Log.i("MtgTools", "HTTP code: " + code + " from " + urlStr);

            InputStream is = (code >= 400) ? c.getErrorStream() : c.getInputStream();
            if (is == null) return null;

            StringBuilder sb = new StringBuilder();
            try (BufferedReader in = new BufferedReader(new InputStreamReader(is))) {
                String line;
                while ((line = in.readLine()) != null) sb.append(line);
            }

            String body = sb.toString();
            if (body.isEmpty()) return null;

            return body;
        } catch (UnknownHostException e) {
            Log.e("MtgTools", "DNS error: " + e.getMessage());
            return null;
        } catch (Exception e) {
            Log.e("MtgTools", "Error post request: ", e);
            return null;
        } finally {
            if (c != null) c.disconnect();
        }
    }

    public static boolean isValidKey(String key, Context context) {
        Log.i("MtgTools", "Check key: " + key);

        String response = postRequest("https://api.mtgmods.com/v1/license/check", key, getDeviceId(context));
        if (response == null) {
            new Handler(Looper.getMainLooper()).post(() -> Toast.makeText(context, "[MTG MODS]\n⚠️ Ошибка подключения ⚠️", Toast.LENGTH_LONG).show());
            return false;
        }

        try {
            JSONObject json = new JSONObject(response);
            Boolean valid = json.has("valid") ? json.getBoolean("valid") : null;
            if (Boolean.TRUE.equals(valid)) {
                String username = json.optString("user", "VIP пользователь");
                new Handler(Looper.getMainLooper()).post(() -> Toast.makeText(context, "[MTG MODS]\n👑 " + username + " 👑", Toast.LENGTH_SHORT).show());
                return true;
            } else if (Boolean.FALSE.equals(valid)) {
                String err = json.optString("error", "");
                String toastMessage;
                if (json.optBoolean("expires", false)) {
                    toastMessage = "[MTG MODS]\n😭 Ключ устарел 😭";
                    context.getSharedPreferences("mtg", Context.MODE_PRIVATE).edit().remove("key").apply();
                } else if ("Key not found".equalsIgnoreCase(err)) {
                    toastMessage = "[MTG MODS]\n❌ Ключ не найден ❌";
                    context.getSharedPreferences("mtg", Context.MODE_PRIVATE).edit().remove("key").apply();
                } else if ("Missing key".equalsIgnoreCase(err)) {
                    toastMessage = "[MTG MODS]\n⚠️ Не введён ключ ⚠️";
                    context.getSharedPreferences("mtg", Context.MODE_PRIVATE).edit().remove("key").apply();
                } else if ("Internal server error".equalsIgnoreCase(err)) {
                    toastMessage = "[MTG MODS]\n❗️ Сервер упал ❗️";
                } else if ("NOT_ACTIVATED".equalsIgnoreCase(err)) {
                    toastMessage = "[MTG MODS]\n👉 Активируйте в TG/DS 👈";
                } else if ("RATE_LIMIT".equalsIgnoreCase(err)) {
                    int retry = json.optInt("retry", 10);
                    toastMessage = "[MTG MODS]\n⏳ АнтиФлуд " + retry + " сек ⏳";
                } else {
                    toastMessage = "[MTG MODS]\n⚠️ Ошибка сервера ⚠️";
                    Log.e("MtgTools", "Unexpected valid=false response: " + response);
                    String finalResponse = response;
                    new Handler(Looper.getMainLooper()).post(() -> Toast.makeText(context, finalResponse, Toast.LENGTH_LONG).show());
                }
                new Handler(Looper.getMainLooper()).post(() -> Toast.makeText(context, toastMessage, Toast.LENGTH_LONG).show());
            } else {
                Log.e("MtgTools", "Error check key: " + response);
                new Handler(Looper.getMainLooper()).post(() -> Toast.makeText(context, "🌐 Смените 4G / Wi-Fi / VPN 🌐", Toast.LENGTH_SHORT).show());
                String finalResponse = response;
                new Handler(Looper.getMainLooper()).post(() -> Toast.makeText(context, finalResponse, Toast.LENGTH_LONG).show());
            };
            return false;
        } catch (Exception e) {
            Log.e("MtgTools", "Error check key: ", e);
            new Handler(Looper.getMainLooper()).post(() -> Toast.makeText(context, e.getMessage(), Toast.LENGTH_LONG).show());
        }
        return false;
    };

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
        input.setHint("Укажите ключ, который вы получили из бота");
        input.setGravity(Gravity.CENTER);
        new AlertDialog.Builder(context)
                .setMessage("Узнать подробней про бонусы и цену VIP, либо приобрести VIP вы можете в Telegram/Discord MTG MODS, например https://t.me/mtgmods/60\n\nЕсли у вас и так уже есть купленный VIP, то введите данные ниже")
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