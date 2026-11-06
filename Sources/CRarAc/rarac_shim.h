// Swift ile UnRAR arasındaki ince C köprüsü.
// UnRAR'ın paketlenmiş (#pragma pack) yapıları Swift'e aktarılamadığı için
// onları burada saklıyoruz ve dışarıya yalnızca düz bir arayüz veriyoruz.
#ifndef RARAC_SHIM_H
#define RARAC_SHIM_H

#include <stdint.h>
#include <wchar.h>

#ifdef __cplusplus
extern "C" {
#endif

// Swift tarafı kullanıcı iptal ettiğinde döner.
#define RARAC_CANCELLED (-1)

// UnRAR'ın dll.hpp içindeki hata kodlarının Swift'e açık kopyaları.
enum {
  RARAC_OK = 0,
  RARAC_NO_MEMORY = 11,
  RARAC_BAD_DATA = 12,
  RARAC_BAD_ARCHIVE = 13,
  RARAC_UNKNOWN_FORMAT = 14,
  RARAC_EOPEN = 15,
  RARAC_ECREATE = 16,
  RARAC_ECLOSE = 17,
  RARAC_EREAD = 18,
  RARAC_EWRITE = 19,
  RARAC_MISSING_PASSWORD = 22,
  RARAC_BAD_PASSWORD = 24,
  RARAC_LARGE_DICT = 25
};

typedef struct {
  void *user;
  // Şifreyi buf içine yazar. 1: şifre verildi, 0: kullanıcı vazgeçti.
  int (*password)(void *user, wchar_t *buf, int capacity);
  // Yeni açılan veri miktarı. 0 dışı dönerse işlem iptal edilir.
  int (*progress)(void *user, int64_t bytes);
  // Sıradaki dosyanın adı. 0 dışı dönerse işlem iptal edilir.
  int (*entry)(void *user, const wchar_t *name);
  // Bulunamayan arşiv parçasının adı.
  void (*missingVolume)(void *user, const wchar_t *name);
  // Güvensiz veya bu diskte oluşturulamayan bağlantı atlandı.
  void (*skippedLink)(void *user);
} RarAcCallbacks;

// Arşivi açmadan önce başlıkları tarar ve toplam açık boyutu döndürür.
int rarac_scan(const char *path, const RarAcCallbacks *callbacks, int64_t *totalBytes);

// Arşivin tamamını dest klasörüne açar.
int rarac_extract(const char *path, const char *dest, const RarAcCallbacks *callbacks);

#ifdef __cplusplus
}
#endif

#endif
