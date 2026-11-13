//+------------------------------------------------------------------+
//| CAuraScanner.mqh — scanner de zonas áureas (símbolo × TF)        |
//| Capa: Scanner                                                     |
//|                                                                  |
//| Igual que EMAScan: símbolos de Observación del Mercado y TFs del  |
//| más grande al más chico, con exclusiones por input. La estrategia |
//| corre de M5 para arriba, así que M1–M4 no se escanean.            |
//|                                                                  |
//| Corre DENTRO del EA (un EA sí puede pedir velas de otros          |
//| símbolos). Procesa pocos pares por llamada a Step() para no       |
//| trabar el gráfico: el EA lo llama desde OnTimer.                  |
//| Un par sin historia todavía (CopyRates corto) queda pendiente y   |
//| se reintenta en la pasada siguiente.                              |
//+------------------------------------------------------------------+
#ifndef AURAX_SCANNER_MQH
#define AURAX_SCANNER_MQH

#include <AuraX/Strategy/CAuraFibo.mqh>

// TFs del scan, GRANDE→CHICO (mismo orden canónico que EMAScan), solo M5 en adelante.
const ENUM_TIMEFRAMES AURA_SCAN_TFS[] =
{
   PERIOD_D1,  PERIOD_H12, PERIOD_H8,  PERIOD_H6,
   PERIOD_H4,  PERIOD_H3,  PERIOD_H2,  PERIOD_H1,
   PERIOD_M30, PERIOD_M20, PERIOD_M15, PERIOD_M12,
   PERIOD_M10, PERIOD_M6,  PERIOD_M5
};

string AuraTFLabel(ENUM_TIMEFRAMES tf)
{
   switch(tf)
   {
      case PERIOD_M1:  return "M1";    case PERIOD_M2:  return "M2";
      case PERIOD_M3:  return "M3";    case PERIOD_M4:  return "M4";
      case PERIOD_M5:  return "M5";    case PERIOD_M6:  return "M6";
      case PERIOD_M10: return "M10";   case PERIOD_M12: return "M12";
      case PERIOD_M15: return "M15";   case PERIOD_M20: return "M20";
      case PERIOD_M30: return "M30";   case PERIOD_H1:  return "H1";
      case PERIOD_H2:  return "H2";    case PERIOD_H3:  return "H3";
      case PERIOD_H4:  return "H4";    case PERIOD_H6:  return "H6";
      case PERIOD_H8:  return "H8";    case PERIOD_H12: return "H12";
      case PERIOD_D1:  return "D1";    case PERIOD_W1:  return "W1";
      case PERIOD_MN1: return "MN";
   }
   return EnumToString(tf);
}

// Sesgo de spike por familia de símbolo (igual que EmaRiskPro):
// Gain = solo compras, Pain = solo ventas, el resto las dos.
void AuraSymbolBias(const string sym, const string gainPfx, const string painPfx,
                    bool &allowBuy, bool &allowSell)
{
   allowBuy = true; allowSell = true;
   if(StringLen(gainPfx) > 0 && StringFind(sym, gainPfx) == 0) { allowSell = false; return; }
   if(StringLen(painPfx) > 0 && StringFind(sym, painPfx) == 0) { allowBuy  = false; return; }
}

//+------------------------------------------------------------------+
//| SAuraScanRow — resultado de un par símbolo × TF                   |
//+------------------------------------------------------------------+
struct SAuraScanRow
{
   string          sym;
   ENUM_TIMEFRAMES tf;
   bool            scanned;   // ya tuvo al menos una pasada con historia completa
   SAuraSetup      setup;     // setup.valid=false → sin Fibo vigente
   double          posNow;    // posición del precio actual en el Fibo (0.38 = Av1, etc.)
};

//+------------------------------------------------------------------+
//| CAuraScanner                                                      |
//+------------------------------------------------------------------+
class CAuraScanner
{
public:
   CAuraScanner() : m_bars(400), m_next(0), m_passDone(false), m_newCount(0) {}

   //| Configuración — llamar antes de BuildList().
   void Configure(int bars, int maxLeg, const string excludedTFs, const string excludedSyms,
                  const string gainPfx, const string painPfx)
   {
      m_bars    = MathMax(100, bars);
      m_engine.SetMaxLeg(maxLeg);
      m_exTFs   = "," + _Clean(excludedTFs) + ",";
      m_exSyms  = "," + _Clean(excludedSyms) + ",";
      m_gainPfx = gainPfx;
      m_painPfx = painPfx;
   }

