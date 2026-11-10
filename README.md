# مشروع عجلة الحظ

الملفات:
- `index.html`  الموقع كاملًا (مفتاح Supabase موضوع فيه). هذا هو الملف الذي ترفعه على الاستضافة.
- `supabase/migrations/20261110000000_init.sql`  الجداول والدوال والأمان.
- `supabase/templates/confirm.html`  قالب رسالة الرمز.
- `supabase/config-snippet.toml`  إعداد طول الرمز (6) والقالب للأمر `config push`.

## الخطوات

1. قاعدة البيانات (اختر طريقة واحدة):
   - من لوحة Supabase: SQL Editor ثم الصق محتوى ملف `20261110000000_init.sql` ثم Run.
   - أو من الطرفية داخل هذا المجلد:
     `supabase login` ثم `supabase init` ثم `supabase link --project-ref zlitjengxfrlyvhypzxv` ثم `supabase db push`
2. رمز التحقق (من اللوحة، وهو الأسلم):
   - Authentication ثم Sign In / Providers ثم Email: اجعل OTP Length = 6.
   - Authentication ثم Email Templates ثم Confirm signup: الصق محتوى `confirm.html` في تبويب Source واحفظ.
3. روابط التحقق: من Authentication ثم URL Configuration اجعل **Site URL** رابط موقعك بعد رفعه (مثل https://اسم.netlify.app)، وأضفه أيضًا إلى **Redirect URLs**، وإلا يعيد الرابط المستخدم إلى localhost.
4. ارفع `index.html` على Netlify Drop (app.netlify.com/drop) داخل مجلد.
5. سجّل حسابك من الموقع، ثم شغّل في SQL Editor (بعد وضع بريدك):
   `update public.profiles set is_admin = true where email = lower('بريدك@example.com');`
6. سجّل الخروج والدخول من جديد فيظهر زر «لوحة الإدارة».

## ضبطات اختيارية
- احتمالات العجلة: دالة `spin` في ملف SQL (الأوزان والقيم).
- سعر النقطة وتكلفة الدورة: `RATE` و`COST` في `index.html` وما يقابلهما في ملف SQL.
- صورة باركود شام كاش: المتغير `SHAM_QR` في `index.html`.
