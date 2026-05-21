//+------------------------------------------------------------------+
//|               BOT_MetaTraderLocal_Reversal_Limit_TierReady_MT5.mq5|
//| XAUUSDc Cent Account - Reversal EA + Pending Limit + Telegram     |
//| Mode: NO GRID / NO MARTINGALE / NO AVERAGING                     |
//+------------------------------------------------------------------+
#property strict
#property version "1.00"

#include <Trade/Trade.mqh>
CTrade trade;

// ================= INPUT TRADING =================
input string TradeSymbol              = "XAUUSDc";
input double LotSize                  = 0.01;
input int    MagicNumber              = 2026051912;
input int    MaxSpreadPoints          = 300;
input int    SlippagePoints           = 50;

input ENUM_TIMEFRAMES TrendTF         = PERIOD_M15;
input int    TrendEMA                 = 34;

input int    EntryEMA                 = 12;
input int    RSI_Period               = 14;
input double BuyRSILevel              = 48.0;
input double SellRSILevel             = 52.0;
input bool   UseFastEntryMode         = true;
input int    SignalLookbackBars       = 2;
input bool   EnableTrendFallback      = true;
input bool   UseMarketForTrendFallback = true;

input int    StopLossPoints           = 1000;
input int    TakeProfitPoints         = 1800;

input bool   UseLimitOrders           = true;
input int    LimitOffsetPoints        = 40;
input int    PendingExpiryMinutes     = 2;
input bool   FallbackMarketIfRejected = true;
input bool   DeleteOppositePending    = true;
input bool   RefreshStalePending      = true;

input bool   UseTrailingStop          = true;
input bool   UseAutoSLPlus            = true;
input int    SLPlusTriggerPoints      = 300;
input int    SLPlusLockPoints         = 80;
input int    TrailStartPoints         = 500;
input int    TrailStepPoints          = 250;

input double DailyMaxLossMoney        = 150.0;
input double DailyTargetMoney         = 300.0;

input bool   OneTradePerCandle        = false;

// ================= REVERSAL MODE =================
input bool   EnableReversalMode       = true;
input int    ReversalDelaySeconds     = 1;

// ================= TELEGRAM =================
input bool   EnableTelegram           = true;
input string TelegramBotToken         = "8957713577:AAFBYCap7FHYKFuZWTPsPs76NPHo1XZb-3M";
input string TelegramChatID           = "764887377";

//TEST

// ================= GLOBAL =================
string symbolName;
int trendEmaHandle = INVALID_HANDLE;
int entryEmaHandle = INVALID_HANDLE;
int rsiHandle = INVALID_HANDLE;

datetime lastTradeCandleTime = 0;
int currentDay = -1;
double startDayEquity = 0.0;

bool dailyTargetSent = false;
bool dailyLossSent = false;
string lastStatus = "Starting";
datetime lastPendingRefreshTime = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   symbolName = TradeSymbol;
   if(symbolName == "") symbolName = _Symbol;
   if(!SymbolSelect(symbolName, true))
   {
      Print("Cannot select input symbol: ", symbolName, ". Fallback to chart symbol: ", _Symbol);
      symbolName = _Symbol;
      if(!SymbolSelect(symbolName, true)) return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);
   trade.SetTypeFillingBySymbol(symbolName);

   trendEmaHandle = iMA(symbolName, TrendTF, TrendEMA, 0, MODE_EMA, PRICE_CLOSE);
   entryEmaHandle = iMA(symbolName, _Period, EntryEMA, 0, MODE_EMA, PRICE_CLOSE);
   rsiHandle = iRSI(symbolName, _Period, RSI_Period, PRICE_CLOSE);

   if(trendEmaHandle == INVALID_HANDLE || entryEmaHandle == INVALID_HANDLE || rsiHandle == INVALID_HANDLE)
   {
      LogStatus("ERROR: Failed to create indicators.");
      SendTelegram("BOT Reversal Limit failed to create indicators on " + symbolName);
      return INIT_FAILED;
   }

   ResetDailyEquity();
   LogStatus("BOT Reversal Limit active on " + symbolName + " | Lot: " + DoubleToString(LotSize, 2) + " | LimitOrders: " + (UseLimitOrders ? "ON" : "OFF"));
   SendTelegram("BOT Reversal Limit ACTIVE\nSymbol: " + symbolName + "\nLot: " + DoubleToString(LotSize, 2) + "\nMode: REVERSAL / LIMIT / NO GRID / NO MARTINGALE");

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(trendEmaHandle != INVALID_HANDLE) IndicatorRelease(trendEmaHandle);
   if(entryEmaHandle != INVALID_HANDLE) IndicatorRelease(entryEmaHandle);
   if(rsiHandle != INVALID_HANDLE) IndicatorRelease(rsiHandle);
   Comment("");
   SendTelegram("BOT Reversal Limit STOP on " + symbolName);
}

