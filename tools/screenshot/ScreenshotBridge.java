package mtg.screenshot;

import android.Manifest;
import android.app.Activity;
import android.content.ContentResolver;
import android.content.ContentValues;
import android.content.Context;
import android.content.pm.PackageManager;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Matrix;
import android.graphics.Rect;
import android.media.MediaScannerConnection;
import android.net.Uri;
import android.os.Build;
import android.os.Environment;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.provider.MediaStore;
import android.view.PixelCopy;
import android.view.SurfaceView;
import android.view.View;
import android.view.ViewGroup;
import android.view.ViewParent;
import android.view.Window;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.OutputStream;
import java.lang.ref.WeakReference;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.List;

/** Own-window screenshots. Callers poll the API; Java never calls into Lua. */
public final class ScreenshotBridge {
    private static final Object LOCK = new Object();
    private static final long COPY_TIMEOUT_MS = 15000L;
    private static final int STORAGE_REQUEST = 0x5343;
    private static WeakReference<Activity> activity = new WeakReference<Activity>(null);
    private static Capture active;
    // One immutable snapshot publishes strings and status together, including across threads.
    private static volatile State state = new State(0, "", "");
    private static final State MEMORY_ERROR = new State(3, "", "Недостаточно памяти для снимка.");

    private ScreenshotBridge() { }

    public static void init(Activity value) {
        synchronized (LOCK) {
            activity = new WeakReference<Activity>(value);
        }
    }

    /** True means accepted; permission requests and asynchronous failures end in status 3. */
    public static boolean capture() {
        final Activity owner;
        final Capture request;
        synchronized (LOCK) {
            if (state.status == 1) {
                return false;
            }
            owner = activity.get();
            if (owner == null) {
                state = new State(3, "", "Окно игры недоступно.");
                return false;
            }
            if (Build.VERSION.SDK_INT < 24) {
                state = new State(3, "", "Для снимка нужен Android 7.0 или новее.");
                return false;
            }
            try {
                request = new Capture(owner);
                State pending = new State(1, "", "");
                active = request;
                state = pending; // Must precede runOnUiThread, which can execute inline.
            } catch (Throwable failure) {
                state = failureState(failure, "Не удалось начать снимок.");
                return false;
            }
        }
        try {
            owner.runOnUiThread(request);
            return true;
        } catch (Throwable failure) {
            request.publish(failureState(failure, "Не удалось начать снимок."));
            return false;
        }
    }

    /** 0 idle, 1 pending, 2 saved, 3 error. */
    public static int getStatus() { return state.status; }
    /** Gallery content URI after success; empty otherwise. */
    public static String getResult() { return state.result; }
    public static String getError() { return state.error; }

    private static final class State {
        final int status;
        final String result;
        final String error;

        State(int status, String result, String error) {
            this.status = status;
            this.result = result;
            this.error = error;
        }
    }

    private static State failureState(Throwable failure, String message) {
        if (failure instanceof OutOfMemoryError) {
            return MEMORY_ERROR;
        }
        try {
            return new State(3, "", failure instanceof SecurityException
                    ? "Нет разрешения на создание снимка." : message);
        } catch (Throwable ignored) {
            return MEMORY_ERROR;
        }
    }

    private static void recycle(Bitmap bitmap) {
        try {
            if (bitmap != null && !bitmap.isRecycled()) { bitmap.recycle(); }
        } catch (Throwable ignored) {
            // Cleanup must never prevent publication of the terminal status.
        }
    }

    private static final class Layer {
        final SurfaceView view;
        final Matrix matrix;
        final Rect clip;
        final int width;
        final int height;

        Layer(SurfaceView view, View decor, Rect clip) throws IOException {
            this.view = view;
            this.clip = clip;
            width = view.getWidth();
            height = view.getHeight();
            matrix = new Matrix();
            View node = view;
            while (node != decor) {
                matrix.postConcat(node.getMatrix());
                matrix.postTranslate(node.getLeft(), node.getTop());
                ViewParent parent = node.getParent();
                if (!(parent instanceof View)) {
                    throw new IOException("SurfaceView покинул окно игры.");
                }
                node = (View) parent;
                matrix.postTranslate(-node.getScrollX(), -node.getScrollY());
            }
        }
    }

