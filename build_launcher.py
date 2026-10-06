import subprocess, os, re, shutil, glob, requests, zipfile, json, sys
from dotenv import load_dotenv

if len(sys.argv) != 2 or sys.argv[1] not in {"arizona", "rodina"}:
    raise RuntimeError("[INFO] 👉 Usage: python builder.py <arizona|rodina>")

PROJECTS_APK = {
    "arizona": "https://mob2.maz-ins.com/client/release/bin/app-arizona-release_web.apk",
    "rodina": "https://mob2.azinternal.com/client/release/bin/app-rodina-release_web.apk",
}

DOWNLOAD_URL = PROJECTS_APK[sys.argv[1]]

##################################################################################################################

PATH = os.path.dirname(__file__).replace('\\', '/')

APKTOOL_PATH = PATH + "/libs/apktool.jar"

APK_NAME = DOWNLOAD_URL.split("/")[-1].removesuffix(".apk")

DECODED_DIR = PATH + "/" + APK_NAME

APK_PATH = DECODED_DIR + ".apk"

##################################################################################################################

if not os.path.exists(APK_PATH):
    print(f"[INFO] 📥 Downloading latest original APK from {DOWNLOAD_URL}...")

    with open(APK_PATH, 'wb') as f:
        f.write(requests.get(DOWNLOAD_URL).content)

##################################################################################################################

if os.path.exists(DECODED_DIR):
    print("[INFO] 🗑️ Delete old decompiled app folder...")
    shutil.rmtree(DECODED_DIR, ignore_errors=True)

print("[INFO] ⚙️ Decompiling APK...")
subprocess.run(["java", "-jar", APKTOOL_PATH, "d", APK_PATH, "-o", DECODED_DIR, "--force"], check=True)
print("[INFO] ✅ APK decompiled successfully!")

##################################################################################################################

LIB_PATH = DECODED_DIR + "/lib/armeabi-v7a"

print(f"[INFO] 🗑️ Delete armeabi-v7a lib folder (Neomloader only 64bit)...")

if os.path.exists(LIB_PATH):
    shutil.rmtree(LIB_PATH)
    print("[INFO] ✅ Folder armeabi-v7a removed successfully!")

##################################################################################################################

SRC_FILES = PATH + "/files"

print("[INFO] 🔧 Adding \"files\" to original client...")

for root, dirs, files in os.walk(SRC_FILES):
    for file in files:
        src_file = os.path.join(root, file)
        dest_file = os.path.join(DECODED_DIR, os.path.relpath(src_file, SRC_FILES))
        os.makedirs(os.path.dirname(dest_file), exist_ok=True)
        shutil.copy2(src_file, dest_file)

print("[INFO] ✅ Folder \"files\" added successfully!")

##################################################################################################################

NEOMLOADER_ZIP_PATH = "libs/neomloader.zip"
NEOMLOADER_TARGET_DIR = os.path.join(DECODED_DIR, "assets", "neomloader")

print("[INFO] 🔧 Extracting NeoMLoader core (libs & default scripts)...")
    
if not os.path.exists(NEOMLOADER_ZIP_PATH):
    raise RuntimeError("❗ NeoMLoader zip not found!")

try:
    with zipfile.ZipFile(NEOMLOADER_ZIP_PATH, 'r') as zip_ref:
        zip_ref.extractall(NEOMLOADER_TARGET_DIR)
    print("[INFO] ✅ NeoMLoader core extracted successfully!")
except Exception as e:
    raise RuntimeError(f"❗ Failed to extract NeoMLoader core: {e}")

##################################################################################################################

SMALI_CLASSES = glob.glob(DECODED_DIR + "/smali_classes*")

SMALI_PATH = ""

for smali_dir in SMALI_CLASSES:
    smali_dir = smali_dir.replace('\\', '/')
    potential_path = smali_dir + "/com/arizona/game/GTASA.smali"
    if os.path.isfile(potential_path):
        SMALI_PATH = smali_dir.replace(DECODED_DIR, '')
        break

if SMALI_PATH == "":
    raise RuntimeError("❗ Failed to find GTASA smali folder!")

# ##################################################################################################################

GTASA_INTERNAL_PATH = DECODED_DIR + SMALI_PATH + "/com/arizona/game/GTASA.smali"

print("[INFO] 🔗 Injecting NeoMLoader into GTASA.smali...")

with open(GTASA_INTERNAL_PATH, "r", encoding="utf-8") as file:
    smali_lines = file.readlines()

check_find_ag_client = False
check_connect = False

