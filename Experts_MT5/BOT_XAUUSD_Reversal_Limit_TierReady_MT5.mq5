//+------------------------------------------------------------------+
//|               BOT_XAUUSD_Reversal_Limit_TierReady_MT5.mq5|
//| XAUUSD Standard Account - Reversal EA + Pending Limit + Telegram     |
//| Mode: NO GRID / NO MARTINGALE / NO AVERAGING                     |
//+------------------------------------------------------------------+
#property strict
#property version "1.00"

#include <Trade/Trade.mqh>
CTrade trade;

// ================= INPUT TRADING =================
input string TradeSymbol              = "XAUUSD";
input double LotSize                  = 0.01;
input int    MagicNumber              = 2026051912;
input int    MaxSpreadPoints          = 600;
input int    SlippagePoints           = 50;

input ENUM_TIMEFRAMES TrendTF         = PERIOD_M15;
input ENUM_TIMEFRAMES SignalTF        = PERIOD_M15;
input int    TrendEMA                 = 34;

input int    EntryEMA                 = 12;
input int    RSI_Period               = 14;
input double BuyRSILevel              = 48.0;
input double SellRSILevel             = 52.0;
input bool   UseFastEntryMode         = true;
input int    SignalLookbackBars       = 2;
input bool   EnableTrendFallback      = true;
input bool   UseMarketForTrendFallback = true;           // Keep trend-follow entries immediate; limit is for reversal mode
input bool   RequireCandleConfirmation = true;
input int    MinSignalBodyPoints      = 35;
input double MaxOppositeWickRatio     = 1.80;

input int    StopLossPoints           = 1000;
input int    TakeProfitPoints         = 500;             // About 50 pips target per run

input bool   UseLimitOrders           = true;
input int    LimitOffsetPoints        = 40;
input int    SplitLimitEntryStepPoints = 60;
input int    PendingExpiryMinutes     = 2;
input bool   FallbackMarketIfRejected = true;
input bool   DeleteOppositePending    = true;
input bool   RefreshStalePending      = true;
input bool   UseThreeOrderSplit       = false;
input double TP2Multiplier            = 1.50;
input double TP3Multiplier            = 2.00;
input bool   UsePartialTakeProfit     = true;
input int    PartialTP1Points         = 200;
input double PartialTP1ClosePercent   = 50.0;
input int    PartialTP2Points         = 350;
input double PartialTP2ClosePercent   = 50.0;

input bool   UseTrailingStop          = true;
input bool   UseAutoSLPlus            = true;
input int    SLPlusTriggerPoints      = 60;
input int    SLPlusLockPoints         = 30;
input int    TrailStartPoints         = 90;
input int    TrailStepPoints          = 40;

input double DailyMaxLossMoney        = 150.0;
input double DailyTargetMoney         = 1000.0;
input int    MaxDailyLosingDeals      = 0;

input bool   OneTradePerCandle        = false;
input int    ReentryCooldownBars      = 1;
input int    MinMinutesBetweenEntries = 5;

// ================= REVERSAL MODE =================
input bool   EnableReversalMode       = true;
input int    ReversalDelaySeconds     = 1;

// ================= TELEGRAM =================
input bool   EnableTelegram           = true;
input string TelegramBotToken         = "8957713577:AAFBYCap7FHYKFuZWTPsPs76NPHo1XZb-3M";
input string TelegramChatID           = "764887377";
input bool   SendAccountTotalSummary  = true;

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
datetime lastEntryOpenTime = 0;
int lastKnownPositionCount = 0;
datetime lastReentryLogTime = 0;
datetime lastIndicatorLogBarTime = 0;
datetime lastPositionExitTime = 0;

double lastTrendClose = 0.0;
double lastTrendEMA = 0.0;
double lastEntryEMA = 0.0;
double lastRSI = 0.0;
double lastOpen1 = 0.0;
double lastClose1 = 0.0;
double lastHigh1 = 0.0;
double lastLow1 = 0.0;
bool lastBuySignal = false;
bool lastSellSignal = false;
bool lastFallbackBuySignal = false;
bool lastFallbackSellSignal = false;
ulong lastNotifiedDealTicket = 0;
string lastSignalDecisionLog = "";
ulong trackedPartialPositionTicket = 0;
bool partialTP1Done = false;
bool partialTP2Done = false;

void ResetPartialTPState()
{
   trackedPartialPositionTicket = 0;
   partialTP1Done = false;
   partialTP2Done = false;
}

bool ClosePartialVolume(const ulong ticket, const double positionVolume, const double percentToClose)
{
   double minLot = SymbolInfoDouble(symbolName, SYMBOL_VOLUME_MIN);
   double closeVolume = NormalizeLots(positionVolume * percentToClose / 100.0);
   double remainingVolume = NormalizeLots(positionVolume - closeVolume);

   if(closeVolume < minLot) return false;
   if(remainingVolume < minLot) return false;

   return trade.PositionClosePartial(ticket, closeVolume);
}

