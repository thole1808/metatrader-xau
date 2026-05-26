//+------------------------------------------------------------------+
//|            BOT_MetaTraderLocal_Reversal_Limit_TierReady_MT4.mq4  |
//| XAUUSD/XAUUSDc MT4 - Companion setup aligned with MT5 version    |
//+------------------------------------------------------------------+
#property strict
#property version   "1.10"
#property description "MT4 companion aligned with MT5 TierReady setup: reversal, limit, split TP, SL Plus, trailing, and Telegram."

input string InpTradeSymbol             = "XAUUSD";
input double InpLotSize                 = 0.01;
input int    InpMagicNumber             = 2026051912;
input int    InpMaxSpreadPoints         = 300;
input int    InpSlippagePoints          = 30;

input ENUM_TIMEFRAMES InpTrendTF        = PERIOD_M15;
input ENUM_TIMEFRAMES InpSignalTF       = PERIOD_M15;
input int    InpTrendEMA                = 34;

input int    InpEntryEMA                = 12;
input int    InpRSIPeriod               = 14;
input double InpBuyRSILevel             = 48.0;
input double InpSellRSILevel            = 52.0;
input bool   InpUseFastEntryMode        = true;
input int    InpSignalLookbackBars      = 2;
input bool   InpEnableTrendFallback     = true;
input bool   InpUseMarketForTrendFallback = true;
input bool   InpRequireCandleConfirmation = true;
input int    InpMinSignalBodyPoints     = 35;
input double InpMaxOppositeWickRatio    = 1.80;

input int    InpStopLossPoints          = 1200;
input int    InpTakeProfitPoints        = 1000;

input bool   InpUseLimitOrders          = true;
input int    InpLimitOffsetPoints       = 40;
input int    InpPendingExpiryMinutes    = 2;
input bool   InpFallbackMarketIfRejected = true;
input bool   InpDeleteOppositePending   = true;
input bool   InpRefreshStalePending     = true;
input bool   InpUseThreeOrderSplit      = true;
input double InpTP2Multiplier           = 1.50;
input double InpTP3Multiplier           = 2.00;

input bool   InpUseTrailingStop         = true;
input bool   InpUseAutoSLPlus           = true;
input int    InpSLPlusTriggerPoints     = 250;
input int    InpSLPlusLockPoints        = 100;
input int    InpTrailStartPoints        = 400;
input int    InpTrailStepPoints         = 150;

input double InpDailyMaxLossMoney       = 150.0;
input double InpDailyTargetMoney        = 300.0;

input bool   InpOneTradePerCandle       = false;
input int    InpReentryCooldownBars     = 1;

input bool   InpEnableReversalMode      = true;
input int    InpReversalDelaySeconds    = 1;

input bool   InpUseTelegram             = true;
input string InpTelegramBotToken        = "";
input string InpTelegramChatId          = "";
input bool   InpSendAccountTotalSummary = true;

string   g_symbol;
datetime g_lastSignalBarTime = 0;
datetime g_lastPositionExitTime = 0;
datetime g_dayStartTime = 0;
double   g_dayStartEquity = 0.0;
bool     g_dailyTargetSent = false;
bool     g_dailyLossSent = false;
int      g_lastKnownOpenTrades = 0;
int      g_lastHistoryCount = 0;

double NormalizeLots(double lots)
{
   double minLot = MarketInfo(g_symbol, MODE_MINLOT);
   double maxLot = MarketInfo(g_symbol, MODE_MAXLOT);
   double stepLot = MarketInfo(g_symbol, MODE_LOTSTEP);
   if(stepLot <= 0.0) stepLot = 0.01;

   double normalized = MathFloor(lots / stepLot) * stepLot;
   if(normalized < minLot) normalized = minLot;
   if(normalized > maxLot) normalized = maxLot;
   return(NormalizeDouble(normalized, 2));
}

double PointsToPips(double pointsValue)
{
   return(pointsValue / 10.0);
}

