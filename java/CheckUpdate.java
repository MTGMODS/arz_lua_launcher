package com.arizona.launcher;

import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.net.Uri;
import android.util.Log;
import android.widget.Toast;

import android.app.AlertDialog;

import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;

public class CheckUpdate {

    public static boolean isNeedUpdate(Activity activity, Context context) {

        try {
            URL url = new URL("https://raw.githubusercontent.com/MTGMODS/arz_lua_launcher/refs/heads/main/launcher.json");

            HttpURLConnection conn = (HttpURLConnection) url.openConnection();
            conn.setRequestMethod("GET");
            conn.setConnectTimeout(3000);
            conn.setReadTimeout(3000);

            StringBuilder response = new StringBuilder();
            try (BufferedReader reader = new BufferedReader(
                    new InputStreamReader(conn.getInputStream(), StandardCharsets.UTF_8))) {
                String line;
                while ((line = reader.readLine()) != null) {
                    response.append(line);
                }
            }
            conn.disconnect();

            JSONObject jsonObject = new JSONObject(response.toString());
            String currentVersion = jsonObject.getString("version");
            String updateUrl = jsonObject.getString("url");

            String appVersion = context.getPackageManager().getPackageInfo(context.getPackageName(), 0).versionName;

            if (!appVersion.equals(currentVersion)) {
                activity.runOnUiThread(() -> new AlertDialog.Builder(context)
                        .setTitle("ℹ️ MonetLoader Update ℹ️")
                        .setMessage("Установленный у вас лаунчер версии " + appVersion + " не актуален!\n\nИспользуйте версию " + currentVersion + " для стабильной игры с Lua")
                        .setPositiveButton("Скачать " + currentVersion, (dialogInterface, i) -> {
                            Intent browserIntent = new Intent(Intent.ACTION_VIEW, Uri.parse(updateUrl));
                            context.startActivity(browserIntent);
                            activity.finishAffinity();
                        })
                        .setNegativeButton("Игнор", (dialogInterface, i) -> {
                            new Thread(() -> com.arizona.launcher.AssetExtractor.unpackAssets(activity, context)).start();
                            dialogInterface.dismiss();
                        })
                        .setCancelable(false)
                        .show());
                return true;
            }

        } catch (Exception e) {
            Log.e("MtgTools", "Error update: ", e);
        }

        return false;
    }


}
