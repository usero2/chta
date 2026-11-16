# เครือข่าย relay และ TryCloudflare ใน cht

## เชื่อมต่อด้วย relay QR (0.0.1+17)

1. ฝั่งที่มี relay เปิด **Connect** QR แสดงข้าง URL ทันที มีปุ่ม Copy และ Save QR อยู่ด้วยกัน
2. อีกฝั่งกด **Scan relay QR** หรือ **Import relay QR** แอปเพิ่ม relay และลองเชื่อมต่อให้ทันที
3. เลือกเพื่อนใน Chats หากเปิดห้องแชตไว้แล้ว แอปจะลองเชื่อมต่อห้องนั้นต่อ

เมื่อไม่มี relay หน้าแชตบนมือถือจะแสดงปุ่มสแกนแทน Reconnect ใช้ contact QR ที่มี relay อยู่แล้วได้ด้วย การสแกนในโหมดนี้เพิ่มเฉพาะเส้นทาง ไม่เพิ่มเพื่อนหรือยืนยัน fingerprint แทนผู้ใช้

QR มีเพียง public URL ไม่มี PIN หรือ recovery phrase QR ที่เปิดอยู่เปลี่ยนตาม URL ปัจจุบัน หากบันทึกรูปไว้แล้ว TryCloudflare เปลี่ยนที่อยู่ ต้องสแกน QR ใหม่หรือใช้ relay สำรองที่ยังออนไลน์

ตรวจบนเครื่องจริงวันที่ 2026-11-13 รุ่น `0.0.1+17`: Desktop เริ่ม relay หลังปลดล็อกและแสดง QR ได้ Android อ่าน PNG ที่สร้างด้วยตัว renderer ของแอปผ่าน **Import relay QR** แล้วเชื่อม public WSS สำเร็จ ทั้งสองฝั่งแสดง **Connected securely** พร้อมประวัติเดิม ไม่ได้ส่งข้อความแทนผู้ใช้ รอบนี้ไม่ได้ทดสอบการเล็งกล้องสแกน QR จริง

เครื่องทดสอบ: HONOR MTN-NX1, Android 16, serial `ANDROID_DEVICE_SERIAL`, package `app.cht.cht` เปิดด้วย `adb -s ANDROID_DEVICE_SERIAL shell am start -n app.cht.cht/.MainActivity` ใช้ USB สำหรับตรวจเครื่องและนำไฟล์ QR เข้าเท่านั้น เส้นทางแชตใช้ public WSS หลักฐานอยู่ใน `target/android-proof` และ mirror `http://127.0.0.1:59449/` (ไม่มีเครื่องมือเปิด mirror ในแผง browser ในรอบนี้) ไม่พบ crash ของแอปใน log ที่เก็บ

## เปิด public relay จาก Windows Desktop

Desktop build `0.0.1+36` and later includes `cloudflared` in the single-file runtime. No separate installation is needed. To start a public relay:

1. เปิด cht และปลดล็อก identity ด้วย PIN ของคุณ
2. เปิด **Connect → Public relay through TryCloudflare**
3. รอแอปแสดง **Public relay is running** แอปจะตรวจ WebSocket ผ่าน URL สาธารณะจริงก่อนแสดงว่าพร้อม
4. เปิด **Contacts** แล้วให้เพื่อนสแกน QR หรือส่งรูป QR/contact card ให้เพื่อน การ์ดรวม public relay URL สูงสุด 2 ที่อยู่ที่ลงลายเซ็นร่วมกับ profile ไว้แล้ว
5. เพื่อนตรวจ fingerprint แล้วกด **Add friend & chat** แอปเพิ่ม relay และเริ่มเชื่อมต่อให้โดยไม่ต้องคัดลอก URL แยก
6. ถ้าฝั่งรับยังไม่ได้บันทึกผู้ส่ง จะเห็น **… wants to chat → Review** ให้ตรวจ fingerprint และยอมรับก่อนเปิดแชต ไม่มีการเชื่อถือ identity ใหม่อัตโนมัติ ทั้งสองฝ่ายต้องเปิดแอปและมี relay ที่ใช้ร่วมกันได้

