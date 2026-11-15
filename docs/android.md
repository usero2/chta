# Android preview

แอป Android ใช้ Flutter UI ร่วมกับ Web/Desktop และเรียก Rust `cht-core` ผ่าน FFI โดยตรง ไม่ต้องเปิดเว็บเซิร์ฟเวอร์เพื่อแสดงหน้าแอป

## ตรวจปลั๊กอินก่อน build

หลังเพิ่ม dependency ต้องรัน `flutter pub get` ใน `apps/flutter_app` ให้จบสำเร็จก่อนใช้ `--no-pub` มิฉะนั้น Dart อาจมี API ใหม่ แต่ `GeneratedPluginRegistrant.java` ยังเป็นรายการเก่า ทำให้เลือกไฟล์ไม่ได้แม้ build APK ผ่าน ตรวจจาก root ด้วย `python scripts/verify-flutter-plugins.py android` และสร้าง APK เมื่อไม่มีรายการขาดเท่านั้น รุ่นแก้ไขนี้คือ `0.0.1+20`

## สิ่งที่รองรับในรอบแรก

- สร้าง/restore identity ด้วย BIP-39 24 คำ และ DID เดิม
- เก็บหลาย identity และเลือกเข้าใช้งานด้วย PIN 6–12 หลัก
- ตั้งชื่อและรูป profile, สแกน QR contact, ตรวจ fingerprint และเลือกเพื่อนเพื่อแชต
- เข้ารหัสข้อความด้วย Noise และเก็บ history แยกตาม identity
- แสดงเวลาส่งและรับแบบ `yyyy-MM-dd HH:mm:ss.fff` ตามเวลาของแต่ละเครื่อง ข้อมูลเก่าที่ไม่มีเวลาแสดง `—`
- ส่งออก recovery phrase ผ่าน Android document picker หลังยืนยันคำเตือนเรื่องไฟล์ plaintext
- เพิ่มเพื่อนจาก **Import QR image** ที่ส่งกันทางอินเทอร์เน็ตได้ และบันทึก public QR เป็น PNG ด้วย **Save my QR image** การเพิ่มเพื่อนตรวจลายเซ็นและบันทึกในเครื่อง ไม่ต้องใช้เครือข่ายเดียวกันหรือ USB

## เพิ่มเพื่อนจากคนละเครือข่าย

1. อีกฝ่ายเปิด Contacts กด **Save my QR image** แล้วส่งไฟล์ PNG ผ่านช่องทางส่วนตัว หรือกด **Copy my card** แล้วส่งข้อความ contact card
2. มือถือรับไฟล์ PNG แล้วเปิด Contacts → **Import QR image** เพื่อเลือกภาพ หรือ **Paste friend card** เพื่อวางข้อความ
3. ตรวจชื่อและ fingerprint กด **Add friend** หากยังไม่ได้เปรียบเทียบ fingerprint สามารถเพิ่มไว้ก่อนแล้ว verify ภายหลัง

การนำเข้า QR ใช้โมเดลที่รวมใน APK และไม่ต้องเชื่อมต่อเครื่องเพื่อน การเพิ่ม contact ไม่ได้เชื่อมต่อ chat ให้เอง: สำหรับอินเทอร์เน็ต ให้ทั้งสองฝ่ายเพิ่ม relay ที่เข้าถึงได้ร่วมกันตามขั้นตอนด้านล่าง

## แชตข้ามอินเทอร์เน็ตโดยไม่ใช้ USB

ใช้แอปรุ่น `0.0.1+12` ขึ้นไปทั้งสองฝ่าย บน Desktop เปิด **Connect → Public relay through TryCloudflare** แล้วรอสถานะพร้อม คัดลอก URL ส่งให้มือถือ จากนั้นมือถือเปิด **Connect → Add relay** วาง URL และเลือกเพื่อนที่ตรวจ fingerprint แล้วใน Contacts เพื่อ Chat ไม่ต้อง Invite/Join ดู [วิธีแชร์ relay list และ automatic failover](relay-mesh.md)

Android ใช้ WSS และ Noise เพื่อคุยผ่าน relay โดยไม่ต้องติดตั้ง cloudflared มีการจำรายการและ reconnect อัตโนมัติเมื่อกลับมาออนไลน์ ต้องมี relay ที่ใช้งานได้อย่างน้อยสองตัวเพื่อให้มีเส้นทางสำรอง และต้องเปิดแอปของผู้รับไว้ รุ่นนี้ยังไม่รองรับ push/foreground service สำหรับรับข้อความเมื่อแอปถูกปิดหรือ Android หยุดเบื้องหลัง

## ทดลองแชตกับ Desktop ผ่าน USB

1. เสียบ USB และอนุญาต USB debugging บนมือถือ
2. เปิด Desktop `cht` เลือก identity และเข้าใช้งานด้วย PIN ระบบเริ่ม listening/relay อัตโนมัติ ตรวจสถานะได้ที่ **Connect**
3. บนมือถือ เลือก **Create new identity** หรือ **Restore another identity** แล้วตั้งชื่อ/PIN
4. ใน **Contacts** ของมือถือ กด **Scan friend QR** และสแกน QR contact ของ Desktop ตรวจ fingerprint ก่อนยืนยัน
5. เลือกเพื่อนคนนั้นแล้วกด Chat แอปจะเชื่อมต่อ Desktop ให้โดยไม่ต้อง Invite/Join
6. Desktop อาจขอให้ตรวจและยืนยัน fingerprint ของมือถือครั้งแรก