bool IsMarketSessionOpen()
{
   int dow = DayOfWeek();
   if(dow == 0 || dow == 6) return(false);
   if(!IsTradeAllowed()) return(false);

   double ask = MarketInfo(g_symbol, MODE_ASK);
   double bid = MarketInfo(g_symbol, MODE_BID);
   if(ask <= 0.0 || bid <= 0.0) return(false);

   return(true);
}

void ResetDailyEquity()
{
   g_dayStartTime = iTime(g_symbol, PERIOD_D1, 0);
   g_dayStartEquity = AccountEquity();
   g_dailyTargetSent = false;
   g_dailyLossSent = false;
}

void UpdateDailyEquity()
{
   datetime currentDay = iTime(g_symbol, PERIOD_D1, 0);
   if(currentDay != 0 && currentDay != g_dayStartTime)
      ResetDailyEquity();
}

double GetDailyPL()
{
   return(AccountEquity() - g_dayStartEquity);
}

void GetAccountHistoryTotals(double &grossWin, double &grossLoss, double &netProfit, int &closedTrades)
{
   grossWin = 0.0;
   grossLoss = 0.0;
   netProfit = 0.0;
   closedTrades = 0;

   for(int i = OrdersHistoryTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_HISTORY)) continue;
      double pl = OrderProfit() + OrderSwap() + OrderCommission();
      if(pl > 0.0) grossWin += pl;
      if(pl < 0.0) grossLoss += MathAbs(pl);
      netProfit += pl;
      closedTrades++;
   }
}

string BuildAccountTotalSummary()
{
   double grossWin, grossLoss, netProfit;
   int closedTrades;
   GetAccountHistoryTotals(grossWin, grossLoss, netProfit, closedTrades);
   double recoveryNeeded = netProfit < 0.0 ? MathAbs(netProfit) : 0.0;

   return("TOTAL ACCOUNT SUMMARY" +
          "\nClosed deals: " + IntegerToString(closedTrades) +
          "\nTotal menang: " + DoubleToString(grossWin, 2) +
          "\nTotal rugi: " + DoubleToString(grossLoss, 2) +
          "\nNet total: " + DoubleToString(netProfit, 2) +
          "\nProfit hari ini: " + DoubleToString(GetDailyPL(), 2) +
          "\nRecovery ke BE: " + DoubleToString(recoveryNeeded, 2));
}

string BuildTechnicalSummary()
{
   return("TECHNICAL SETUP" +
          "\nTrend TF: " + TimeframeToText(InpTrendTF) +
          "\nSignal TF: " + TimeframeToText(InpSignalTF) +
          "\nTrend EMA: " + IntegerToString(InpTrendEMA) +
          "\nEntry EMA: " + IntegerToString(InpEntryEMA) +
          "\nRSI Period: " + IntegerToString(InpRSIPeriod) +
          "\nRSI Buy/Sell: " + DoubleToString(InpBuyRSILevel, 1) + " / " + DoubleToString(InpSellRSILevel, 1) +
          "\nMode: Reversal + Limit + SL Plus + Trailing");
}

string BuildStartupMessage()
{
   string message = "EA STARTED" +
          "\nBot: Reversal Limit TierReady MT4" +
          "\nSymbol: " + g_symbol +
          "\nLot: " + DoubleToString(InpLotSize, 2) +
          "\nLimit Orders: " + (InpUseLimitOrders ? "ON" : "OFF") +
          "\nExecution: " + (InpUseThreeOrderSplit ? "3 Orders" : "Single Order") +
          "\nSL Plus Trigger/Lock: " + IntegerToString(InpSLPlusTriggerPoints) + " / " + IntegerToString(InpSLPlusLockPoints) +
          "\nTrailing Start/Step: " + IntegerToString(InpTrailStartPoints) + " / " + IntegerToString(InpTrailStepPoints) +
          "\n\n" + BuildTechnicalSummary();

   if(InpSendAccountTotalSummary)
      message += "\n\n" + BuildAccountTotalSummary();

   return(message);
}

