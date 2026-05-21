//+------------------------------------------------------------------+
//|            BOT_MetaTraderLocal_Reversal_Limit_TierReady_MT4.mq4  |
//| XAUUSD/XAUUSDc MT4 - Reversal style EA with Telegram             |
//| Simplified MT4 companion for the MT5 TierReady version           |
//+------------------------------------------------------------------+
#property strict
#property version   "1.00"
#property description "MT4 companion EA with EMA trend, RSI confirmation, SL Plus style trailing, and Telegram."

input string InpTradeSymbol          = "XAUUSD";
input int    InpMagicNumber          = 2026051912;
input double InpFixedLot             = 0.02;
input int    InpMaxSpreadPoints      = 300;
input int    InpSlippagePoints       = 30;

input ENUM_TIMEFRAMES InpTrendTF     = PERIOD_M15;
input ENUM_TIMEFRAMES InpSignalTF    = PERIOD_M15;
input int    InpTrendEMA             = 34;
input int    InpEntryEMA             = 12;
input int    InpRSIPeriod            = 14;
input double InpBuyRSILevel          = 48.0;
input double InpSellRSILevel         = 52.0;

input int    InpStopLossPoints       = 1000;
input int    InpTakeProfitPoints     = 500;
input bool   InpUseSLPlus            = true;
input int    InpSLPlusTriggerPoints  = 60;
input int    InpSLPlusLockPoints     = 30;
input bool   InpUseTrailingStop      = true;
input int    InpTrailStartPoints     = 90;
input int    InpTrailStepPoints      = 40;

input bool   InpUseTelegram          = true;
input string InpTelegramBotToken     = "";
input string InpTelegramChatId       = "";

string   g_symbol;
datetime g_lastBarTime = 0;
ulong    g_lastClosedTicket = 0;

int OnInit()
{
   g_symbol = InpTradeSymbol;
   if(g_symbol == "") g_symbol = Symbol();
   if(!SymbolSelect(g_symbol, true)) return(INIT_FAILED);

   Print("BOT MT4 TierReady active on ", g_symbol);
   SendTelegramMessage("EA STARTED\nBot: Reversal Limit TierReady MT4\nSymbol: " + g_symbol +
                       "\nLot: " + DoubleToString(InpFixedLot, 2) +
                       "\nTrend TF: " + TimeframeToText(InpTrendTF) +
                       "\nSignal TF: " + TimeframeToText(InpSignalTF));
   return(INIT_SUCCEEDED);
}

void OnTick()
{
   if(Symbol() != g_symbol && !IsTesting()) return;
   RefreshRates();

   ManageOpenTrades();
   NotifyClosedTrades();

   if(!IsNewSignalBar()) return;
   if(GetSpreadPoints() > InpMaxSpreadPoints) return;
   if(CountOpenTrades() > 0) return;

   int signal = GetSignal();
   if(signal == OP_BUY) OpenTrade(OP_BUY);
   if(signal == OP_SELL) OpenTrade(OP_SELL);
}

bool IsNewSignalBar()
{
   datetime barTime = iTime(g_symbol, InpSignalTF, 0);
   if(barTime == 0 || barTime == g_lastBarTime) return(false);
   g_lastBarTime = barTime;
   return(true);
}

double GetSpreadPoints()
{
   return(MarketInfo(g_symbol, MODE_SPREAD));
}

int CountOpenTrades()
{
   int count = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol() == g_symbol && OrderMagicNumber() == InpMagicNumber) count++;
   }
   return(count);
}

int GetSignal()
{
   double trendEMA = iMA(g_symbol, InpTrendTF, InpTrendEMA, 0, MODE_EMA, PRICE_CLOSE, 1);
   double entryEMA = iMA(g_symbol, InpSignalTF, InpEntryEMA, 0, MODE_EMA, PRICE_CLOSE, 1);
   double close1   = iClose(g_symbol, InpSignalTF, 1);
   double open1    = iOpen(g_symbol, InpSignalTF, 1);
   double close2   = iClose(g_symbol, InpSignalTF, 2);
   double open2    = iOpen(g_symbol, InpSignalTF, 2);
   double high1    = iHigh(g_symbol, InpSignalTF, 1);
   double low1     = iLow(g_symbol, InpSignalTF, 1);
   double high2    = iHigh(g_symbol, InpSignalTF, 2);
   double low2     = iLow(g_symbol, InpSignalTF, 2);
   double rsi1     = iRSI(g_symbol, InpSignalTF, InpRSIPeriod, PRICE_CLOSE, 1);

   bool trendBuy = iClose(g_symbol, InpTrendTF, 1) > trendEMA;
   bool trendSell = iClose(g_symbol, InpTrendTF, 1) < trendEMA;
   bool bullish = close1 > open1 && close2 > open2 && low1 >= low2;
   bool bearish = close1 < open1 && close2 < open2 && high1 <= high2;

   if(trendBuy && close1 > entryEMA && bullish && rsi1 >= InpBuyRSILevel) return(OP_BUY);
   if(trendSell && close1 < entryEMA && bearish && rsi1 <= InpSellRSILevel) return(OP_SELL);
   return(-1);
}

