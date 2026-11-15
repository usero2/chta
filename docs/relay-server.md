# Public relay สำหรับ cht

`cht-relay` เป็นโปรแกรม Rust แยกจาก Flutter รันโดยไม่มีหน้าจอหรือ login ใช้ libp2p Circuit Relay v2 บน TCP + Noise + Yamux เก็บ Peer ID เดิมหลัง restart และจำกัดทรัพยากรได้ เหมาะสำหรับ VPS ที่มี public IPv4/IPv6 และรับ TCP จากภายนอกได้ โดเมนเป็นตัวเลือก

แอป Web/Android/Desktop มี client สำหรับ WebSocket application relay `/cht`, การแลก signed relay catalog และ reconnect/failover แล้ว ดู [วิธีเปิด TryCloudflare จาก Desktop และข้อจำกัดของ relay mesh](relay-mesh.md) ส่วน TCP Circuit Relay v2 กับ application WebSocket relay เป็นคนละโปรโตคอล การติดตั้ง config TCP อย่างเดียวในเอกสารนี้จะไม่เปิดเส้นทาง chat ของแอปโดยอัตโนมัติ

## สร้างโปรแกรม

บน Linux VPS ที่มี Rust stable และ C build tools รันจาก repository root:

```bash
cargo build --locked --release --manifest-path rust/crates/relay_server/Cargo.toml --target-dir target/relay-server
target/relay-server/release/cht-relay --help
```

Linux กับ Windows ใช้ source เดียวกัน แต่ต้อง build executable สำหรับ OS ที่จะใช้งาน รุ่น Windows อยู่ที่ `target/relay-server/release/cht-relay.exe` หลัง build ด้วยคำสั่งเดียวกันบน Windows ตัว crate แยก workspace เพื่อไม่เพิ่ม dependency ของ server ลง WASM

## ติดตั้งบน VPS

ใช้ Linux ที่รัน systemd รุ่น 250 ขึ้นไป มี `python3`, `openssl`, `systemd-creds` และ public IP ของเครื่อง ตรวจว่าผู้ให้บริการอนุญาต inbound TCP พอร์ตที่เลือก ตัวอย่างนี้ใช้ **4001/TCP** และไม่มี WebSocket/HTTP listener

1. คัดลอก `deploy/relay/relay.example.json` เป็น `relay.json`
2. เปลี่ยน `203.0.113.10` เป็น public IP ของ VPS จริง คง `state_dir` เป็น `/var/lib/cht-relay` เมื่อใช้ unit ที่ให้มา
3. ตรวจ config และติดตั้งบน VPS:

```bash
target/relay-server/release/cht-relay --config relay.json --check-config
sudo bash deploy/relay/install.sh target/relay-server/release/cht-relay relay.json
sudo journalctl -u cht-relay -n 30 --no-pager
```

Installer สร้าง user `cht-relay`, ติดตั้ง binary/config/unit, สร้าง credential เข้ารหัสครั้งแรก แล้วเปิดบริการพร้อมตั้งให้เริ่มหลัง reboot การเรียกซ้ำจะอัปเดต binary/config และ restart โดยเก็บ identity กับ credential เดิมไว้ รองรับพอร์ตตั้งแต่ 1024 สำหรับ unit นี้เพราะรันโดยไม่มีสิทธิ์ root

เปิด inbound **TCP 4001** ใน firewall ของผู้ให้บริการ VPS ด้วย ถ้าเครื่องใช้ UFW อยู่แล้ว:

```bash
sudo ufw allow 4001/tcp
```

เปลี่ยนเลขให้ตรง config โดยไม่ต้องเปิดพอร์ต companion `17357` ของ Desktop บนอินเทอร์เน็ต Installer ไม่เปลี่ยน firewall และไม่เปิดใช้งาน UFW ให้เอง

ตรวจการทำงาน:

```bash
systemctl is-enabled cht-relay
systemctl is-active cht-relay
sudo journalctl -u cht-relay -f
```

log `starting` มี public address เช่น `/ip4/PUBLIC_IP/tcp/4001/p2p/12D3KooW...` เก็บ address นี้ไว้สำหรับ relay client ในขั้นต่อไป ส่วน `listening` ยืนยันว่า bind พอร์ตได้ ยังต้องทดสอบเข้าถึงจากเครือข่ายอื่นก่อนถือว่าเป็น public relay ที่ใช้งานได้จริง

## ขีดจำกัดเริ่มต้น

| ค่า | ค่าเริ่มต้น | ความหมาย |
|---|---:|---|
| `max_connections` | 128 | จำนวน established transport connections รวม |
| `max_connections_per_peer` | 4 | connections ต่อ Peer ID |
| `max_pending_incoming` / `max_pending_outgoing` | 32 / 16 | connections ระหว่าง handshake |
| `max_reservations` / `max_reservations_per_peer` | 64 / 1 | การจองที่อยู่ relay รวม / ต่อ peer |
| `reservation_seconds` | 3600 | อายุ reservation ก่อน client ต้องต่ออายุ |
| `max_circuits` / `max_circuits_per_peer` | 32 / 4 | circuits ที่ส่งข้อมูลพร้อมกัน รวม / ต่อ peer |
| `circuit_seconds` | 300 | อายุสูงสุดต่อ circuit |
| `circuit_bytes` | 8388608 | ข้อมูลสูงสุด 8 MiB รวมสองทิศทางต่อ circuit |

