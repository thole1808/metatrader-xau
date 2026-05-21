# XAUUSD ProRisk EA untuk MetaTrader

EA ini dibuat untuk XAUUSD dengan pendekatan trend-following konservatif:

- EMA 50/200 sebagai filter trend.
- RSI sebagai sinyal pullback/re-entry.
- ATR untuk Stop Loss, Take Profit, dan trailing stop.
- Risk per trade default `0.50%` dari balance.
- Daily loss guard default `3%` agar EA berhenti membuka posisi baru saat hari sedang buruk.

Penting: tidak ada bot yang bisa menjamin profit. Jalankan di akun demo dan backtest dulu sebelum live.

## File EA

- MT4: `Experts/XAUUSD_ProRisk_EA.mq4`
- MT5: `Experts_MT5/XAUUSD_ProRisk_Scalper_MT5.mq5`
- MT5 24 jam + tiered profit lock: `Experts_MT5/XAUUSDc_ProRisk_24H_TierLock_MT5.mq5`

## Cara pasang di MT5 Desktop

1. Buka MetaTrader 5.
2. Klik `File > Open Data Folder`.
3. Masuk ke `MQL5/Experts`.
4. Masukkan file `Experts_MT5/XAUUSD_ProRisk_Scalper_MT5.mq5` ke folder tersebut.
5. Buka MetaEditor, compile file `.mq5`, lalu pastikan tidak ada error.
6. Restart MT5 atau klik kanan `Expert Advisors` di Navigator lalu `Refresh`.
7. Buka chart `XAUUSD`, disarankan timeframe `M5`.
8. Drag EA `XAUUSD_ProRisk_Scalper_MT5` ke chart.
9. Aktifkan `Algo Trading` dan centang izin live trading pada EA.

## Cara pasang di MT4 Desktop

1. Buka MetaTrader 4.
2. Klik `File > Open Data Folder`.
3. Masuk ke `MQL4/Experts`.
4. Masukkan file `Experts/XAUUSD_ProRisk_EA.mq4` ke folder tersebut.
5. Restart MT4 atau klik kanan `Expert Advisors` di Navigator lalu `Refresh`.
6. Buka chart `XAUUSD`, disarankan timeframe `M15` atau `H1`.
7. Drag EA `XAUUSD_ProRisk_EA` ke chart.
8. Aktifkan `Allow live trading` dan tombol `AutoTrading`.

## Setting awal untuk saldo 1091.61 cent

Jika akun Anda akun cent, balance `1091.61 cent` kira-kira setara `10.9161 USD`. Gunakan risiko kecil dulu:

- `InpUseFixedLot`: `true` untuk MT5
- `InpFixedLot`: `0.01` untuk MT5
- `InpRiskPercent`: `0.25` sampai `0.35` untuk scalping MT5
- `InpMaxDailyLossPercent`: `2.00` sampai `3.00`
- `InpEquityStopPercent`: `5.00` sampai `6.00` untuk MT5
- `InpMaxSpreadPoints`: sesuaikan broker, mulai dari `80`
- `InpTradeSymbol`: default MT5 sudah `XAUUSDc`; ubah hanya jika nama simbol di broker Anda berbeda

Catatan: jika `InpUseFixedLot = true`, EA akan memakai `InpFixedLot` dan mengabaikan hitungan `InpRiskPercent`.

## Fitur MT5 Scalping

Versi MT5 memakai teknikal scalping:

- Timeframe sinyal default `M5`.
- EMA 20/100 sebagai filter trend cepat.
- RSI untuk konfirmasi momentum pullback.
- Stochastic untuk timing entry scalping.
- ATR untuk SL dan TP wajib.
- Break-even otomatis untuk mengunci profit.
- Trailing stop ATR setelah posisi bergerak profit.
- Daily loss guard untuk menghentikan entry baru.
- Equity stop guard untuk menutup posisi EA jika drawdown harian terlalu besar.
- Spread guard supaya EA tidak entry saat spread XAUUSD melebar.
- Telegram heartbeat default setiap `60` menit untuk pantau EA masih running.

Catatan: `SL Profit` di EA berarti saat posisi sudah bergerak profit, EA akan memindahkan Stop Loss ke area profit kecil sesuai `InpBreakEvenAtR` dan `InpLockProfitR`.

## Versi MT5 24 Jam TierLock

File `Experts_MT5/XAUUSDc_ProRisk_24H_TierLock_MT5.mq5` dibuat terpisah dengan default:

- `InpUseTradingHours`: `false`, jadi EA boleh mencari entry 24 jam selama market broker buka.
- `InpFixedLot`: `0.01`.
- `InpTradeSymbol`: `XAUUSDc`.
- `InpUseTieredProfitLock`: `true`.

Tiered profit lock bukan partial close. Karena lot `0.01` biasanya tidak bisa dipecah, EA mengunci SL bertingkat saat profit naik:

- Tier 1: profit `1.00R`, SL dikunci `0.20R`.
- Tier 2: profit `1.50R`, SL dikunci `0.75R`.
- Tier 3: profit `2.00R`, SL dikunci `1.25R`.
- Tier 4: profit `2.50R`, SL dikunci `1.75R`.
- Tier 5: profit `3.00R`, SL dikunci `2.25R`.
- Tier 6: profit `4.00R`, SL dikunci `3.00R`.

## Kirim notifikasi ke Telegram

EA ini bisa kirim pesan Telegram saat:

- EA mulai berjalan.
- Order BUY/SELL berhasil dibuka.
- Order gagal dibuka.
- Daily loss guard aktif.
- Trailing stop berhasil diperbarui.

Cara setting:

1. Buat bot lewat Telegram `@BotFather`, lalu ambil `Bot Token`.
2. Ambil `chat_id` Telegram Anda. Cara paling mudah: kirim pesan ke bot Anda, lalu buka di browser:

   ```text
   https://api.telegram.org/botTOKEN_BOT_ANDA/getUpdates
   ```

   Cari bagian `"chat":{"id":...}`.

3. Di MT4/MT5 buka `Tools > Options > Expert Advisors`.
4. Centang `Allow WebRequest for listed URL`.
5. Tambahkan URL:

   ```text
   https://api.telegram.org
   ```

6. Saat memasang EA ke chart, isi input:

- `InpUseTelegram`: `true`
- `InpTelegramBotToken`: token dari `@BotFather`, isi lewat input EA saat pasang di chart
- `InpTelegramChatId`: chat_id Anda, isi lewat input EA saat pasang di chart
- `InpStatusEveryMinutes`: `60` untuk laporan status berkala di MT5

## Rekomendasi pemakaian

- Mulai dari demo minimal 1-2 minggu.
- Hindari news besar seperti NFP, CPI, FOMC jika spread broker melebar.
- Jangan naikkan risk hanya karena beberapa trade profit.
- Backtest MT5 scalping di `M5`, lalu bandingkan `M15`.

## Catatan risiko

Tidak ada EA yang bisa menjamin profit. Untuk XAUUSD, scalping sangat sensitif terhadap spread, slippage, news, dan server broker. Jalankan di demo/backtest dulu sebelum live.
