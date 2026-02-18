# GSBWIFI Manager (macOS Native)

GSBWIFI ağlarına otomatik giriş yapan, kota takibi sağlayan ve çoklu hesap yönetimini destekleyen macOS menü bar uygulamasıdır. Swift ve SwiftUI ile geliştirilmiştir.

## Özellikler

- Yerel Performans: CoreWLAN ile hızlı ağ tespiti.
- Arayüz: Sade ve anlaşılır kullanıcı arayüzü.
- Çoklu Hesap: Birden fazla hesap ekleme ve geçiş yapabilme imkanı.
- Otomatik Giriş: Ağ algılandığında otomatik giriş yapma.
- Oturum Yönetimi: Maksimum cihaz sınırı hatasında eski oturumu sonlandırıp yeni giriş yapabilme.
- Kota Takibi: Kalan kota ve süre bilgisini görüntüleme.
- Hız Testi: Anlık bağlantı hızı ölçümü.

## Kurulum

Bu proje Xcode gerektirmez. Terminal üzerinden derlenebilir.

1. Terminali açın ve proje dizinine gidin:
   cd swift

2. Uygulamayı derleyin ve başlatın:
   ./build.sh run

Derlenen uygulama "swift/build/GSBWiFiManager.app" dizininde oluşturulur. Kalıcı kullanım için bu dosyayı Uygulamalar klasörüne taşıyabilirsiniz.

## Kullanım

1. Uygulamayı başlatın.
2. Menü çubuğundaki ikona tıklayın.
3. Hesap ekleme ekranından bilgilerinizi girin.
4. "Giriş Yap" butonunu kullanarak bağlantıyı sağlayın.

## Güvenlik

Hesap bilgileri yerel olarak saklanır ve sadece resmi GSB Portal (wifi.gsb.gov.tr) ile iletişim kurulur.