//+------------------------------------------------------------------+
void OnTick()
{
   CheckNewDay();
   if(UseTrailingStop) ManageTrailingStop();
   ShowPanel();

   if(IsDailyLimitReached()) return;

   int spread = (int)SymbolInfoInteger(symbolName, SYMBOL_SPREAD);
   if(spread > MaxSpreadPoints)
   {
      lastStatus = "Spread too high: " + IntegerToString(spread);
      return;
   }

   datetime candleTime = iTime(symbolName, _Period, 0);
   if(OneTradePerCandle && candleTime == lastTradeCandleTime)
   {
      lastStatus = "One trade per candle guard";
      return;
   }

   bool buySignal = false;
   bool sellSignal = false;
   if(!GetSignals(buySignal, sellSignal)) return;

   bool fallbackBuySignal = false;
   bool fallbackSellSignal = false;
   if(EnableTrendFallback)
      GetTrendFallbackSignals(fallbackBuySignal, fallbackSellSignal);

   int myPositions = CountMyPositions();
   int currentType = GetMyPositionType();

   if(myPositions > 0)
   {
      if(EnableReversalMode)
      {
         if(currentType == POSITION_TYPE_BUY && sellSignal)
         {
            CloseMyPositions();
            Sleep(ReversalDelaySeconds * 1000);
            DeleteMyPendingOrders();
            PlaceEntry(false, candleTime, "REVERSAL SELL");
         }
         else if(currentType == POSITION_TYPE_SELL && buySignal)
         {
            CloseMyPositions();
            Sleep(ReversalDelaySeconds * 1000);
            DeleteMyPendingOrders();
            PlaceEntry(true, candleTime, "REVERSAL BUY");
         }
         else
         {
            lastStatus = "Position running, waiting reversal";
         }
      }
      return;
   }

   if(CountMyPendingOrders() > 0)
   {
      if(RefreshStalePending)
         RefreshPendingIfNeeded(candleTime);
      lastStatus = "Pending order already exists";
      return;
   }

   if(buySignal)
   {
      if(DeleteOppositePending) DeleteMyPendingOrders();
      PlaceEntry(true, candleTime, "BOT BUY LIMIT");
   }
   else if(sellSignal)
   {
      if(DeleteOppositePending) DeleteMyPendingOrders();
      PlaceEntry(false, candleTime, "BOT SELL LIMIT");
   }
   else if(fallbackBuySignal)
   {
      if(DeleteOppositePending) DeleteMyPendingOrders();
      if(UseMarketForTrendFallback)
         PlaceEntryMarket(true, candleTime, "TREND FALLBACK BUY");
      else
         PlaceEntry(true, candleTime, "TREND FALLBACK BUY LIMIT");
   }
   else if(fallbackSellSignal)
   {
      if(DeleteOppositePending) DeleteMyPendingOrders();
      if(UseMarketForTrendFallback)
         PlaceEntryMarket(false, candleTime, "TREND FALLBACK SELL");
      else
         PlaceEntry(false, candleTime, "TREND FALLBACK SELL LIMIT");
   }
   else
   {
      lastStatus = "Waiting signal";
   }
}