string BuildFormattedEntryMessage(string side, string mode, double entryPrice, double sl, double tp1, double tp2, double tp3, int digits)
{
   double point = MarketInfo(g_symbol, MODE_POINT);
   string message = "ENTRY OPENED" +
                    "\nBot: Reversal Limit TierReady MT4" +
                    "\nType: " + side + " " + mode +
                    "\nSymbol: " + g_symbol +
                    "\nLot Total: " + DoubleToString(InpLotSize, 2) +
                    "\nEntry: " + DoubleToString(entryPrice, digits) +
                    "\nSL: " + DoubleToString(sl, digits) + " (" + DoubleToString(PointsToPips(MathAbs(entryPrice - sl) / point), 1) + " pips)" +
                    "\nTP1: " + DoubleToString(tp1, digits) + " (" + DoubleToString(PointsToPips(MathAbs(tp1 - entryPrice) / point), 1) + " pips)";

   if(InpUseThreeOrderSplit)
      message += "\nTP2: " + DoubleToString(tp2, digits) + " (" + DoubleToString(PointsToPips(MathAbs(tp2 - entryPrice) / point), 1) + " pips)" +
                 "\nTP3: " + DoubleToString(tp3, digits) + " (" + DoubleToString(PointsToPips(MathAbs(tp3 - entryPrice) / point), 1) + " pips)";

   message += "\nProfit hari ini: " + DoubleToString(GetDailyPL(), 2);
   return(message);
}

string BuildCloseMessage(string side, double closePrice, double volume, double profitValue, double closePips)
{
   string message = (profitValue >= 0.0 ? "CLOSE PROFIT" : "CLOSE LOSS") +
          "\nBot: Reversal Limit TierReady MT4" +
          "\nType: " + side +
          "\nSymbol: " + g_symbol +
          "\nVolume: " + DoubleToString(volume, 2) +
          "\nClose Price: " + DoubleToString(closePrice, Digits) +
          "\nP/L: " + DoubleToString(profitValue, 2) +
          "\nPips: " + DoubleToString(closePips, 1) +
          "\nProfit hari ini: " + DoubleToString(GetDailyPL(), 2);

   if(InpSendAccountTotalSummary)
      message += "\n\n" + BuildAccountTotalSummary();

   return(message);
}

int OnInit()
{
   g_symbol = InpTradeSymbol;
   if(g_symbol == "") g_symbol = Symbol();
   if(!SymbolSelect(g_symbol, true)) return(INIT_FAILED);

   ResetDailyEquity();
   SendTelegramMessage(BuildStartupMessage());
   return(INIT_SUCCEEDED);
}

void OnTick()
{
   if(Symbol() != g_symbol && !IsTesting()) return;
   RefreshRates();
   UpdateDailyEquity();
   ManageOpenTrades();
   NotifyClosedTrades();

   if(!IsMarketSessionOpen()) return;
   if(IsDailyLimitReached()) return;

   datetime signalBar = iTime(g_symbol, InpSignalTF, 0);
   if(InpOneTradePerCandle && signalBar == g_lastSignalBarTime) return;
   if(GetSpreadPoints() > InpMaxSpreadPoints) return;

   int myTrades = CountOpenTrades();
   if(g_lastKnownOpenTrades > 0 && myTrades == 0)
      g_lastPositionExitTime = TimeCurrent();
   g_lastKnownOpenTrades = myTrades;

   if(g_lastPositionExitTime > 0 && InpReentryCooldownBars > 0)
   {
      int barsSinceExit = iBarShift(g_symbol, InpSignalTF, g_lastPositionExitTime, false);
      if(barsSinceExit >= 0 && barsSinceExit < InpReentryCooldownBars) return;
   }

   bool buySignal = false, sellSignal = false;
   GetSignals(buySignal, sellSignal);
   bool fallbackBuy = false, fallbackSell = false;
   if(InpEnableTrendFallback) GetTrendFallbackSignals(fallbackBuy, fallbackSell);

   if(myTrades > 0)
   {
      if(InpEnableReversalMode)
      {
         int currentType = GetOpenTradeType();
         if(currentType == OP_BUY && sellSignal)
         {
            CloseMyTrades();
            Sleep(InpReversalDelaySeconds * 1000);
            DeletePendingOrders();
            PlaceEntry(false, "REVERSAL SELL");
         }
         else if(currentType == OP_SELL && buySignal)
         {
            CloseMyTrades();
            Sleep(InpReversalDelaySeconds * 1000);
            DeletePendingOrders();
            PlaceEntry(true, "REVERSAL BUY");
         }
      }
      return;
   }

   if(CountPendingOrders() > 0)
   {
      if(InpRefreshStalePending) RefreshPendingOrders();
      return;
   }

   if(buySignal) PlaceEntry(true, "BOT BUY LIMIT");
   else if(sellSignal) PlaceEntry(false, "BOT SELL LIMIT");
   else if(fallbackBuy) PlaceEntryMarket(true, "TREND FALLBACK BUY");
   else if(fallbackSell) PlaceEntryMarket(false, "TREND FALLBACK SELL");
}

