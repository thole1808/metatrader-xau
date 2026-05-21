//+------------------------------------------------------------------+
//|                                  XAUUSD_ProRisk_Scalper_MT5.mq5   |
//|  Risk-managed XAUUSD scalping EA for MetaTrader 5                 |
//|  No profit guarantee. Demo/backtest before live trading.          |
//+------------------------------------------------------------------+
#property strict
#property version   "1.00"
#property description "XAUUSD MT5 scalper with EMA trend, RSI/Stochastic pullback, ATR SL/TP, break-even, trailing, equity guard, Telegram."

#include <Trade/Trade.mqh>

input string          InpTradeSymbol             = "XAUUSDc";      // Broker symbol, e.g. XAUUSDc/XAUUSDm/GOLD
input ENUM_TIMEFRAMES InpSignalTimeframe         = PERIOD_M5;       // Scalping timeframe
input long            InpMagicNumber             = 24052026;
input bool            InpUseFixedLot             = true;            // Use fixed lot instead of risk-based sizing
input double          InpFixedLot                = 0.01;            // Fixed lot for small/cent account
input double          InpRiskPercent             = 0.35;            // Risk per trade, low for cent account
input double          InpMaxDailyLossPercent     = 3.00;            // Stop new trades after daily loss
input double          InpEquityStopPercent       = 6.00;            // Close EA trades if equity drops this much from day start
input int             InpMaxSpreadPoints         = 120;             // Max spread in points
input int             InpDeviationPoints         = 30;
input int             InpFastEma                 = 20;
input int             InpSlowEma                 = 100;
input int             InpRsiPeriod               = 14;
input int             InpStochK                  = 5;
input int             InpStochD                  = 3;
input int             InpStochSlowing            = 3;
input int             InpAtrPeriod               = 14;
input double          InpAtrStopMultiplier       = 1.60;            // Mandatory SL distance
input double          InpRewardRisk              = 1.25;            // Mandatory TP distance
input double          InpBreakEvenAtR            = 0.75;            // Move SL to profit after this R
input double          InpLockProfitR             = 0.10;            // Lock this R when BE triggers
input double          InpTrailAtrMultiplier      = 1.00;
input bool            InpUseTradingHours         = true;
input int             InpStartHour               = 7;               // Server time
input int             InpEndHour                 = 22;              // Server time
input bool            InpOnePositionAtATime      = true;
input bool            InpCloseOnOppositeSignal   = false;
input int             InpStatusEveryMinutes      = 60;              // Telegram heartbeat while EA is running
input bool            InpUseTelegram             = true;
input string InpTelegramBotToken     = "8957713577:AAFBYCap7FHYKFuZWTPsPs76NPHo1XZb-3M";        // Example: 123456:ABC-DEF...
input string InpTelegramChatId       = "764887377";   


CTrade trade;

string   g_symbol;
datetime g_lastBarTime = 0;
datetime g_dayStartTime = 0;
double   g_dayStartEquity = 0.0;
bool     g_dailyGuardNotified = false;
bool     g_equityStopNotified = false;
datetime g_lastStatusTime = 0;
datetime g_lastChartPanelTime = 0;
string   g_lastEaStatus = "Starting";
string   g_lastTelegramStatus = "Not tested yet";

int g_fastEmaHandle = INVALID_HANDLE;
int g_slowEmaHandle = INVALID_HANDLE;
int g_rsiHandle = INVALID_HANDLE;
int g_stochHandle = INVALID_HANDLE;
int g_atrHandle = INVALID_HANDLE;

