#!/usr/bin/env python3
"""RarAc motoru için uçtan uca testler. Kullanım: python3 -I tests/run_tests.py <cli> <çalışma klasörü>"""
import ctypes, hashlib, os, shutil, struct, subprocess, sys, zlib
from pathlib import Path

CLI, WORK = sys.argv[1], Path(sys.argv[2])
shutil.rmtree(WORK, ignore_errors=True)
WORK.mkdir(parents=True)
failures = []


def check(name, ok, detail=""):
    print(("  ok   " if ok else "  FAIL ") + name + (f"  -> {detail}" if detail and not ok else ""))
    if not ok:
        failures.append(name)


def fresh(name):
    d = WORK / name
    d.mkdir()
    return d


def run(archive, *extra):
    out = subprocess.run([CLI, str(archive), *extra], capture_output=True, text=True, timeout=300)
    return out.stdout


def result_path(output):
    for line in output.splitlines():
        if line.startswith("OK "):
            return Path(line[3:])
    return None


def no_temp_left(folder):
    return not [p for p in os.listdir(folder) if p.startswith(".rarac-")]


# --- RAR4 ---------------------------------------------------------------
def r4_block(body):
    crc = zlib.crc32(body) & 0xFFFF
    return struct.pack("<H", crc) + body


def r4_file(name, data=b"", directory=False, attr=None):
    raw = name.encode("utf-8")
    flags = 0x8000 | 0x0200 | (0x00E0 if directory else 0)
    if attr is None:
        attr = 0o40755 if directory else 0o100644
    head_size = 32 + len(raw)
    body = struct.pack(
        "<BHHIIBIIBBHI", 0x74, flags, head_size, len(data), len(data), 3,
        zlib.crc32(data), 0x5A000000 | (1 << 16) | (1 << 21), 29, 0x30, len(raw), attr,
    ) + raw
    return r4_block(body) + data


def rar4(*files):
    main = r4_block(struct.pack("<BHHHI", 0x73, 0, 13, 0, 0))
    end = bytes.fromhex("C43D7B00400700")
    return b"Rar!\x1a\x07\x00" + main + b"".join(files) + end


# --- RAR5 ---------------------------------------------------------------
def vint(n):
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        out.append(b | (0x80 if n else 0))
        if not n:
            return bytes(out)


def r5_block(body):
    head = vint(len(body)) + body
    return struct.pack("<I", zlib.crc32(head)) + head


def r5_main(arch_flags=0, number=None):
    body = vint(1) + vint(0) + vint(arch_flags)
    if number is not None:
        body += vint(number)
    return r5_block(body)


def r5_end(more=False):
    return r5_block(vint(5) + vint(0) + vint(1 if more else 0))


def r5_file(name, data=b"", unp=None, crc=None, extra=b"", hflags=0, directory=False, attr=None):
    raw = name.encode("utf-8")
    unp = len(data) if unp is None else unp
    crc = zlib.crc32(data) if crc is None else crc
    if attr is None:
        attr = 0o40755 if directory else 0o100644
    hf = hflags | (0x02 if data or not directory else 0) | (0x01 if extra else 0)
    body = vint(2) + vint(hf)
    if extra:
        body += vint(len(extra))
    if hf & 0x02:
        body += vint(len(data))
    ff = 0x01 if directory else 0x04
    body += vint(ff) + vint(unp) + vint(attr)
    if not directory:
        body += struct.pack("<I", crc)
    body += vint(0) + vint(1) + vint(len(raw)) + raw + extra
    return r5_block(body) + data


def rar5(*files):
    return b"Rar!\x1a\x07\x01\x00" + r5_main() + b"".join(files) + r5_end()


def symlink_extra(target):
    t = target.encode()
    rec = vint(5) + vint(1) + vint(0) + vint(len(t)) + t
    return vint(len(rec)) + rec


def aes_cbc(key, iv, data):
    lib = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
    out = ctypes.create_string_buffer(len(data))
    moved = ctypes.c_size_t()
    status = lib.CCCrypt(0, 0, 0, key, ctypes.c_size_t(32), iv, data, ctypes.c_size_t(len(data)), out,
                         ctypes.c_size_t(len(data)), ctypes.byref(moved))
    assert status == 0
    return out.raw[: moved.value]