double NormalizeLots(const double lots)
{
   double minLot = SymbolInfoDouble(symbolName, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(symbolName, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(symbolName, SYMBOL_VOLUME_STEP);

   if(stepLot <= 0.0) stepLot = 0.01;
   double normalized = MathFloor(lots / stepLot) * stepLot;
   if(normalized < minLot) normalized = minLot;
   if(normalized > maxLot) normalized = maxLot;

   int lotDigits = 2;
   if(stepLot < 0.01) lotDigits = 3;
   if(stepLot < 0.001) lotDigits = 4;
   return(NormalizeDouble(normalized, lotDigits));
}

void LogIndicatorSnapshot(const datetime candleTime)
{
   if(candleTime == lastIndicatorLogBarTime) return;
   lastIndicatorLogBarTime = candleTime;

   int spread = (int)SymbolInfoInteger(symbolName, SYMBOL_SPREAD);
   string tfLabel = EnumToString((ENUM_TIMEFRAMES)SignalTF);
   string signalLabel = "NONE";

   if(lastBuySignal) signalLabel = "BUY_REV";
   else if(lastSellSignal) signalLabel = "SELL_REV";
   else if(lastFallbackBuySignal) signalLabel = "BUY_FALLBACK";
   else if(lastFallbackSellSignal) signalLabel = "SELL_FALLBACK";

   Print("[SignalLog] TF=", tfLabel,
         " | Spread=", spread,
         " | TrendClose=", DoubleToString(lastTrendClose, 2),
         " | TrendEMA=", DoubleToString(lastTrendEMA, 2),
         " | EntryEMA=", DoubleToString(lastEntryEMA, 2),
         " | RSI=", DoubleToString(lastRSI, 2),
         " | O=", DoubleToString(lastOpen1, 2),
         " | H=", DoubleToString(lastHigh1, 2),
         " | L=", DoubleToString(lastLow1, 2),
         " | C=", DoubleToString(lastClose1, 2),
         " | Signal=", signalLabel);

   if(lastSignalDecisionLog != "")
      Print("[SignalCheck] ", lastSignalDecisionLog);
}

void GetAccountHistoryTotals(double &grossWin, double &grossLoss, double &netProfit, int &closedDeals)
{
   grossWin = 0.0;
   grossLoss = 0.0;
   netProfit = 0.0;
   closedDeals = 0;

   if(!HistorySelect(0, TimeCurrent())) return;

   int totalDeals = HistoryDealsTotal();
   for(int i = 0; i < totalDeals; i++)
   {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket == 0) continue;

      long dealEntry = HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
      if(dealEntry != DEAL_ENTRY_OUT && dealEntry != DEAL_ENTRY_INOUT && dealEntry != DEAL_ENTRY_OUT_BY) continue;

      double dealProfit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT) +
                          HistoryDealGetDouble(dealTicket, DEAL_SWAP) +
                          HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);

      if(dealProfit > 0.0) grossWin += dealProfit;
      if(dealProfit < 0.0) grossLoss += MathAbs(dealProfit);

      netProfit += dealProfit;
      closedDeals++;
   }
}

void GetTodayHistoryTotals(double &grossWinToday, double &grossLossToday, double &netProfitToday, int &closedDealsToday, int &losingDealsToday)
{
   grossWinToday = 0.0;
   grossLossToday = 0.0;
   netProfitToday = 0.0;
   closedDealsToday = 0;
   losingDealsToday = 0;

   MqlDateTime nowStruct;
   TimeToStruct(TimeCurrent(), nowStruct);
   nowStruct.hour = 0;
   nowStruct.min = 0;
   nowStruct.sec = 0;
   datetime dayStart = StructToTime(nowStruct);

   if(!HistorySelect(dayStart, TimeCurrent())) return;

   int totalDeals = HistoryDealsTotal();
   for(int i = 0; i < totalDeals; i++)
   {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket == 0) continue;

      long dealEntry = HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
      if(dealEntry != DEAL_ENTRY_OUT && dealEntry != DEAL_ENTRY_INOUT && dealEntry != DEAL_ENTRY_OUT_BY) continue;

      double dealProfit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT) +
                          HistoryDealGetDouble(dealTicket, DEAL_SWAP) +
                          HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);

      if(dealProfit > 0.0) grossWinToday += dealProfit;
      if(dealProfit < 0.0)
      {
         grossLossToday += MathAbs(dealProfit);
         losingDealsToday++;
      }

      netProfitToday += dealProfit;
      closedDealsToday++;
   }
}

string BuildAccountTotalSummary()
{
   double grossWin, grossLoss, netProfit;
   int closedDeals;
   GetAccountHistoryTotals(grossWin, grossLoss, netProfit, closedDeals);
   double grossWinToday, grossLossToday, netProfitToday;
   int closedDealsToday, losingDealsToday;
   GetTodayHistoryTotals(grossWinToday, grossLossToday, netProfitToday, closedDealsToday, losingDealsToday);

   double recoveryNeeded = 0.0;
   if(netProfit < 0.0) recoveryNeeded = MathAbs(netProfit);

   return("TOTAL ACCOUNT SUMMARY" +
          "\nClosed deals: " + IntegerToString(closedDeals) +
          "\nTotal menang: " + DoubleToString(grossWin, 2) +
          "\nTotal rugi: " + DoubleToString(grossLoss, 2) +
          "\nNet total: " + DoubleToString(netProfit, 2) +
          "\nClosed deals hari ini: " + IntegerToString(closedDealsToday) +
          "\nRugi hari ini: " + IntegerToString(losingDealsToday) +
          "\nProfit hari ini: " + DoubleToString(netProfitToday, 2) +
          "\nRecovery ke BE: " + DoubleToString(recoveryNeeded, 2));
}

double PointsToPips(const double pointsValue)
{
   return(pointsValue / 10.0);
}

