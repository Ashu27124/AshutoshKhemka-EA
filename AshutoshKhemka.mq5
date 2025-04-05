//+------------------------------------------------------------------+
//|                                               AshutoshKhemka.mq5 |
//|                                  Copyright 2025, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version   "1.00"

#include <Trade/Trade.mqh>
#include <Trade/SymbolInfo.mqh>

// Input parameters
input ENUM_TIMEFRAMES      TimeFrame      = PERIOD_M5; // TimeFrame
input int                  MovingAverage  = 9;        // Moving Average
input double               TakeProfit     = 1000;     // Take Profit in points
input int                  Volume         = 5;        // Initial contract volume
input string               StartTime      = "09:00";  // Start time for new trades
input string               EndTime        = "16:00";  // End time for new trades
input string               CloseTime      = "17:30";  // Closing time for open positions
input double               ProfitLimit    = 1000;     // Daily profit limit
input double               LossLimit      = 500;      // Daily loss limit
input double               BreakEven      = 500;      // Points to activate break-even
input double               PartialProfit  = 500;      // Points to take partial profit
input int                  PartialVol     = 3;        // Contracts for partial profit

// Expert Advisor (EA) identifier
int magic_number = 1234; 

// Moving average handler
int moving_average_handle;

// Symbol information
CSymbolInfo symbol; 
CTrade       trade;

// Time control structures
MqlDateTime start_time, end_time, close_time;

// New candle verification
static datetime last_bar_time = 0;

// Day‑tracking
static datetime day_start_time = 0;
static double   day_profit    = 0;
static double   day_loss      = 0;

// Enum for buy/sell signals
enum ENUM_SIGNAL {BUY = 1, SELL  = -1, NONE   = 0};

// Stores the last trade signal
ENUM_SIGNAL last_signal;

//+------------------------------------------------------------------+
//| Validate inputs and initialize EA                                 |
//+------------------------------------------------------------------+
int OnInit()
  {
   if(!symbol.Name(_Symbol))
     {
      Print("Error loading symbol.");
      return(INIT_FAILED);
     }

   moving_average_handle = iMA(_Symbol, TimeFrame, MovingAverage, 0, MODE_EMA, PRICE_CLOSE);
   if(moving_average_handle < 0)
     {
      Print("Error initializing moving average.");
      return(INIT_FAILED);
     }

   // Initialize time variables
   TimeToStruct(StringToTime(StartTime), start_time);
   TimeToStruct(StringToTime(EndTime),   end_time);
   TimeToStruct(StringToTime(CloseTime), close_time);

   last_signal = NONE;
   day_start_time = iTime(_Symbol, PERIOD_D1, 0);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Detect a new trading day                                          |
//+------------------------------------------------------------------+
bool IsNewDay()
  {
   datetime today = iTime(_Symbol, PERIOD_D1, 0);
   if(today != day_start_time)
     {
      // reset counters
      day_start_time = today;
      day_profit = 0;
      day_loss   = 0;
      return(true);
     }
   return(false);
  }

//+------------------------------------------------------------------+
//| Detect a new completed candle on chosen timeframe                 |
//+------------------------------------------------------------------+
bool IsNewCandle()
  {
   datetime bar_time = iTime(_Symbol, TimeFrame, 0);
   if(bar_time != last_bar_time)
     {
      last_bar_time = bar_time;
      return(true);
     }
   return(false);
  }

//+------------------------------------------------------------------+
//| Check daily profit / loss limits                                  |
//+------------------------------------------------------------------+
bool CheckLimits()
  {
   double equity_now  = AccountInfoDouble(ACCOUNT_EQUITY);
   double profit_now  = AccountInfoDouble(ACCOUNT_PROFIT);
   double today_pl    = profit_now - (day_profit - day_loss);

   if(today_pl >= ProfitLimit)
     {
      Print("Daily profit limit reached.");
      return(true);
     }
   if(today_pl <= -LossLimit)
     {
      Print("Daily loss limit reached.");
      return(true);
     }
   return(false);
  }

//+------------------------------------------------------------------+
//| Generate trading signal                                           |
//+------------------------------------------------------------------+
ENUM_SIGNAL CheckSignal()
  {
   double ma[];
   double close[];
   if(CopyBuffer(moving_average_handle, 0, 1, 2, ma) != 2) return(NONE);
   if(CopyClose(_Symbol, TimeFrame, 1, 2, close) != 2)     return(NONE);

   if(close[0] > ma[0]) return(BUY);
   if(close[0] < ma[0]) return(SELL);
   return(NONE);
  }

//+------------------------------------------------------------------+
//| Manage existing open positions                                    |
//+------------------------------------------------------------------+
void ManageOpenPositions(ENUM_SIGNAL signal)
  {
   for(int i=PositionsTotal()-1; i>=0; i--)
     {
      ulong   ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic_number) continue;

      double entry_price = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl          = PositionGetDouble(POSITION_SL);
      double tp          = PositionGetDouble(POSITION_TP);
      long   type        = PositionGetInteger(POSITION_TYPE);

      // Close if opposite signal appears
      if((signal == BUY && type == POSITION_TYPE_SELL) || (signal == SELL && type == POSITION_TYPE_BUY))
         trade.PositionClose(ticket);

      // Update trailing stop / break‑even
      double current_price = (type==POSITION_TYPE_BUY)?symbol.Bid():symbol.Ask();
      double distance      = (type==POSITION_TYPE_BUY)?(current_price-entry_price):(entry_price-current_price);

      if(distance*symbol.Point() >= BreakEven && sl == 0)
        {
         double new_sl = entry_price;
         trade.PositionModify(ticket, new_sl, tp);
        }
     }
  }

