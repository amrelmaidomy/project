# تشغيل معاك على اللاب من Android Studio

المقصود هنا تشغيل **تطبيق Android داخل محاكي على Windows**. الموديلان يعملان
في خادم على نفس اللاب: Whisper `large-v3-turbo` لتفريغ الصوت، وHabibi
`Specialized/EGY` مع Vocos لنطق الرد المصري. المواعيد تبقى محلية داخل Android.
لا يحتاج المحاكي توصيل هاتف أو `adb reverse`.

الجهاز المستهدف للتجربة: HP ZBook 15 G6، RAM20GB، NVIDIA Quadro T2000 4GB.
ابدأ بمحاكي واحد وRAM3GB. إصدار CPU للخادم متحقق منه محليًا، لكنه بطيء في
توليد الصوت. إعداد CUDA اختياري ومناسب للتجربة على كارتك؛ لم يُختبر على T2000
في بيئة التطوير، وقد يحتاج تحديث تعريف NVIDIA. لا يلزم تنزيل CUDA Toolkit.

للتوقعات: في بيئة التجربة ذات4أنوية، توليد حوالي4ثواني صوت أخذ202ثانية على
CPU. الردود الطويلة قد تتجاوز مهلة5دقائق وتفشل. لذلك تشغيل Habibi على CPU يصلح
لفحص التوصيل، وقد لا يناسب محادثة متواصلة. تجربة الكارت عندك هي الخطوة التالية،
مع مراجعة وضوح النطق والأرقام قبل الاعتماد على الصوت لتأكيد المواعيد.

## 1. البرامج المطلوبة مرة واحدة