def r5_encrypted_file(name, plain, password):
    salt, iv, lg2 = bytes(range(16)), bytes(range(16, 32)), 15
    count = 1 << lg2
    pw = password.encode("utf-8")
    key = hashlib.pbkdf2_hmac("sha256", pw, salt, count)
    v3 = hashlib.pbkdf2_hmac("sha256", pw, salt, count + 32)
    check = bytearray(8)
    for i in range(32):
        check[i % 8] ^= v3[i]
    check = bytes(check)
    rec = vint(1) + vint(0) + vint(1) + bytes([lg2]) + salt + iv + check + hashlib.sha256(check).digest()[:4]
    padded = plain + b"\0" * (-len(plain) % 16)
    return r5_file(name, aes_cbc(key, iv, padded), unp=len(plain), crc=zlib.crc32(plain), extra=vint(len(rec)) + rec)


# --- Testler --------------------------------------------------------------
print("RAR4: Türkçe adlar ve klasörler")
d = fresh("rar4")
(d / "yedek.rar").write_bytes(rar4(
    r4_file("şarkılar", directory=True),
    r4_file("şarkılar/çiğdem.txt", b"merhaba dunya"),
    r4_file("öteki.txt", b"ikinci dosya"),
))
out = run(d / "yedek.rar")
res = result_path(out)
check("birden çok üst öğe, arşiv adlı klasöre açılır", res is not None and res.name == "yedek", out)
if res:
    check("içerik doğru", (res / "şarkılar/çiğdem.txt").read_bytes() == b"merhaba dunya")
    check("ikinci dosya doğru", (res / "öteki.txt").read_bytes() == b"ikinci dosya")
check("geçici klasör kalmaz", no_temp_left(d))

print("RAR5: tek üst öğe ve ad çakışması")
d = fresh("rar5")
(d / "tek.rar").write_bytes(rar5(r5_file("rapor.txt", b"icerik")))
first = result_path(run(d / "tek.rar"))
check("tek dosya ekstra klasörsüz açılır", first == (d / "rapor.txt").resolve() or first == d / "rapor.txt", str(first))
second = result_path(run(d / "tek.rar"))
check("var olan dosyanın üzerine yazılmaz", second is not None and second.name == "rapor 2.txt", str(second))
check("eski dosya korunur", (d / "rapor.txt").read_bytes() == b"icerik")

print("Güvenlik: klasör dışına yazma denemeleri")
d = fresh("attack")
box = d / "kutu"
box.mkdir()
(box / "kotu.rar").write_bytes(rar5(
    r5_file("../../kacak1.txt", b"x"),
    r5_file("/tmp/rarac_kacak2.txt", b"x"),
    r5_file("normal.txt", b"guvenli"),
))
out = run(box / "kotu.rar")
check("../ ile dışarı çıkamaz", not (d / "kacak1.txt").exists() and not (WORK / "kacak1.txt").exists(), out)
check("mutlak yola yazamaz", not Path("/tmp/rarac_kacak2.txt").exists(), out)

d = fresh("symlink")
box = d / "kutu"
box.mkdir()
outside = d / "disari"
outside.mkdir()
(box / "link.rar").write_bytes(rar5(
    r5_file("baglanti", b"", extra=symlink_extra("../../disari"), attr=0o120777),
    r5_file("baglanti/kacak.txt", b"x"),
    r5_file("normal.txt", b"guvenli"),
))
out = run(box / "link.rar")
res = result_path(out)
check("sembolik bağ üzerinden dışarı yazamaz", list(outside.iterdir()) == [], out)
check("güvensiz bağ atlanır, kalan dosyalar açılır", "SKIPPED 1" in out and res is not None and (res / "normal.txt").read_bytes() == b"guvenli", out)
check("atlanan bağ oluşturulmaz", res is not None and not (res / "baglanti").is_symlink(), out)

d = fresh("safelink")
(d / "iyi.rar").write_bytes(rar5(
    r5_file("gercek.txt", b"veri"),
    r5_file("kisayol.txt", b"", extra=symlink_extra("gercek.txt"), attr=0o120777),
))
out = run(d / "iyi.rar")
res = result_path(out)
check("klasör içi bağ korunur", "SKIPPED 0" in out and res is not None and (res / "kisayol.txt").is_symlink() and (res / "kisayol.txt").read_bytes() == b"veri", out)

d = fresh("rar4link")
(d / "eski.rar").write_bytes(rar4(
    r4_file("kotu", b"/etc/passwd", attr=0o120777),
    r4_file("a.txt", b"1"),
    r4_file("b.txt", b"2"),
))
out = run(d / "eski.rar")
res = result_path(out)
check("RAR4'te güvensiz bağ atlanır", "SKIPPED 1" in out and res is not None and (res / "b.txt").exists() and not (res / "kotu").is_symlink(), out)