//+------------------------------------------------------------------+
bool GetSignals(bool &buySignal, bool &sellSignal)
{
   // Reversal entry prefers a confirmed candle close with trend support.
   double trendEMA[1];
   double entryEMA[2];
   double rsi[3];

   ArraySetAsSeries(trendEMA, true);
   ArraySetAsSeries(entryEMA, true);
   ArraySetAsSeries(rsi, true);

   if(CopyBuffer(trendEmaHandle, 0, 0, 1, trendEMA) <= 0) return false;
   if(CopyBuffer(entryEmaHandle, 0, 0, 2, entryEMA) <= 0) return false;
   if(CopyBuffer(rsiHandle, 0, 0, 3, rsi) <= 0) return false;

   double trendClose = iClose(symbolName, TrendTF, 1);
   double close1 = iClose(symbolName, _Period, 1);
   double open1 = iOpen(symbolName, _Period, 1);
   int lookbackShift = MathMax(2, SignalLookbackBars);
   double close2 = iClose(symbolName, _Period, lookbackShift);

   bool trendBuy = trendClose > trendEMA[0];
   bool trendSell = trendClose < trendEMA[0];
   bool bullishCandle = close1 > open1;
   bool bearishCandle = close1 < open1;
   bool priceImprovingBuy = close1 >= close2;
   bool priceImprovingSell = close1 <= close2;

   buySignal = trendBuy && close1 > entryEMA[0] && bullishCandle && rsi[0] >= BuyRSILevel;
   sellSignal = trendSell && close1 < entryEMA[0] && bearishCandle && rsi[0] <= SellRSILevel;

   if(UseFastEntryMode)
   {
      bool buyMomentum = rsi[0] >= BuyRSILevel && rsi[1] >= BuyRSILevel - 2.0;
      bool sellMomentum = rsi[0] <= SellRSILevel && rsi[1] <= SellRSILevel + 2.0;

      buySignal = buySignal || (trendBuy && close1 > entryEMA[1] && buyMomentum && priceImprovingBuy);
      sellSignal = sellSignal || (trendSell && close1 < entryEMA[1] && sellMomentum && priceImprovingSell);
   }

   return true;
}

//+------------------------------------------------------------------+
void GetTrendFallbackSignals(bool &buySignal, bool &sellSignal)
{
   buySignal = false;
   sellSignal = false;

   double trendEMA[1];
   double entryEMA[2];
   double rsi[2];

   ArraySetAsSeries(trendEMA, true);
   ArraySetAsSeries(entryEMA, true);
   ArraySetAsSeries(rsi, true);

   if(CopyBuffer(trendEmaHandle, 0, 0, 1, trendEMA) <= 0) return;
   if(CopyBuffer(entryEmaHandle, 0, 0, 2, entryEMA) <= 0) return;
   if(CopyBuffer(rsiHandle, 0, 0, 2, rsi) <= 0) return;

   double close1 = iClose(symbolName, _Period, 1);
   double high1 = iHigh(symbolName, _Period, 1);
   double low1 = iLow(symbolName, _Period, 1);
   double close2 = iClose(symbolName, _Period, 2);
   double high2 = iHigh(symbolName, _Period, 2);
   double low2 = iLow(symbolName, _Period, 2);
   double trendClose = iClose(symbolName, TrendTF, 1);

   bool strongUpTrend = trendClose > trendEMA[0] && close1 > entryEMA[0] && close1 > close2;
   bool strongDownTrend = trendClose < trendEMA[0] && close1 < entryEMA[0] && close1 < close2;
   bool makingHigherHigh = high1 >= high2;
   bool makingLowerLow = low1 <= low2;

   buySignal = strongUpTrend && makingHigherHigh && rsi[0] >= BuyRSILevel + 2.0;
   sellSignal = strongDownTrend && makingLowerLow && rsi[0] <= SellRSILevel - 2.0;
}

