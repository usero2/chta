# chta — Public source, releases และการอัปเดต

สถานะ: แบบเสนอสำหรับระบบ release/updater; source repository เริ่มเป็น private ตามคำสั่งล่าสุดของเจ้าของ
วันที่: 2026-11-15

## สิ่งที่ผู้ใช้กำหนด

- เป้าหมายเดิมคือ Source และ GitHub Releases เป็น public; คำสั่งล่าสุดให้เริ่ม source ที่ `usero2/chta` เป็น private ก่อน ห้ามเปลี่ยนเป็น public จนกว่าเจ้าของจะสั่ง
- `roadmaps/` อยู่เฉพาะในเครื่อง ห้ามนำขึ้น remote
- เป้าหมายแพลตฟอร์มอ้างอิง Gridcraft และคง Android ของ chta
- Windows ต้องมีตัวเลือกดาวน์โหลดไฟล์เดียว `chta.exe`
- เจ้าของเลือก MIT License สำหรับ source ของ chta; dependencies คง license ของแต่ละโครงการ
- แอปตรวจเวอร์ชันใหม่จาก GitHub Releases ได้ และแสดงเวอร์ชันที่ติดตั้งท้ายหน้า Profile
- ความสามารถหลักต้องเหมือนกันทุกแพลตฟอร์ม การทำ package สำเร็จอย่างเดียวไม่ถือว่ารองรับแล้ว

## แนวทาง

ใช้ repository public สำหรับ source และ Releases ในที่เดียว ตามตัวเลือกที่ผู้ใช้เลือกไว้ เริ่ม public history จาก snapshot ที่ตรวจแล้ว เก็บ repository และประวัติเดิมไว้ในเครื่อง จากนั้นพัฒนาและออก tag ใน public history ใหม่

ทางเลือกที่พิจารณา: push ประวัติเดิมทำง่ายแต่จะเปิดเผยไฟล์ส่วนตัวที่เคย commit; rewrite ประวัติเดิมต้องเปลี่ยน commit IDs และตรวจทุก ref; snapshot ใหม่แยกขอบเขตข้อมูลชัดกว่า จึงเสนอใช้ snapshot ใหม่ โดยยังไม่ได้สร้าง remote หรือ push

การรองรับแพลตฟอร์มให้ทยอยผ่านการทดสอบตามลำดับด้านล่าง เป้าหมายยังครบตาม Gridcraft แต่ release แสดงเฉพาะแพลตฟอร์มที่ผ่านจริง ส่วนที่ยังพอร์ตไม่เสร็จระบุ Planned ห้ามสร้างไฟล์เปล่าหรือเปลี่ยนนามสกุลแทน package

## เป้าหมายไฟล์แจกจ่าย