    // All capture bitmap ownership below is confined to the main thread until save().
    private static final class Capture implements Runnable {
        final WeakReference<Activity> owner;
        final Handler main = new Handler(Looper.getMainLooper());
        final List<Layer> layers = new ArrayList<Layer>();
        final Runnable timeout = new Runnable() {
            @Override public void run() { fail("Истекло время ожидания кадра игры."); }
        };
        Context context;
        Bitmap image;
        Bitmap overlay;
        int nextLayer;
        boolean ended;

        Capture(Activity owner) { this.owner = new WeakReference<Activity>(owner); }

        @Override public void run() {
            try {
                Activity value = owner.get();
                if (value == null || value.isFinishing() || value.isDestroyed()
                        || value.getWindow() == null) {
                    fail("Окно игры недоступно.");
                    return;
                }
                if (Build.VERSION.SDK_INT <= 28 && value.checkSelfPermission(
                        Manifest.permission.WRITE_EXTERNAL_STORAGE) != PackageManager.PERMISSION_GRANTED) {
                    value.requestPermissions(new String[] {
                            Manifest.permission.WRITE_EXTERNAL_STORAGE }, STORAGE_REQUEST);
                    fail("Разрешите доступ к хранилищу и повторите снимок.");
                    return;
                }
                context = value.getApplicationContext();
                if (context == null) {
                    fail("Контекст игры недоступен.");
                    return;
                }
                Window window = value.getWindow();
                View decor = window.getDecorView();
                if (!decor.isShown() || !decor.isAttachedToWindow()
                        || decor.getWidth() <= 0 || decor.getHeight() <= 0) {
                    fail("Откройте окно игры и повторите снимок.");
                    return;
                }
                collect(decor, decor, layers);
                image = Bitmap.createBitmap(decor.getWidth(), decor.getHeight(), Bitmap.Config.ARGB_8888);
                if (!layers.isEmpty()) {
                    image.eraseColor(Color.BLACK);
                    overlay = Bitmap.createBitmap(decor.getWidth(), decor.getHeight(), Bitmap.Config.ARGB_8888);
                    // SurfaceView clears its holes on this separate, initially transparent bitmap.
                    decor.draw(new Canvas(overlay));
                    armTimeout();
                    copyNext();
                } else if (Build.VERSION.SDK_INT >= 26) {
                    armTimeout();
                    copyWindow(window);
                } else {
                    decor.draw(new Canvas(image));
                    save();
                }
            } catch (Throwable failure) {
                fail(failureState(failure, "Не удалось получить кадр игры."));
            }
        }

        void armTimeout() throws IOException {
            if (!main.postDelayed(timeout, COPY_TIMEOUT_MS)) {
                throw new IOException("Поток окна игры остановлен.");
            }
        }

        void copyNext() {
            if (ended) { return; }
            if (nextLayer == layers.size()) {
                new Canvas(image).drawBitmap(overlay, 0f, 0f, null);
                recycle(overlay);
                overlay = null;
                save();
                return;
            }
            final Layer layer = layers.get(nextLayer++);
            final Bitmap destination = Bitmap.createBitmap(layer.width,
                    layer.height, Bitmap.Config.ARGB_8888);
            try {
                PixelCopy.request(layer.view, destination, new PixelCopy.OnPixelCopyFinishedListener() {
                    @Override public void onPixelCopyFinished(int code) {
                        try {
                            if (ended) { return; }
                            if (code != PixelCopy.SUCCESS) {
                                fail(copyError(code));
                                return;
                            }
                            Canvas canvas = new Canvas(image);
                            canvas.concat(layer.matrix);
                            canvas.clipRect(layer.clip);
                            canvas.drawBitmap(destination, 0f, 0f, null);
                        } catch (Throwable failure) {
                            fail(failureState(failure, "Не удалось собрать снимок игры."));
                        } finally {
                            // PixelCopy has finished writing; even a timed-out request is now safe to recycle.
                            recycle(destination);
                        }
                        if (!ended) {
                            try { copyNext(); }
                            catch (Throwable failure) {
                                fail(failureState(failure, "Не удалось получить кадр игры."));
                            }
                        }
                    }
                }, main);
            } catch (Throwable failure) {
                recycle(destination); // A rejected request has no writer/callback.
                fail(failureState(failure, "Не удалось скопировать поверхность игры."));
            }
        }