double GetSpreadPoints()
{
   return(MarketInfo(g_symbol, MODE_SPREAD));
}

bool IsDailyLimitReached()
{
   double dailyPL = GetDailyPL();
   if(dailyPL <= -InpDailyMaxLossMoney)
   {
      if(!g_dailyLossSent)
      {
         SendTelegramMessage("DAILY LOSS REACHED\nBot: Reversal Limit TierReady MT4\nLoss: " + DoubleToString(dailyPL, 2) + "\nTrading stop today.");
         g_dailyLossSent = true;
      }
      return(true);
   }
   if(dailyPL >= InpDailyTargetMoney)
   {
      if(!g_dailyTargetSent)
      {
         SendTelegramMessage("DAILY TARGET REACHED\nBot: Reversal Limit TierReady MT4\nProfit: " + DoubleToString(dailyPL, 2) + "\nTrading stop today.");
         g_dailyTargetSent = true;
      }
      return(true);
   }
   return(false);
}

int CountOpenTrades()
{
   int count = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol() == g_symbol && OrderMagicNumber() == InpMagicNumber && (OrderType() == OP_BUY || OrderType() == OP_SELL))
         count++;
   }
   return(count);
}

int CountPendingOrders()
{
   int count = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol() == g_symbol && OrderMagicNumber() == InpMagicNumber && OrderType() > OP_SELL)
         count++;
   }
   return(count);
}

int GetOpenTradeType()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol() == g_symbol && OrderMagicNumber() == InpMagicNumber && (OrderType() == OP_BUY || OrderType() == OP_SELL))
         return(OrderType());
   }
   return(-1);
}

