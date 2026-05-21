//+------------------------------------------------------------------+
//|                                               XAUUSD_ProRisk_EA.mq4|
//|  Conservative XAUUSD trend-pullback Expert Advisor for MetaTrader 4|
//|  Risk-managed template: no profit guarantee. Backtest before live. |
//+------------------------------------------------------------------+
#property strict
#property version   "1.00"
#property description "XAUUSD EA with EMA trend filter, RSI pullback, ATR SL/TP, trailing stop, and daily loss guard."

input string InpTradeSymbol          = "XAUUSD";  // Symbol to trade; leave XAUUSD or broker suffix like XAUUSDm
input int    InpMagicNumber          = 24052026;
input double InpRiskPercent          = 0.50;      // Risk per trade in percent of balance
input double InpMaxDailyLossPercent  = 3.00;      // Stop new trades after daily loss percent
input double InpMaxSpreadPoints      = 80;        // Max spread in points. Adjust for your broker
input int    InpSlippagePoints       = 30;
input int    InpFastEma              = 50;
input int    InpSlowEma              = 200;
input int    InpRsiPeriod            = 14;
input int    InpAtrPeriod            = 14;
input double InpAtrStopMultiplier    = 2.0;
input double InpRewardRisk           = 1.6;
input double InpTrailAtrMultiplier   = 1.2;
input bool   InpUseTradingHours      = true;
input int    InpStartHour            = 7;         // Broker/server time
input int    InpEndHour              = 22;        // Broker/server time
input bool   InpOneTradeAtATime      = true;
input bool   InpUseTelegram          = false;     // Enable Telegram notifications
input string InpTelegramBotToken     = "8957713577:AAFBYCap7FHYKFuZWTPsPs76NPHo1XZb-3M";        // Example: 123456:ABC-DEF...
input string InpTelegramChatId       = "764887377";        // Your personal/group/channel chat_id

string   g_symbol;
datetime g_lastBarTime = 0;
datetime g_dayStartTime = 0;
double   g_dayStartEquity = 0.0;
bool     g_dailyGuardNotified = false;

int OnInit()
{
   g_symbol = InpTradeSymbol;
   if(g_symbol == "") g_symbol = Symbol();

   if(!SymbolSelect(g_symbol, true))
   {
      Print("Cannot select symbol: ", g_symbol);
      return(INIT_FAILED);
   }

   ResetDailyGuard();
   Print("XAUUSD_ProRisk_EA initialized on ", g_symbol, ". Backtest on demo before live.");
   SendTelegramMessage("EA started on " + g_symbol + " | Balance: " + DoubleToString(AccountBalance(), 2) +
                       " | Equity: " + DoubleToString(AccountEquity(), 2));
   return(INIT_SUCCEEDED);
}

void OnTick()
{
   if(Symbol() != g_symbol && !IsTesting()) return;

   RefreshRates();
   UpdateDailyGuard();
   ManageOpenTrades();

   if(!IsNewBar()) return;
   if(!CanOpenNewTrade()) return;

   int signal = GetSignal();
   if(signal == OP_BUY)  OpenTrade(OP_BUY);
   if(signal == OP_SELL) OpenTrade(OP_SELL);
}

bool IsNewBar()
{
   datetime barTime = iTime(g_symbol, PERIOD_CURRENT, 0);
   if(barTime == 0 || barTime == g_lastBarTime) return(false);
   g_lastBarTime = barTime;
   return(true);
}

void ResetDailyGuard()
{
   g_dayStartTime = iTime(g_symbol, PERIOD_D1, 0);
   g_dayStartEquity = AccountEquity();
   g_dailyGuardNotified = false;
}

void UpdateDailyGuard()
{
   datetime currentDay = iTime(g_symbol, PERIOD_D1, 0);
   if(currentDay != 0 && currentDay != g_dayStartTime)
      ResetDailyGuard();
}

bool CanOpenNewTrade()
{
   if(!IsTradeAllowed()) return(false);
   if(InpUseTradingHours && !IsInsideTradingHours()) return(false);
   if(GetSpreadPoints() > InpMaxSpreadPoints) return(false);

   if(g_dayStartEquity > 0.0)
   {
      double dailyLossPct = 100.0 * (g_dayStartEquity - AccountEquity()) / g_dayStartEquity;
      if(dailyLossPct >= InpMaxDailyLossPercent)
      {
         Print("Daily loss guard active: ", DoubleToString(dailyLossPct, 2), "%");
         if(!g_dailyGuardNotified)
         {
            SendTelegramMessage("Daily loss guard active on " + g_symbol +
                                " | Loss: " + DoubleToString(dailyLossPct, 2) + "%" +
                                " | Equity: " + DoubleToString(AccountEquity(), 2));
            g_dailyGuardNotified = true;
         }
         return(false);
      }
   }

   if(InpOneTradeAtATime && CountOpenTrades() > 0) return(false);
   return(true);
}