การ์ดเก่ายังเพิ่มเพื่อนได้ หากไม่มี relay URL ให้เพิ่มใน **Connect → Add relay** ครั้งแรกเอง รับทั้ง `https://ชื่อสุ่ม.trycloudflare.com` และ `wss://ชื่อสุ่ม.trycloudflare.com/cht` QR ใช้ขอบว่าง 4 modules และรูป export 1200×1200 โดยไม่มีกรอบขาวซ้อน

ไม่ต้องกรอก public IP, เปิด inbound port ที่ router, กด Invite/Join หรือติดตั้ง cloudflared บนเครื่องที่เข้ามาแชต ตัว Desktop ที่เปิด relay รัน `cht-relay.exe` และ cloudflared ให้เอง หลังเปิดสวิตช์ครั้งแรก แอปจำค่าไว้และเริ่มบริการอีกครั้งหลัง login

ปิดสวิตช์เพื่อหยุดบริการและยกเลิกการเริ่มอัตโนมัติ การ lock/switch identity หรือปิดแอปจะหยุด process ที่แอปเป็นเจ้าของ Windows Job Object กำหนดให้ปิดลูกข่ายแม้ process หลักถูกยุติ แอปไม่หยุด cloudflared ของโปรแกรมอื่น

Public relay ยอมให้ผู้ใช้ cht ที่พิสูจน์การครอบครอง DID ใช้ส่งข้อมูลเข้ารหัสผ่านเครื่องนี้ได้ ไม่มี PIN/allowlist สำหรับ public WebSocket relay ในรุ่นนี้ PIN login ยังคงใช้ปลดล็อก identity ในเครื่องตามเดิม ส่วน PIN ของ listener TCP เดิมเป็นการตั้งค่าแยกกัน

## แชร์รายการ relay

แต่ละ relay ส่งรายการที่ลงลายเซ็นให้ node ที่เชื่อมต่ออยู่ node นำข้อมูลไปแลกเปลี่ยนกับเพื่อนบ้านต่อได้ ตัวอย่าง A รู้จัก B และ B รู้จัก C: รายการที่ตรวจสอบผ่านจะกระจายจน A รู้จัก C ได้ โดยไม่ต้องมี Google Sheets หรือ directory กลาง

**Share relay list** คัดลอกรายการสาธารณะเป็น JSON ส่งให้เพื่อน แล้วให้วางในช่องเดียวกับ URL ได้ รายการนี้ไม่มี recovery phrase, private key, PIN หรือเนื้อหาแชต

- record มี relay ID, public key, endpoint, เวลาออก/หมดอายุ และ Ed25519 signature
- ตรวจ signature, ID ที่ผูกกับ key, อายุ record, รูปแบบ endpoint และจำกัดขนาดก่อนรับข้อมูล
- record อายุ 15 นาที และเจ้าของออก record ใหม่ขณะยังทำงาน; แอปเก็บได้สูงสุด 1000 records และ 8 bootstrap URLs การแลกเปลี่ยนส่งครั้งละไม่เกิน 64 records และหมุนรายการต่อเนื่อง
- เก็บรายการไว้ในเครื่องและตรวจซ้ำเมื่อเปิดแอป record หมดอายุจะไม่ถูกใช้เป็นข้อมูลค้นหาใหม่
- จำ key ของ bootstrap endpoint ที่เคยเชื่อมต่อ หาก key เปลี่ยนจะปฏิเสธจนผู้ใช้ลบและเพิ่มที่อยู่นั้นใหม่
- records ที่ได้จากเครือข่ายต้องใช้ public `wss://…/cht` ไม่รับ private/loopback addresses; localhost รับได้เมื่อผู้ใช้เพิ่มเป็น bootstrap โดยตรงเพื่อทดสอบ

ลายเซ็นบอกว่าใครเป็นเจ้าของ record ไม่ได้ยืนยันว่า relay นั้นน่าเชื่อถือหรือเข้าถึงได้ตลอดเวลา Peer ยังต้องตรวจ identity และสร้าง Noise session ระหว่างกันทุกครั้ง

## สลับเส้นทางและเชื่อมต่อใหม่

Web, Windows และ Android ตั้งเป้าหมายจำนวน relay ที่เชื่อมพร้อมกันได้ใน **Connect → Internet connections → Relay limit → Apply** ช่วง **50–1000** ค่าเริ่มต้น 50 และจำค่าหลังเปิดใหม่ จำนวนจริงขึ้นกับ relay ที่รู้จักและเข้าถึงได้ แอปเริ่ม handshake พร้อมกันไม่เกิน 6 ตัว รับ catalog ต่อเนื่องจาก 3 เส้นทาง ส่วนเส้นทางสำรองส่ง keepalive ขนาดเล็กเพื่อลด traffic การลดจำนวนจะรักษาเส้นทางแชตที่ใช้อยู่