bool IsMarketSessionOpen()
{
   long tradeMode = SymbolInfoInteger(symbolName, SYMBOL_TRADE_MODE);
   if(tradeMode == SYMBOL_TRADE_MODE_DISABLED || tradeMode == SYMBOL_TRADE_MODE_CLOSEONLY)
      return(false);

   MqlDateTime nowStruct;
   TimeToStruct(TimeCurrent(), nowStruct);
   int nowSeconds = nowStruct.hour * 3600 + nowStruct.min * 60 + nowStruct.sec;

   bool foundSession = false;
   for(int sessionIndex = 0; sessionIndex < 10; sessionIndex++)
   {
      datetime fromTime, toTime;
      if(!SymbolInfoSessionTrade(symbolName, (ENUM_DAY_OF_WEEK)nowStruct.day_of_week, sessionIndex, fromTime, toTime))
         break;

      foundSession = true;
      MqlDateTime fromStruct, toStruct;
      TimeToStruct(fromTime, fromStruct);
      TimeToStruct(toTime, toStruct);
      int fromSeconds = fromStruct.hour * 3600 + fromStruct.min * 60 + fromStruct.sec;
      int toSeconds = toStruct.hour * 3600 + toStruct.min * 60 + toStruct.sec;

      if(fromSeconds <= toSeconds)
      {
         if(nowSeconds >= fromSeconds && nowSeconds <= toSeconds) return(true);
      }
      else
      {
         if(nowSeconds >= fromSeconds || nowSeconds <= toSeconds) return(true);
      }
   }

   if(foundSession) return(false);

   double ask = SymbolInfoDouble(symbolName, SYMBOL_ASK);
   double bid = SymbolInfoDouble(symbolName, SYMBOL_BID);
   return(ask > 0.0 && bid > 0.0);
}

double GetPositionEntryPriceFromHistory(const ulong positionId)
{
   if(positionId == 0 || !HistorySelect(0, TimeCurrent())) return(0.0);

   int totalDeals = HistoryDealsTotal();
   for(int i = 0; i < totalDeals; i++)
   {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket == 0) continue;
      if((ulong)HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID) != positionId) continue;

      long dealEntry = HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
      if(dealEntry == DEAL_ENTRY_IN || dealEntry == DEAL_ENTRY_INOUT)
         return(HistoryDealGetDouble(dealTicket, DEAL_PRICE));
   }
   return(0.0);
}

string BuildTechnicalSummary()
{
   return("TECHNICAL SETUP" +
          "\nTrend TF: " + EnumToString((ENUM_TIMEFRAMES)TrendTF) +
          "\nSignal TF: " + EnumToString((ENUM_TIMEFRAMES)SignalTF) +
          "\nTrend EMA: " + IntegerToString(TrendEMA) +
          "\nEntry EMA: " + IntegerToString(EntryEMA) +
          "\nRSI Period: " + IntegerToString(RSI_Period) +
          "\nRSI Buy/Sell: " + DoubleToString(BuyRSILevel, 1) + " / " + DoubleToString(SellRSILevel, 1) +
          "\nMode: Reversal + Limit + SL Plus + Trailing" +
          "\nPartial TP: " + (UsePartialTakeProfit ? "ON" : "OFF"));
}

string BuildStartupMessage()
{
   string limitMode = UseLimitOrders ? "ON" : "OFF";
   string splitMode = UseThreeOrderSplit ? "3 Orders" : "Single Order";
   string message = "EA STARTED" +
          "\nBot: Reversal Limit TierReady" +
          "\nSymbol: " + symbolName +
          "\nLot: " + DoubleToString(LotSize, 2) +
          "\nLimit Orders: " + limitMode +
          "\nExecution: " + splitMode +
          "\nSL Plus Trigger/Lock: " + IntegerToString(SLPlusTriggerPoints) + " / " + IntegerToString(SLPlusLockPoints) +
          "\nTrailing Start/Step: " + IntegerToString(TrailStartPoints) + " / " + IntegerToString(TrailStepPoints) +
          "\n\n" + BuildTechnicalSummary();

   if(SendAccountTotalSummary)
      message += "\n\n" + BuildAccountTotalSummary();

   return(message);
}

string BuildFormattedEntryMessage(const string side, const string mode, const double entryPrice, const double sl, const double tp1, const double tp2, const double tp3, const int digits)
{
   double point = SymbolInfoDouble(symbolName, SYMBOL_POINT);
   double slPips = PointsToPips(MathAbs(entryPrice - sl) / point);
   double tp1Pips = PointsToPips(MathAbs(tp1 - entryPrice) / point);
   double tp2Pips = PointsToPips(MathAbs(tp2 - entryPrice) / point);
   double tp3Pips = PointsToPips(MathAbs(tp3 - entryPrice) / point);
   double dailyPL = AccountInfoDouble(ACCOUNT_EQUITY) - startDayEquity;

   string message = "ENTRY OPENED" +
                    "\nBot: Reversal Limit TierReady" +
                    "\nType: " + side + " " + mode +
                    "\nSymbol: " + symbolName +
                    "\nLot Total: " + DoubleToString(LotSize, 2) +
                    "\nEntry: " + DoubleToString(entryPrice, digits) +
                    "\nSL: " + DoubleToString(sl, digits) + " (" + DoubleToString(slPips, 1) + " pips)" +
                    "\nTP1: " + DoubleToString(tp1, digits) + " (" + DoubleToString(tp1Pips, 1) + " pips)";

   if(UseThreeOrderSplit)
      message += "\nTP2: " + DoubleToString(tp2, digits) + " (" + DoubleToString(tp2Pips, 1) + " pips)" +
                 "\nTP3: " + DoubleToString(tp3, digits) + " (" + DoubleToString(tp3Pips, 1) + " pips)";

   message += "\nProfit hari ini: " + DoubleToString(dailyPL, 2);

   return(message);
}

