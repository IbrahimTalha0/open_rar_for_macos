#include "rar.hpp"
#include "rarac_shim.h"

static int CALLBACK OnUnrarEvent(UINT msg, LPARAM userData, LPARAM p1, LPARAM p2) {
  const RarAcCallbacks *cb = reinterpret_cast<const RarAcCallbacks *>(userData);
  switch (msg) {
    case UCM_CHANGEVOLUMEW:
      if (p2 == RAR_VOL_ASK) {
        cb->missingVolume(cb->user, reinterpret_cast<const wchar_t *>(p1));
        return -1;
      }
      return 1;
    case UCM_PROCESSDATA:
      return cb->progress(cb->user, static_cast<int64_t>(p2)) == 0 ? 1 : -1;
    case UCM_NEEDPASSWORDW:
      return cb->password(cb->user, reinterpret_cast<wchar_t *>(p1), static_cast<int>(p2)) ? 1 : -1;
    case UCM_LARGEDICT:
      // Çok büyük sözlük isteyen arşivler onlarca GB bellek ayırabilir, reddediyoruz.
      return -1;
    default:
      return 0;
  }
}

static HANDLE OpenArchive(const char *path, unsigned int mode, const RarAcCallbacks *cb, int *error) {
  // Önceki arşivden veya yanlış şifre denemesinden kalan hata taşınmasın.
  ErrHandler.Clean();
  RAROpenArchiveDataEx data;
  memset(&data, 0, sizeof(data));
  data.ArcName = const_cast<char *>(path);
  data.OpenMode = mode;
  data.Callback = OnUnrarEvent;
  data.UserData = reinterpret_cast<LPARAM>(cb);
  HANDLE handle = RAROpenArchiveEx(&data);
  *error = handle == nullptr || data.OpenResult != 0 ? static_cast<int>(data.OpenResult) : 0;
  if (handle != nullptr && *error != 0) {
    RARCloseArchive(handle);
    return nullptr;
  }
  return handle;
}

extern "C" int rarac_scan(const char *path, const RarAcCallbacks *cb, int64_t *totalBytes) {
  int error = 0;
  HANDLE handle = OpenArchive(path, RAR_OM_LIST, cb, &error);
  if (handle == nullptr) return error;

  RARHeaderDataEx header;
  int64_t total = 0;
  int result = 0;
  for (;;) {
    memset(&header, 0, sizeof(header));
    result = RARReadHeaderEx(handle, &header);
    if (result != 0) break;
    total += (static_cast<int64_t>(header.UnpSizeHigh) << 32) | header.UnpSize;
    result = RARProcessFile(handle, RAR_SKIP, nullptr, nullptr);
    if (result != 0) break;
  }
  RARCloseArchive(handle);
  *totalBytes = total;
  return result == ERAR_END_ARCHIVE ? 0 : result;
}

extern "C" int rarac_extract(const char *path, const char *dest, const RarAcCallbacks *cb) {
  int error = 0;
  HANDLE handle = OpenArchive(path, RAR_OM_EXTRACT, cb, &error);
  if (handle == nullptr) return error;

  RARHeaderDataEx header;
  int result = 0;
  for (;;) {
    memset(&header, 0, sizeof(header));
    result = RARReadHeaderEx(handle, &header);
    if (result != 0) break;
    if (cb->entry(cb->user, header.FileNameW) != 0) {
      result = RARAC_CANCELLED;
      break;
    }
    result = RARProcessFile(handle, RAR_EXTRACT, const_cast<char *>(dest), nullptr);
    // UnRAR klasör dışına çıkan bağlantıları reddeder. Arşivin kalanını yine de açıyoruz.
    if (header.RedirType != 0 && (result == ERAR_UNKNOWN || result == ERAR_ECREATE)) {
      cb->skippedLink(cb->user);
      // UnRAR'ın hata durumu global ve kalıcı. Sıfırlamazsak sonraki sağlam dosyalar da hatalı görünür.
      ErrHandler.Clean();
      continue;
    }
    if (result != 0) break;
  }
  RARCloseArchive(handle);
  return result == ERAR_END_ARCHIVE ? 0 : result;
}