int OnInit()
{
   g_symbol = InpTradeSymbol;
   if(g_symbol == "") g_symbol = _Symbol;

   if(!SymbolSelect(g_symbol, true))
   {
      Print("Cannot select input symbol: ", g_symbol, ". Fallback to chart symbol: ", _Symbol);
      g_symbol = _Symbol;
      if(!SymbolSelect(g_symbol, true))
      {
         Print("Cannot select chart symbol: ", g_symbol);
         return(INIT_FAILED);
      }
   }

   g_fastEmaHandle = iMA(g_symbol, InpSignalTimeframe, InpFastEma, 0, MODE_EMA, PRICE_CLOSE);
   g_slowEmaHandle = iMA(g_symbol, InpSignalTimeframe, InpSlowEma, 0, MODE_EMA, PRICE_CLOSE);
   g_rsiHandle = iRSI(g_symbol, InpSignalTimeframe, InpRsiPeriod, PRICE_CLOSE);
   g_stochHandle = iStochastic(g_symbol, InpSignalTimeframe, InpStochK, InpStochD, InpStochSlowing, MODE_SMA, STO_LOWHIGH);
   g_atrHandle = iATR(g_symbol, InpSignalTimeframe, InpAtrPeriod);

   if(g_fastEmaHandle == INVALID_HANDLE || g_slowEmaHandle == INVALID_HANDLE ||
      g_rsiHandle == INVALID_HANDLE || g_stochHandle == INVALID_HANDLE || g_atrHandle == INVALID_HANDLE)
   {
      Print("Indicator handle creation failed.");
      return(INIT_FAILED);
   }

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(g_symbol);

   ResetDailyGuard();
   LogStatus("EA initialized on " + g_symbol +
             " | Chart: " + _Symbol +
             " | FixedLot: " + DoubleToString(InpFixedLot, 2) +
             " | Telegram: " + (InpUseTelegram ? "ON" : "OFF") +
             " | Token: " + (InpTelegramBotToken == "" ? "EMPTY" : "FILLED") +
             " | ChatId: " + (InpTelegramChatId == "" ? "EMPTY" : "FILLED"));

   bool telegramOk = SendTelegramMessage("MT5 EA started on " + g_symbol +
                                         " | Balance: " + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2) +
                                         " | Equity: " + DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2));
   LogStatus("Telegram startup test: " + (telegramOk ? "OK" : "FAILED") + " | " + g_lastTelegramStatus);
   UpdateChartPanel();

   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   Comment("");
   if(g_fastEmaHandle != INVALID_HANDLE) IndicatorRelease(g_fastEmaHandle);
   if(g_slowEmaHandle != INVALID_HANDLE) IndicatorRelease(g_slowEmaHandle);
   if(g_rsiHandle != INVALID_HANDLE) IndicatorRelease(g_rsiHandle);
   if(g_stochHandle != INVALID_HANDLE) IndicatorRelease(g_stochHandle);
   if(g_atrHandle != INVALID_HANDLE) IndicatorRelease(g_atrHandle);
}

void OnTick()
{
   UpdateDailyGuard();
   MonitorPositionsHard();
   SendStatusHeartbeat();
   UpdateChartPanel();

   if(!IsNewBar()) return;
   if(!CanOpenNewTrade()) return;

   int signal = GetScalpingSignal();
   if(signal == ORDER_TYPE_BUY) OpenTrade(ORDER_TYPE_BUY);
   if(signal == ORDER_TYPE_SELL) OpenTrade(ORDER_TYPE_SELL);
}

bool IsNewBar()
{
   datetime times[];
   ArraySetAsSeries(times, true);
   if(CopyTime(g_symbol, InpSignalTimeframe, 0, 2, times) < 2) return(false);
   if(times[0] == g_lastBarTime) return(false);
   g_lastBarTime = times[0];
   return(true);
}

void ResetDailyGuard()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   dt.hour = 0;
   dt.min = 0;
   dt.sec = 0;
   g_dayStartTime = StructToTime(dt);
   g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   g_dailyGuardNotified = false;
   g_equityStopNotified = false;
}

void UpdateDailyGuard()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   dt.hour = 0;
   dt.min = 0;
   dt.sec = 0;
   datetime today = StructToTime(dt);
   if(today != g_dayStartTime) ResetDailyGuard();
}