for i, line in enumerate(smali_lines):
    match1 = re.search(r'const-string(?:/jumbo)? (v\d+), "ag-client"', line)
    if match1:
        check_find_ag_client = True
        var_name = match1.group(1)
        
        if f"invoke-static {{{var_name}}}, Ljava/lang/System;->loadLibrary(Ljava/lang/String;)V" in smali_lines[i + 2]:
            smali_lines.insert(i + 4, f'\n    const-string {var_name}, "neomloader"\n\n    invoke-static {{{var_name}}}, Ljava/lang/System;->loadLibrary(Ljava/lang/String;)V\n\n')
            print("[INFO] ✅ NeoMLoader injected successfully!")
            check_connect = True
            break

if not check_find_ag_client:
    raise RuntimeError("❌ Failed to locate 'ag-client' in GTASA.smali.")

if not check_connect:
    raise RuntimeError("❌ Failed to locate 'ag-client' loadLibrary call in GTASA.smali.")

with open(GTASA_INTERNAL_PATH, "w", encoding="utf-8") as file:
    file.writelines(smali_lines)

##################################################################################################################

smali_numbers = []

for path in SMALI_CLASSES:
    name = os.path.basename(path)
    if name.startswith("smali_classes"):
        num = name.replace("smali_classes", "")
        if num.isdigit():
            smali_numbers.append(int(num))

if not smali_numbers:
    raise RuntimeError("❌ No smali_classes folders found!")

LATEST_SMALI = max(smali_numbers)

##################################################################################################################

PATH_SMALI_TOOLS = DECODED_DIR + f"/smali_classes{LATEST_SMALI + 1}"

print("[INFO] 🔧 Compiling MTG Tools from java files to smali...")

def compile_java_to_smali():
    classpath = f"libs/android.jar{os.pathsep}libs/unity-ads-4.4.1.jar"

    java_dir = "java" 
    java_files = glob.glob(os.path.join(java_dir, "*.java"))

    if not java_files:
        raise RuntimeError(f"❗ Java source files not found in {java_dir} folder!")

    try:
        print("[INFO] ⚙️ Java -> Class...")
        subprocess.run([
            "javac", 
            "--release", "8", 
            "-Xlint:-options",
            "-nowarn",
            "-cp", classpath
        ] + java_files, check=True)

        print("[INFO] ⚙️ Class -> Dex...")
        class_files = [os.path.join(java_dir, f) for f in os.listdir(java_dir) if f.endswith('.class')]
        subprocess.run([
            "java", "-cp", "libs/d8.jar", "com.android.tools.r8.D8", 
            "--release", 
            "--output", ".", 
            "--lib", "libs/android.jar",
            "--lib", "libs/unity-ads-4.4.1.jar"
        ] + class_files, check=True)

        print("[INFO] ⚙️ Dex -> Smali...")
        subprocess.run([
            "java", "-jar", "libs/baksmali.jar", 
            "d", "classes.dex", 
            "-o", PATH_SMALI_TOOLS
        ], check=True)

        print("[INFO] ✅ MTG Tools compiled successfully!")

    except subprocess.CalledProcessError as e:
        raise RuntimeError(f"❗ Failed compile MTG Tools: {e}")
    finally:
        if os.path.exists("classes.dex"):
            os.remove("classes.dex")
        
        for f in os.listdir(java_dir):
            if f.endswith('.class'):
                os.remove(os.path.join(java_dir, f))
                
compile_java_to_smali()

##################################################################################################################

PATH_SMALI_ADS = DECODED_DIR + f"/smali_classes{LATEST_SMALI + 2}"

print("[INFO] 🔧 Compiling Unity Ads from jar to smali...")

def compile_unity_ads_to_smali():
    unity_jars = [
        "libs/unity-ads-4.4.1.jar",
        "libs/unity-scaradapter-common.jar",
        "libs/unity-scaradapter-1920.jar",
        "libs/unity-scaradapter-1950.jar",
        "libs/unity-scaradapter-2000.jar",
    ]
    temp_dex_dir = "temp_unity_dex"

    for jar in unity_jars:
        if not os.path.exists(jar):
            raise RuntimeError(f"❗ Jar not found: {jar}")

    os.makedirs(temp_dex_dir, exist_ok=True)

    try:
        print("[INFO] ⚙️ Unity Ads Jar -> Dex...")
        
        subprocess.run([
            "java",
            "-cp", "libs/d8.jar",
            "com.android.tools.r8.D8",
            "--release",
            "--output", temp_dex_dir,
            "--lib", "libs/android.jar",
            *unity_jars
        ], check=True)

        print("[INFO] ⚙️ Dex -> Smali...")

        dex_file = os.path.join(temp_dex_dir, "classes.dex")
        subprocess.run([
            "java", "-jar", "libs/baksmali.jar",
            "d", dex_file,
            "-o", PATH_SMALI_ADS
        ], check=True)

    except subprocess.CalledProcessError as e:
        raise RuntimeError(f"❗ Failed compile Unity Ads: {e}")
    finally:
        if os.path.exists(temp_dex_dir):
            shutil.rmtree(temp_dex_dir)

    print("[INFO] ✅ Unity Ads compiled successfully!")