1. نزّل [Android Studio](https://developer.android.com/studio)، وشغّل المعالج الأولي.
2. نزّل [Flutter SDK3.35.7 لويندوز](https://storage.googleapis.com/flutter_infra_release/flutter/stable/windows/flutter_windows_3.35.7-stable.zip).
   فكّه في مجلد ثابت خارج OneDrive، مثل `C:\Users\amrel\Tools\flutter`.
3. من Android Studio افتح **Settings > Plugins > Marketplace**، ثبّت **Flutter**
   ووافق على إضافة **Dart**، ثم أعد فتح Android Studio.
4. من **SDK Manager** ثبّت Android SDK Platform36، وPlatform35 للإضافات،
   وSDK Build-Tools36.0.0 و35.0.0، وPlatform-Tools وCommand-line Tools وAndroid Emulator.
5. افتح PowerShell وشغّل من مسار Flutter الذي اخترته:

   ```powershell
   & "$env:USERPROFILE\Tools\flutter\bin\flutter.bat" doctor --android-licenses
   & "$env:USERPROFILE\Tools\flutter\bin\flutter.bat" doctor
   ```

   وافق على تراخيص Android. متطلبات Visual Studio تخص تطبيقات Windows؛ هدفنا Android.
6. يستخدم إعداد الخادم `uv.exe` الذي جهزته سابقًا. انسخه إلى `backend` في المصدر
   الجديد. إن لم يكن لديك، نزّل [ZIP uv الرسمي لويندوز](https://github.com/astral-sh/uv/releases/latest/download/uv-x86_64-pc-windows-msvc.zip)
   وفكّه، ثم انسخ `uv.exe` إلى `backend`. لا تحتاج تثبيت Python يدويًا.

## 2. تجهيز الموديلين والخادم

فك مصدر المشروع في مجلد جديد، وافتح PowerShell في **جذر المشروع**: المجلد الذي
يحتوي `backend` و`mobile` و`scripts`. على ZBook المزود بكارت NVIDIA، لتجربة
تشغيل Habibi على الكارت مع إبقاء Whisper على CPU/int8:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\setup-windows.ps1 -UseCuda
```

يتحقق السكريبت من وجود تعريف NVIDIA، ويثبت بيئة Habibi CUDA مستقلة. لو لم يكن
التعريف متاحًا أو أردت البدء بالمسار المتحقق منه CPU، استخدم:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\setup-windows.ps1
```

لا تشغّل الإعدادين معًا. لكل اختيار بيئته المنفصلة، وملف الإعداد المحلي يحدد
الاختيار الأخير. أول إعداد قد ينزّل عدة جيجابايت من مكتبات التشغيل إضافة إلى
الموديلات؛ انتظر عبارة **Setup complete**. إعداد CUDA يحتاج مساحة أكبر من CPU.

الإعداد يعيد استخدام `WhisperModels\large-v3-turbo` والتنزيلات المصرية الموجودة
في `Downloads` أو `TTSModels` عندما تطابق البصمات، ويكمل الناقص فقط. ينزّل نسخة
EGY وحدها وVocos؛ لا ينزّل Unified أو باقي اللهجات. الإعدادات تحفظ في
`.local/model-config.json`، والموديلات افتراضيًا في `%USERPROFILE%\Ma3akModels`.
[تفاصيل المصادر والعينة المرجعية](model-setup.md).

شغّل الخادم واترك هذه النافذة مفتوحة:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\start-backend-windows.ps1
```

افتح في متصفح اللاب `http://127.0.0.1:8000/health`. `status: ok` يعني أن API يرد؛
حالة `speech` و`tts` تبدأ `not_loaded` وتتحول `ready` بعد أول طلب ناجح. ظهور
`not_loaded` لا يثبت أن النماذج شغالة. عند الخطأ تعرض الحالة السبب.

## 3. إنشاء المحاكي

1. من **Tools > Device Manager > Create Device** اختَر هاتفًا متوسطًا.
2. نزّل صورة **Android15 / API35 / x86_64 / Google APIs**، ثم أنشئ الجهاز.
3. اضبط RAM على3072MB. عند تشغيل Habibi على T2000 اختَر **Graphics: Software**
   أو **SwiftShader** لتترك ذاكرة الكارت للموديل. ابدأ بمحاكي واحد.
4. شغّل المحاكي. لو طلب تفعيل Virtualization، فعّل Intel VT-x من BIOS ثم
   **Windows Hypervisor Platform** من ميزات Windows وأعد التشغيل.
5. من **Extended Controls > Microphone** فعّل **Virtual microphone uses host
   audio input**. اسمح لبرامج سطح المكتب باستخدام الميكروفون من إعدادات خصوصية
   Windows، واختر ميكروفونك الصحيح في إعدادات الصوت. ارفع صوت الوسائط.

## 4. فتح المشروع وتشغيله

1. في Android Studio اختَر **Open** وافتح مجلد **`mobile`**؛ هذا مشروع Flutter.
2. لو طلب Flutter SDK، اختَر مجلد `Tools\flutter`، ثم انتظر **Pub get**.
3. من شريط الأجهزة اختَر المحاكي الذي شغّلته.
4. افتح `lib/main.dart` واضغط زر **Run ▶**. العنوان الافتراضي للخادم
   `http://10.0.2.2:8000`، وهو عنوان اللاب من داخل محاكي Android.
5. لو لم يجلب Android Studio الحزم تلقائيًا، افتح Terminal داخله وشغّل
   `flutter pub get --enforce-lockfile`. استخدم مسار `flutter.bat` الكامل إذا لم
   تضفه إلى PATH. الأخطاء في Build تحتاج قراءة رسالتها؛ `flutter doctor` يساعد
   على تحديد SDK أو التراخيص الناقصة.

لا تغيّر عنوان API إلى `127.0.0.1` داخل المحاكي؛ هذا يشير للمحاكي نفسه.

## 5. التجربة بالترتيب

1. افتح صفحة المساعد واكتب: **عندي دكتور بكرة الساعة خمسة العصر، فكرني قبله بساعتين**.
   يجب أن تظهر التفاصيل. انتظر صوت Habibi؛ أول رد يحمل النموذج وقد يتأخر، خصوصًا
   في CPU. الحفظ يحتاج تأكيدك، ولا يتوقف على نجاح الصوت.
2. جرّب زر الميكروفون واسمح بالإذن. راجع النص الظاهر، ثم أكّد الموعد إن كان صحيحًا.
3. اضغط **تشغيل يا رفيق** واسمح بالإشعارات والمنبّهات الدقيقة. قل **يا رفيق**، ثم
   انتظر الرد قبل قول الموعد. يظهر **آخر كلام سمعته** لتشخيص التفريغ، و**بجهّز الرد
   بصوت Habibi** أثناء التوليد. عند طلب التأكيد قل **أيوه احفظ** أو **إلغاء**.
4. جرّب Home داخل المحاكي، ثم النداء. هذه تجربة Android؛ جودة ميكروفون المحاكي
   ليست قياسًا لميكروفون Samsung الفعلي.

إذا ظهر OOM/CUDA، أوقف الخادم وأعد الإعداد دون `-UseCuda` للرجوع لمسار CPU، أو
أغلق التطبيقات التي تستخدم VRAM وأعد الاختبار. مسار CPU أبطأ. لا يوجد تحويل
صامت لصوت Google أو Samsung عند فشل Habibi؛ يعرض التطبيق رسالة واضحة.

## 6. الهاتف يأتي بعد نجاح المحاكي

عند الانتهاء من الاختبار، صِل A52 وفعّل USB debugging ثم من `mobile`:

```powershell
adb reverse tcp:8000 tcp:8000
flutter run --dart-define=API_BASE_URL=http://127.0.0.1:8000
```

ولإنشاء APK للهاتف بعد ذلك:

```powershell
flutter build apk --debug --split-per-abi --target-platform android-arm64 --dart-define=API_BASE_URL=http://127.0.0.1:8000
```

الموديلان سيبقيان على اللاب في هذه البنية؛ الهاتف أو المحاكي يسجل ويشغل WAV
والتنبيهات. اختبار الشاشة المقفولة والبطارية ووصول التنبيه يحتاج الجهاز الفعلي.