void OpenTrade(int type)
{
   double point = MarketInfo(g_symbol, MODE_POINT);
   double ask = MarketInfo(g_symbol, MODE_ASK);
   double bid = MarketInfo(g_symbol, MODE_BID);
   int digits = (int)MarketInfo(g_symbol, MODE_DIGITS);

   double entry = (type == OP_BUY) ? ask : bid;
   double sl = (type == OP_BUY) ? entry - InpStopLossPoints * point : entry + InpStopLossPoints * point;
   double tp = (type == OP_BUY) ? entry + InpTakeProfitPoints * point : entry - InpTakeProfitPoints * point;

   int ticket = OrderSend(g_symbol, type, InpFixedLot, NormalizeDouble(entry, digits), InpSlippagePoints,
                          NormalizeDouble(sl, digits), NormalizeDouble(tp, digits),
                          "TierReady MT4", InpMagicNumber, 0, clrGold);

   if(ticket < 0)
   {
      int err = GetLastError();
      Print("OrderSend failed. Error: ", err);
      SendTelegramMessage("ENTRY FAILED\nBot: Reversal Limit TierReady MT4\nSymbol: " + g_symbol +
                          "\nError: " + IntegerToString(err));
      return;
   }

   SendTelegramMessage(StringFormat("ENTRY OPENED\nBot: Reversal Limit TierReady MT4\nType: %s\nSymbol: %s\nLot: %.2f\nEntry: %s\nSL: %s\nTP: %s",
                                    type == OP_BUY ? "BUY" : "SELL",
                                    g_symbol,
                                    InpFixedLot,
                                    DoubleToString(entry, digits),
                                    DoubleToString(sl, digits),
                                    DoubleToString(tp, digits)));
}

void ManageOpenTrades()
{
   double point = MarketInfo(g_symbol, MODE_POINT);
   double bid = MarketInfo(g_symbol, MODE_BID);
   double ask = MarketInfo(g_symbol, MODE_ASK);
   int digits = (int)MarketInfo(g_symbol, MODE_DIGITS);

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol() != g_symbol || OrderMagicNumber() != InpMagicNumber) continue;

      double openPrice = OrderOpenPrice();
      double sl = OrderStopLoss();
      double tp = OrderTakeProfit();

      if(OrderType() == OP_BUY)
      {
         double profitPoints = (bid - openPrice) / point;
         double newSL = sl;
         bool modify = false;

         if(InpUseSLPlus && profitPoints >= InpSLPlusTriggerPoints)
         {
            double slPlus = NormalizeDouble(openPrice + InpSLPlusLockPoints * point, digits);
            if(sl == 0.0 || slPlus > sl) { newSL = slPlus; modify = true; }
         }

         if(InpUseTrailingStop && profitPoints >= InpTrailStartPoints)
         {
            double trailSL = NormalizeDouble(bid - InpTrailStepPoints * point, digits);
            if(trailSL > newSL) { newSL = trailSL; modify = true; }
         }

         if(modify) OrderModify(OrderTicket(), openPrice, newSL, tp, 0, clrGreen);
      }

      if(OrderType() == OP_SELL)
      {
         double profitPoints = (openPrice - ask) / point;
         double newSL = sl;
         bool modify = false;

         if(InpUseSLPlus && profitPoints >= InpSLPlusTriggerPoints)
         {
            double slPlus = NormalizeDouble(openPrice - InpSLPlusLockPoints * point, digits);
            if(sl == 0.0 || slPlus < sl) { newSL = slPlus; modify = true; }
         }

         if(InpUseTrailingStop && profitPoints >= InpTrailStartPoints)
         {
            double trailSL = NormalizeDouble(ask + InpTrailStepPoints * point, digits);
            if(newSL == 0.0 || trailSL < newSL) { newSL = trailSL; modify = true; }
         }

         if(modify) OrderModify(OrderTicket(), openPrice, newSL, tp, 0, clrRed);
      }
   }
}

void NotifyClosedTrades()
{
   for(int i = OrdersHistoryTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_HISTORY)) continue;
      if(OrderSymbol() != g_symbol || OrderMagicNumber() != InpMagicNumber) continue;
      if((ulong)OrderTicket() == g_lastClosedTicket) return;

      g_lastClosedTicket = (ulong)OrderTicket();
      double pl = OrderProfit() + OrderSwap() + OrderCommission();
      SendTelegramMessage(StringFormat("%s\nBot: Reversal Limit TierReady MT4\nSymbol: %s\nTicket: %d\nP/L: %.2f",
                                       pl >= 0.0 ? "CLOSE PROFIT" : "CLOSE LOSS",
                                       g_symbol,
                                       OrderTicket(),
                                       pl));
      return;
   }
}

string TimeframeToText(int tf)
{
   if(tf == PERIOD_M1) return("M1");
   if(tf == PERIOD_M5) return("M5");
   if(tf == PERIOD_M15) return("M15");
   if(tf == PERIOD_M30) return("M30");
   if(tf == PERIOD_H1) return("H1");
   if(tf == PERIOD_H4) return("H4");
   if(tf == PERIOD_D1) return("D1");
   return("CURRENT");
}

bool SendTelegramMessage(string message)
{
   if(!InpUseTelegram) return(false);
   if(InpTelegramBotToken == "" || InpTelegramChatId == "") return(false);

   string url = "https://api.telegram.org/bot" + InpTelegramBotToken + "/sendMessage";
   string postData = "chat_id=" + InpTelegramChatId + "&text=" + UrlEncode(message);
   string headers = "Content-Type: application/x-www-form-urlencoded\r\n";

   char data[];
   char result[];
   string resultHeaders;
   StringToCharArray(postData, data, 0, WHOLE_ARRAY, CP_UTF8);

   int status = WebRequest("POST", url, headers, 5000, data, result, resultHeaders);
   if(status < 200 || status >= 300)
   {
      Print("Telegram send failed. HTTP: ", status, " Error: ", GetLastError());
      return(false);
   }
   return(true);
}

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
   return(encoded);
}
//+------------------------------------------------------------------+
