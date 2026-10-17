# Geo Attendance

نظام حضور وانصراف يعتمد على الموقع الجغرافي. يتكون من تطبيق Flutter للموظفين وخادم FastAPI يتحقق من النطاق الجغرافي على الخادم قبل قبول أي عملية حضور أو انصراف.

## المكونات

- `mobile/` تطبيق Flutter (Android أولاً، وقابل للتوسعة إلى iOS).
- `backend/` خادم FastAPI + SQLAlchemy.
- `.github/workflows/android-build.yml` بناء APK تلقائياً من GitHub Actions.
- `.github/workflows/backend-tests.yml` اختبارات الخادم تلقائياً.

## منطق الأمان في النسخة الحالية

1. المستخدم يسجل الدخول برمز موظف + PIN.
2. أول جهاز يسجل الدخول يرتبط بالحساب بواسطة `device_id` محفوظ في التخزين الآمن.
3. التطبيق يطلب موقعاً عالي الدقة عند الضغط على حضور/انصراف فقط.
4. إذا أبلغ Android أن الموقع Mock يتم رفض العملية قبل إرسالها، ويعيد الخادم التحقق من العلم المرسل أيضاً.
5. الخادم يحسب المسافة فعلياً بين موقع الموظف وموقع العمل باستخدام Haversine.
6. إذا تجاوزت المسافة نصف القطر المسموح أو كانت دقة الموقع أسوأ من الحد المحدد، تُرفض العملية.
7. وقت العملية يؤخذ من الخادم وليس من ساعة الهاتف.

> ملاحظة مهمة: GPS/Mock detection وحدهما لا يضمنان منع التحايل 100%. للإصدار الإنتاجي عالي الأمان أضف Play Integrity وBLE Beacon أو شبكة Wi‑Fi موثوقة داخل الموقع.

## تشغيل الخادم محلياً

```bash
cd backend
python -m venv .venv
source .venv/bin/activate   # Windows: .venv\\Scripts\\activate
pip install -r requirements.txt
cp .env.example .env
# عدّل الإحداثيات والـ PIN والمفاتيح في .env
uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
```

افتح:

- `http://127.0.0.1:8000/health`
- `http://127.0.0.1:8000/docs`

## إعداد موقع العمل

داخل `backend/.env` عدّل القيم التالية إلى الإحداثيات الحقيقية:

```env
WORKSITE_NAME=Main Site
WORKSITE_LATITUDE=0.0
WORKSITE_LONGITUDE=0.0
WORKSITE_RADIUS_METERS=50
MAX_LOCATION_ACCURACY_METERS=35
```

عندما تكون الإحداثيات `0.0 / 0.0` يبقى موقع العمل **معطلاً تلقائياً** ولن يقبل الخادم أي حضور. أدخل الإحداثيات الحقيقية ثم أعد تشغيل الخادم.

استخدم HTTPS للخادم في النسخة المثبتة على الهاتف؛ الإصدار Release لا يفعّل HTTP غير المشفر.

## الحساب الأولي

يتم إنشاء مستخدم تجريبي عند أول تشغيل حسب `.env`:

```env
BOOTSTRAP_EMPLOYEE_CODE=EMP001
BOOTSTRAP_EMPLOYEE_NAME=Demo Employee
BOOTSTRAP_EMPLOYEE_PIN=ChangeMe1234
```

غيّر هذه القيم قبل النشر الحقيقي.

## بناء APK محلياً

يتعمد المستودع توليد مجلد Android من Flutter لتقليل الملفات الثابتة والمحافظة على توافقه مع Flutter الحديث:

```bash
cd mobile
flutter create --platforms=android --org com.geoattendance --project-name geo_attendance .
python scripts/prepare_android.py
flutter pub get
flutter build apk --release --dart-define=API_BASE_URL=https://YOUR-BACKEND.example.com
```

## بناء APK على GitHub

1. ارفع المشروع إلى GitHub.
2. افتح `Actions`.
3. اختر **Build Android APK**.
4. اضغط **Run workflow**.
5. أدخل عنوان الخادم مثل `https://attendance.example.com`.
6. بعد نجاح البناء، نزّل Artifact باسم `geo-attendance-apk`.

GitHub Actions يستخدم Flutter 3.47.0 وقناة stable.

## تشغيل اختبارات الخادم

```bash
cd backend
pip install -r requirements.txt
pytest -q
```

## ما هو غير مضاف بعد

- لوحة إدارة Web كاملة.
- Play Integrity / App Attest.
- BLE Beacon.
- إدارة موظفين متعددة من الواجهة.
- توقيع Release مخصص لمتجر Google Play.
- iOS build workflow.

هذه العناصر مناسبة للمرحلة الثانية بعد تحديد موقع العمل الفعلي وسياسة الدوام.