bool CanOpenNewTrade()
{
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED))
   {
      g_lastEaStatus = "Trading not allowed. Check Algo Trading and EA permissions.";
      return(false);
   }
   if(InpUseTradingHours && !IsInsideTradingHours())
   {
      g_lastEaStatus = "Outside trading hours";
      return(false);
   }
   if(GetSpreadPoints() > InpMaxSpreadPoints)
   {
      g_lastEaStatus = "Spread too high: " + IntegerToString(GetSpreadPoints()) + " points";
      return(false);
   }
   if(IsDailyLossGuardActive())
   {
      g_lastEaStatus = "Daily loss guard active";
      return(false);
   }
   if(InpOnePositionAtATime && CountOpenPositions() > 0)
   {
      g_lastEaStatus = "Position already running";
      return(false);
   }
   g_lastEaStatus = "Ready, waiting for scalping signal";
   return(true);
}

bool IsInsideTradingHours()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(InpStartHour == InpEndHour) return(true);
   if(InpStartHour < InpEndHour) return(dt.hour >= InpStartHour && dt.hour < InpEndHour);
   return(dt.hour >= InpStartHour || dt.hour < InpEndHour);
}

bool IsDailyLossGuardActive()
{
   if(g_dayStartEquity <= 0.0) return(false);

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double dailyLossPct = 100.0 * (g_dayStartEquity - equity) / g_dayStartEquity;
   if(dailyLossPct < InpMaxDailyLossPercent) return(false);

   if(!g_dailyGuardNotified)
   {
      string msg = "Daily loss guard active on " + g_symbol +
                   " | Loss: " + DoubleToString(dailyLossPct, 2) + "%" +
                   " | Equity: " + DoubleToString(equity, 2);
      Print(msg);
      SendTelegramMessage(msg);
      g_dailyGuardNotified = true;
   }

   return(true);
}

int GetSpreadPoints()
{
   long spread = 0;
   SymbolInfoInteger(g_symbol, SYMBOL_SPREAD, spread);
   return((int)spread);
}

int CountOpenPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) == g_symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber) count++;
   }
   return(count);
}

bool GetBufferValue(const int handle, const int buffer, const int shift, double &value)
{
   double data[];
   ArraySetAsSeries(data, true);
   if(CopyBuffer(handle, buffer, shift, 1, data) != 1) return(false);
   value = data[0];
   return(true);
}

int GetScalpingSignal()
{
   double fast1, fast2, slow1, rsi1, rsi2, stochK1, stochK2, stochD1, stochD2;
   if(!GetBufferValue(g_fastEmaHandle, 0, 1, fast1)) return(-1);
   if(!GetBufferValue(g_fastEmaHandle, 0, 2, fast2)) return(-1);
   if(!GetBufferValue(g_slowEmaHandle, 0, 1, slow1)) return(-1);
   if(!GetBufferValue(g_rsiHandle, 0, 1, rsi1)) return(-1);
   if(!GetBufferValue(g_rsiHandle, 0, 2, rsi2)) return(-1);
   if(!GetBufferValue(g_stochHandle, 0, 1, stochK1)) return(-1);
   if(!GetBufferValue(g_stochHandle, 0, 2, stochK2)) return(-1);
   if(!GetBufferValue(g_stochHandle, 1, 1, stochD1)) return(-1);
   if(!GetBufferValue(g_stochHandle, 1, 2, stochD2)) return(-1);

   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(g_symbol, InpSignalTimeframe, 0, 3, rates) < 3) return(-1);

   bool upTrend = fast1 > slow1 && fast1 >= fast2 && rates[1].close > slow1;
   bool downTrend = fast1 < slow1 && fast1 <= fast2 && rates[1].close < slow1;
   bool bullishCandle = rates[1].close > rates[1].open;
   bool bearishCandle = rates[1].close < rates[1].open;

   bool stochBuyCross = stochK2 <= stochD2 && stochK1 > stochD1 && stochK1 < 55.0;
   bool stochSellCross = stochK2 >= stochD2 && stochK1 < stochD1 && stochK1 > 45.0;

   if(upTrend && bullishCandle && rsi2 < 48.0 && rsi1 > 50.0 && stochBuyCross) return(ORDER_TYPE_BUY);
   if(downTrend && bearishCandle && rsi2 > 52.0 && rsi1 < 50.0 && stochSellCross) return(ORDER_TYPE_SELL);

   return(-1);
}