ข้อความใน Noise session เดียวใช้ relay ทีละเส้นทางเพื่อรักษาลำดับ เมื่อเส้นทางหลักหลุด จะใช้ตัวสำรองและสร้าง authenticated session ใหม่ โดยคง conversation/history เดิม ข้อความที่ยังไม่ได้รับ acknowledgement จะ retry ด้วย message ID เดิมและใช้ประวัติช่วยป้องกันการแสดงซ้ำ การตั้ง 1000 ใช้ socket/หน่วยความจำ/แบตเตอรี่มากขึ้น ไม่ได้สร้าง public relay ใหม่ 1000 เครื่องให้เอง

มี heartbeat และ retry โดยเพิ่มเวลารอจนสูงสุดประมาณ 60 วินาที เพื่อลดการเชื่อมต่อถี่ขณะไม่มีอินเทอร์เน็ต ข้อความรับ/ack ถูกเข้ารหัสก่อนส่งผ่าน relay ดังนั้น relay หรือ Cloudflare ไม่สามารถปลอม acknowledgement ที่ถูกต้องของ session ได้ รุ่นนี้มี active chat session หนึ่งคู่ต่อ identity ในแต่ละครั้ง

ต้องมี relay ที่เข้าถึงได้อย่างน้อย 2 ตัวจึงจะมี failover เมื่อ relay ตัวหนึ่งดับ รายการที่แชร์ไม่สร้างเครื่องบริการใหม่ขึ้นมาเอง และยังต้องมี bootstrap ที่ใช้งานได้อย่างน้อยหนึ่งตัวเพื่อเริ่มรู้จักเครือข่าย หากทุก node ปิดและ TryCloudflare เปลี่ยน URL พร้อมกัน ต้องแชร์ URL ใหม่อย่างน้อยหนึ่งตัว

**Online ตลอดเวลาไม่สามารถรับประกันได้** เมื่อเครื่องหลับ, ไม่มีอินเทอร์เน็ต, แอปถูกปิด หรือ Android หยุดแอปเบื้องหลัง รุ่นนี้ยังไม่มี Android foreground service, push wake-up หรือกล่องข้อความ offline บน relay จึงไม่แสดงว่าเพื่อนได้รับข้อความแล้วจนปลายทางถอดรหัสและยืนยันจริง

## การทำงานของ Desktop host