ตรวจจาก [Gridcraft v0.19.1](https://github.com/storytold/gridcraft/releases/tag/v0.19.1) และ [รายการ assets](https://github.com/storytold/gridcraft/releases/expanded_assets/v0.19.1) เมื่อ 2026-11-15 ชื่อไฟล์ด้านล่างเป็นแบบเสนอของ chta; `<version>` คือ release version ที่ไม่มี `v` นำหน้า

| แพลตฟอร์ม | สถาปัตยกรรม | ไฟล์เป้าหมาย | งานที่ยังต้องทำใน chta |
| --- | --- | --- | --- |
| Windows | x64 | `chta.exe`, `chta-<version>-windows-x64-portable.zip`, `.msi` | มี single EXE แล้ว; เพิ่ม installer, clean CI และ updater |
| Windows | ARM64 | `chta-<version>-windows-arm64.exe`, `-portable.zip`, `.msi` | พอร์ต launcher, Rust และ plugins; ทดสอบ ARM64 จริง |
| macOS | universal: Intel + Apple Silicon | `chta-<version>-macos-universal.dmg` | สร้าง runner, native bridges, Keychain, signing/notarization |
| Linux | x86_64 | `chta-<version>-linux-x86_64` + `.AppImage`, `.deb`, `.rpm`, `.flatpak`, `.pkg.tar.zst`, `.tar.gz` | สร้าง runner, native bridges, secret storage และ packages |
| Linux | aarch64 | ชุดเดียวกับ Linux x86_64 โดยเปลี่ยน architecture | build/test ARM64 และ dependencies ทุกตัว |
| Linux | riscv64 | `chta-<version>-linux-riscv64` + `.deb`, `.rpm`, `.tar.gz` | ต้องพอร์ต Flutter engine/embedder และ dependencies ก่อน |
| FreeBSD | x86_64, aarch64 | `chta-<version>-freebsd-<arch>.tar.gz` | ต้องพอร์ต GUI/native services และทดสอบทั้งสอง architecture |
| Web | WASM พร้อม browser fallback ตาม Flutter build | `chta-web-<version>.zip`; ใช้งานที่ `https://chta.app/chat` | มี deployment แล้ว; เพิ่ม release archive และ update prompt |
| Android — เพิ่มจาก Gridcraft | arm64-v8a เริ่มต้น | `chta-<version>-android-arm64-v8a.apk` | มี build แล้ว; ทำ production signing และ update flow |

Windows portable ZIP บรรจุ single EXE และเอกสาร license; ถ้าแตกไฟล์ ARM64 ให้ชื่อ executable ภายในเป็น `chta.exe` เช่นกัน Android ABI อื่นและ iOS อยู่นอก matrix ครั้งนี้จนกว่าจะเพิ่ม runner/native core และทดสอบครบ

ไฟล์สนับสนุน: `SHA256SUMS.txt`, `SHA256SUMS.txt.sig`, `update-manifest.json`, `update-manifest.json.sig`, public verification key, third-party notices และ SBOM ของ binary แต่ละรุ่น AppImage เพิ่ม `.zsync` เมื่อตัวอัปเดตแบบนั้นผ่านการทดสอบ; Flatpak/OCI metadata และ package signatures ให้สร้างจากระบบ package จริงเมื่อมี repository ที่ใช้งานได้

Gridcraft มี CLI สำหรับ macOS ด้วย การเพิ่ม CLI เป็นอีกผลิตภัณฑ์หนึ่ง ไม่ใช่เงื่อนไขของการให้แอปแชตรองรับ macOS ในแบบนี้

## ข้อจำกัดจาก source ปัจจุบัน

- Flutter runners ใน repository มี Windows, Android และ Web ยังไม่มี Linux/macOS runners
- Rust vault มี Windows DPAPI และ Android bridge; macOS/Linux/FreeBSD ต้องมีระบบเก็บกุญแจที่เหมาะสม ห้ามใช้ plaintext fallback
- QR scanner, notifications, WebRTC, media player, file picker, native mesh และ relay host ต้องตรวจแต่ละ OS/architecture
- [Flutter supported platforms](https://docs.flutter.dev/reference/supported-platforms) ครอบคลุม Windows/macOS/Linux x64/ARM64 แต่ไม่มี FreeBSD และ Linux RISC-V ในรายการ การรองรับสองกลุ่มนี้เป็นงานพอร์ต ไม่ใช่เพิ่มชื่อเข้า CI อย่างเดียว
- SDK และ dependencies ที่ project pin ใช้จริงเป็นฐานตรวจ ไม่อ้างว่ารองรับเพียงเพราะ Flutter รุ่นล่าสุดรองรับ
- Feature parity หมายถึง identity, contacts, chats/groups, media/files, profile, sync และข้อมูลต้องทำงานตามสัญญาเดียวกัน ความสามารถเปิด TCP listener/host relay ใน browser มีข้อจำกัดของ browser และต้องแสดงสถานะให้ตรงจริง

## โครงสร้างข้อมูลและการเริ่ม public history

```text
legacy-workspace/                   repository เดิมและประวัติเดิม เก็บเป็น local archive
  roadmaps\                          ข้อมูลเจ้าของ อยู่ที่เดิมและถูก ignore
source-workspace/           source public ที่ผ่านการตรวจ; ไม่มี .git ของเดิม
  apps\  rust\  assets\branding\
  scripts\  deploy\  docs\            เฉพาะเอกสารที่ตรวจแล้ว
  .github\workflows\                  CI/release ที่จะเพิ่ม
private-workspace/            logs, captures, รายงานตรวจ, ข้อมูลภายใน
```

เก็บ signing keys ใน protected credential store แยกจากทั้งสอง repo ไม่ใช่โฟลเดอร์ที่ export source เป็นประจำ ส่วน runtime identity/history/cache ใช้ app data เดิมต่อไป การอัปเดตไม่ย้ายหรือลบข้อมูล

ทำแล้วใน local commit `03fda71`: ignore และเลิก track `roadmaps/`, ย้ายสำเนาไอคอนที่ build ต้องใช้ไป `assets/branding/chta-icon.png`; ไฟล์ส่วนตัวเดิมยังอยู่ แต่ **ประวัติเก่ายังมี roadmaps** จึงห้าม push history เดิม

- [ ] สร้างรายการ source ที่อนุญาต export จาก tracked files; ไม่ copy ทั้ง working directory
- [ ] ตรวจ secrets และข้อมูลส่วนตัวทั้งข้อความ/ภาพ/เอกสาร/ไฟล์บีบอัด; เก็บรายงานแบบ redact นอก public tree
- [ ] ตรวจเอกสารที่อาจอ้าง DID จริง, device serial, local IP, screenshots และข้อมูลจาก roadmaps; ย้ายรายงานภายในหรือแทนด้วยข้อมูลจำลอง
- [ ] ไม่ export `roadmaps/`, `.git/`, `.worktrees/`, `.superpowers/`, logs, build outputs, credentials และ private evidence; คัดเลือก `docs/superpowers/` เป็นรายไฟล์
- [x] เจ้าของเลือก MIT และเพิ่ม LICENSE ของ project แล้ว
- [ ] ตรวจ third-party notices ก่อนเผยแพร่ไฟล์ติดตั้ง
- [ ] สร้าง Git history ใหม่จาก snapshot สะอาด และตรวจ `git ls-tree`/source ZIP รวมไฟล์ที่ GitHub สร้างจาก tag
- [ ] build จาก clean checkout ที่ไม่มี roadmaps ได้ครบ; artifact scan ต้องยืนยันว่าไม่มีข้อมูลส่วนตัวแทรกมา
- [ ] ส่งมอบเส้นทางพัฒนาใหม่ให้ชัด: หลังเริ่ม public history ใช้ `chta-public` เป็น source หลัก เก็บ repo เดิมเป็น local archive ไม่ merge history เดิมกลับมา

การเลือกชื่อ owner/repository และ license รวมถึงการ publish จริง ต้องเสร็จก่อน push ครั้งแรก ไม่มีการเดาค่าเหล่านี้หรือเผยแพร่ในขั้นวางแผน

## Commits และ release pipeline ที่เสนอ

แยก commit ที่ตรวจได้: privacy/export → platform bridges → packaging ทีละแพลตฟอร์ม → signed update metadata → updater → CI/release docs ห้ามรวมการเปลี่ยน protocol ที่ยังไม่ผ่าน acceptance ไว้ใน release commit

กำหนด version จากข้อมูลกลางและ build number ที่เพิ่มเสมอ ตัวอย่าง preview tag `v0.0.1-alpha.1` กับ native build name `0.0.1`/build number ที่จองใหม่; manifest เก็บ tag version, native version และ build แยกชัด ห้ามนำหมายเลขตัวอย่างไปแทน build ที่ใช้ไปแล้ว Stable ใช้ tag `vX.Y.Z`; แต่ละ tag ต้องชี้ source commit เดียวกันทุกแพลตฟอร์ม

- [ ] PR/commit ผ่าน tests, analyzer, Rust lint และ privacy scan
- [ ] CI ใช้ SDK/toolchain pin และ lockfiles; build ใน workspace สะอาด
- [ ] ใช้ manifest ของไฟล์ runtime ที่อนุญาตก่อน pack single EXE เพราะ packer ปัจจุบันอ่านไฟล์ใน Release directory ทั้งหมด
- [ ] สร้าง packages เฉพาะ matrix ที่ผ่าน; signing หลัง package bytes สุดท้าย
- [ ] ทดสอบ fresh install และ update จากรุ่นก่อน โดยเก็บ identity/PIN/history/files/drafts
- [ ] ตรวจ signature, SHA256, package architecture, permissions และ malware scan
- [ ] รวม artifacts/notes/manifest เป็น Draft release; failed required target ต้องหยุด publication ส่วน planned target แสดงสถานะตามจริง
- [ ] ตรวจ Draft และ source archive พร้อมกัน แล้วจึง publish tag/release ที่ผ่านทั้งหมด

GitHub สร้าง source ZIP/tar จาก tag ให้อัตโนมัติ จึงต้องทำความสะอาด source ก่อนสร้าง tag ที่เผยแพร่ ([GitHub Releases](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases))

## การตรวจและติดตั้งอัปเดต

ข้อเสนอของผู้พัฒนา: ตรวจหลังเริ่มแอปแบบไม่บล็อก login/chat และไม่ถี่กว่า 24 ชั่วโมง มีปุ่ม Check for updates ใน Profile; timeout/offline ไม่เปลี่ยนสถานะแชต ไม่ส่ง DID/รายชื่อเพื่อน/ข้อความไปกับคำขออัปเดต Stable และ Preview แยกช่อง โดย Stable ไม่ติดตั้ง Preview เอง

ดาวน์โหลด signed manifest จาก public GitHub Releases โดยไม่ฝัง GitHub token ในแอป Manifest ระบุ schema version, channel, release version, build, source commit, platform/architecture, minimum OS, asset URL, byte size และ SHA256 ใช้ Ed25519 release key แยกจากกุญแจ identity; client pin public key ไว้ใน binary ตรวจ detached signature ของ exact UTF-8 bytes พร้อม domain prefix ก่อน parse

กำหนดเพดาน manifest 256 KiB, HTTPS เท่านั้น, asset URL ต้องตรง repository ที่ตั้งไว้, ตรวจ redirect ไป GitHub asset hosts ที่อนุญาต, reject version/build ที่ย้อนกลับและ hash/size ผิด Key rotation ให้ key ปัจจุบันรับรอง key ใหม่ก่อนเลิก key เก่า; key สูญหาย/รั่วต้องมีขั้นตอน incident และออก trusted recovery build ห้ามดึง key ใหม่จาก URL แล้วเชื่อทันที

| ช่องทางติดตั้ง | พฤติกรรมอัปเดต |
| --- | --- |
| Windows single EXE / portable | ดาวน์โหลดและตรวจ → ผู้ใช้เลือก Restart to update → flush ข้อมูล → ออกจาก tray/process จริง → helper รอทั้ง launcher และ runtime → เปลี่ยนไฟล์แบบ atomic → เปิดใหม่; เก็บ backup และใช้ rollback เมื่อ schema ยังเข้ากันได้ |
| Windows MSI | ใช้ MSI upgrade กับ product identity ที่คงที่; ไม่ให้ portable updater เขียนทับ managed installation |
| Android APK | ดาวน์โหลด ตรวจ hash/signing certificate แล้วเปิด Android installer ให้ผู้ใช้ยืนยัน; ใช้ applicationId เดิมและ versionCode ที่สูงกว่า |
| macOS DMG | ดาวน์โหลดและตรวจ signed/notarized app แล้วติดตั้งผ่าน flow ที่รองรับสิทธิ์ของเครื่อง; flush ก่อน restart |
| Linux AppImage / tar และ FreeBSD tar | replacement หลังตรวจไฟล์และสิทธิ์; restart ที่ชัดเจน; เก็บ rollback ที่ compatible |
| deb/rpm/Flatpak/Arch package | ใช้กลไก package manager ของช่องทางนั้น; ในแอปแจ้งอัปเดตและพาไปขั้นตอนที่ถูกต้อง |
| Web | แจ้ง New version → บันทึก draft/view state → reload; bindings/WASM/assets ต้องเป็นรุ่นเดียวกันและ cache ไม่คละรุ่น |

Android ปัจจุบันใช้ debug signing สำหรับ release จึงต้องวาง production key และทดสอบ migration ก่อนแจก public ห้ามแก้ด้วย uninstall ซึ่งลบข้อมูลเดิม ต้องตรวจ signing lineage/OS ที่รองรับกับรุ่นที่ติดตั้งจริง และมี encrypted migration สำหรับเส้นทางที่อัปเกรดทับไม่ได้ ([apksigner](https://developer.android.com/tools/apksigner))

## ลำดับดำเนินงานและเกณฑ์รับงาน

1. **Public source readiness:** export/privacy/license/source archive ตรวจผ่านก่อนสร้าง public remote
2. **รุ่นแรกจากแพลตฟอร์มที่มีอยู่:** Windows x64 single EXE + Android ARM64 + Web, เพิ่ม release metadata และ updater ที่ผ่าน update/recovery tests
3. **Desktop หลักตาม Gridcraft:** Windows ARM64, macOS universal, Linux x86_64/aarch64; เพิ่มรูปแบบ installer/package ของแต่ละ OS หลังแอปทำงานครบ
4. **พอร์ตเพิ่มเติม:** Linux RISC-V และ FreeBSD สอง architecture; ใช้ runner/engine/toolchain และเครื่องทดสอบที่ทำงานจริงก่อนเลื่อนจาก Planned

ทุกแพลตฟอร์มต้องผ่าน identity create/restore/switch/PIN, contacts/QR, encrypted DM/group, relay reconnect, media/file transfer/cache/progress, notifications ตามสิทธิ์ OS, profile version, draft/scroll state และ multi-device sync เมื่อฟีเจอร์นั้นเสร็จ การ update ต้องทดสอบขณะมี draft/ไฟล์กำลังส่งและกรณีไฟดับ/เน็ตหลุด/ดิสก์เต็ม ไม่เผยแพร่คำอ้างว่าฟีเจอร์ที่ยังพัฒนาเสร็จแล้ว

ส่วนที่ builder เลือกได้: ชื่อ CI jobs, package builder ที่ไม่เปลี่ยน matrix, cache layout และรายละเอียด test harness ส่วนขั้นต่ำ OS ต้องประกาศจากผลทดสอบของ SDK/dependencies ที่ pin จริงก่อนเปิด target นั้นเป็น Supported

## สถานะปัจจุบัน

สร้าง `https://github.com/usero2/chta` แบบ private และอัปโหลด source snapshot สะอาดจาก `source-workspace/` แล้ว ไม่รวม roadmaps และประวัติเดิม ระบบ CI/updater และ GitHub Release ยังไม่ได้ดำเนินการ การเปิด repository เป็น public ต้องรอคำสั่งเจ้าของ ส่วนเลขเวอร์ชันท้าย Profile อยู่ใน build 31 แล้ว