void GetSignals(bool &buySignal, bool &sellSignal)
{
   buySignal = false;
   sellSignal = false;

   double trendEMA = iMA(g_symbol, InpTrendTF, InpTrendEMA, 0, MODE_EMA, PRICE_CLOSE, 1);
   double entryEMA1 = iMA(g_symbol, InpSignalTF, InpEntryEMA, 0, MODE_EMA, PRICE_CLOSE, 1);
   double entryEMA2 = iMA(g_symbol, InpSignalTF, InpEntryEMA, 0, MODE_EMA, PRICE_CLOSE, 2);
   double close1 = iClose(g_symbol, InpSignalTF, 1);
   double open1 = iOpen(g_symbol, InpSignalTF, 1);
   double high1 = iHigh(g_symbol, InpSignalTF, 1);
   double low1 = iLow(g_symbol, InpSignalTF, 1);
   double close2 = iClose(g_symbol, InpSignalTF, MathMax(2, InpSignalLookbackBars));
   double open2 = iOpen(g_symbol, InpSignalTF, 2);
   double high2 = iHigh(g_symbol, InpSignalTF, 2);
   double low2 = iLow(g_symbol, InpSignalTF, 2);
   double rsi1 = iRSI(g_symbol, InpSignalTF, InpRSIPeriod, PRICE_CLOSE, 1);
   double rsi2 = iRSI(g_symbol, InpSignalTF, InpRSIPeriod, PRICE_CLOSE, 2);
   double point = MarketInfo(g_symbol, MODE_POINT);

   bool trendBuy = iClose(g_symbol, InpTrendTF, 1) > trendEMA;
   bool trendSell = iClose(g_symbol, InpTrendTF, 1) < trendEMA;
   bool bullish = close1 > open1;
   bool bearish = close1 < open1;
   bool priceImprovingBuy = close1 >= close2;
   bool priceImprovingSell = close1 <= close2;
   double body1 = MathAbs(close1 - open1);
   double upperWick1 = high1 - MathMax(open1, close1);
   double lowerWick1 = MathMin(open1, close1) - low1;
   bool bullishPrev = close2 > open2;
   bool bearishPrev = close2 < open2;
   bool higherLow = low1 >= low2;
   bool lowerHigh = high1 <= high2;

   bool candleConfirmBuy = true;
   bool candleConfirmSell = true;
   if(InpRequireCandleConfirmation)
   {
      candleConfirmBuy = bullish && bullishPrev && higherLow &&
                         body1 >= InpMinSignalBodyPoints * point &&
                         upperWick1 <= body1 * InpMaxOppositeWickRatio;

      candleConfirmSell = bearish && bearishPrev && lowerHigh &&
                          body1 >= InpMinSignalBodyPoints * point &&
                          lowerWick1 <= body1 * InpMaxOppositeWickRatio;
   }

   buySignal = trendBuy && close1 > entryEMA1 && candleConfirmBuy && rsi1 >= InpBuyRSILevel;
   sellSignal = trendSell && close1 < entryEMA1 && candleConfirmSell && rsi1 <= InpSellRSILevel;

   if(InpUseFastEntryMode)
   {
      bool buyMomentum = rsi1 >= InpBuyRSILevel && rsi2 >= InpBuyRSILevel - 2.0;
      bool sellMomentum = rsi1 <= InpSellRSILevel && rsi2 <= InpSellRSILevel + 2.0;
      if(trendBuy && close1 > entryEMA2 && buyMomentum && priceImprovingBuy && candleConfirmBuy) buySignal = true;
      if(trendSell && close1 < entryEMA2 && sellMomentum && priceImprovingSell && candleConfirmSell) sellSignal = true;
   }
}

void GetTrendFallbackSignals(bool &buySignal, bool &sellSignal)
{
   buySignal = false;
   sellSignal = false;

   double trendEMA = iMA(g_symbol, InpTrendTF, InpTrendEMA, 0, MODE_EMA, PRICE_CLOSE, 1);
   double entryEMA = iMA(g_symbol, InpSignalTF, InpEntryEMA, 0, MODE_EMA, PRICE_CLOSE, 1);
   double close1 = iClose(g_symbol, InpSignalTF, 1);
   double open1 = iOpen(g_symbol, InpSignalTF, 1);
   double high1 = iHigh(g_symbol, InpSignalTF, 1);
   double low1 = iLow(g_symbol, InpSignalTF, 1);
   double close2 = iClose(g_symbol, InpSignalTF, 2);
   double open2 = iOpen(g_symbol, InpSignalTF, 2);
   double high2 = iHigh(g_symbol, InpSignalTF, 2);
   double low2 = iLow(g_symbol, InpSignalTF, 2);
   double rsi1 = iRSI(g_symbol, InpSignalTF, InpRSIPeriod, PRICE_CLOSE, 1);
   double point = MarketInfo(g_symbol, MODE_POINT);

   bool strongUpTrend = iClose(g_symbol, InpTrendTF, 1) > trendEMA && close1 > entryEMA && close1 > close2;
   bool strongDownTrend = iClose(g_symbol, InpTrendTF, 1) < trendEMA && close1 < entryEMA && close1 < close2;
   bool makingHigherHigh = high1 >= high2;
   bool makingLowerLow = low1 <= low2;
   double body1 = MathAbs(close1 - open1);
   bool bullishPrev = close2 > open2;
   bool bearishPrev = close2 < open2;

   buySignal = strongUpTrend && makingHigherHigh && bullishPrev && body1 >= InpMinSignalBodyPoints * point && rsi1 >= InpBuyRSILevel + 2.0;
   sellSignal = strongDownTrend && makingLowerLow && bearishPrev && body1 >= InpMinSignalBodyPoints * point && rsi1 <= InpSellRSILevel - 2.0;
}