//+------------------------------------------------------------------+
void PlaceEntry(const bool isBuy, const datetime candleTime, const string reason)
{
   // Limit entry tries to get a slightly better price than immediate market execution.
   double ask = SymbolInfoDouble(symbolName, SYMBOL_ASK);
   double bid = SymbolInfoDouble(symbolName, SYMBOL_BID);
   double point = SymbolInfoDouble(symbolName, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(symbolName, SYMBOL_DIGITS);
   int stopsLevel = (int)SymbolInfoInteger(symbolName, SYMBOL_TRADE_STOPS_LEVEL);
   double minDistance = (stopsLevel + 5) * point;
   double offset = MathMax(LimitOffsetPoints * point, minDistance);

   double entry = isBuy ? ask - offset : bid + offset;
   double sl = isBuy ? entry - StopLossPoints * point : entry + StopLossPoints * point;
   double tp = isBuy ? entry + TakeProfitPoints * point : entry - TakeProfitPoints * point;

   entry = NormalizeDouble(entry, digits);
   sl = NormalizeDouble(sl, digits);
   tp = NormalizeDouble(tp, digits);

   bool result = false;
   string side = isBuy ? "BUY" : "SELL";

   if(UseLimitOrders)
   {
      datetime expiry = TimeCurrent() + PendingExpiryMinutes * 60;
      if(isBuy)
         result = trade.BuyLimit(LotSize, entry, symbolName, sl, tp, ORDER_TIME_SPECIFIED, expiry, reason);
      else
         result = trade.SellLimit(LotSize, entry, symbolName, sl, tp, ORDER_TIME_SPECIFIED, expiry, reason);

      if(result)
      {
         lastTradeCandleTime = candleTime;
         lastPendingRefreshTime = TimeCurrent();
         LogStatus(side + " LIMIT placed | Entry: " + DoubleToString(entry, digits) + " | SL: " + DoubleToString(sl, digits) + " | TP: " + DoubleToString(tp, digits));
         SendTelegram(side + " LIMIT PLACED\nSymbol: " + symbolName + "\nLot: " + DoubleToString(LotSize, 2) + "\nEntry: " + DoubleToString(entry, digits) + "\nSL: " + DoubleToString(sl, digits) + "\nTP: " + DoubleToString(tp, digits));
         return;
      }

      LogStatus(side + " LIMIT rejected: " + trade.ResultRetcodeDescription());
      if(!FallbackMarketIfRejected) return;
   }

   PlaceEntryMarket(isBuy, candleTime, reason + " MARKET");
}

//+------------------------------------------------------------------+
void PlaceEntryMarket(const bool isBuy, const datetime candleTime, const string reason)
{
   // Market fallback keeps the bot active when pending limits are not suitable.
   double ask = SymbolInfoDouble(symbolName, SYMBOL_ASK);
   double bid = SymbolInfoDouble(symbolName, SYMBOL_BID);
   double point = SymbolInfoDouble(symbolName, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(symbolName, SYMBOL_DIGITS);

   double marketEntry = isBuy ? ask : bid;
   double marketSL = isBuy ? marketEntry - StopLossPoints * point : marketEntry + StopLossPoints * point;
   double marketTP = isBuy ? marketEntry + TakeProfitPoints * point : marketEntry - TakeProfitPoints * point;
   marketSL = NormalizeDouble(marketSL, digits);
   marketTP = NormalizeDouble(marketTP, digits);

   if(isBuy)
      result = trade.Buy(LotSize, symbolName, 0.0, marketSL, marketTP, reason + " MARKET");
   else
      result = trade.Sell(LotSize, symbolName, 0.0, marketSL, marketTP, reason + " MARKET");

   if(result)
   {
      lastTradeCandleTime = candleTime;
      LogStatus(side + " MARKET opened | SL: " + DoubleToString(marketSL, digits) + " | TP: " + DoubleToString(marketTP, digits));
      SendTelegram(side + " MARKET OPEN\nSymbol: " + symbolName + "\nLot: " + DoubleToString(LotSize, 2) + "\nSL: " + DoubleToString(marketSL, digits) + "\nTP: " + DoubleToString(marketTP, digits));
   }
   else
   {
      LogStatus(side + " MARKET failed: " + trade.ResultRetcodeDescription());
      SendTelegram(side + " ENTRY FAILED\nSymbol: " + symbolName + "\nReason: " + trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
void ManageTrailingStop()
{
   double point = SymbolInfoDouble(symbolName, SYMBOL_POINT);
   double bid = SymbolInfoDouble(symbolName, SYMBOL_BID);
   double ask = SymbolInfoDouble(symbolName, SYMBOL_ASK);
   int digits = (int)SymbolInfoInteger(symbolName, SYMBOL_DIGITS);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbolName || PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      int type = (int)PositionGetInteger(POSITION_TYPE);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl = PositionGetDouble(POSITION_SL);
      double tp = PositionGetDouble(POSITION_TP);

      if(type == POSITION_TYPE_BUY)
      {
         double profitPoints = (bid - openPrice) / point;

         if(UseAutoSLPlus && profitPoints >= SLPlusTriggerPoints)
         {
            double slPlus = NormalizeDouble(openPrice + SLPlusLockPoints * point, digits);
            if(sl == 0.0 || slPlus > sl)
               trade.PositionModify(ticket, slPlus, tp);
         }

         if(profitPoints >= TrailStartPoints)
         {
            double newSL = NormalizeDouble(bid - TrailStepPoints * point, digits);
            if(newSL > sl) trade.PositionModify(ticket, newSL, tp);
         }
      }
      else if(type == POSITION_TYPE_SELL)
      {
         double profitPoints = (openPrice - ask) / point;

         if(UseAutoSLPlus && profitPoints >= SLPlusTriggerPoints)
         {
            double slPlus = NormalizeDouble(openPrice - SLPlusLockPoints * point, digits);
            if(sl == 0.0 || slPlus < sl)
               trade.PositionModify(ticket, slPlus, tp);
         }

         if(profitPoints >= TrailStartPoints)
         {
            double newSL = NormalizeDouble(ask + TrailStepPoints * point, digits);
            if(sl == 0 || newSL < sl) trade.PositionModify(ticket, newSL, tp);
         }
      }
   }
}

//+------------------------------------------------------------------+
int CountMyPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket) && PositionGetString(POSITION_SYMBOL) == symbolName && PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         count++;
   }
   return count;
}

//+------------------------------------------------------------------+
int CountMyPendingOrders()
{
   int count = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || !OrderSelect(ticket)) continue;
      if(OrderGetString(ORDER_SYMBOL) == symbolName && OrderGetInteger(ORDER_MAGIC) == MagicNumber) count++;
   }
   return count;
}