string BuildCloseMessage(const string side, const double profitValue, const double closePrice, const double volume, const long reasonCode, const int digits, const double closePips)
{
   string outcome = profitValue >= 0.0 ? "CLOSE PROFIT" : "CLOSE LOSS";
   double dailyPL = AccountInfoDouble(ACCOUNT_EQUITY) - startDayEquity;
   string message = outcome +
          "\nBot: Reversal Limit TierReady" +
          "\nType: " + side +
          "\nSymbol: " + symbolName +
          "\nVolume: " + DoubleToString(volume, 2) +
          "\nClose Price: " + DoubleToString(closePrice, digits) +
          "\nP/L: " + DoubleToString(profitValue, 2) +
          "\nPips: " + DoubleToString(closePips, 1) +
          "\nProfit hari ini: " + DoubleToString(dailyPL, 2) +
          "\nReason Code: " + IntegerToString((int)reasonCode);

   if(SendAccountTotalSummary)
      message += "\n\n" + BuildAccountTotalSummary();

   return(message);
}

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
   entryEmaHandle = iMA(symbolName, SignalTF, EntryEMA, 0, MODE_EMA, PRICE_CLOSE);
   rsiHandle = iRSI(symbolName, SignalTF, RSI_Period, PRICE_CLOSE);

   if(trendEmaHandle == INVALID_HANDLE || entryEmaHandle == INVALID_HANDLE || rsiHandle == INVALID_HANDLE)
   {
      LogStatus("ERROR: Failed to create indicators.");
      SendTelegram("BOT Reversal Limit failed to create indicators on " + symbolName);
      return INIT_FAILED;
   }

   ResetDailyEquity();
   string limitOrdersLabel = "OFF";
   if(UseLimitOrders) limitOrdersLabel = "ON";
   LogStatus("BOT Reversal Limit active on " + symbolName + " | Lot: " + DoubleToString(LotSize, 2) + " | LimitOrders: " + limitOrdersLabel);
   SendTelegram(BuildStartupMessage());

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(trendEmaHandle != INVALID_HANDLE) IndicatorRelease(trendEmaHandle);
   if(entryEmaHandle != INVALID_HANDLE) IndicatorRelease(entryEmaHandle);
   if(rsiHandle != INVALID_HANDLE) IndicatorRelease(rsiHandle);
   Comment("");
   SendTelegram("EA STOPPED\nBot: Reversal Limit TierReady\nSymbol: " + symbolName);
}

