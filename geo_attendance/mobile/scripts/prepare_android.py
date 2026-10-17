from pathlib import Path

manifest = Path('android/app/src/main/AndroidManifest.xml')
if not manifest.exists():
    raise SystemExit('Android project not found. Run flutter create --platforms=android ... first.')

text = manifest.read_text(encoding='utf-8')
permissions = '''\n    <uses-permission android:name="android.permission.INTERNET" />\n    <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />\n    <uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION" />'''

if 'android.permission.ACCESS_FINE_LOCATION' not in text:
    text = text.replace(
        '<manifest xmlns:android="http://schemas.android.com/apk/res/android">',
        '<manifest xmlns:android="http://schemas.android.com/apk/res/android">' + permissions,
    )

text = text.replace('android:label="geo_attendance"', 'android:label="Geo Attendance"')
manifest.write_text(text, encoding='utf-8')

# flutter_secure_storage 11.x requires Android SDK 23+.
gradle_kts = Path('android/app/build.gradle.kts')
if gradle_kts.exists():
    g = gradle_kts.read_text(encoding='utf-8')
    g = g.replace('minSdk = flutter.minSdkVersion', 'minSdk = 23')
    gradle_kts.write_text(g, encoding='utf-8')
else:
    gradle = Path('android/app/build.gradle')
    if gradle.exists():
        g = gradle.read_text(encoding='utf-8')
        g = g.replace('minSdkVersion flutter.minSdkVersion', 'minSdkVersion 23')
        gradle.write_text(g, encoding='utf-8')

print('Android project prepared: permissions, label, minSdk >= 23.')
