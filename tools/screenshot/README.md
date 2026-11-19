# PNG-скріншоти для NeoMLoader

Готовий пакет: `dist/mtg-screenshot.zip`. Розпакуй **вміст** у свою папку `neomloader`, щоб вийшло:

- `neomloader/lib/android/screenshot.lua`
- `neomloader/lib/android/jar/mtg-screenshot.jar`
- `neomloader/Screenshot.lua` — необов'язковий тестовий скрипт із командою `/screenshot`.

Перезапусти скрипти/гру. `/screenshot` створює один PNG у **Pictures/Arizona Helper** та додає його в Галерею.
У платному Arizona Helper також доступна окрема дія біндера `{screenshot}`. Став її окремим рядком; вона не надсилається в чат.
Наприклад, щоб зняти результат `/time` у редакторі біндера:

```text
/time
{wait(500)}
{screenshot}
```

У збереженому тексті команди це `/time&{wait(500)}&{screenshot}`. Звичайна затримка біндера
також діє перед скріншотом; `{wait(...)}` замінює її для наступного кроку. Біндер чекає результат
збереження. `/stop` перериває очікування та наступні кроки; вже запущений PNG може зберегтися.
Одночасно виконується лише один запит скріншота в модулі.

Android 7+ (API 24). На Android 10+ збереження власних зображень через MediaStore не потребує доступу до всієї Галереї.
На Android 7–9 потрібен дозволений запис у сховище; після системного запиту дозволу повтори команду.
Для цих старих версій Android APK має декларувати `WRITE_EXTERNAL_STORAGE`: оновлений `build_launcher.py`
додає цей дозвіл із `maxSdkVersion=28`. У вже встановленому старому APK без цього дозволу потрібна
перезбірка/оновлення APK; ZIP сам не може змінити AndroidManifest. На Android 10+ це не потрібно.
Це знімок поточного вікна гри, включно з ігровими SurfaceView та звичайними Android View. Системна клавіатура,
панель повідомлень та інші застосунки поза вікном гри не захоплюються. MediaProjection, запис відео та root не використовуються.

## Перезбірка

```powershell
python tools/build_screenshot.py
```

Потрібні JDK (`java`, `javac`), а також `libs/android.jar` і `libs/d8.jar` із цього репо.
Збирається Java 8 bytecode та DEX для API 24+. В APK потрапляють лише готові Lua/JAR ресурси; окрема перебудова APK
не потрібна для ручного встановлення ZIP. Джерело Java: `tools/screenshot/ScreenshotBridge.java`.

Lua API: `save(cancel)` чекає збереження всередині Lua-корутини та повертає `ok, uri_or_error`.
`cancel` — необов'язкова функція; `true` скасовує очікування. Для окремого асинхронного керування:
`capture()` запускає захоплення; `status()` повертає `PENDING`, `SUCCESS` або `ERROR`;
`result()` — content URI, `error()` — текст помилки. Опитування виконуй із Lua-корутини із `wait(50)`.
Зворотні виклики з Java-потоків у Lua не використовуються.


## Перевірки

Java-компіляція та D8 виконуються самим build-скриптом. Для тестів Lua JNI-обгортки:

```powershell
$env:LUA = 'C:/path/to/lua5.1.exe'
python tools/screenshot/test_screenshot.py
```

Ці перевірки підміняють Android API та перевіряють JNI-посилання, очікування, помилки й скасування.
Вони не перевіряють реальне зображення. Після встановлення перевір `/screenshot` у грі,
наявність PNG у Галереї та відсутність чорного кадру на конкретному телефоні.


API: [PixelCopy](https://developer.android.com/reference/android/view/PixelCopy),
[MediaStore](https://developer.android.com/training/data-storage/shared/media),
[DexClassLoader](https://developer.android.com/reference/dalvik/system/DexClassLoader).