void NormalizeTradeLevels(bool isBuy, double entryPrice, double &sl, double &tp, int digits)
{
   double point = MarketInfo(g_symbol, MODE_POINT);
   double minDistance = MathMax(MarketInfo(g_symbol, MODE_STOPLEVEL) * point, 5 * point);
   if(isBuy)
   {
      if(entryPrice - sl < minDistance) sl = entryPrice - minDistance;
      if(tp - entryPrice < minDistance) tp = entryPrice + minDistance;
   }
   else
   {
      if(sl - entryPrice < minDistance) sl = entryPrice + minDistance;
      if(entryPrice - tp < minDistance) tp = entryPrice - minDistance;
   }
   sl = NormalizeDouble(sl, digits);
   tp = NormalizeDouble(tp, digits);
}

void SendSplitEntrySummary(string side, string mode, double entryPrice, double sl, double tp1, double tp2, double tp3, int digits)
{
   SendTelegramMessage(BuildFormattedEntryMessage(side, mode, entryPrice, sl, tp1, tp2, tp3, digits));
}

bool PlaceSingleLimit(bool isBuy, double lots, double entry, double sl, double tp, string comment)
{
   int type = isBuy ? OP_BUYLIMIT : OP_SELLLIMIT;
   int ticket = OrderSend(g_symbol, type, lots, entry, InpSlippagePoints, sl, tp, comment, InpMagicNumber, TimeCurrent() + InpPendingExpiryMinutes * 60, clrGold);
   return(ticket > 0);
}

bool PlaceSingleMarket(bool isBuy, double lots, double sl, double tp, string comment)
{
   double price = isBuy ? Ask : Bid;
   int type = isBuy ? OP_BUY : OP_SELL;
   int ticket = OrderSend(g_symbol, type, lots, price, InpSlippagePoints, sl, tp, comment, InpMagicNumber, 0, clrGold);
   return(ticket > 0);
}

void PlaceEntry(bool isBuy, string reason)
{
   double point = MarketInfo(g_symbol, MODE_POINT);
   int digits = (int)MarketInfo(g_symbol, MODE_DIGITS);
   double ask = MarketInfo(g_symbol, MODE_ASK);
   double bid = MarketInfo(g_symbol, MODE_BID);
   double minDistance = MathMax(MarketInfo(g_symbol, MODE_STOPLEVEL) * point, 5 * point);
   double offset = MathMax(InpLimitOffsetPoints * point, minDistance);
   double entry = isBuy ? ask - offset : bid + offset;
   double sl = isBuy ? entry - InpStopLossPoints * point : entry + InpStopLossPoints * point;
   double tp1 = isBuy ? entry + InpTakeProfitPoints * point : entry - InpTakeProfitPoints * point;
   double tp2 = isBuy ? entry + (InpTakeProfitPoints * InpTP2Multiplier) * point : entry - (InpTakeProfitPoints * InpTP2Multiplier) * point;
   double tp3 = isBuy ? entry + (InpTakeProfitPoints * InpTP3Multiplier) * point : entry - (InpTakeProfitPoints * InpTP3Multiplier) * point;

   entry = NormalizeDouble(entry, digits);
   NormalizeTradeLevels(isBuy, entry, sl, tp1, digits);
   NormalizeTradeLevels(isBuy, entry, sl, tp2, digits);
   NormalizeTradeLevels(isBuy, entry, sl, tp3, digits);

   string side = isBuy ? "BUY" : "SELL";
   double lot1 = NormalizeLots(InpLotSize / 3.0);
   double lot2 = NormalizeLots(InpLotSize / 3.0);
   double lot3 = NormalizeLots(InpLotSize - lot1 - lot2);
   if(lot3 <= 0.0) lot3 = lot2;

   bool result = false;
   if(InpUseLimitOrders)
   {
      if(InpUseThreeOrderSplit)
      {
         bool ok1 = PlaceSingleLimit(isBuy, lot1, entry, sl, tp1, reason + " TP1");
         bool ok2 = PlaceSingleLimit(isBuy, lot2, entry, sl, tp2, reason + " TP2");
         bool ok3 = PlaceSingleLimit(isBuy, lot3, entry, sl, tp3, reason + " TP3");
         result = ok1 || ok2 || ok3;
      }
      else
      {
         result = PlaceSingleLimit(isBuy, InpLotSize, entry, sl, tp1, reason);
      }

      if(result)
      {
         g_lastSignalBarTime = iTime(g_symbol, InpSignalTF, 0);
         if(InpUseThreeOrderSplit) SendSplitEntrySummary(side, "LIMIT SPLIT", entry, sl, tp1, tp2, tp3, digits);
         else SendTelegramMessage(BuildFormattedEntryMessage(side, "LIMIT", entry, sl, tp1, tp2, tp3, digits));
         return;
      }

      if(!InpFallbackMarketIfRejected) return;
   }

   PlaceEntryMarket(isBuy, reason + " MARKET");
}