//+------------------------------------------------------------------+
void OnTick()
{
   CheckNewDay();
   if(UsePartialTakeProfit) ManagePartialTakeProfit();
   if(UseTrailingStop) ManageTrailingStop();
   ShowPanel();

   if(IsDailyLimitReached()) return;

   if(!IsMarketSessionOpen())
   {
      lastStatus = "Market closed, waiting open session";
      return;
   }

   int spread = (int)SymbolInfoInteger(symbolName, SYMBOL_SPREAD);
   if(spread > MaxSpreadPoints)
   {
      lastStatus = "Spread too high: " + IntegerToString(spread);
      return;
   }

   datetime candleTime = iTime(symbolName, SignalTF, 0);
   if(OneTradePerCandle && candleTime == lastTradeCandleTime)
   {
      lastStatus = "One trade per candle guard";
      return;
   }

   if(lastEntryOpenTime != 0 && MinMinutesBetweenEntries > 0)
   {
      int secondsSinceEntry = (int)(TimeCurrent() - lastEntryOpenTime);
      int waitSeconds = MinMinutesBetweenEntries * 60;
      if(secondsSinceEntry < waitSeconds)
      {
         int minutesLeft = (int)MathCeil((double)(waitSeconds - secondsSinceEntry) / 60.0);
         lastStatus = "Entry spacing active: wait " + IntegerToString(minutesLeft) + " min";
         return;
      }
   }

   bool buySignal = false;
   bool sellSignal = false;
   if(!GetSignals(buySignal, sellSignal)) return;

   bool fallbackBuySignal = false;
   bool fallbackSellSignal = false;
   if(EnableTrendFallback)
      GetTrendFallbackSignals(fallbackBuySignal, fallbackSellSignal);
   lastFallbackBuySignal = fallbackBuySignal;
   lastFallbackSellSignal = fallbackSellSignal;
   LogIndicatorSnapshot(candleTime);

   int myPositions = CountMyPositions();
   int currentType = GetMyPositionType();
   if(lastKnownPositionCount > 0 && myPositions == 0)
   {
      lastPositionExitTime = TimeCurrent();
      ResetPartialTPState();
      LogStatus("No open position detected. Waiting for next valid re-entry signal.");
      lastReentryLogTime = TimeCurrent();
   }
   lastKnownPositionCount = myPositions;

   if(lastPositionExitTime != 0 && ReentryCooldownBars > 0)
   {
      int barsSinceExit = iBarShift(symbolName, SignalTF, lastPositionExitTime, false);
      if(barsSinceExit >= 0 && barsSinceExit < ReentryCooldownBars)
      {
         lastStatus = "Re-entry cooldown active";
         return;
      }
   }

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
      if(TimeCurrent() - lastReentryLogTime > 5)
      {
         LogStatus("Valid re-entry signal detected: BUY reversal setup.");
         lastReentryLogTime = TimeCurrent();
      }
      if(DeleteOppositePending) DeleteMyPendingOrders();
      PlaceEntry(true, candleTime, "BOT BUY LIMIT");
   }
   else if(sellSignal)
   {
      if(TimeCurrent() - lastReentryLogTime > 5)
      {
         LogStatus("Valid re-entry signal detected: SELL reversal setup.");
         lastReentryLogTime = TimeCurrent();
      }
      if(DeleteOppositePending) DeleteMyPendingOrders();
      PlaceEntry(false, candleTime, "BOT SELL LIMIT");
   }
   else if(fallbackBuySignal)
   {
      if(TimeCurrent() - lastReentryLogTime > 5)
      {
         LogStatus("Valid re-entry signal detected: BUY trend fallback.");
         lastReentryLogTime = TimeCurrent();
      }
      if(DeleteOppositePending) DeleteMyPendingOrders();
      PlaceEntryMarket(true, candleTime, "TREND FALLBACK BUY");
   }
   else if(fallbackSellSignal)
   {
      if(TimeCurrent() - lastReentryLogTime > 5)
      {
         LogStatus("Valid re-entry signal detected: SELL trend fallback.");
         lastReentryLogTime = TimeCurrent();
      }
      if(DeleteOppositePending) DeleteMyPendingOrders();
      PlaceEntryMarket(false, candleTime, "TREND FALLBACK SELL");
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
   double close1 = iClose(symbolName, SignalTF, 1);
   double open1 = iOpen(symbolName, SignalTF, 1);
   double high1 = iHigh(symbolName, SignalTF, 1);
   double low1 = iLow(symbolName, SignalTF, 1);
   int lookbackShift = MathMax(2, SignalLookbackBars);
   double close2 = iClose(symbolName, SignalTF, lookbackShift);
   double open2 = iOpen(symbolName, SignalTF, 2);
   double high2 = iHigh(symbolName, SignalTF, 2);
   double low2 = iLow(symbolName, SignalTF, 2);
   double point = SymbolInfoDouble(symbolName, SYMBOL_POINT);

   lastTrendClose = trendClose;
   lastTrendEMA = trendEMA[0];
   lastEntryEMA = entryEMA[0];
   lastRSI = rsi[0];
   lastOpen1 = open1;
   lastClose1 = close1;
   lastHigh1 = high1;
   lastLow1 = low1;

   bool trendBuy = trendClose > trendEMA[0];
   bool trendSell = trendClose < trendEMA[0];
   bool bullishCandle = close1 > open1;
   bool bearishCandle = close1 < open1;
   bool priceImprovingBuy = close1 >= close2;
   bool priceImprovingSell = close1 <= close2;
   double body1 = MathAbs(close1 - open1);
   double upperWick1 = high1 - MathMax(open1, close1);
   double lowerWick1 = MathMin(open1, close1) - low1;
   bool bullishPrevCandle = close2 > open2;
   bool bearishPrevCandle = close2 < open2;
   bool higherLowStructure = low1 >= low2;
   bool lowerHighStructure = high1 <= high2;

   bool candleConfirmBuy = true;
   bool candleConfirmSell = true;
   if(RequireCandleConfirmation)
   {
      candleConfirmBuy = bullishCandle &&
                         bullishPrevCandle &&
                         higherLowStructure &&
                         body1 >= MinSignalBodyPoints * point &&
                         upperWick1 <= body1 * MaxOppositeWickRatio;

      candleConfirmSell = bearishCandle &&
                          bearishPrevCandle &&
                          lowerHighStructure &&
                          body1 >= MinSignalBodyPoints * point &&
                          lowerWick1 <= body1 * MaxOppositeWickRatio;
   }

   bool rsiBuyPass = rsi[0] >= BuyRSILevel;
   bool rsiSellPass = rsi[0] <= SellRSILevel;
   bool entryBuyPass = close1 > entryEMA[0];
   bool entrySellPass = close1 < entryEMA[0];

   buySignal = trendBuy && entryBuyPass && candleConfirmBuy && rsiBuyPass;
   sellSignal = trendSell && entrySellPass && candleConfirmSell && rsiSellPass;

   if(UseFastEntryMode)
   {
      bool buyMomentum = rsi[0] >= BuyRSILevel && rsi[1] >= BuyRSILevel - 2.0;
      bool sellMomentum = rsi[0] <= SellRSILevel && rsi[1] <= SellRSILevel + 2.0;

      buySignal = buySignal || (trendBuy && close1 > entryEMA[1] && buyMomentum && priceImprovingBuy && candleConfirmBuy);
      sellSignal = sellSignal || (trendSell && close1 < entryEMA[1] && sellMomentum && priceImprovingSell && candleConfirmSell);
   }

   lastBuySignal = buySignal;
   lastSellSignal = sellSignal;
   lastSignalDecisionLog =
      "BUY[trend=" + (trendBuy ? "PASS" : "BLOCK") +
      " tc=" + DoubleToString(trendClose, 2) +
      " ema=" + DoubleToString(trendEMA[0], 2) +
      ", entryEMA=" + (entryBuyPass ? "PASS" : "BLOCK") +
      " c=" + DoubleToString(close1, 2) +
      " e=" + DoubleToString(entryEMA[0], 2) +
      ", candle=" + (candleConfirmBuy ? "PASS" : "BLOCK") +
      " body=" + DoubleToString(body1 / point, 1) +
      " min=" + IntegerToString(MinSignalBodyPoints) +
      ", rsi=" + (rsiBuyPass ? "PASS" : "BLOCK") +
      " v=" + DoubleToString(rsi[0], 2) +
      " min=" + DoubleToString(BuyRSILevel, 1) +
      "] SELL[trend=" + (trendSell ? "PASS" : "BLOCK") +
      " tc=" + DoubleToString(trendClose, 2) +
      " ema=" + DoubleToString(trendEMA[0], 2) +
      ", entryEMA=" + (entrySellPass ? "PASS" : "BLOCK") +
      " c=" + DoubleToString(close1, 2) +
      " e=" + DoubleToString(entryEMA[0], 2) +
      ", candle=" + (candleConfirmSell ? "PASS" : "BLOCK") +
      " body=" + DoubleToString(body1 / point, 1) +
      " min=" + IntegerToString(MinSignalBodyPoints) +
      ", rsi=" + (rsiSellPass ? "PASS" : "BLOCK") +
      " v=" + DoubleToString(rsi[0], 2) +
      " max=" + DoubleToString(SellRSILevel, 1) +
      "]";

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

   double close1 = iClose(symbolName, SignalTF, 1);
   double open1 = iOpen(symbolName, SignalTF, 1);
   double high1 = iHigh(symbolName, SignalTF, 1);
   double low1 = iLow(symbolName, SignalTF, 1);
   double close2 = iClose(symbolName, SignalTF, 2);
   double open2 = iOpen(symbolName, SignalTF, 2);
   double high2 = iHigh(symbolName, SignalTF, 2);
   double low2 = iLow(symbolName, SignalTF, 2);
   double trendClose = iClose(symbolName, TrendTF, 1);
   double point = SymbolInfoDouble(symbolName, SYMBOL_POINT);

   bool strongUpTrend = trendClose > trendEMA[0] && close1 > entryEMA[0] && close1 > close2;
   bool strongDownTrend = trendClose < trendEMA[0] && close1 < entryEMA[0] && close1 < close2;
   bool makingHigherHigh = high1 >= high2;
   bool makingLowerLow = low1 <= low2;
   double body1 = MathAbs(close1 - open1);
   bool bullishPrevCandle = close2 > open2;
   bool bearishPrevCandle = close2 < open2;

   bool fallbackBuyConfirm = body1 >= MinSignalBodyPoints * point && bullishPrevCandle;
   bool fallbackSellConfirm = body1 >= MinSignalBodyPoints * point && bearishPrevCandle;
   bool fallbackRsiBuyPass = rsi[0] >= BuyRSILevel + 2.0;
   bool fallbackRsiSellPass = rsi[0] <= SellRSILevel - 2.0;

   buySignal = strongUpTrend && makingHigherHigh && fallbackBuyConfirm && fallbackRsiBuyPass;
   sellSignal = strongDownTrend && makingLowerLow && fallbackSellConfirm && fallbackRsiSellPass;

   if(!lastBuySignal && !lastSellSignal)
   {
      lastSignalDecisionLog =
         lastSignalDecisionLog +
         " | FALLBACK BUY[trend=" + (strongUpTrend ? "PASS" : "BLOCK") +
         " c1=" + DoubleToString(close1, 2) +
         " e=" + DoubleToString(entryEMA[0], 2) +
         ", structure=" + (makingHigherHigh ? "PASS" : "BLOCK") +
         " h1=" + DoubleToString(high1, 2) +
         " h2=" + DoubleToString(high2, 2) +
         ", candle=" + (fallbackBuyConfirm ? "PASS" : "BLOCK") +
         " body=" + DoubleToString(body1 / point, 1) +
         ", rsi=" + (fallbackRsiBuyPass ? "PASS" : "BLOCK") +
         " v=" + DoubleToString(rsi[0], 2) +
         "] FALLBACK SELL[trend=" + (strongDownTrend ? "PASS" : "BLOCK") +
         " c1=" + DoubleToString(close1, 2) +
         " e=" + DoubleToString(entryEMA[0], 2) +
         ", structure=" + (makingLowerLow ? "PASS" : "BLOCK") +
         " l1=" + DoubleToString(low1, 2) +
         " l2=" + DoubleToString(low2, 2) +
         ", candle=" + (fallbackSellConfirm ? "PASS" : "BLOCK") +
         " body=" + DoubleToString(body1 / point, 1) +
         ", rsi=" + (fallbackRsiSellPass ? "PASS" : "BLOCK") +
         " v=" + DoubleToString(rsi[0], 2) +
         "]";
   }
}