//+------------------------------------------------------------------+
int GetMyPositionType()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket) && PositionGetString(POSITION_SYMBOL) == symbolName && PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         return (int)PositionGetInteger(POSITION_TYPE);
   }
   return -1;
}

//+------------------------------------------------------------------+
void CloseMyPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket) && PositionGetString(POSITION_SYMBOL) == symbolName && PositionGetInteger(POSITION_MAGIC) == MagicNumber)
      {
         if(trade.PositionClose(ticket)) LogStatus("Closed position ticket: " + IntegerToString((int)ticket));
         else LogStatus("Close failed: " + trade.ResultRetcodeDescription());
      }
   }
}

//+------------------------------------------------------------------+
void DeleteMyPendingOrders()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || !OrderSelect(ticket)) continue;
      if(OrderGetString(ORDER_SYMBOL) == symbolName && OrderGetInteger(ORDER_MAGIC) == MagicNumber)
      {
         if(trade.OrderDelete(ticket)) LogStatus("Deleted pending ticket: " + IntegerToString((int)ticket));
      }
   }
}

// Re-create pending orders if the market moved on and the old pending became too stale.
void RefreshPendingIfNeeded(const datetime candleTime)
{
   if(lastPendingRefreshTime != 0 && TimeCurrent() - lastPendingRefreshTime < 20) return;

   double ask = SymbolInfoDouble(symbolName, SYMBOL_ASK);
   double bid = SymbolInfoDouble(symbolName, SYMBOL_BID);
   double point = SymbolInfoDouble(symbolName, SYMBOL_POINT);
   double refreshDistance = MathMax(LimitOffsetPoints * point * 3.0, 120 * point);

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || !OrderSelect(ticket)) continue;
      if(OrderGetString(ORDER_SYMBOL) != symbolName || OrderGetInteger(ORDER_MAGIC) != MagicNumber) continue;

      ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      double priceOpen = OrderGetDouble(ORDER_PRICE_OPEN);

      if(type == ORDER_TYPE_BUY_LIMIT && MathAbs(ask - priceOpen) > refreshDistance)
      {
         if(trade.OrderDelete(ticket))
         {
            lastPendingRefreshTime = TimeCurrent();
            LogStatus("Refreshing stale BUY LIMIT");
            PlaceEntry(true, candleTime, "REFRESH BUY LIMIT");
         }
         return;
      }

      if(type == ORDER_TYPE_SELL_LIMIT && MathAbs(priceOpen - bid) > refreshDistance)
      {
         if(trade.OrderDelete(ticket))
         {
            lastPendingRefreshTime = TimeCurrent();
            LogStatus("Refreshing stale SELL LIMIT");
            PlaceEntry(false, candleTime, "REFRESH SELL LIMIT");
         }
         return;
      }
   }
}

