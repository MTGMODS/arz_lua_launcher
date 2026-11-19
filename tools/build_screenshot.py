"""Build a DEX JAR and ready-to-install NeoMLoader screenshot ZIP."""
from pathlib import Path
import argparse
import json
import shutil
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def write_zip(path, entries):
    path.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(path, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
        for name, data in sorted(entries.items()):
            info = zipfile.ZipInfo(name, date_time=(2020, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(info, data)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--java', default=shutil.which('java'))
    parser.add_argument('--javac', default=shutil.which('javac'))
    args = parser.parse_args()
    if not args.java or not args.javac:
        parser.error('A JDK with java and javac is required; use --java and --javac for explicit paths.')
    sdk = ROOT / 'libs/android.jar'
    source = ROOT / 'tools/screenshot/ScreenshotBridge.java'
    output = ROOT / 'files/assets/neomloader/lib/android/jar/mtg-screenshot.jar'
    with tempfile.TemporaryDirectory(prefix='mtg-screenshot-') as tmp:
        classes, dex = Path(tmp) / 'classes', Path(tmp) / 'dex'
        classes.mkdir(); dex.mkdir()
        subprocess.run([args.javac, '--release', '8', '-encoding', 'UTF-8', '-cp', str(sdk),
                        '-d', str(classes), str(source)], check=True)
        inputs = sorted(str(path) for path in classes.rglob('*.class'))
        subprocess.run([args.java, '-cp', str(ROOT / 'libs/d8.jar'), 'com.android.tools.r8.D8',
                        '--release', '--min-api', '24', '--lib', str(sdk), '--output', str(dex)] + inputs, check=True)
        data = (dex / 'classes.dex').read_bytes()
        if not data.startswith(b'dex\n'):
            raise RuntimeError('Compiler output is not a DEX file')
        write_zip(output, {'classes.dex': data})
    package = ROOT / 'dist/mtg-screenshot.zip'
    write_zip(package, {
        'lib/android/jar/mtg-screenshot.jar': output.read_bytes(),
        'lib/android/screenshot.lua': (ROOT / 'files/assets/neomloader/lib/android/screenshot.lua').read_bytes(),
        'Screenshot.lua': (ROOT / 'tools/screenshot/Screenshot.lua').read_bytes(),
        'README.md': (ROOT / 'tools/screenshot/README.md').read_bytes(),
    })
    print(json.dumps({'jar': str(output), 'package': str(package), 'dex_bytes': len(data)}))


if __name__ == '__main__':
    main()