bool IsInsideTradingHours()
{
   int hour = TimeHour(TimeCurrent());
   if(InpStartHour == InpEndHour) return(true);
   if(InpStartHour < InpEndHour)
      return(hour >= InpStartHour && hour < InpEndHour);
   return(hour >= InpStartHour || hour < InpEndHour);
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
   double fast1 = iMA(g_symbol, PERIOD_CURRENT, InpFastEma, 0, MODE_EMA, PRICE_CLOSE, 1);
   double slow1 = iMA(g_symbol, PERIOD_CURRENT, InpSlowEma, 0, MODE_EMA, PRICE_CLOSE, 1);
   double fast2 = iMA(g_symbol, PERIOD_CURRENT, InpFastEma, 0, MODE_EMA, PRICE_CLOSE, 2);
   double rsi1  = iRSI(g_symbol, PERIOD_CURRENT, InpRsiPeriod, PRICE_CLOSE, 1);
   double rsi2  = iRSI(g_symbol, PERIOD_CURRENT, InpRsiPeriod, PRICE_CLOSE, 2);
   double close1 = iClose(g_symbol, PERIOD_CURRENT, 1);

   bool upTrend = fast1 > slow1 && fast1 >= fast2 && close1 > slow1;
   bool downTrend = fast1 < slow1 && fast1 <= fast2 && close1 < slow1;

   // Pullback entry: join trend after RSI recovers from exhaustion zone.
   if(upTrend && rsi2 < 45.0 && rsi1 > 50.0) return(OP_BUY);
   if(downTrend && rsi2 > 55.0 && rsi1 < 50.0) return(OP_SELL);

   return(-1);
}

void OpenTrade(int type)
{
   double atr = iATR(g_symbol, PERIOD_CURRENT, InpAtrPeriod, 1);
   if(atr <= 0.0) return;

   double point = MarketInfo(g_symbol, MODE_POINT);
   double ask = MarketInfo(g_symbol, MODE_ASK);
   double bid = MarketInfo(g_symbol, MODE_BID);
   int digits = (int)MarketInfo(g_symbol, MODE_DIGITS);

   double entry = (type == OP_BUY) ? ask : bid;
   double stopDistance = MathMax(atr * InpAtrStopMultiplier, MarketInfo(g_symbol, MODE_STOPLEVEL) * point);
   double takeDistance = stopDistance * InpRewardRisk;

   double sl = (type == OP_BUY) ? entry - stopDistance : entry + stopDistance;
   double tp = (type == OP_BUY) ? entry + takeDistance : entry - takeDistance;
   double lots = CalculateLots(stopDistance);
   if(lots <= 0.0) return;

   int ticket = OrderSend(g_symbol, type, lots, NormalizeDouble(entry, digits), InpSlippagePoints,
                          NormalizeDouble(sl, digits), NormalizeDouble(tp, digits),
                          "XAUUSD ProRisk", InpMagicNumber, 0, clrGold);

   if(ticket < 0)
   {
      int err = GetLastError();
      Print("OrderSend failed. Error: ", err);
      SendTelegramMessage("OrderSend failed on " + g_symbol + " | Error: " + IntegerToString(err));
   }
   else
   {
      Print("Opened ", type == OP_BUY ? "BUY" : "SELL", " ticket ", ticket, " lots ", DoubleToString(lots, 2));
      SendTelegramMessage("Opened " + (type == OP_BUY ? "BUY" : "SELL") + " " + g_symbol +
                          " | Ticket: " + IntegerToString(ticket) +
                          " | Lots: " + DoubleToString(lots, 2) +
                          " | Entry: " + DoubleToString(entry, digits) +
                          " | SL: " + DoubleToString(sl, digits) +
                          " | TP: " + DoubleToString(tp, digits));
   }
}