เมื่อถึงเวลาหรือ byte budget circuit จะปิด client ต้องเปิด circuit ใหม่ โดยไม่ควรแสดงว่าได้รับข้อความแล้วจนปลายทางยืนยัน ระดับนี้เป็นเพดานต่อ circuit **ไม่ใช่** เพดาน MB/s หรือโควตารายเดือนรวม ผู้ให้บริการ VPS อาจคิดค่าทราฟฟิกแยกต่างหาก

คง request rate limiters ต่อ Peer ID/IP ของ libp2p ไว้ด้วย บริการ systemd จำกัดหน่วยความจำไว้ 512 MiB และ file descriptors 4096 ค่า default เป็นจุดเริ่มต้นสำหรับทดสอบ ยังต้องวัดโหลดจริงก่อนเปิดสาธารณะจำนวนมาก Relay เปิดให้ peer ที่รองรับโปรโตคอลจองใช้งานได้ ไม่มี PIN/allowlist ในรุ่นนี้

## Peer ID และข้อมูลลับ

Peer ID นี้เป็นตัวตน transport ของ relay แยกจาก `did:cht:...` ของผู้ใช้ chat เก็บ private key ใน `/var/lib/cht-relay/identity.enc.json` แบบ XChaCha20-Poly1305 พร้อม Argon2id ไม่เขียน private key แบบ plaintext ลงดิสก์ หาก unlock ไม่ได้หรือไฟล์เสีย โปรแกรมหยุดและไม่สร้าง identity ทับ

Installer สุ่ม secret แล้วส่งผ่าน pipe ไปเก็บเป็น systemd encrypted credential ที่ `/etc/credstore.encrypted/cht-relay-identity-password.cred` โดยผูกกับ host key ของเครื่อง systemd ถอดรหัสให้ service ผ่านไฟล์ credential ส่วนตัวขณะทำงาน จึงเริ่มหลัง reboot ได้โดยไม่ต้องกรอกรหัส สอดคล้องกับ [systemd credentials](https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html#Credentials) และ [systemd-creds](https://www.freedesktop.org/software/systemd/man/latest/systemd-creds.html)

สำรอง identity, encrypted credential และ host key `/var/lib/systemd/credential.secret` ในพื้นที่สำรองที่เข้ารหัสและเข้าถึงได้เฉพาะผู้ดูแล การมีไฟล์ encrypted credential อย่างเดียวไม่พอสำหรับย้าย VPS ใหม่ Host key เป็นข้อมูลลับระดับเครื่อง ต้องจัดการเหมือน root credential การ upgrade/reboot บน VPS เดิมไม่ต้องสร้าง secret หรือ Peer ID ใหม่ อย่าลบ state หรือ credential เพื่อแก้ปัญหา startup

ถ้ารันเองนอก systemd ให้สร้าง credential file ที่มี random secret อย่างน้อย 32 bytes แล้วตั้ง environment **เป็น path**:

```bash
umask 077
mkdir -p relay-data
chmod 700 relay-data
openssl rand -base64 48 > relay-password
export CHT_RELAY_KEY_PASSWORD_FILE="$PWD/relay-password"
target/relay-server/release/cht-relay --config relay.json --print-peer-id
target/relay-server/release/cht-relay --config relay.json
```

ปรับ `state_dir` ใน config เป็น path ที่เขียนได้ก่อน ตัวอย่าง manual นี้มี plaintext secret file ที่ต้องป้องกันด้วย permission; การติดตั้ง systemd ใช้ encrypted credential บนดิสก์แทน Windows ต้องกำหนด ACL ของ credential/state ให้เฉพาะบัญชีที่รันบริการ (โปรแกรมตรวจ Unix permissions อัตโนมัติเฉพาะ Linux)

## ตรวจสอบ source

```bash
cargo fmt --manifest-path rust/crates/relay_server/Cargo.toml -- --check
cargo clippy --locked --manifest-path rust/crates/relay_server/Cargo.toml --all-targets -- -D warnings
cargo test --locked --manifest-path rust/crates/relay_server/Cargo.toml
bash -n deploy/relay/install.sh
```

ชุดทดสอบใช้ peer จำลองบน loopback เพื่อส่ง payload ผ่าน relay จริง ตรวจการปฏิเสธเมื่อเกิน connection/reservation และการตัด circuit เมื่อใช้ byte budget หมด รวมถึงตรวจว่า identity คงเดิมและไม่ถูกเขียนทับเมื่อ credential ผิด ไม่ส่งข้อความไปยัง contact จริงของผู้ใช้

การตรวจบนเครื่องพัฒนา: Windows server tests, Clippy และ Release build ผ่าน รวมถึงตรวจ syntax ของ installer และทดสอบการแชร์รายการผ่าน A → B → C การสร้าง TryCloudflare/เชื่อมต่อ WSS จริง และการส่งข้อความ Rust/WASM หลัง relay หลักหยุดแล้ว ยังไม่ได้รัน Linux/systemd จริง การ cross-check Linux บน Windows ติดที่ไม่มี `x86_64-linux-gnu-gcc` จึงต้อง build และทดสอบบริการบน VPS ตามขั้นตอนข้างต้นก่อนเปิดใช้งานจริง

log เป็น JSON มีสถานะ, public address ของ relay และสถิติรวมทุก 30 วินาที ไม่บันทึกเนื้อหาข้อความ การเข้ารหัส transport ไปยัง relay ไม่ทดแทน session E2E ของ cht ต้องคงการยืนยันตัวตนและการเข้ารหัสระหว่างคู่สนทนาเมื่อพัฒนา client ตาม [Circuit Relay v2 specification](https://github.com/libp2p/specs/blob/master/relay/circuit-v2.md)