compile_unity_ads_to_smali()

##################################################################################################################

print("[INFO] 🔧 Moving androidx folder to smali_classes...")

src_move = os.path.join(DECODED_DIR, "smali_classes3", "androidx")
dst_move = os.path.join(DECODED_DIR, f"smali_classes{LATEST_SMALI + 3}", "androidx")
if os.path.exists(src_move):
    os.makedirs(os.path.dirname(dst_move), exist_ok=True)
    shutil.move(src_move, dst_move)

##################################################################################################################

MANIFEST_PATH = DECODED_DIR + "/AndroidManifest.xml"

print("[INFO] 📢 Adding Unity Ads activities to AndroidManifest.xml...")

with open(MANIFEST_PATH, "r", encoding="utf-8") as file:
    manifest_data = file.read()

new_activities = '''
<activity android:name="com.unity3d.services.ads.adunit.AdUnitActivity" android:configChanges="fontScale|keyboard|keyboardHidden|locale|mnc|mcc|navigation|orientation|screenLayout|screenSize|smallestScreenSize|uiMode|touchscreen" android:hardwareAccelerated="true" android:theme="@android:style/Theme.NoTitleBar.Fullscreen"/>
<activity android:name="com.unity3d.services.ads.adunit.AdUnitTransparentActivity" android:configChanges="fontScale|keyboard|keyboardHidden|locale|mnc|mcc|navigation|orientation|screenLayout|screenSize|smallestScreenSize|uiMode|touchscreen" android:hardwareAccelerated="true" android:theme="@android:style/Theme.Translucent.NoTitleBar.Fullscreen"/>
<activity android:name="com.unity3d.services.ads.adunit.AdUnitTransparentSoftwareActivity" android:configChanges="fontScale|keyboard|keyboardHidden|locale|mnc|mcc|navigation|orientation|screenLayout|screenSize|smallestScreenSize|uiMode|touchscreen" android:hardwareAccelerated="false" android:theme="@android:style/Theme.Translucent.NoTitleBar.Fullscreen"/>
<activity android:name="com.unity3d.services.ads.adunit.AdUnitSoftwareActivity" android:configChanges="fontScale|keyboard|keyboardHidden|locale|mnc|mcc|navigation|orientation|screenLayout|screenSize|smallestScreenSize|uiMode|touchscreen" android:hardwareAccelerated="false" android:theme="@android:style/Theme.NoTitleBar.Fullscreen"/>
'''

manifest_data = re.sub(
    r'(<activity[^>]+PlayCoreDialogWrapperActivity[^>]+/>)',
    r'\1' + new_activities,
    manifest_data
)

if 'com.unity3d.services.ads.adunit' in manifest_data:
    print("[INFO] ✅ Unity Ads activities added successfully!")
else:
    raise RuntimeError("❌ Failed to add Unity Ads activities to AndroidManifest.xml.")

with open(MANIFEST_PATH, "w", encoding="utf-8") as file:
    file.write(manifest_data)

##################################################################################################################

ARZ_SMALI_PATH = ""

for smali_dir in SMALI_CLASSES:
    smali_dir = smali_dir.replace('\\', '/')
    potential_path = smali_dir + "/com/arizona/launcher/UpdateService.smali"
    if os.path.isfile(potential_path):
        ARZ_SMALI_PATH = smali_dir.replace(DECODED_DIR, '')
        break

if ARZ_SMALI_PATH == "":
    raise RuntimeError("❗ Arizona Launcher smali folder not found!")

##################################################################################################################

MAIN_ENTRENCH_PATH = DECODED_DIR + ARZ_SMALI_PATH + "/com/arizona/launcher/MainEntrench.smali"

print("[INFO] 🔧 Injecting call MTG Tools...")

with open(MAIN_ENTRENCH_PATH, "r", encoding="utf-8") as file:
    smali_lines = file.readlines()

check_inject = False

for i, line in enumerate(smali_lines):
    match_toast = re.search(r'invoke-virtual {(v\d+)}, Landroid/widget/Toast;->show\(\)V', line)
    if match_toast:
        smali_lines.insert(i + 2, '    invoke-static {p0, p0}, Lcom/arizona/launcher/MtgTools;->initialize(Landroid/app/Activity;Landroid/content/Context;)V\n\n')
        check_inject = True
        break