print("Şifreli arşiv")
d = fresh("enc")
(d / "gizli.rar").write_bytes(rar5(r5_encrypted_file("sir.txt", b"cok gizli veri", "gizli123")))
out = run(d / "gizli.rar", "--passwords", "gizli123")
res = result_path(out)
check("doğru şifre açar", res is not None and res.read_bytes() == b"cok gizli veri", out)
if res:
    res.unlink()
out = run(d / "gizli.rar", "--passwords", "yanlis,gizli123")
res = result_path(out)
check("yanlış şifrede tekrar sorar", "PROMPT wrong=true" in out and res is not None, out)
if res:
    check("ikinci denemede içerik doğru", res.read_bytes() == b"cok gizli veri")
    res.unlink()
out = run(d / "gizli.rar")
check("şifreden vazgeçince iptal olur", "CANCELLED" in out and no_temp_left(d), out)

print("Çok parçalı arşiv")
d = fresh("multi")
payload = os.urandom(200_000)
a, b = payload[:120_000], payload[120_000:]
crc = zlib.crc32(payload)
sig = b"Rar!\x1a\x07\x01\x00"
(d / "film.part1.rar").write_bytes(
    sig + r5_main(1) + r5_file("film.bin", a, unp=len(payload), crc=crc, hflags=0x10) + r5_end(True))
(d / "film.part2.rar").write_bytes(
    sig + r5_main(3, 1) + r5_file("film.bin", b, unp=len(payload), crc=crc, hflags=0x08) + r5_end())
res = result_path(run(d / "film.part2.rar"))
check("ikinci parçadan açılsa da birleştirir", res is not None and res.read_bytes() == payload, str(res))
if res:
    res.unlink()
(d / "film.part2.rar").unlink()
out = run(d / "film.part1.rar")
check("eksik parçayı adıyla bildirir", "ERR" in out and "film.part2.rar" in out, out)
check("eksik parçada geçici klasör kalmaz", no_temp_left(d))

print("Bozuk dosyalar")
d = fresh("bad")
(d / "crc.rar").write_bytes(rar5(r5_file("a.txt", b"veri", crc=12345)))
out = run(d / "crc.rar")
check("CRC hatası yakalanır", "ERR" in out, out)
check("bozuk dosya ortada kalmaz", not (d / "a.txt").exists() and no_temp_left(d))
(d / "sahte.rar").write_bytes(b"bu bir rar degil" * 100)
out = run(d / "sahte.rar")
check("RAR olmayan dosya reddedilir", "ERR" in out, out)
(d / "boyle.rar").write_bytes(rar5(r5_file("b.bin", os.urandom(50_000)))[:20_000])
out = run(d / "boyle.rar")
check("kesilmiş arşiv hata verir", "ERR" in out and no_temp_left(d), out)

print("Karantina etiketi")
d = fresh("quarantine")
(d / "q.rar").write_bytes(rar4(r4_file("a.txt", b"1"), r4_file("b.txt", b"2")))
tag = "0081;00000000;Safari;"
os.setxattr(d / "q.rar", "com.apple.quarantine", tag.encode()) if hasattr(os, "setxattr") else subprocess.run(
    ["xattr", "-w", "com.apple.quarantine", tag, str(d / "q.rar")], check=True)
res = result_path(run(d / "q.rar"))
got = subprocess.run(["xattr", "-p", "com.apple.quarantine", str(res / "a.txt")], capture_output=True, text=True)
check("açılan dosyalar etiketi taşır", got.stdout.strip() == tag, got.stdout + got.stderr)

print("İptal ve hız (büyük arşiv)")
d = fresh("big")
blob = os.urandom(1 << 20) * 800
big = d / "buyuk.rar"
with open(big, "wb") as f:
    f.write(rar5(r5_file("buyuk.bin", blob)))
out = run(big, "--cancel-on-progress")
check("iptal temiz çıkar", "CANCELLED" in out and no_temp_left(d) and not (d / "buyuk.bin").exists(), out)
out = run(big)
res = result_path(out)
check("büyük dosya doğru açılır", res is not None and res.stat().st_size == len(blob), out)
for line in out.splitlines():
    if line.startswith("TIME"):
        secs = float(line.split()[1])
        print(f"  bilgi 800 MB saklı veri: {secs:.2f} sn, {800 / secs:.0f} MB/sn")

print()
print(f"{len(failures)} hata" if failures else "Tüm testler geçti")
sys.exit(1 if failures else 0)