การ forward พอร์ตต้องตั้งใหม่เมื่อถอด/เสียบสายหรือเริ่ม ADB ใหม่:

```powershell
adb -s <serial> reverse tcp:17357 tcp:17357
```

รอบนี้ Android เชื่อม `ws://127.0.0.1:17357` ผ่าน `adb reverse` ไปยัง companion ที่ Desktop เปิดบน loopback ข้อความยังเข้ารหัสแบบ end-to-end ภายในช่องทางนี้ ต้องใช้ Desktop identity ที่ตรงกับ contact ที่เลือก และรองรับ companion ที่เชื่อมอยู่หนึ่งรายในแต่ละครั้ง

**ข้อจำกัดของ USB path:** ต้องเสียบ USB ไว้ สำหรับอินเทอร์เน็ตใช้ WebSocket relay path ข้างต้นแทน ยังไม่มี Android relay hosting, mDNS discovery, background wake-up และ release signing สำหรับเผยแพร่จริง การ restore identity เดิมนำ DID กลับมา แต่ไม่ย้าย history จากเครื่องอื่น

## Build และ deploy

สภาพแวดล้อมที่ทดสอบ: Flutter 3.47.9, Rust target `aarch64-linux-android`, Android SDK 36, NDK `30.0.14904198`, JDK จาก Android Studio และมือถือ MTN NX1 (Android 16, ARM64)

จาก root ของ repository:

```powershell
rustup target add aarch64-linux-android
powershell -ExecutionPolicy Bypass -File scripts/build-android-core.ps1
Set-Location apps/flutter_app
flutter pub get
flutter build apk --release --target-platform android-arm64 --build-number=22
adb -s <serial> install --user 0 -r build/app/outputs/flutter-apk/app-release.apk
adb -s <serial> reverse tcp:17357 tcp:17357
adb -s <serial> shell am start --user 0 -n app.cht.cht/.MainActivity
```

APK: `apps/flutter_app/build/app/outputs/flutter-apk/app-release.apk` (package `app.cht.cht`, version `0.0.1`, build 22; preview still uses the debug signing key)

ปุ่ม **Try connecting again** แสดงความคืบหน้าและ error ในหน้า offline ไม่เริ่มคำขอซ้อนกัน และรอจน Noise handshake ยืนยันคู่สนทนาสำเร็จ หากไม่สำเร็จภายใน 30 วินาทีจะคืนปุ่มให้ลองใหม่ได้

ต้อง build Rust ใหม่ก่อน build APK เมื่อแก้ Rust; `.so` ที่สร้างขึ้นไม่เก็บใน Git รองรับเฉพาะ ARM64 และ Android API 24 ขึ้นไปในรอบนี้ ปิด Kotlin incremental compilation เพื่อหลีกเลี่ยง cache path คนละไดรฟ์บน Windows ระหว่างโปรเจกต์กับ Pub cache

## การเก็บข้อมูล

Android Keystore เก็บ AES-256-GCM key สำหรับห่อ random 32-byte storage key ที่ Rust ใช้ ไม่มีการเขียน storage key แบบ plaintext ลงไฟล์ ตัว wrapping key ที่ห่อแล้วและ IV อยู่ใน private SharedPreferences ส่วน identity/account/history อยู่ใน private files directory

Rust ใช้ HKDF-SHA256 แยก context และ XChaCha20-Poly1305 ป้องกันไฟล์ แต่ละ identity ใช้ salt สุ่มและ Argon2id (64 MiB, 3 passes, 1 lane) ร่วมกับ PIN สำหรับป้องกัน identity secret มี cooldown หลังใส่ PIN ผิดห้าครั้ง ข้อมูล profile/contact/history เข้ารหัสด้วย device storage key และเข้าถึงผ่านแอปหลัง unlock แต่ไม่ได้เข้ารหัสแยกด้วย PIN

ปิด Android backup เพื่อไม่ให้ย้าย ciphertext ไปยังเครื่องที่ไม่มี Keystore key เดิม การถอนการติดตั้ง/ล้างข้อมูลทำให้ข้อมูลในเครื่องหาย ต้องเก็บ recovery phrase ไว้เอง Android document picker เขียน phrase แบบ plaintext เฉพาะเมื่อผู้ใช้ยืนยันและเลือกไฟล์ ไม่มีการสร้างไฟล์ชั่วคราวสำหรับ export

Network security config อนุญาต cleartext เฉพาะ loopback สำหรับ USB companion ส่วนข้อความ chat ภายในยังเข้ารหัสด้วย Noise แอปและ protocol ยังไม่ได้รับการตรวจสอบด้านความปลอดภัยอย่างอิสระ

อ้างอิง: [Android Keystore](https://developer.android.com/privacy-and-security/keystore), [Network security configuration](https://developer.android.com/privacy-and-security/security-config)

## Media ? build 22

???? **+** ???? Gallery (???????????????????), Audio ??? Files ????????????? ???????????????? caption ??????? ??????????? encrypted cache ????????? ??????????????? [chat-media.md](chat-media.md)

??????? dependencies ???? `flutter pub get` ?????? ??????? `python scripts/verify-flutter-plugins.py` ??? root ???? build ??? `--no-pub` ?????????????? native picker/player registration