//+------------------------------------------------------------------+
//| Cancel opposite pending orders                                    |
//+------------------------------------------------------------------+
void ClosePendingOrders(ENUM_SIGNAL signal)
  {
   for(int i=OrdersTotal()-1; i>=0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(!OrderSelect(ticket)) continue;
      if(OrderGetInteger(ORDER_MAGIC) != magic_number) continue;

      long type = OrderGetInteger(ORDER_TYPE);
      if((signal==BUY && (type==ORDER_TYPE_SELL_LIMIT||type==ORDER_TYPE_SELL_STOP)) ||
         (signal==SELL && (type==ORDER_TYPE_BUY_LIMIT||type==ORDER_TYPE_BUY_STOP)))
         trade.OrderDelete(ticket);
     }
  }

//+------------------------------------------------------------------+
//| Take partial profits                                              |
//+------------------------------------------------------------------+
void ManagePartialProfit()
  {
   for(int i=PositionsTotal()-1; i>=0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic_number) continue;

      long   type        = PositionGetInteger(POSITION_TYPE);
      double entry_price = PositionGetDouble(POSITION_PRICE_OPEN);
      double current     = (type==POSITION_TYPE_BUY)?symbol.Bid():symbol.Ask();
      double distance    = (type==POSITION_TYPE_BUY)?(current-entry_price):(entry_price-current);

      if(distance*symbol.Point() >= PartialProfit && PositionGetDouble(POSITION_VOLUME) >= PartialVol)
        {
         trade.PositionClosePartial(ticket, PartialVol);
        }
     }
  }

//+------------------------------------------------------------------+
//| Additional break‑even logic (handled in ManageOpenPositions)      |
//+------------------------------------------------------------------+
void ApplyBreakEven(){}

//+------------------------------------------------------------------+
//| Open new trades if conditions met                                 |
//+------------------------------------------------------------------+
void ExecuteNewTrade(ENUM_SIGNAL signal)
  {
   if(signal == NONE) return;

   // Check trading window
   datetime now = TimeCurrent();
   MqlDateTime st, et; TimeToStruct(now, st); et = st;
   st.hour = start_time.hour; st.min = start_time.min;
   et.hour = end_time.hour;   et.min = end_time.min;

   if(now < StructToTime(st) || now > StructToTime(et)) return;

   // Avoid multiple positions in same direction
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      if(!PositionSelectByIndex(i)) continue;
      if(PositionGetInteger(POSITION_MAGIC) == magic_number && PositionGetInteger(POSITION_TYPE) == ((signal==BUY)?POSITION_TYPE_BUY:POSITION_TYPE_SELL))
         return;
     }

   double sl = 0; // could be set to opposite side of MA, left 0 for simplicity
   double tp = (signal==BUY)?(symbol.Ask()+TakeProfit*symbol.Point()):(symbol.Bid()-TakeProfit*symbol.Point());

   trade.SetExpertMagicNumber(magic_number);
   trade.SetDeviationInPoints(10);
   if(signal==BUY)
      trade.Buy(Volume, NULL, symbol.Ask(), sl, tp);
   else if(signal==SELL)
      trade.Sell(Volume, NULL, symbol.Bid(), sl, tp);
  }

//+------------------------------------------------------------------+
//| Close all trades at daily close time                              |
//+------------------------------------------------------------------+
void CheckClosingTime()
  {
   datetime now = TimeCurrent();
   MqlDateTime ct; TimeToStruct(now, ct);
   if(ct.hour == close_time.hour && ct.min >= close_time.min)
     {
      for(int i=PositionsTotal()-1;i>=0;i--)
        {
         ulong ticket = PositionGetTicket(i);
         if(!PositionSelectByTicket(ticket)) continue;
         if(PositionGetInteger(POSITION_MAGIC) != magic_number) continue;
         trade.PositionClose(ticket);
        }
     }
  }

//+------------------------------------------------------------------+
//| Event triggered on EA de‑initialization                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   Print("EA stopped. Reason:", reason);
  }

//+------------------------------------------------------------------+
//| Event triggered on each new tick                                  |
//+------------------------------------------------------------------+
void OnTick()
  {
   if(!symbol.RefreshRates()) return;

   if(IsNewDay()) last_signal = NONE;

   if(last_signal == NONE)
      last_signal = CheckSignal();

   if(!IsNewCandle()) return;

   if(CheckLimits()) return;

   ENUM_SIGNAL signal = CheckSignal();

   ManageOpenPositions(signal);
   ClosePendingOrders(signal);
   ManagePartialProfit();
   ApplyBreakEven();
   ExecuteNewTrade(signal);
   CheckClosingTime();
  }

//+------------------------------------------------------------------+