//+------------------------------------------------------------------+
void ResetDailyEquity()
{
   MqlDateTime now;
   TimeToStruct(TimeCurrent(), now);
   currentDay = now.day;
   startDayEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   dailyTargetSent = false;
   dailyLossSent = false;
   LogStatus("Reset daily equity: " + DoubleToString(startDayEquity, 2));
}

//+------------------------------------------------------------------+
void CheckNewDay()
{
   MqlDateTime now;
   TimeToStruct(TimeCurrent(), now);
   if(now.day != currentDay) ResetDailyEquity();
}

//+------------------------------------------------------------------+
bool IsDailyLimitReached()
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double diff = equity - startDayEquity;

   if(diff <= -DailyMaxLossMoney)
   {
      if(!dailyLossSent)
      {
         SendTelegram("DAILY LOSS REACHED\nBot: Reversal Limit\nLoss: " + DoubleToString(diff, 2) + "\nTrading stop today.");
         dailyLossSent = true;
      }
      lastStatus = "Daily max loss reached: " + DoubleToString(diff, 2);
      return true;
   }

   if(diff >= DailyTargetMoney)
   {
      if(!dailyTargetSent)
      {
         SendTelegram("DAILY TARGET REACHED\nBot: Reversal Limit\nProfit: " + DoubleToString(diff, 2) + "\nTrading stop today.");
         dailyTargetSent = true;
      }
      lastStatus = "Daily target reached: " + DoubleToString(diff, 2);
      return true;
   }

   return false;
}

//+------------------------------------------------------------------+
void ShowPanel()
{
   double dailyPL = AccountInfoDouble(ACCOUNT_EQUITY) - startDayEquity;
   Comment("BOT MetaTraderLocal Reversal Limit\n",
           "Symbol: ", symbolName, " | TF: ", EnumToString(_Period), "\n",
           "Positions: ", CountMyPositions(), " | Pending: ", CountMyPendingOrders(), "\n",
           "Daily P/L: ", DoubleToString(dailyPL, 2), "\n",
           "Lot: ", DoubleToString(LotSize, 2), " | Spread: ", IntegerToString((int)SymbolInfoInteger(symbolName, SYMBOL_SPREAD)), "\n",
           "Mode: REVERSAL / LIMIT / NO GRID\n",
           "Status: ", lastStatus);
}

//+------------------------------------------------------------------+
void LogStatus(const string message)
{
   lastStatus = message;
   Print("[ReversalLimit] ", message);
}

//+------------------------------------------------------------------+
bool SendTelegram(string message)
{
   if(!EnableTelegram) return false;
   if(TelegramBotToken == "" || TelegramChatID == "")
   {
      Print("[Telegram] token/chat_id empty.");
      return false;
   }

   string url = "https://api.telegram.org/bot" + TelegramBotToken + "/sendMessage";
   string headers = "Content-Type: application/x-www-form-urlencoded\r\n";
   string data = "chat_id=" + UrlEncode(TelegramChatID) + "&text=" + UrlEncode(message);

   char post[];
   char result[];
   string result_headers;
   int size = StringToCharArray(data, post, 0, WHOLE_ARRAY, CP_UTF8) - 1;
   if(size > 0) ArrayResize(post, size);

   ResetLastError();
   int res = WebRequest("POST", url, headers, 5000, post, result, result_headers);
   if(res == -1)
   {
      Print("[Telegram] WebRequest failed. Error: ", GetLastError(), ". Add https://api.telegram.org to allowed URLs.");
      return false;
   }

   Print("[Telegram] sent. HTTP: ", res);
   return res >= 200 && res < 300;
}

//+------------------------------------------------------------------+
string UrlEncode(string text)
{
   string encoded = "";
   uchar bytes[];
   StringToCharArray(text, bytes, 0, WHOLE_ARRAY, CP_UTF8);

   for(int i = 0; i < ArraySize(bytes) - 1; i++)
   {
      uchar c = bytes[i];
      if((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.' || c == '~')
         encoded += CharToString(c);
      else if(c == ' ')
         encoded += "+";
      else
         encoded += "%" + StringFormat("%02X", c);
   }

   return encoded;
}