void OpenTrade(const int type)
{
   double atr;
   if(!GetBufferValue(g_atrHandle, 0, 1, atr) || atr <= 0.0) return;

   double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   double point = SymbolInfoDouble(g_symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(g_symbol, SYMBOL_DIGITS);
   int stopsLevel = (int)SymbolInfoInteger(g_symbol, SYMBOL_TRADE_STOPS_LEVEL);

   double entry = (type == ORDER_TYPE_BUY) ? ask : bid;
   double minStopDistance = (stopsLevel + 5) * point;
   double stopDistance = MathMax(atr * InpAtrStopMultiplier, minStopDistance);
   double takeDistance = stopDistance * InpRewardRisk;

   double sl = (type == ORDER_TYPE_BUY) ? entry - stopDistance : entry + stopDistance;
   double tp = (type == ORDER_TYPE_BUY) ? entry + takeDistance : entry - takeDistance;
   double lots = CalculateLots(stopDistance);
   if(lots <= 0.0) return;

   sl = NormalizeDouble(sl, digits);
   tp = NormalizeDouble(tp, digits);

   bool ok = false;
   if(type == ORDER_TYPE_BUY) ok = trade.Buy(lots, g_symbol, 0.0, sl, tp, "XAUUSD MT5 ProRisk Scalper");
   if(type == ORDER_TYPE_SELL) ok = trade.Sell(lots, g_symbol, 0.0, sl, tp, "XAUUSD MT5 ProRisk Scalper");

   if(!ok)
   {
      string failMsg = "Order failed on " + g_symbol + " | Retcode: " + IntegerToString((int)trade.ResultRetcode()) +
                       " | " + trade.ResultRetcodeDescription();
      LogStatus(failMsg);
      SendTelegramMessage(failMsg);
      return;
   }

   ulong deal = trade.ResultDeal();
   string msg = "Opened " + (type == ORDER_TYPE_BUY ? "BUY" : "SELL") + " " + g_symbol +
                " | Deal: " + IntegerToString((int)deal) +
                " | Lots: " + DoubleToString(lots, 2) +
                " | SL: " + DoubleToString(sl, digits) +
                " | TP: " + DoubleToString(tp, digits);
   LogStatus(msg);
   SendTelegramMessage(msg);
}

double CalculateLots(const double stopDistancePrice)
{
   double minLot = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_STEP);
   int volumeDigits = GetVolumeDigits(lotStep);

   if(minLot <= 0.0 || maxLot <= 0.0 || lotStep <= 0.0) return(0.0);

   if(InpUseFixedLot)
   {
      double fixedLots = MathFloor(InpFixedLot / lotStep) * lotStep;
      fixedLots = MathMax(minLot, MathMin(maxLot, fixedLots));
      return(NormalizeDouble(fixedLots, volumeDigits));
   }

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskMoney = balance * InpRiskPercent / 100.0;
   double tickValue = SymbolInfoDouble(g_symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(g_symbol, SYMBOL_TRADE_TICK_SIZE);

   if(tickValue <= 0.0 || tickSize <= 0.0) return(0.0);

   double valuePerLot = (stopDistancePrice / tickSize) * tickValue;
   if(valuePerLot <= 0.0) return(0.0);

   double lots = riskMoney / valuePerLot;
   lots = MathFloor(lots / lotStep) * lotStep;
   lots = MathMax(minLot, MathMin(maxLot, lots));

   return(NormalizeDouble(lots, volumeDigits));
}

int GetVolumeDigits(const double lotStep)
{
   int volumeDigits = 2;
   if(lotStep < 0.01) volumeDigits = 3;
   if(lotStep < 0.001) volumeDigits = 4;
   return(volumeDigits);
}

void MonitorPositionsHard()
{
   if(g_dayStartEquity > 0.0)
   {
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      double equityLossPct = 100.0 * (g_dayStartEquity - equity) / g_dayStartEquity;
      if(equityLossPct >= InpEquityStopPercent)
      {
         CloseAllEaPositions("Equity stop active | Loss: " + DoubleToString(equityLossPct, 2) + "%");
         return;
      }
   }

   double atr;
   if(!GetBufferValue(g_atrHandle, 0, 1, atr) || atr <= 0.0) return;

   double point = SymbolInfoDouble(g_symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(g_symbol, SYMBOL_DIGITS);
   int stopsLevel = (int)SymbolInfoInteger(g_symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minStopDistance = (stopsLevel + 5) * point;
   double trailDistance = MathMax(atr * InpTrailAtrMultiplier, minStopDistance);
   double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol || PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;

      ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl = PositionGetDouble(POSITION_SL);
      double tp = PositionGetDouble(POSITION_TP);
      double current = (posType == POSITION_TYPE_BUY) ? bid : ask;
      double initialRisk = EstimateInitialRisk(openPrice, sl, tp, posType);
      if(initialRisk <= 0.0) continue;

      double profitDistance = (posType == POSITION_TYPE_BUY) ? current - openPrice : openPrice - current;
      double newSl = sl;
      bool shouldModify = false;

      if(profitDistance >= initialRisk * InpBreakEvenAtR)
      {
         double lockDistance = initialRisk * InpLockProfitR;
         double beSl = (posType == POSITION_TYPE_BUY) ? openPrice + lockDistance : openPrice - lockDistance;
         if(IsBetterStop(posType, beSl, newSl))
         {
            newSl = beSl;
            shouldModify = true;
         }
      }

      if(profitDistance > trailDistance)
      {
         double trailSl = (posType == POSITION_TYPE_BUY) ? current - trailDistance : current + trailDistance;
         if(IsBetterStop(posType, trailSl, newSl))
         {
            newSl = trailSl;
            shouldModify = true;
         }
      }

      if(InpCloseOnOppositeSignal)
      {
         int signal = GetScalpingSignal();
         if((posType == POSITION_TYPE_BUY && signal == ORDER_TYPE_SELL) ||
            (posType == POSITION_TYPE_SELL && signal == ORDER_TYPE_BUY))
         {
            ClosePositionByTicket(ticket, "Opposite scalping signal");
            continue;
         }
      }

      if(shouldModify)
      {
         newSl = NormalizeDouble(newSl, digits);
         if(ModifyPositionStops(ticket, newSl, tp))
            SendTelegramMessage("SL profit/trailing updated on " + g_symbol + " | Ticket: " + IntegerToString((int)ticket) +
                                " | New SL: " + DoubleToString(newSl, digits));
         else
            Print("PositionModify failed: ", trade.ResultRetcodeDescription());
      }
   }
}

bool ModifyPositionStops(const ulong ticket, const double sl, const double tp)
{
   MqlTradeRequest request;
   MqlTradeResult result;
   ZeroMemory(request);
   ZeroMemory(result);

   request.action = TRADE_ACTION_SLTP;
   request.position = ticket;
   request.symbol = g_symbol;
   request.sl = sl;
   request.tp = tp;
   request.magic = InpMagicNumber;

   bool ok = OrderSend(request, result);
   if(!ok)
   {
      Print("OrderSend SLTP failed. Error: ", GetLastError());
      return(false);
   }

   if(result.retcode != TRADE_RETCODE_DONE && result.retcode != TRADE_RETCODE_DONE_PARTIAL)
   {
      Print("SLTP modify retcode: ", result.retcode, " | ", result.comment);
      return(false);
   }

   return(true);
}

double EstimateInitialRisk(const double openPrice, const double sl, const double tp, const ENUM_POSITION_TYPE posType)
{
   if(sl > 0.0) return(MathAbs(openPrice - sl));
   if(tp > 0.0 && InpRewardRisk > 0.0) return(MathAbs(tp - openPrice) / InpRewardRisk);
   return(0.0);
}

bool IsBetterStop(const ENUM_POSITION_TYPE posType, const double candidate, const double currentSl)
{
   if(posType == POSITION_TYPE_BUY) return(currentSl == 0.0 || candidate > currentSl);
   return(currentSl == 0.0 || candidate < currentSl);
}

void CloseAllEaPositions(const string reason)
{
   if(!g_equityStopNotified)
   {
      LogStatus(reason);
      SendTelegramMessage(reason + " | Closing EA positions on " + g_symbol);
      g_equityStopNotified = true;
   }

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol || PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      ClosePositionByTicket(ticket, reason);
   }
}

void ClosePositionByTicket(const ulong ticket, const string reason)
{
   if(!PositionSelectByTicket(ticket)) return;
   if(trade.PositionClose(ticket))
   {
      LogStatus("Closed position on " + g_symbol + " | Ticket: " + IntegerToString((int)ticket) + " | Reason: " + reason);
      SendTelegramMessage("Closed position on " + g_symbol + " | Ticket: " + IntegerToString((int)ticket) + " | Reason: " + reason);
   }
   else
      Print("PositionClose failed: ", trade.ResultRetcodeDescription());
}

void SendStatusHeartbeat()
{
   if(!InpUseTelegram || InpStatusEveryMinutes <= 0) return;
   datetime now = TimeCurrent();
   if(g_lastStatusTime != 0 && now - g_lastStatusTime < InpStatusEveryMinutes * 60) return;

   g_lastStatusTime = now;
   string msg = "EA monitor " + g_symbol +
                " | Equity: " + DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2) +
                " | Positions: " + IntegerToString(CountOpenPositions()) +
                " | Spread: " + IntegerToString(GetSpreadPoints()) + " points" +
                " | Status: " + g_lastEaStatus;
   LogStatus(msg);
   SendTelegramMessage(msg);
}