double CalculateLots(double stopDistancePrice)
{
   double riskMoney = AccountBalance() * InpRiskPercent / 100.0;
   double tickValue = MarketInfo(g_symbol, MODE_TICKVALUE);
   double tickSize = MarketInfo(g_symbol, MODE_TICKSIZE);
   double minLot = MarketInfo(g_symbol, MODE_MINLOT);
   double maxLot = MarketInfo(g_symbol, MODE_MAXLOT);
   double lotStep = MarketInfo(g_symbol, MODE_LOTSTEP);

   if(tickValue <= 0.0 || tickSize <= 0.0 || lotStep <= 0.0) return(0.0);

   double valuePerLot = (stopDistancePrice / tickSize) * tickValue;
   if(valuePerLot <= 0.0) return(0.0);

   double lots = riskMoney / valuePerLot;
   lots = MathFloor(lots / lotStep) * lotStep;
   lots = MathMax(minLot, MathMin(maxLot, lots));

   return(NormalizeDouble(lots, 2));
}

void ManageOpenTrades()
{
   double atr = iATR(g_symbol, PERIOD_CURRENT, InpAtrPeriod, 1);
   if(atr <= 0.0) return;

   double point = MarketInfo(g_symbol, MODE_POINT);
   double stopLevel = MarketInfo(g_symbol, MODE_STOPLEVEL) * point;
   double trailDistance = MathMax(atr * InpTrailAtrMultiplier, stopLevel);
   int digits = (int)MarketInfo(g_symbol, MODE_DIGITS);
   double bid = MarketInfo(g_symbol, MODE_BID);
   double ask = MarketInfo(g_symbol, MODE_ASK);

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol() != g_symbol || OrderMagicNumber() != InpMagicNumber) continue;

      bool modified = false;
      double newSl = OrderStopLoss();

      if(OrderType() == OP_BUY)
      {
         double candidate = NormalizeDouble(bid - trailDistance, digits);
         if(candidate > OrderOpenPrice() && (OrderStopLoss() == 0.0 || candidate > OrderStopLoss() + point))
         {
            newSl = candidate;
            modified = true;
         }
      }
      else if(OrderType() == OP_SELL)
      {
         double candidate = NormalizeDouble(ask + trailDistance, digits);
         if(candidate < OrderOpenPrice() && (OrderStopLoss() == 0.0 || candidate < OrderStopLoss() - point))
         {
            newSl = candidate;
            modified = true;
         }
      }

      if(modified)
      {
         bool ok = OrderModify(OrderTicket(), OrderOpenPrice(), newSl, OrderTakeProfit(), 0, clrGold);
         if(!ok)
            Print("OrderModify failed. Error: ", GetLastError());
         else
            SendTelegramMessage("Trailing stop updated on " + g_symbol +
                                " | Ticket: " + IntegerToString(OrderTicket()) +
                                " | New SL: " + DoubleToString(newSl, digits));
      }
   }
}

string UrlEncode(string value)
{
   string encoded = "";
   int length = StringLen(value);

   for(int i = 0; i < length; i++)
   {
      ushort ch = StringGetCharacter(value, i);

      if((ch >= '0' && ch <= '9') ||
         (ch >= 'A' && ch <= 'Z') ||
         (ch >= 'a' && ch <= 'z') ||
         ch == '-' || ch == '_' || ch == '.' || ch == '~')
      {
         encoded += ShortToString(ch);
      }
      else if(ch == ' ')
      {
         encoded += "%20";
      }
      else if(ch == '\n')
      {
         encoded += "%0A";
      }
      else
      {
         encoded += "%" + StringFormat("%02X", ch);
      }
   }

   return(encoded);
}

bool SendTelegramMessage(string message)
{
   if(!InpUseTelegram) return(false);
   if(InpTelegramBotToken == "" || InpTelegramChatId == "")
   {
      Print("Telegram is enabled, but bot token or chat_id is empty.");
      return(false);
   }

   string url = "https://api.telegram.org/bot" + InpTelegramBotToken + "/sendMessage";
   string postData = "chat_id=" + UrlEncode(InpTelegramChatId) +
                     "&text=" + UrlEncode(message) +
                     "&disable_web_page_preview=true";

   char data[];
   char result[];
   string responseHeaders;
   string headers = "Content-Type: application/x-www-form-urlencoded\r\n";

   int dataSize = StringToCharArray(postData, data, 0, WHOLE_ARRAY, CP_UTF8) - 1;
   if(dataSize > 0) ArrayResize(data, dataSize);
   ResetLastError();

   int status = WebRequest("POST", url, headers, 5000, data, result, responseHeaders);
   if(status == -1)
   {
      Print("Telegram WebRequest failed. Error: ", GetLastError(),
            ". Add https://api.telegram.org to MT4 allowed WebRequest URLs.");
      return(false);
   }

   if(status < 200 || status >= 300)
   {
      Print("Telegram returned HTTP status: ", status);
      return(false);
   }

   return(true);
}
//+------------------------------------------------------------------+
