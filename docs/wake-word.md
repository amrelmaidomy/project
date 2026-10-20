# كلمة التنبيه الاختيارية على Android

> هذا الملف يشرح مسار ONNX القديم وتجربة Hey Jarvis الإنجليزية. نداء **«يا رفيق»**
> الحالي يستخدم Whisper على اللاب مع رد ومحادثة في الخلفية؛ راجع
> [تشغيل يا رفيق](rafiq.md). قيود انتظار فتح الواجهة المذكورة أدناه تخص مسار ONNX.

التطبيق يعمل بالزر والكتابة دون تشغيل كلمة التنبيه. مسار Android الاختياري يشغّل
نماذج ONNX الحقيقية محليًا: PCM ثم mel spectrogram ثم speech embedding ثم classifier.
**نموذج «يا مساعد» المدرّب غير موجود في المستودع**؛ لن تظهر حالة «بسمع يا مساعد»
ولن يُستبدل بصوت تجريبي. توجد تجربة منفصلة ومعلنة لعبارة **Hey Jarvis الإنجليزية**.

اختبارات الحفظ والمحادثة وWhisper في بيئة التطوير سبقت إضافة المسار الاختياري.
إثبات وصول إشعار والهاتف مغلق التطبيق، وتجربة ميكروفون Android والكلمة الإيجابية،
يحتاجان هاتفًا فعليًا وفق [اختبارات الجهاز](android-device-checks.md).

## تنزيل النموذج التجريبي مع التحقق

من جذر المشروع:

```bash
python3 scripts/fetch_wake_models.py --demo
# اختياري: تشغيل المراحل الثلاث فعليًا على CPU واختبار الصمت
backend/.venv/bin/python scripts/fetch_wake_models.py --demo --verify-inference
```

السكريبت ينزّل الملفات التالية من commit ثابت في مصدر Android الأصلي، عبر HTTPS
بفحص TLS الافتراضي، ويتحقق من SHA-256 قبل اعتماد كل ملف. النماذج المحفوظة سابقًا
تُفحص أيضًا، والملف المختلف لا يُستبدل إلا باستخدام `--replace` صراحةً. حد كل ملف
32 MiB. لا تنسخ روابط تنزيل خاصة أو رموز وصول إلى الكود: ملف `models.json` النهائي
يحتوي أسماء الملفات والبصمات والعبارة والعتبة فقط؛ روابط التنزيل تبقى خارج APK.