if not check_inject: # FallBack
    for i, line in enumerate(smali_lines):
        if " onCreate(" in line:
            for j in range(i, len(smali_lines)):
                if "return-void" in smali_lines[j]:
                    smali_lines.insert(j, '    invoke-static {p0, p0}, Lcom/arizona/launcher/MtgTools;->initialize(Landroid/app/Activity;Landroid/content/Context;)V\n\n')
                    check_inject = True
                    break
            break

if not check_inject:
    raise RuntimeError("❌ Failed to inject MTGTools.")

version_pattern = re.compile(r'const-string v\d+, " v(\d+\.\d+\.\d+)')
version_app = "lua"

for line in smali_lines:
    match_version = version_pattern.search(line)
    if match_version:
        version_app = "v" + match_version.group(1)
        break

with open(MAIN_ENTRENCH_PATH, "w", encoding="utf-8") as file:
    file.writelines(smali_lines)

#################################################################################################################

UPDATE_SERVICE_PATH = DECODED_DIR + ARZ_SMALI_PATH + "/com/arizona/launcher/UpdateService.smali"

print("[INFO] 🔒 Disable client updates...")

with open(UPDATE_SERVICE_PATH, "r", encoding="utf-8") as file:
    smali_lines = file.readlines()

matches = [i for i, line in enumerate(smali_lines) if "needUpdateMsg" in line]

if len(matches) != 3:
    print("[INFO] ❌ Unexpected UpdateService structure (needUpdateMsg).")
    print("[INFO] ❌ Client updates not disabled!")
else:
    insert_index = matches[2]
    smali_lines.insert(insert_index + 2, "    const/4 p3, 0x0\n\n")

    with open(UPDATE_SERVICE_PATH, "w", encoding="utf-8") as file:
        file.writelines(smali_lines)

    print("[INFO] ✅ Client updates disabled successfully!")
    
##################################################################################################################

print("[INFO] ⚙️ Rebuilding APK...")
subprocess.run(["java", "-jar", APKTOOL_PATH, "b", DECODED_DIR], check=True)
print("[INFO] ✅ APK rebuilt successfully!")

##################################################################################################################

load_dotenv(os.path.join(PATH, ".env"))

SIGNED_APK = PATH + f"/{APK_NAME}.apk"
APKSIGNER_PATH = PATH + "/libs/apksigner.jar"
UNSIGNED_APK = DECODED_DIR + "/dist/" + APK_NAME + ".apk"

KEYSTORE_PATH = PATH + "/key.jks"
KEY_ALIAS = os.getenv("KEY_ALIAS")
KEY_PASS = os.getenv("KEY_PASS")
KEYSTORE_PASS = os.getenv("KEYSTORE_PASS") or KEY_PASS

if os.path.exists(SIGNED_APK):
    os.remove(SIGNED_APK)

print("[INFO] 🔐 Signing APK...")

if os.path.exists(KEYSTORE_PATH) and KEY_ALIAS and KEY_PASS:
    try:
        subprocess.run([
            "java",
            "--enable-native-access=ALL-UNNAMED",
            "-jar",
            APKSIGNER_PATH,
            "sign",
            "--ks", KEYSTORE_PATH,
            "--ks-key-alias", KEY_ALIAS,
            "--ks-pass", f"pass:{KEYSTORE_PASS}",
            "--key-pass", f"pass:{KEY_PASS}",
            "--out", SIGNED_APK,
            UNSIGNED_APK
        ], check=True)
        print(f"[INFO] ✅ Signed successfully!")
        print(f"[INFO] ℹ️ Your launcher {version_app}: {SIGNED_APK}")

        idsig = SIGNED_APK + ".idsig"
        if os.path.exists(idsig):
            os.remove(idsig)

    except subprocess.CalledProcessError as e:
        print(f"[ERROR] {e}")
else:
    print(f"[INFO] ➡️ Signing skipped (no keystore or env vars found)")
    shutil.move(UNSIGNED_APK, SIGNED_APK)
    print(f"[INFO] ℹ️ Your no_signed launcher {version_app}: {SIGNED_APK}")
    
##################################################################################################################

print("[INFO] ✅ Build process completed successfully!")

is_github_actions = os.environ.get("GITHUB_ACTIONS") == "true"

if not is_github_actions:
    print("[INFO] 🗑️ Remove temporary build directory...")
    shutil.rmtree(DECODED_DIR, ignore_errors=True)
    
##################################################################################################################

