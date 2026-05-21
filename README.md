# XAU MetaTrader Bots

Kumpulan EA MetaTrader untuk `XAUUSD/XAUUSDc` yang dipakai untuk akun cent dan eksperimen entry reversal, limit order, profit lock, dan Telegram monitoring.

Penting:

- Tidak ada EA yang bisa menjamin profit.
- Selalu test di demo/backtest dulu.
- XAU sangat sensitif terhadap spread, slippage, dan news.

## File Utama

- MT4: `Experts/XAUUSD_ProRisk_EA.mq4`
- MT4 companion untuk VPS/terminal MT4: `Experts/BOT_MetaTraderLocal_Reversal_Limit_TierReady_MT4.mq4`
- MT5 scalper awal: `Experts_MT5/XAUUSD_ProRisk_Scalper_MT5.mq5`
- MT5 24 jam tier lock: `Experts_MT5/XAUUSDc_ProRisk_24H_TierLock_MT5.mq5`
- MT5 reversal limit aktif: `Experts_MT5/BOT_MetaTraderLocal_Reversal_Limit_TierReady_MT5.mq5`

## EA Aktif Sekarang

File:

- `Experts_MT5/BOT_MetaTraderLocal_Reversal_Limit_TierReady_MT5.mq5`

Karakter utamanya:

- Fokus `reversal limit`
- Bisa pakai `trend fallback`
- Punya `SignalTF` tetap, jadi chart boleh dipindah timeframe tanpa mengubah logika sinyal
- Bisa `split 3 order`
- `TP` bertingkat
- `SL Plus` untuk lock profit
- `Trailing stop`
- `Daily target/loss guard`
- `Cooldown` setelah posisi close
- Log indikator ke tab `Experts`
- Telegram notifikasi

## Inti Fungsi EA Aktif

1. Baca trend pakai `TrendEMA` pada `TrendTF`
2. Baca sinyal entry pakai candle, `EntryEMA`, dan `RSI` pada `SignalTF`
3. Validasi candle agar tidak asal entry
4. Entry reversal pakai `limit order` bila cocok
5. Fallback ke `market order` bila perlu
6. Pecah entry ke `3 order` dengan `TP` bertingkat
7. Geser `SL` ke profit pakai `SL Plus`
8. Lanjut kunci profit pakai `trailing`

## Input Penting EA Aktif

- `TradeSymbol`
- `LotSize`
- `TrendTF`
- `SignalTF`
- `TrendEMA`
- `EntryEMA`
- `RSI_Period`
- `BuyRSILevel`
- `SellRSILevel`
- `UseLimitOrders`
- `UseThreeOrderSplit`
- `TakeProfitPoints`
- `SLPlusTriggerPoints`
- `SLPlusLockPoints`
- `TrailStartPoints`
- `TrailStepPoints`
- `DailyMaxLossMoney`
- `DailyTargetMoney`
- `ReentryCooldownBars`

## TP Bertingkat

Kalau `UseThreeOrderSplit = true`, satu sinyal bisa dibagi jadi 3 order:

- `TP1 = TakeProfitPoints`
- `TP2 = TP2Multiplier x TakeProfitPoints`
- `TP3 = TP3Multiplier x TakeProfitPoints`

Contoh:

- `TakeProfitPoints = 500`
- `TP2Multiplier = 1.50`
- `TP3Multiplier = 2.00`

Maka:

- TP1 = `500`
- TP2 = `750`
- TP3 = `1000`

## SL Plus Dan Trailing

Tujuannya:

- posisi hijau jangan mudah balik merah
- profit kecil cepat diamankan
- posisi runner tetap punya peluang jalan lebih jauh

Urutannya:

1. Posisi profit sampai `SLPlusTriggerPoints`
2. `SL` dipindah ke area plus sebesar `SLPlusLockPoints`
3. Setelah profit makin jauh, `trailing` lanjut mengunci

## Log Di Experts

EA aktif sekarang menulis log ke tab `Experts` seperti:

- status EA
- sinyal buy/sell
- snapshot indikator
- nilai `RSI`
- nilai EMA
- candle `O/H/L/C`
- status re-entry cooldown
- status pending order

Contoh log:

```text
[SignalLog] TF=PERIOD_M15 | Spread=... | TrendClose=... | TrendEMA=... | EntryEMA=... | RSI=... | O=... | H=... | L=... | C=... | Signal=BUY_REV
```

## Rekap Total Account Ke Telegram

EA aktif sekarang bisa kirim rekap total history account saat startup.

Input:

- `SendAccountTotalSummary = true`

Yang dikirim:

- total closed deals
- total menang
- total rugi
- net total
- sisa recovery ke break-even

Catatan:

- data diambil dari history yang tersedia di terminal MT5
- rekap ini bersifat account-wide, bukan cuma trade EA ini

## Telegram

Setting Telegram:

1. Buat bot di `@BotFather`
2. Ambil `Bot Token`
3. Ambil `chat_id`
4. Di MT5 buka `Tools > Options > Expert Advisors`
5. Centang `Allow WebRequest for listed URL`
6. Tambahkan:

```text
https://api.telegram.org
```

Input yang dipakai:

- `EnableTelegram = true`
- `TelegramBotToken = ...`
- `TelegramChatID = ...`

## Workflow Mac + MT5

Source utama dikerjakan dari project ini:

- `/Users/achmadagus/Documents/Project/scipt-xau-metatrader`

File MT5 di folder `Experts/Advisors` sudah dihubungkan ke source project, jadi alurnya:

1. Edit source di project ini
2. Save
3. Compile di MetaEditor
4. MT5 pakai versi terbaru

## Catatan Risiko

- Lot lebih besar = drawdown lebih cepat
- `SL Plus` yang terlalu cepat akan sering mengunci profit kecil
- `M15` lebih sabar daripada `M5`
- Jangan paksa entry ramai kalau market sedang choppy dan jelek