//+------------------------------------------------------------------+
void NormalizeTradeLevels(const bool isBuy, const double entryPrice, double &sl, double &tp, const int digits)
{
   double point = SymbolInfoDouble(symbolName, SYMBOL_POINT);
   int stopsLevel = (int)SymbolInfoInteger(symbolName, SYMBOL_TRADE_STOPS_LEVEL);
   double minDistance = (stopsLevel + 5) * point;

   if(isBuy)
   {
      if(entryPrice - sl < minDistance) sl = entryPrice - minDistance;
      if(tp - entryPrice < minDistance) tp = entryPrice + minDistance;
      if(sl >= entryPrice) sl = entryPrice - minDistance;
      if(tp <= entryPrice) tp = entryPrice + minDistance;
   }
   else
   {
      if(sl - entryPrice < minDistance) sl = entryPrice + minDistance;
      if(entryPrice - tp < minDistance) tp = entryPrice - minDistance;
      if(sl <= entryPrice) sl = entryPrice + minDistance;
      if(tp >= entryPrice) tp = entryPrice - minDistance;
   }

   sl = NormalizeDouble(sl, digits);
   tp = NormalizeDouble(tp, digits);
}

//+------------------------------------------------------------------+
bool PlaceSingleLimit(const bool isBuy, const double lots, const double entry, const double sl, const double tp, const datetime expiry, const string reason)
{
   if(isBuy)
      return trade.BuyLimit(lots, entry, symbolName, sl, tp, ORDER_TIME_SPECIFIED, expiry, reason);
   return trade.SellLimit(lots, entry, symbolName, sl, tp, ORDER_TIME_SPECIFIED, expiry, reason);
}

//+------------------------------------------------------------------+
bool PlaceSingleMarket(const bool isBuy, const double lots, const double sl, const double tp, const string reason)
{
   if(isBuy)
      return trade.Buy(lots, symbolName, 0.0, sl, tp, reason);
   return trade.Sell(lots, symbolName, 0.0, sl, tp, reason);
}