- cloudflared ใช้ config ว่างของ cht แยกจาก config/account ของโปรแกรมอื่น และไม่ส่ง named-tunnel credentials จาก environment ไปใช้
- เปิด HTTP/WebSocket origin บน `127.0.0.1` เท่านั้น โดยใช้พอร์ตว่างภายในเครื่อง แล้วให้ tunnel เป็นทางเข้าจากอินเทอร์เน็ต
- เก็บ relay transport identity และ service credential แบบเข้ารหัสด้วย Windows DPAPI ใน `%APPDATA%\cht\public-relay\data` ไม่ใช้ recovery phrase ของผู้ใช้เป็น key ของ relay
- relay ID คงเดิมหลัง restart; TryCloudflare URL เปลี่ยนได้ แอปแทนที่ URL เดิมและแชร์ record ใหม่ให้เส้นทางที่ยังเข้าถึงได้
- เมื่อ tunnel/process หลุดจะเริ่มใหม่อัตโนมัติตราบใดที่สวิตช์ยังเปิด หากผู้ใช้ปิดสวิตช์จะไม่ restart
- ตรวจ DNS/HTTPS/WebSocket สาธารณะก่อนแสดงว่าพร้อม สำหรับชื่อ TryCloudflare ใช้ [Cloudflare DNS-over-HTTPS](https://developers.cloudflare.com/1.1.1.1/encryption/dns-over-https/make-api-requests/dns-json/) เพื่อลดผลจาก negative DNS cache ขณะสร้างชื่อใหม่ โดยคงการตรวจ certificate/TLS hostname ตามปกติและไม่เปลี่ยน DNS ของระบบ

## โปรโตคอลและขีดจำกัด

WebSocket `/cht` เป็น **application relay protocol ของ cht** แยกจาก libp2p Circuit Relay v2 TCP ที่มีอยู่ เดสก์ท็อป/เว็บ/Android ใช้ signed challenge เพื่อจอง DID บน relay จากนั้นแลก signed contact cards และทำ Noise KK เพื่อรับรองคู่สนทนา WebSocket เพียงเชื่อมติดยังไม่ถือว่า chat authenticated

relay เผย public challenge กับ signed catalog, รองรับ directory exchange และส่ง opaque envelopes ไปยัง DID ที่เชื่อมต่ออยู่ ไม่มีการอ่าน/เก็บเนื้อหาข้อความ จำนวนต่อ connection ถูกจำกัดด้วย bounded queues, frame size 256 KiB, routed body 64 KiB, incoming quota เริ่มต้น 8 MiB/นาที และ 1200 text frames/นาที แอปจำกัดข้อความใหม่ไว้ 12000 ตัวอักษรและคิวรอ acknowledgement 100 ข้อความ

ค่าของ WebSocket server อยู่ใน config `websocket`: `listen`, `public_url`, `bootstrap_urls`, `max_clients`, `bytes_per_minute`, `allow_loopback` ค่าเริ่มต้น server รับ 128 connections; Desktop host ใช้ 64 รวม connections ที่กำลัง handshake/directory exchange ของฝั่งรับ ค่าของ libp2p `limits.circuit_bytes`/`circuit_seconds` ไม่ได้ใช้กับโปรโตคอล WebSocket นี้

การส่งข้อความต้องมี client ทั้งสองเชื่อมต่อกับ relay ร่วมกัน การแลก catalog ช่วยให้รู้จัก relay เดียวกัน ยังไม่ได้ทำการ forward ข้อความจาก relay หนึ่งไปหา DID ที่เกาะอยู่เฉพาะอีก relay หนึ่งอย่างโปร่งใส จึงเป็น relay mesh สำหรับ discovery และ client failover ไม่ใช่ store-and-forward ข้ามทุก node

TryCloudflare เหมาะสำหรับทดสอบ URL เป็นแบบชั่วคราวและไม่มี uptime guarantee ตาม [ข้อกำหนด Quick Tunnels](https://developers.cloudflare.com/tunnel/get-started/quick-tunnels/) เส้นทางนี้ยังอาศัยโครงสร้างพื้นฐาน Cloudflare ข้อความใช้การเข้ารหัสระหว่างคู่สนทนาเพิ่มเติมจาก TLS แต่ระบบยังเป็น experimental และยังไม่ได้รับการ audit อิสระ

## การตรวจสอบ

ตรวจด้วย Rust protocol/server tests, Flutter tests, Windows Job Object test และ browser contexts สองชุดที่สร้าง identity ทดสอบใหม่ ส่งข้อความผ่าน Rust/WASM จริง ก่อนหยุด relay หลักแล้วตรวจว่ารับข้อความใหม่ผ่าน relay สำรองได้ ไม่ใช้ recovery phrase/PIN หรือส่งข้อความหา contact จริงของผู้ใช้

ชุดทดสอบจำลองตรวจ socket 1000 เส้นทางพร้อมกัน การจำค่าจำนวน การจำกัด handshake 6 ตัว และการรักษา active route ตอนลดเหลือ 50 รวมถึง signed directory 1000 records การทดสอบนี้ไม่ใช่ผลวัดโหลดผ่านอินเทอร์เน็ตจริง 1000 relays

ทดสอบการสร้าง tunnel สาธารณะจริงแบบเลือกเปิด (จะปิด process และลบ state ทดสอบเมื่อจบ):

```powershell
cd apps/flutter_app
flutter test test/relay/trycloudflare_integration_test.dart --dart-define=CHT_TEST_PUBLIC_RELAY=true
```

Build the Windows release first; the test uses its bundled `cht-relay.exe` and `cloudflared.exe`. Normal test runs skip public tunnel startup so they can run offline.

## ?????????? ? build23

relay ???????????????????????? bandwidth/frame budget ??? ??????????????????????? heartbeat ???????????? ????? ???? frame ??? bounded queues ????????? ???????????????????????????? relay ??????????????????? relay ????????????????? socket ?????????????
