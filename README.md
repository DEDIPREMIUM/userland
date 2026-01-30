# Server Termux (UserLAnd Edition)

Script ini adalah porting dari [Server Termux Original](https://github.com/DEDIPREMIUM/servertermux) yang dikhususkan untuk berjalan di lingkungan **UserLAnd (Ubuntu/Debian)**. Script ini menghilangkan ketergantungan pada `termux-api` dan menggunakan perintah standar Linux.

## 🚀 Fitur

*   **Host Zero Server:** Server HTTP ringan berbasis Python.
*   **Cloudflare Tunnel:** Expose localhost ke internet menggunakan Cloudflare Tunnel (mendukung Token).
*   **Template Website Siap Pakai:**
    *   🌐 **Modern Welcome:** Halaman pembuka yang estetik.
    *   🚀 **SpeedTest Ultimate:** Template tes kecepatan internet dengan tampilan mewah.
    *   📊 **System Monitor:** Dashboard monitoring CPU, RAM, dan Baterai secara realtime.
    *   🎬 **Anime Indonesia:** Template demo streaming video.
*   **File Editor:** Edit file `index.html`, `style.css`, dan `script.js` langsung dari menu.
*   **Dukungan UserLAnd:** Berjalan lancar di Ubuntu/Debian pada aplikasi UserLAnd tanpa root (menggunakan `sudo` jika perlu).

## 📦 Cara Instalasi

Pastikan Anda sudah berada di dalam sesi Ubuntu di aplikasi UserLAnd.

1.  **Clone Repository ini (atau download scriptnya):**
    ```bash
    git clone https://github.com/DEDIPREMIUM/servertermux.git
    cd servertermux
    ```

2.  **Jalankan Script Setup:**
    Script ini akan menginstall dependensi yang diperlukan (Python3, Cloudflared, dll) dan membuat file server.
    ```bash
    chmod +x setup_server.sh
    ./setup_server.sh
    ```

3.  **Jalankan Menu:**
    Setelah setup selesai, jalankan menu utama dengan perintah:
    ```bash
    ./menu.sh
    ```

## 🛠️ Cara Penggunaan

1.  **Masukkan Token Cloudflare:**
    *   Pilih menu `[1] Masukkan Token`.
    *   Paste token tunnel Cloudflare Anda (dapatkan dari Dashboard Cloudflare Zero Trust).
2.  **Jalankan Server:**
    *   Pilih menu `[2] Jalankan / Refresh`.
    *   Script akan menjalankan Python Server dan Cloudflared Tunnel secara background.
3.  **Kelola Website:**
    *   Pilih menu `[5] Kelola File Website`.
    *   Pilih template yang diinginkan (misal: SpeedTest atau Monitor) untuk digenerate otomatis.
    *   Akses website melalui domain Cloudflare Anda.

## 📋 Persyaratan

*   Aplikasi **UserLAnd** (Android).
*   Sesi **Ubuntu** atau **Debian**.
*   Koneksi Internet.
*   Token Cloudflare Tunnel.

## ⚠️ Catatan

*   Script ini dimodifikasi agar kompatibel dengan path Linux standar (`/proc/stat`, `/proc/meminfo`, dll) dan tidak menggunakan `pkg` atau `termux-*`.
*   Fitur update git otomatis dinonaktifkan di versi ini untuk menjaga kompatibilitas modifikasi.