المصدر المثبت:
[`msnilsen/openwakeword-android`، b49f3ab14cf558ac0c2aef73a5e6c83da7a08558](https://github.com/msnilsen/openwakeword-android/tree/b49f3ab14cf558ac0c2aef73a5e6c83da7a08558/openwakeword/src/main/assets/openwakeword).
تمت مطابقة الملفات المنزلة مع محتويات هذا commit وحساب البصمات الفعلية:

| ملف داخل APK | SHA-256 |
|---|---|
| `melspectrogram.onnx` | `ba2b0e0f8b7b875369a2c89cb13360ff53bac436f2895cced9f479fa65eb176f` |
| `embedding_model.onnx` | `70d164290c1d095d1d4ee149bc5e00543250a7316b59f31d056cff7bd3075c1f` |
| `hey_jarvis.onnx` | `94a13cfe60075b132f6a472e7e462e8123ee70861bc3fb58434a73712ee0d2cb` |

تُحفظ الأصول في `mobile/android/app/src/main/assets/wakeword/`. ملفات ONNX
والـmanifest المُولّد مستثناة من Git؛ شغّل التنزيل قبل إعادة بناء APK عند الحاجة
للتجربة. عند غياب الأصول تبقى تجربة الكلمة غير متاحة، وباقي التطبيق يعمل.

بعد إعادة البناء وتثبيت التطبيق، افتح شاشة المساعد واضغط **تجربة Hey Jarvis**
صراحةً. اسمح بالميكروفون والإشعارات. سيظهر إشعار دائم به زر «إيقاف». لا ينتظر
هذا النموذج عبارة «يا مساعد». إيقاف الخدمة من الإشعار يوقف الميكروفون ويحدّث
حالة Flutter؛ إعادة فتح التطبيق أو إعادة تشغيل الهاتف لا تعيدان تفعيلها تلقائيًا.

## عقد النماذج الحقيقي

مستوحى من [Android port](https://github.com/msnilsen/openwakeword-android) ومن
[`openWakeWord AudioFeatures`](https://github.com/dscripka/openWakeWord/blob/main/openwakeword/utils.py).
المعالجة مستقلة عن Whisper ولا ترسل الصوت إلى الخادم:

| المرحلة | الإدخال الفعلي FLOAT32 | المخرج المطلوب |
|---|---|---|
| PCM | 16 kHz، mono، int16 محوّل إلى float **دون قسمة على 32768** | إطار 1280 عينة/80 ms |
| mel | `[1,1760]`، إطار + تداخل 480 عينة | `[1,1,8,32]`، ثم `x / 10 + 2` |
| embedding | `[1,76,32,1]`، نافذة mel متحركة | `[1,1,1,96]` |
| classifier | `[1,16,96]`، آخر 16 embedding | `[1,1]` واحتمال محدود بين 0 و1 |

يتحقق Kotlin من عدد المداخل والمخارج وأنواعها وأبعادها عند التحميل، ومن الأبعاد
والقيم المحدودة عند كل استدلال. النموذج غير المتوافق يعرض خطأ واضحًا. لا تتحول
أخطاء الاستدلال إلى نتيجة كشف صورية أو قيمة نجاح. يبدأ التقييم بعد تراكم نوافذ
صوت حقيقية؛ توجد فترة تهيئة تقارب ثانيتين بعد بدء الاستماع أو استئنافه.

نتيجة اختبار البيئة بتاريخ 19 أكتوبر 2026: تشغيل فعلي للمراحل الثلاث على CPU
أنتج 16 توقعًا للصمت، وأقصى نتيجة لـHey Jarvis كانت `0.00000504`، أقل من العتبة
`0.6`. هذه نتيجة تنفيذ نماذج حقيقية والتحقق من tensors؛ لا تثبت حساسية الكلمة
الإيجابية، أو دقة اللهجات، أو تكامل AudioRecord على هاتف.

## الميكروفون والخلفية

تستخدم الخدمة `foregroundServiceType="microphone"`، تبدأ فقط من تطبيق ظاهر
بعد اختيار المستخدم، وتبقى بإشعار دائم وزر إيقاف. العمليات `start/pause/resume/stop`
متسلسلة. `pause` لا ينجح إلا بعد توقف `AudioRecord` وانتهاء thread التسجيل؛ عند
الفشل لا يفتح المساعد مسجلًا منافسًا. تُغلق tensors والنتائج وsessions بوضوح،
ويظل `OrtEnvironment` المشترك على مستوى العملية مفتوحًا للمستخدمين الآخرين.

عند الكشف توقف الخدمة ميكروفونها **قبل** إرسال الحدث إلى Flutter. يوقف المساعد
الاستماع طوال «معاك»، والتسجيل، وWhisper، وفهم الموعد، والرد المنطوق؛ ثم يستأنف
فقط إذا كانت الميزة لا تزال مفعّلة. إلغاء المستخدم للخدمة أثناء المحادثة يمنع
إعادة تشغيلها من callback متأخر.

عندما يكون التطبيق ظاهرًا وFlutter engine متصلًا، يصل الحدث فتُفتح صفحة المساعد
ويبدأ نفس مسار زر الميكروفون. عند إخفاء التطبيق لا تبدأ Activity تلقائيًا ولا
تُفتح جلسة تسجيل سرية: يُحتفظ بالكشف وتعرض الخدمة إشعار «سمعت العبارة، افتح التطبيق».
يضغط المستخدم الإشعار؛ بعد استئناف Flutter يُسلّم الكشف مرة واحدة. إذا انفصل
Flutter engine واستمرت خدمة Android، يقرأ engine الجديد حالة الخدمة عند الاتصال.
هذه ليست بنية headless Flutter ولا تعِد بإيقاظ تطبيق أوقفه Android أو المستخدم
إجباريًا. لا تبدأ الخدمة بعد reboot، ولا تعيد تشغيل نفسها بعد قتل العملية؛
التفعيل يتم يدويًا من جديد. الحالة المعلّقة محلية في العملية وليست سجلًا دائمًا
بعد قتلها. تذكيرات المواعيد المجدولة لها boot receiver مستقل عن خدمة الكلمة.

قنوات المضيف:

```text
MethodChannel: com.ma3ak.reminder/wake_word
  status, start({profile}), stop, pause, resume, acknowledgeDetection
EventChannel: com.ma3ak.reminder/wake_word/events
  status أو detected، مع enabled/listening/profile/phrase/message
  pendingDetection/detectionId/score عند الكشف
```

`WakeWordService` يقدّم `status` وstream باسم `detections`. يمنع تسليم الكشف
الخلفي إلى واجهة Dart حتى تصبح `AppLifecycleState.resumed`، ويتحقق من المنصة
قبل الاتصال بالقنوات؛ النسخ غير Android تعرض حالة غير متاحة دون محاولة ميكروفون.

## تدريب «يا مساعد» وإضافتها

التدريب الحقيقي يحتاج بيانات وتقييمًا؛ لا يوجد classifier عربي مُختلق أو نموذج
إنجليزي أُعيدت تسميته. استخدم [التدريب الرسمي لـopenWakeWord](https://github.com/dscripka/openWakeWord/tree/main/examples)
و[`custom_model.yml`](https://github.com/dscripka/openWakeWord/blob/main/examples/custom_model.yml)
لتوليد/تحضير البيانات وتصدير ONNX المتوافق. المواد المطلوبة وفق تصميم المشروع:

1. اجمع بموافقة أصحاب التسجيلات 15 متحدثًا × 20 مرة لعبارة «يا مساعد» كبداية
   لبيانات حقيقية، مع تنوع الجنس والمسافة والضوضاء ومستوى الصوت.
2. اجمع negatives مثل «يا محمد»، «يا معلم»، «ساعدني»، «مساعد»، «المساعد»،
   «يا محمود»، وأصوات محادثة طبيعية طويلة. احتفظ باختبار منفصل لمتحدثين لم
   يدخلوا التدريب. المجموعة الأولية 300 مقطع لا تكفي لادعاء نموذج نهائي؛
   وصفة upstream تعتمد عينات موجبة مولدة كثيرة، مع augmentation وبيانات سالبة.
3. درّب باستخدام وصفة upstream وثبّت إصدارها وإعداداتها. صدّر `ya_mosaed.onnx`
   بعقد `[1,16,96] -> [1,1]`. قيّم false activations/hour، ومعدل فقد الكلمة،
   والضوضاء، والبطارية، ثم اختر threshold من بيانات validation.
4. احسب SHA-256 للملف **من artifact التدريب الموثوق** قبل نشره عبر HTTPS.
   أنشئ manifest محليًا خارج Git بروابط تنزيلك، مستخدمًا مدخلي mel/embedding
   المثبتين أعلاه، وأضف داخل `classifiers`:

```json
{
  "ya_mosaed": {
    "file": "ya_mosaed.onnx",
    "url": "https://YOUR_MODEL_HOST/ya_mosaed.onnx",
    "sha256": "PUT_THE_ACTUAL_64_HEX_SHA256_FROM_TRAINING_HERE",
    "phrase": "يا مساعد",
    "threshold": 0.6
  }
}
```

هذا مقتطف توضيحي وليس manifest صالحًا للتنفيذ؛ يجب أن يحتوي الملف الكامل
`version: 1` و`mel` و`embedding` و`classifiers`، ولكل نموذج `file/url/sha256`.
السكريبت يرفض placeholders. يمكن نسخ `DEMO` من السكريبت محليًا وتغيير قسم
classifier فقط؛ `hey_jarvis` و`ya_mosaed` ملفان منفصلان واختياران منفصلان.

```bash
python3 scripts/fetch_wake_models.py --manifest /path/to/reviewed-private-manifest.json --replace
# اختبر تشغيل الأبعاد والصمت، ثم أعد بناء APK واختبر المتحدثين الحقيقيين
backend/.venv/bin/python scripts/fetch_wake_models.py --manifest /path/to/reviewed-private-manifest.json --verify-inference
```

احتفظ بالـmanifest الخاص خارج المستودع إذا احتوت روابطه على توقيع مؤقت. لا تُحفظ
الروابط في metadata المعبأة في Android. لا تفعّل خيار «يا مساعد» للاستخدام النهائي
قبل قياس الكلمة الصحيحة والـnegatives على الهاتف والتحقق من تبادل الميكروفون.

## المصدر والترخيص

خوارزمية البث مقتبسة بتعديلات في إدارة الخدمة والموارد والتحقق من الأبعاد من
`msnilsen/openwakeword-android` commit
`b49f3ab14cf558ac0c2aef73a5e6c83da7a08558`، Apache License 2.0؛ النسخة الكاملة
في [LICENSE.openwakeword](../mobile/lib/features/wake_word/LICENSE.openwakeword).
نموذج Google speech embedding منشور بترخيص Apache 2.0. نماذج wake الجاهزة من
openWakeWord ومنها Hey Jarvis مرخصة [CC BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/)،
ولهذا تُوصف تجربة Hey Jarvis هنا بأنها تجربة إنجليزية اختيارية. راجع تراخيص
[upstream](https://github.com/dscripka/openWakeWord#license) عند إعادة توزيع النماذج.
