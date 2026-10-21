# TurathReplica

مشروع iOS Native بـ SwiftUI مبني من الصفر اعتمادًا على تحليل بنية تطبيق المتجر وطلبات الـAPI المسجلة، وليس WebView أو HTML.

## ما تم تنفيذه

- Splash بنمط FLOAT وحركات قريبة من التطبيق.
- Theme Night بالألوان المستخرجة من `StoreDesign`.
- Floating Tab Bar: الرئيسية، استكشف، التحديثات، المتجر، البحث.
- Home server-driven مع renderers: `CARD_BAND`, `SHOWCASE`, `CATEGORY_STRIP`, `CATEGORY_GRID`, `LIST_LARGE`.
- صفحة تفاصيل تطبيق مع بيانات الإصدار والحجم والملاحظات والخيارات والتقييم والتطبيقات المشابهة.
- Explore بنمط TILES.
- Search بنمط HERO.
- Updates مبني على feed API.
- Shop يقرأ cards API.
- شاشة حساب/اشتراك بنمط TICKET.
- Fallback data حتى تبقى الواجهة قابلة للمعاينة إذا تعذر الاتصال بالـAPI.
- GitHub Actions يبني IPA غير موقّع تلقائيًا.

## الخطوط

الكود يدعم أسماء الخطوط الأصلية تلقائيًا إذا أضيفت ملفات مرخّصة بهذه الأسماء داخل `StoreReplica/Resources/`:

- `PingARLT-Regular.ttf`
- `PingARLT-Medium.ttf`
- `PingARLT-Bold.ttf`
- `PingARLT-Black.ttf`

ملفات الخط نفسها غير مضمّنة في الريبو. بدونها يستخدم المشروع fallback قريب من iOS.

## API / UDID

لأسباب الخصوصية لا يحتوي المشروع على UDID الذي ظهر في ملف المراقبة. الـAPI base والـslug موجودان في `StoreReplica/StoreReplica.swift`. إذا كان خادمك يتطلب UDID، اربطه بمصدر آمن خاص بك بدل نشره داخل الريبو العام.

## البناء

من GitHub افتح **Actions → Build IPA → Run workflow**. الناتج يظهر كـ artifact باسم `TurathReplica-unsigned`.