//+------------------------------------------------------------------+
void SendSplitEntrySummary(const string side, const string mode, const double sl, const double tp1, const double tp2, const double tp3, const int digits)
{
   double entryPrice = SymbolInfoDouble(symbolName, side == "BUY" ? SYMBOL_ASK : SYMBOL_BID);
   SendTelegram(BuildFormattedEntryMessage(side, mode, entryPrice, sl, tp1, tp2, tp3, digits));
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
   double tp1 = isBuy ? entry + TakeProfitPoints * point : entry - TakeProfitPoints * point;
   double tp2 = isBuy ? entry + (TakeProfitPoints * TP2Multiplier) * point : entry - (TakeProfitPoints * TP2Multiplier) * point;
   double tp3 = isBuy ? entry + (TakeProfitPoints * TP3Multiplier) * point : entry - (TakeProfitPoints * TP3Multiplier) * point;

   entry = NormalizeDouble(entry, digits);
   NormalizeTradeLevels(isBuy, entry, sl, tp1, digits);
   NormalizeTradeLevels(isBuy, entry, sl, tp2, digits);
   NormalizeTradeLevels(isBuy, entry, sl, tp3, digits);

   bool result = false;
   string side = "SELL";
   if(isBuy) side = "BUY";
   double splitLot1 = NormalizeLots(LotSize / 3.0);
   double splitLot2 = NormalizeLots(LotSize / 3.0);
   double splitLot3 = NormalizeLots(LotSize - splitLot1 - splitLot2);
   if(splitLot3 <= 0.0) splitLot3 = splitLot2;
   double splitStep = SplitLimitEntryStepPoints * point;
   double entry1 = entry;
   double entry2 = isBuy ? entry - splitStep : entry + splitStep;
   double entry3 = isBuy ? entry - (splitStep * 2.0) : entry + (splitStep * 2.0);
   double sl1 = sl;
   double sl2 = isBuy ? entry2 - StopLossPoints * point : entry2 + StopLossPoints * point;
   double sl3 = isBuy ? entry3 - StopLossPoints * point : entry3 + StopLossPoints * point;

   NormalizeTradeLevels(isBuy, entry1, sl1, tp1, digits);
   NormalizeTradeLevels(isBuy, entry2, sl2, tp2, digits);
   NormalizeTradeLevels(isBuy, entry3, sl3, tp3, digits);

   if(UseLimitOrders)
   {
      datetime expiry = TimeCurrent() + PendingExpiryMinutes * 60;
      if(UseThreeOrderSplit)
      {
         bool ok1 = PlaceSingleLimit(isBuy, splitLot1, entry1, sl1, tp1, expiry, reason + " TP1");
         bool ok2 = PlaceSingleLimit(isBuy, splitLot2, entry2, sl2, tp2, expiry, reason + " TP2");
         bool ok3 = PlaceSingleLimit(isBuy, splitLot3, entry3, sl3, tp3, expiry, reason + " TP3");
         result = ok1 || ok2 || ok3;
      }
      else
      {
         if(isBuy)
            result = trade.BuyLimit(LotSize, entry, symbolName, sl, tp1, ORDER_TIME_SPECIFIED, expiry, reason);
         else
            result = trade.SellLimit(LotSize, entry, symbolName, sl, tp1, ORDER_TIME_SPECIFIED, expiry, reason);
      }

      if(result)
      {
         lastTradeCandleTime = candleTime;
         lastPendingRefreshTime = TimeCurrent();
         lastEntryOpenTime = TimeCurrent();
         if(UseThreeOrderSplit)
            LogStatus(side + " LIMIT ladder placed | E1: " + DoubleToString(entry1, digits) + " | E2: " + DoubleToString(entry2, digits) + " | E3: " + DoubleToString(entry3, digits));
         else
            LogStatus(side + " LIMIT placed | Entry: " + DoubleToString(entry, digits) + " | SL: " + DoubleToString(sl, digits));
         if(UseThreeOrderSplit)
            SendSplitEntrySummary(side, "LIMIT SPLIT", sl, tp1, tp2, tp3, digits);
         else
            SendTelegram(BuildFormattedEntryMessage(side, "LIMIT", entry, sl, tp1, tp2, tp3, digits));
         return;
      }

      string limitRejectReason = trade.ResultRetcodeDescription();
      LogStatus(side + " LIMIT rejected: " + limitRejectReason);
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
   bool result = false;
   string side = "SELL";
   if(isBuy) side = "BUY";

   double marketEntry = isBuy ? ask : bid;
   double marketSL = isBuy ? marketEntry - StopLossPoints * point : marketEntry + StopLossPoints * point;
   double marketTP1 = isBuy ? marketEntry + TakeProfitPoints * point : marketEntry - TakeProfitPoints * point;
   double marketTP2 = isBuy ? marketEntry + (TakeProfitPoints * TP2Multiplier) * point : marketEntry - (TakeProfitPoints * TP2Multiplier) * point;
   double marketTP3 = isBuy ? marketEntry + (TakeProfitPoints * TP3Multiplier) * point : marketEntry - (TakeProfitPoints * TP3Multiplier) * point;
   NormalizeTradeLevels(isBuy, marketEntry, marketSL, marketTP1, digits);
   NormalizeTradeLevels(isBuy, marketEntry, marketSL, marketTP2, digits);
   NormalizeTradeLevels(isBuy, marketEntry, marketSL, marketTP3, digits);
   double splitLot1 = NormalizeLots(LotSize / 3.0);
   double splitLot2 = NormalizeLots(LotSize / 3.0);
   double splitLot3 = NormalizeLots(LotSize - splitLot1 - splitLot2);
   if(splitLot3 <= 0.0) splitLot3 = splitLot2;

   if(UseThreeOrderSplit)
   {
      bool ok1 = PlaceSingleMarket(isBuy, splitLot1, marketSL, marketTP1, reason + " TP1");
      bool ok2 = PlaceSingleMarket(isBuy, splitLot2, marketSL, marketTP2, reason + " TP2");
      bool ok3 = PlaceSingleMarket(isBuy, splitLot3, marketSL, marketTP3, reason + " TP3");
      result = ok1 || ok2 || ok3;
   }
   else
   {
      if(isBuy)
         result = trade.Buy(LotSize, symbolName, 0.0, marketSL, marketTP1, reason + " MARKET");
      else
         result = trade.Sell(LotSize, symbolName, 0.0, marketSL, marketTP1, reason + " MARKET");
   }

   if(result)
   {
      lastTradeCandleTime = candleTime;
      lastEntryOpenTime = TimeCurrent();
      LogStatus(side + " MARKET opened | SL: " + DoubleToString(marketSL, digits));
      if(UseThreeOrderSplit)
         SendSplitEntrySummary(side, "MARKET SPLIT", marketSL, marketTP1, marketTP2, marketTP3, digits);
      else
         SendTelegram(BuildFormattedEntryMessage(side, "MARKET", marketEntry, marketSL, marketTP1, marketTP2, marketTP3, digits));
   }
   else
   {
      string failReason = trade.ResultRetcodeDescription();
      string failMessage = side + " ENTRY FAILED\nSymbol: " + symbolName + "\nReason: " + failReason;
      LogStatus(side + " MARKET failed: " + failReason);
      SendTelegram(failMessage);
   }
}

//+------------------------------------------------------------------+
void ManagePartialTakeProfit()
{
   double point = SymbolInfoDouble(symbolName, SYMBOL_POINT);
   double bid = SymbolInfoDouble(symbolName, SYMBOL_BID);
   double ask = SymbolInfoDouble(symbolName, SYMBOL_ASK);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbolName || PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      int type = (int)PositionGetInteger(POSITION_TYPE);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double volume = PositionGetDouble(POSITION_VOLUME);
      double profitPoints = 0.0;

      if(type == POSITION_TYPE_BUY)
         profitPoints = (bid - openPrice) / point;
      else if(type == POSITION_TYPE_SELL)
         profitPoints = (openPrice - ask) / point;

      if(trackedPartialPositionTicket != ticket)
      {
         trackedPartialPositionTicket = ticket;
         partialTP1Done = false;
         partialTP2Done = false;
      }

      if(!partialTP1Done && profitPoints >= PartialTP1Points)
      {
         if(ClosePartialVolume(ticket, volume, PartialTP1ClosePercent))
         {
            partialTP1Done = true;
            LogStatus("Partial TP1 executed on ticket: " + IntegerToString((int)ticket));
         }
      }

      if(!partialTP2Done && profitPoints >= PartialTP2Points)
      {
         double refreshedVolume = PositionGetDouble(POSITION_VOLUME);
         if(ClosePartialVolume(ticket, refreshedVolume, PartialTP2ClosePercent))
         {
            partialTP2Done = true;
            LogStatus("Partial TP2 executed on ticket: " + IntegerToString((int)ticket));
         }
      }
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
         else
         {
            string closeFailReason = trade.ResultRetcodeDescription();
            LogStatus("Close failed: " + closeFailReason);
         }
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
   double grossWinToday, grossLossToday, netProfitToday;
   int closedDealsToday, losingDealsToday;
   GetTodayHistoryTotals(grossWinToday, grossLossToday, netProfitToday, closedDealsToday, losingDealsToday);

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

   if(MaxDailyLosingDeals > 0 && losingDealsToday >= MaxDailyLosingDeals && netProfitToday < 0.0)
   {
      lastStatus = "Daily losing-deal guard reached: " + IntegerToString(losingDealsToday);
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
   string tfLabel = EnumToString((ENUM_TIMEFRAMES)SignalTF);
   string sessionLabel = IsMarketSessionOpen() ? "OPEN" : "CLOSED";
   Comment("BOT MetaTraderLocal Reversal Limit\n",
           "Symbol: ", symbolName, " | TF: ", tfLabel, "\n",
           "Positions: ", CountMyPositions(), " | Pending: ", CountMyPendingOrders(), "\n",
           "Daily P/L: ", DoubleToString(dailyPL, 2), "\n",
           "Lot: ", DoubleToString(LotSize, 2), " | Spread: ", IntegerToString((int)SymbolInfoInteger(symbolName, SYMBOL_SPREAD)), "\n",
           "Session: ", sessionLabel, "\n",
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
void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
{
   if(!EnableTelegram) return;
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   if(trans.deal == 0 || trans.deal == lastNotifiedDealTicket) return;

   if(!HistoryDealSelect(trans.deal)) return;

   string dealSymbol = HistoryDealGetString(trans.deal, DEAL_SYMBOL);
   long dealMagic = HistoryDealGetInteger(trans.deal, DEAL_MAGIC);
   long dealEntry = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);

   if(dealSymbol != symbolName || dealMagic != MagicNumber) return;
   if(dealEntry != DEAL_ENTRY_OUT && dealEntry != DEAL_ENTRY_INOUT && dealEntry != DEAL_ENTRY_OUT_BY) return;

   double dealProfit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT) +
                       HistoryDealGetDouble(trans.deal, DEAL_SWAP) +
                       HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);
   double dealPrice = HistoryDealGetDouble(trans.deal, DEAL_PRICE);
   double dealVolume = HistoryDealGetDouble(trans.deal, DEAL_VOLUME);
   long dealReason = HistoryDealGetInteger(trans.deal, DEAL_REASON);
   long dealType = HistoryDealGetInteger(trans.deal, DEAL_TYPE);
    ulong positionId = (ulong)HistoryDealGetInteger(trans.deal, DEAL_POSITION_ID);
   int digits = (int)SymbolInfoInteger(symbolName, SYMBOL_DIGITS);
   double point = SymbolInfoDouble(symbolName, SYMBOL_POINT);

   string side = "SELL";
   if(dealType == DEAL_TYPE_BUY || dealType == DEAL_TYPE_BUY_CANCELED) side = "BUY";

   double entryPrice = GetPositionEntryPriceFromHistory(positionId);
   double closePips = 0.0;
   if(entryPrice > 0.0 && point > 0.0)
      closePips = PointsToPips(MathAbs(dealPrice - entryPrice) / point);

   lastNotifiedDealTicket = trans.deal;
   SendTelegram(BuildCloseMessage(side, dealProfit, dealPrice, dealVolume, dealReason, digits, closePips));
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