void LogStatus(const string message)
{
   g_lastEaStatus = message;
   Print("[XAUUSDc Scalper] ", message);
}

void UpdateChartPanel()
{
   datetime now = TimeCurrent();
   if(g_lastChartPanelTime != 0 && now - g_lastChartPanelTime < 2) return;
   g_lastChartPanelTime = now;

   Comment("XAUUSDc ProRisk Scalper MT5\n",
           "Symbol: ", g_symbol, " | TF: ", EnumToString(InpSignalTimeframe), "\n",
           "Lot: ", DoubleToString(InpFixedLot, 2), " | Positions: ", IntegerToString(CountOpenPositions()), "\n",
           "Spread: ", IntegerToString(GetSpreadPoints()), "/", IntegerToString(InpMaxSpreadPoints), " points\n",
           "Equity: ", DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2),
           " | Balance: ", DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2), "\n",
           "EA Status: ", g_lastEaStatus, "\n",
           "Telegram: ", g_lastTelegramStatus, "\n",
           "Server Time: ", TimeToString(now, TIME_DATE | TIME_SECONDS));
}

string UrlEncode(string value)
{
   string encoded = "";
   int length = StringLen(value);

   for(int i = 0; i < length; i++)
   {
      ushort ch = StringGetCharacter(value, i);
      if((ch >= '0' && ch <= '9') || (ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z') ||
         ch == '-' || ch == '_' || ch == '.' || ch == '~')
         encoded += ShortToString(ch);
      else if(ch == ' ')
         encoded += "%20";
      else if(ch == '\n')
         encoded += "%0A";
      else
         encoded += "%" + StringFormat("%02X", ch);
   }

   return(encoded);
}

bool SendTelegramMessage(string message)
{
   if(!InpUseTelegram)
   {
      g_lastTelegramStatus = "OFF";
      return(false);
   }
   if(InpTelegramBotToken == "" || InpTelegramChatId == "")
   {
      g_lastTelegramStatus = "FAILED: token/chat_id empty";
      Print("[Telegram] Telegram is enabled, but token/chat_id is empty.");
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
      int err = GetLastError();
      g_lastTelegramStatus = "FAILED WebRequest error " + IntegerToString(err);
      Print("[Telegram] WebRequest failed. Error: ", err,
            ". In MT5 open Tools > Options > Expert Advisors, enable WebRequest and add https://api.telegram.org");
      return(false);
   }

   if(status < 200 || status >= 300)
   {
      string response = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);
      g_lastTelegramStatus = "FAILED HTTP " + IntegerToString(status);
      Print("[Telegram] HTTP status: ", status, " | Response: ", response);
      return(false);
   }

   g_lastTelegramStatus = "OK HTTP " + IntegerToString(status);
   Print("[Telegram] Sent OK. HTTP status: ", status);
   return(true);
}
//+------------------------------------------------------------------+