        void copyWindow(Window window) {
            // Transfer the destination out of UI cleanup while PixelCopy owns it.
            final Bitmap destination = image;
            image = null;
            try {
                PixelCopy.request(window, destination, new PixelCopy.OnPixelCopyFinishedListener() {
                    @Override public void onPixelCopyFinished(int code) {
                        if (ended) {
                            recycle(destination);
                            return;
                        }
                        image = destination;
                        try {
                            if (code == PixelCopy.SUCCESS) { save(); }
                            else { fail(copyError(code)); }
                        } catch (Throwable failure) {
                            fail(failureState(failure, "Не удалось получить кадр окна."));
                        }
                    }
                }, main);
            } catch (Throwable failure) {
                recycle(destination);
                fail(failureState(failure, "Не удалось скопировать окно игры."));
            }
        }

        void save() {
            final Bitmap ready = image;
            final Context app = context;
            // No timeout may recycle the worker's image or publish a competing result.
            main.removeCallbacks(timeout);
            ended = true;
            image = null;
            releaseUi();
            try {
                new Thread(new Runnable() {
                    @Override public void run() {
                        State outcome;
                        try {
                            outcome = new State(2, store(app, ready), "");
                        } catch (Throwable failure) {
                            outcome = failureState(failure, "Не удалось сохранить снимок в галерею.");
                        } finally {
                            recycle(ready);
                        }
                        publish(outcome);
                    }
                }, "ArizonaScreenshot").start();
            } catch (Throwable failure) {
                recycle(ready);
                publish(failureState(failure, "Не удалось запустить сохранение снимка."));
            }
        }

        void fail(String message) { fail(failureState(null, message)); }

        void fail(State outcome) {
            if (ended) { return; }
            ended = true;
            main.removeCallbacks(timeout);
            releaseUi();
            publish(outcome);
        }

        void releaseUi() {
            recycle(image);
            recycle(overlay);
            image = null;
            overlay = null;
            layers.clear();
            context = null;
        }

        void publish(State outcome) {
            synchronized (LOCK) {
                if (active == this) {
                    active = null;
                    state = outcome;
                }
            }
        }
    }

    private static void collect(View view, View decor, List<Layer> layers) throws IOException {
        if (view.getVisibility() != View.VISIBLE || view.getAlpha() <= 0f) { return; }
        if (view instanceof SurfaceView) {
            Rect clip = new Rect();
            if (view.getWidth() > 0 && view.getHeight() > 0 && view.getLocalVisibleRect(clip)) {
                Rect ownClip = view.getClipBounds();
                if (ownClip != null && !clip.intersect(ownClip)) { return; }
                SurfaceView surface = (SurfaceView) view;
                if (!surface.getHolder().getSurface().isValid()) {
                    throw new IOException("Поверхность игры ещё не готова.");
                }
                layers.add(new Layer(surface, decor, clip));
            }
        }
        if (view instanceof ViewGroup) {
            ViewGroup group = (ViewGroup) view;
            List<View> children = new ArrayList<View>(group.getChildCount());
            for (int i = 0; i < group.getChildCount(); i++) { children.add(group.getChildAt(i)); }
            // Stable sort preserves child order for equal elevations, the usual game layout.
            Collections.sort(children, new Comparator<View>() {
                @Override public int compare(View a, View b) { return Float.compare(a.getZ(), b.getZ()); }
            });
            for (View child : children) { collect(child, decor, layers); }
        }
    }

    private static String copyError(int code) {
        if (code == PixelCopy.ERROR_SOURCE_NO_DATA) {
            return "Кадр игры ещё не готов. Повторите снимок.";
        }
        if (code == PixelCopy.ERROR_TIMEOUT) { return "Истекло время ожидания кадра игры."; }
        return "Не удалось скопировать кадр игры (код " + code + ").";
    }