void PlaceEntryMarket(bool isBuy, string reason)
{
   double point = MarketInfo(g_symbol, MODE_POINT);
   int digits = (int)MarketInfo(g_symbol, MODE_DIGITS);
   double entry = isBuy ? Ask : Bid;
   double sl = isBuy ? entry - InpStopLossPoints * point : entry + InpStopLossPoints * point;
   double tp1 = isBuy ? entry + InpTakeProfitPoints * point : entry - InpTakeProfitPoints * point;
   double tp2 = isBuy ? entry + (InpTakeProfitPoints * InpTP2Multiplier) * point : entry - (InpTakeProfitPoints * InpTP2Multiplier) * point;
   double tp3 = isBuy ? entry + (InpTakeProfitPoints * InpTP3Multiplier) * point : entry - (InpTakeProfitPoints * InpTP3Multiplier) * point;

   NormalizeTradeLevels(isBuy, entry, sl, tp1, digits);
   NormalizeTradeLevels(isBuy, entry, sl, tp2, digits);
   NormalizeTradeLevels(isBuy, entry, sl, tp3, digits);

   string side = isBuy ? "BUY" : "SELL";
   double lot1 = NormalizeLots(InpLotSize / 3.0);
   double lot2 = NormalizeLots(InpLotSize / 3.0);
   double lot3 = NormalizeLots(InpLotSize - lot1 - lot2);
   if(lot3 <= 0.0) lot3 = lot2;

   bool result = false;
   if(InpUseThreeOrderSplit)
   {
      bool ok1 = PlaceSingleMarket(isBuy, lot1, sl, tp1, reason + " TP1");
      bool ok2 = PlaceSingleMarket(isBuy, lot2, sl, tp2, reason + " TP2");
      bool ok3 = PlaceSingleMarket(isBuy, lot3, sl, tp3, reason + " TP3");
      result = ok1 || ok2 || ok3;
   }
   else
   {
      result = PlaceSingleMarket(isBuy, InpLotSize, sl, tp1, reason);
   }

   if(result)
   {
      g_lastSignalBarTime = iTime(g_symbol, InpSignalTF, 0);
      if(InpUseThreeOrderSplit) SendSplitEntrySummary(side, "MARKET SPLIT", entry, sl, tp1, tp2, tp3, digits);
      else SendTelegramMessage(BuildFormattedEntryMessage(side, "MARKET", entry, sl, tp1, tp2, tp3, digits));
   }
}