   //| (Re)arma la lista de pares desde Observación del Mercado.
   //| Conserva los resultados de pares que siguen en la lista.
   void BuildList()
   {
      SAuraScanRow old[];
      int nOld = ArraySize(m_rows);
      ArrayResize(old, nOld);
      for(int i = 0; i < nOld; i++) old[i] = m_rows[i];

      ArrayResize(m_rows, 0);
      int nSym = SymbolsTotal(true);
      for(int t = 0; t < ArraySize(AURA_SCAN_TFS); t++)
      {
         ENUM_TIMEFRAMES tf = AURA_SCAN_TFS[t];
         if(StringFind(m_exTFs, "," + AuraTFLabel(tf) + ",") >= 0) continue;
         for(int s = 0; s < nSym; s++)
         {
            string sym = SymbolName(s, true);
            string symU = sym;
            StringToUpper(symU);
            if(StringFind(m_exSyms, "," + symU + ",") >= 0) continue;
            int k = ArraySize(m_rows);
            ArrayResize(m_rows, k + 1);
            ZeroMemory(m_rows[k].setup);
            m_rows[k].sym     = sym;
            m_rows[k].tf      = tf;
            m_rows[k].scanned = false;
            m_rows[k].posNow  = 0.0;
            for(int i = 0; i < nOld; i++)
               if(old[i].sym == sym && old[i].tf == tf) { m_rows[k] = old[i]; break; }
         }
      }
      if(m_next >= ArraySize(m_rows)) m_next = 0;
   }

   //| Procesa hasta `budget` pares. Devuelve true al completar una pasada entera.
   bool Step(int budget)
   {
      int n = ArraySize(m_rows);
      if(n == 0) return true;
      bool wrapped = false;
      for(int b = 0; b < budget && b < n; b++)
      {
         _ScanOne(m_next);
         m_next++;
         if(m_next >= n) { m_next = 0; wrapped = true; m_passDone = true; }
      }
      return wrapped;
   }

   //| Refresca solo la posición del precio actual (barato, sin re-detectar).
   void RefreshPrices()
   {
      for(int i = 0; i < ArraySize(m_rows); i++)
         if(m_rows[i].setup.valid) m_rows[i].posNow = _PosNow(m_rows[i]);
   }

   int  Count() const          { return ArraySize(m_rows); }
   bool PassDone() const       { return m_passDone; }
   void GetRow(int i, SAuraScanRow &r) const { r = m_rows[i]; }

   //| Novedades: pares que acaban de llegar a Av1 (o a una zona más lejana)
   //| desde la última consulta. Texto listo para mostrar/notificar.
   int ConsumeNews(string &msgs[])
   {
      int c = m_newCount;
      ArrayResize(msgs, c);
      for(int i = 0; i < c; i++) msgs[i] = m_news[i];
      m_newCount = 0;
      ArrayResize(m_news, 0);
      return c;
   }

private:
   CAuraFiboEngine m_engine;
   SAuraScanRow    m_rows[];
   int             m_bars, m_next;
   bool            m_passDone;
   string          m_exTFs, m_exSyms, m_gainPfx, m_painPfx;
   string          m_news[];
   int             m_newCount;

   string _Clean(const string s) const
   {
      string r = s;
      StringReplace(r, " ", "");
      StringToUpper(r);
      return r;
   }

   double _PosNow(const SAuraScanRow &r) const
   {
      double px = r.setup.isBuy ? SymbolInfoDouble(r.sym, SYMBOL_ASK)
                                : SymbolInfoDouble(r.sym, SYMBOL_BID);
      if(px <= 0.0) return 0.0;
      return AuraExt(r.setup, px);
   }

   void _ScanOne(int i)
   {
      MqlRates rates[];
      int got = AuraLoadRates(m_rows[i].sym, m_rows[i].tf, m_bars, rates);
      if(got < 50) return;   // historia todavía cargando → se reintenta en la próxima pasada

      bool allowBuy, allowSell;
      AuraSymbolBias(m_rows[i].sym, m_gainPfx, m_painPfx, allowBuy, allowSell);

      SAuraSetup prev = m_rows[i].setup;
      SAuraSetup cur;
      m_engine.Evaluate(rates, got, m_rows[i].tf, allowBuy, allowSell, cur);
      m_rows[i].setup   = cur;
      m_rows[i].posNow  = cur.valid ? _PosNow(m_rows[i]) : 0.0;

      // Novedad solo después de la primera pasada (al arrancar no se avisa todo lo viejo)
      bool wasScanned = m_rows[i].scanned;
      m_rows[i].scanned = true;
      if(!wasScanned || !cur.valid || cur.state != AURA_ST_ACTIVE) return;

      EAuraZone zNow  = AuraZoneOf(AuraExt(cur, cur.xExt));
      EAuraZone zPrev = AURA_Z_NONE;
      if(prev.valid && prev.state == AURA_ST_ACTIVE && prev.t0 == cur.t0)
         zPrev = AuraZoneOf(AuraExt(prev, prev.xExt));
      if(zNow <= zPrev) return;

      string msg = StringFormat("%s %s %s → %s", m_rows[i].sym, AuraTFLabel(m_rows[i].tf),
                                cur.isBuy ? "COMPRA" : "VENTA", AuraZoneName(zNow));
      ArrayResize(m_news, m_newCount + 1);
      m_news[m_newCount++] = msg;
   }
};

#endif // AURAX_SCANNER_MQH