    private static String store(Context app, Bitmap bitmap) throws IOException, InterruptedException {
        ContentResolver resolver = app.getContentResolver();
        if (Build.VERSION.SDK_INT >= 29) {
            ContentValues values = new ContentValues();
            values.put("_display_name", "Arizona_Helper_" + System.currentTimeMillis() + ".png");
            values.put("mime_type", "image/png");
            values.put("relative_path", Environment.DIRECTORY_PICTURES + "/Arizona Helper");
            values.put("is_pending", 1);
            Uri uri = resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values);
            if (uri == null) { throw new IOException("Галерея не создала запись."); }
            boolean complete = false;
            try {
                String result = uri.toString();
                try (OutputStream stream = resolver.openOutputStream(uri, "w")) {
                    writePng(bitmap, stream);
                }
                values.clear();
                values.put("is_pending", 0);
                if (resolver.update(uri, values, null, null) != 1) {
                    throw new IOException("Галерея не опубликовала снимок.");
                }
                complete = true;
                return result;
            } finally {
                if (!complete) { deleteRow(resolver, uri); }
            }
        }
        if (!Environment.MEDIA_MOUNTED.equals(Environment.getExternalStorageState())) {
            throw new IOException("Хранилище недоступно.");
        }
        File directory = new File(Environment.getExternalStoragePublicDirectory(
                Environment.DIRECTORY_PICTURES), "Arizona Helper");
        if (!directory.isDirectory() && !directory.mkdirs() && !directory.isDirectory()) {
            throw new IOException("Не удалось создать папку снимков.");
        }
        File file = File.createTempFile("Arizona_Helper_" + System.currentTimeMillis() + "_", ".png", directory);
        Scan scan = null;
        boolean complete = false;
        try {
            try (OutputStream stream = new FileOutputStream(file)) { writePng(bitmap, stream); }
            scan = new Scan(resolver);
            MediaScannerConnection.scanFile(app, new String[] { file.getAbsolutePath() },
                    new String[] { "image/png" }, scan);
            String result = scan.await().toString();
            complete = true;
            return result;
        } finally {
            if (!complete) {
                if (scan != null) { scan.cancel(); }
                file.delete();
            }
        }
    }

    private static void writePng(Bitmap bitmap, OutputStream stream) throws IOException {
        if (stream == null || !bitmap.compress(Bitmap.CompressFormat.PNG, 100, stream)) {
            throw new IOException("Не удалось записать PNG.");
        }
        stream.flush();
    }

    private static void deleteRow(ContentResolver resolver, Uri uri) {
        if (uri != null) {
            try { resolver.delete(uri, null, null); }
            catch (Throwable ignored) { /* Best effort if the provider itself is unavailable. */ }
        }
    }

    private static final class Scan implements MediaScannerConnection.OnScanCompletedListener {
        final ContentResolver resolver;
        Uri uri;
        boolean done;
        boolean cancelled;

        Scan(ContentResolver resolver) { this.resolver = resolver; }

        @Override public void onScanCompleted(String path, Uri value) {
            synchronized (this) {
                if (!cancelled) {
                    uri = value;
                    done = true;
                    notifyAll();
                    return;
                }
            }
            // A late scan after timeout must not leave an orphaned Gallery row.
            deleteRow(resolver, value);
        }

        synchronized Uri await() throws IOException, InterruptedException {
            long deadline = SystemClock.uptimeMillis() + COPY_TIMEOUT_MS;
            while (!done) {
                long remaining = deadline - SystemClock.uptimeMillis();
                if (remaining <= 0) { throw new IOException("Галерея не ответила вовремя."); }
                wait(remaining);
            }
            if (uri == null) { throw new IOException("Галерея не зарегистрировала снимок."); }
            return uri;
        }

        void cancel() {
            Uri value;
            synchronized (this) {
                cancelled = true;
                value = uri;
            }
            deleteRow(resolver, value);
        }
    }
}