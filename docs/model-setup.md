# النماذج المحلية المستخدمة

- **Whisper large-v3-turbo** بصيغة faster-whisper/CTranslate2، حوالي1.62GB.
  المصدر `dropbox-dash/faster-whisper-large-v3-turbo` عند commit
  `0a363e9161cbc7ed1431c9597a8ceaf0c4f78fcf`؛ هذا هو الاسم الحالي للمستودع الذي
  كان باسم `mobiuslabsgmbh`. التشغيل الافتراضي CPU/int8.
- **Habibi-TTS Specialized/EGY**، checkpoint حوالي1.35GB و`vocab.txt` المطابق.
  المصدر `SWivid/Habibi-TTS` عند
  `3ad11a152851245c002156526c5e1d0b12f2b9d5`، مجلد `Specialized/EGY`.
- **Vocos mel24kHz**، حوالي54MB، لتحويل مخرجات Habibi إلى WAV. المصدر
  `charactr/vocos-mel-24khz` عند `0feb3fdd929bcd6649e0e7c5a688cf7dd012ef21`.

`scripts/prepare-models.py` يثبت المصادر والبصمات الفعلية SHA-256 لكل ملف. يعيد
استخدام التنزيل الصحيح، ويحفظ الملفات الجديدة في staging ثم يتحقق قبل اعتمادها.
لا يستبدل ملفًا مختلفًا بلا اختيار صريح `--replace`. خيار `--offline` يسمح بإعادة
التحقق دون شبكة، و`--list` يعرض الملفات المطلوبة دون تنزيل. النماذج خارج المستودع
ولا تدخل مصدر ZIP أو APK. لا يحتاج تنزيلها مفتاح API.

## العينة المرجعية للصوت

Habibi يحتاج عينة صوت مع تفريغها. الوضع التجريبي يستخدم `assets/EGY.mp3` المرفقة
بحزمة `habibi-tts`؛ [توثيق العينات الرسمي](https://github.com/SWivid/Habibi-TTS/blob/main/src/habibi_tts/assets/README.md)
يذكر أنها مثال من مكتبة أصوات ElevenLabs. لا نعيد استضافة هذه العينة في المشروع،
ولا نعتبر ترخيص كود Habibi تصريحًا مستقلًا لإعادة توزيع العينة.

يمكن اختيار تسجيلك المصري الخاص، من0.5 إلى12 ثانية، بتفريغ مطابق، عند الإعداد:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\setup-windows.ps1 -ReferenceAudio "C:\MyVoice\reference.wav" -ReferenceText "النص المطابق للتسجيل بالكامل"
```

أضف `-UseCuda` لاختيار بيئة GPU. يمكن تعديل `TTS_REFERENCE_AUDIO` و
`TTS_REFERENCE_TEXT` في `.local/model-config.json` وإعادة تشغيل الخادم.
لا يسجل التطبيق عينة صوتك أو يغيرها تلقائيًا.

## التشغيل والعزل

الخادم الأساسي يحتفظ ببيئته وقفل uv. يستخدم Habibi بيئة مستقلة
`backend/tts_runtime/.venv` مع Torch CPU مثبت المصدر؛ اختيار CUDA له مشروع وقفل
منفصلان تحت `backend/tts_runtime/cuda`. القفل لا يعني أن CUDA جُرّب على كل جهاز.
الـworker يحافظ على النموذج بعد التحميل، ويعمل على طلب واحد في المرة بمهلة300ثانية.
لا يحمّل نموذجًا أثناء `/health` أو بدء API. عند نقص ملف أو فشل التوليد يرجع503
وحالة خطأ؛ لا يرجع WAV صوريًا ولا صوتًا من محرّك الهاتف.

`POST /synthesize` يأخذ JSON بحقل `text` حتى600حرف ويرجع PCM16 WAV. يبقى التسجيل
متوقفًا أثناء التوليد والتشغيل؛ انتظر انتهاء الرد. توجد ذاكرة مؤقتة محدودة لآخر
8ردود صغيرة في RAM، وتُزال ملفات WAV المؤقتة بعد الطلب. تُغلق العملية عند إغلاق
الخادم. `/health` يعرض `speech` و`tts` بصورة مستقلة.

الإعداد الافتراضي يستخدم32خطوة توليد ومعالجة العينة كما في كود Habibi الرسمي.
تجربة CPU حقيقية استغرقت201.85ثانية لإنتاج3.979ثانية صوت؛ زمن لابك قد يختلف.
الرد الطويل قد يتجاوز مهلة300ثانية. اختبار التفريغ الآلي استعاد المعنى الأساسي
للرد وحذف التحية الأولى؛ يلزم الاستماع وفحص نطق الأرقام على جهازك.
نتائج CUDA على T2000 4GB لم تُقَس هنا. [سجل التحقق](validation.md).

لفحص التوليد خارج التطبيق والخادم شغّال، من جذر المشروع:

```powershell
.\backend\uv.exe run --project backend --frozen --no-dev python scripts/smoke_voice_models.py
```

يحفظ الرد في `dist/habibi-reply.wav` للاستماع. أضف `--audio "C:\MyVoice\test.wav"`
لاختبار Whisper أيضًا بتسجيل WAV حقيقي. نجاح الطلب لا يضمن أن كل كلمة منطوقة صحيحة.

ملفات النماذج المحددة منشورة بتراخيصها: Whisper/التحويل تحت MIT، نسخة EGY من
Habibi تحت Apache2.0 وفق بطاقة النموذج، وVocos تحت MIT. احتفظ بالتوثيق الأصلي
والتراخيص عند إعادة التوزيع. بقية لهجات Habibi وUnified لها شروط مختلفة؛ ليست
جزءًا من هذا الإعداد.