void ManageOpenTrades()
{
   double point = MarketInfo(g_symbol, MODE_POINT);
   int digits = (int)MarketInfo(g_symbol, MODE_DIGITS);

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol() != g_symbol || OrderMagicNumber() != InpMagicNumber) continue;
      if(OrderType() != OP_BUY && OrderType() != OP_SELL) continue;

      double openPrice = OrderOpenPrice();
      double sl = OrderStopLoss();
      double tp = OrderTakeProfit();
      double newSL = sl;
      bool modify = false;

      if(OrderType() == OP_BUY)
      {
         double profitPoints = (Bid - openPrice) / point;
         if(InpUseAutoSLPlus && profitPoints >= InpSLPlusTriggerPoints)
         {
            double slPlus = NormalizeDouble(openPrice + InpSLPlusLockPoints * point, digits);
            if(sl == 0.0 || slPlus > newSL) { newSL = slPlus; modify = true; }
         }
         if(InpUseTrailingStop && profitPoints >= InpTrailStartPoints)
         {
            double trailSL = NormalizeDouble(Bid - InpTrailStepPoints * point, digits);
            if(trailSL > newSL) { newSL = trailSL; modify = true; }
         }
      }
      else
      {
         double profitPoints = (openPrice - Ask) / point;
         if(InpUseAutoSLPlus && profitPoints >= InpSLPlusTriggerPoints)
         {
            double slPlus = NormalizeDouble(openPrice - InpSLPlusLockPoints * point, digits);
            if(sl == 0.0 || newSL == 0.0 || slPlus < newSL) { newSL = slPlus; modify = true; }
         }
         if(InpUseTrailingStop && profitPoints >= InpTrailStartPoints)
         {
            double trailSL = NormalizeDouble(Ask + InpTrailStepPoints * point, digits);
            if(newSL == 0.0 || trailSL < newSL) { newSL = trailSL; modify = true; }
         }
      }

      if(modify) OrderModify(OrderTicket(), openPrice, newSL, tp, 0, clrNONE);
   }
}

void CloseMyTrades()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol() != g_symbol || OrderMagicNumber() != InpMagicNumber) continue;
      if(OrderType() != OP_BUY && OrderType() != OP_SELL) continue;
      bool ok = OrderClose(OrderTicket(), OrderLots(), OrderType() == OP_BUY ? Bid : Ask, InpSlippagePoints, clrRed);
      if(!ok) Print("OrderClose failed: ", GetLastError());
   }
}

void DeletePendingOrders()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol() != g_symbol || OrderMagicNumber() != InpMagicNumber) continue;
      if(OrderType() > OP_SELL) OrderDelete(OrderTicket());
   }
}

void RefreshPendingOrders()
{
   double point = MarketInfo(g_symbol, MODE_POINT);
   double refreshDistance = MathMax(InpLimitOffsetPoints * point * 3.0, 120 * point);
   datetime signalBar = iTime(g_symbol, InpSignalTF, 0);

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol() != g_symbol || OrderMagicNumber() != InpMagicNumber) continue;
      if(OrderType() == OP_BUYLIMIT && MathAbs(Ask - OrderOpenPrice()) > refreshDistance)
      {
         if(OrderDelete(OrderTicket())) PlaceEntry(true, "REFRESH BUY LIMIT");
         return;
      }
      if(OrderType() == OP_SELLLIMIT && MathAbs(OrderOpenPrice() - Bid) > refreshDistance)
      {
         if(OrderDelete(OrderTicket())) PlaceEntry(false, "REFRESH SELL LIMIT");
         return;
      }
   }
}

void NotifyClosedTrades()
{
   int historyCount = OrdersHistoryTotal();
   if(historyCount == g_lastHistoryCount) return;
   g_lastHistoryCount = historyCount;

   for(int i = OrdersHistoryTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_HISTORY)) continue;
      if(OrderSymbol() != g_symbol || OrderMagicNumber() != InpMagicNumber) continue;

      double entryPrice = OrderOpenPrice();
      double closePrice = OrderClosePrice();
      double point = MarketInfo(g_symbol, MODE_POINT);
      double closePips = PointsToPips(MathAbs(closePrice - entryPrice) / point);
      double pl = OrderProfit() + OrderSwap() + OrderCommission();
      string side = OrderType() == OP_BUY ? "BUY" : "SELL";

      SendTelegramMessage(BuildCloseMessage(side, closePrice, OrderLots(), pl, closePips));
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

   ResetLastError();
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
