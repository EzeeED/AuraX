//+------------------------------------------------------------------+
//| CAuraFibo.mqh — Motor de la estrategia "Zonas Áureas" (AuraX)    |
//| Capa: Strategy                                                    |
//|                                                                  |
//| Detección SOLO con velas (sin EMAs) — reglas del dueño            |
//| (chat 2026-11-13):                                                |
//|   · Último impulso: retroceso de mínimo 3 velas + impulso de      |
//|     mínimo 3 velas. Las velas se cuentan por COLOR de cierre y no |
//|     tienen que ser seguidas. Se marca de mecha a mecha.           |
//|   · El impulso tiene que romper el extremo previo al retroceso    |
//|     (ZONA) con más cuerpo que mecha.                              |
//|   · Fibo sobre el impulso entero: 0 = donde ARRANCÓ el impulso,   |
//|     1 = donde TERMINÓ. Las zonas son extensiones negativas:       |
//|        Av1 -0.38 · Av2 -0.68 · Av3 -1 · Última zona -1.618 ·      |
//|        Engaño -2 · No Fasha -2.236                                |
//|   · Impulso bajista → zonas ARRIBA del 0 → se buscan VENTAS.      |
//|     Impulso alcista → zonas ABAJO del 0 → se buscan COMPRAS.      |
//|   · Desde Av1 ya se puede entrar.                                 |
//|   · Llegó a Av1/Av2 y hace 3 velas de retroceso → pagó. En M15 o  |
//|     más se marca el SIGUIENTE Fibo, UNA sola vez (regla 5).       |
//|   · Llegó a Av3 o más → TP por porcentaje FIJO por zona, medido   |
//|     en un Fibo desde el fin del impulso (1) hasta el extremo:     |
//|        Av3 14% · Última zona 21% · Engaño 30% · No Fasha 35%      |
//|     (un poco antes de la zona objetivo: "no al pip").             |
//|   · Vela que CIERRA con cuerpo más allá de No Fasha → stop.       |
//|                                                                  |
//| Implementación: todo se calcula en "espacio VENTA". Para compras  |
//| se invierten los precios (high↔−low, open/close → −open/−close),  |
//| así una sola lógica sirve para las dos direcciones.               |
//+------------------------------------------------------------------+
#ifndef AURAX_FIBO_MQH
#define AURAX_FIBO_MQH

//-- Niveles del Fibo (valor absoluto de la extensión negativa) ─────
#define AURA_LVL_AV1     0.38
#define AURA_LVL_AV2     0.68
#define AURA_LVL_AV3     1.0
#define AURA_LVL_FINAL   1.618
#define AURA_LVL_ENGANO  2.0
#define AURA_LVL_NOFASHA 2.236

//-- TP fijo por zona alcanzada (% del Fibo fin-del-impulso → extremo) ──
// Valores exactos que caen justo en la zona objetivo: 16 / 23.6 / 33.3 / 38.2.
// Decisión del dueño: un poco antes ("no al pip") y NO editables.
#define AURA_TP_PCT_AV3      0.14   // llegó a Av3         → TP cerca de Av2
#define AURA_TP_PCT_FINAL    0.21   // llegó a Última zona → TP cerca de Av3
#define AURA_TP_PCT_ENGANO   0.30   // llegó a Engaño      → TP cerca de Av3
#define AURA_TP_PCT_NOFASHA  0.35   // tocó No Fasha       → TP cerca de Av3

#define AURA_MIN_CANDLES     3      // velas mínimas de retroceso / impulso / pago
#define AURA_REANCHOR_MIN_TF PERIOD_M15   // regla 5: "de M15 en adelante"

//-- Zona alcanzada (índice) ────────────────────────────────────────
enum EAuraZone
{
   AURA_Z_NONE = 0,   // todavía no llegó a Av1
   AURA_Z_AV1,
   AURA_Z_AV2,
   AURA_Z_AV3,
   AURA_Z_FINAL,
   AURA_Z_ENGANO,
   AURA_Z_NOFASHA
};

//-- Estado del setup ───────────────────────────────────────────────
enum EAuraState
{
   AURA_ST_ARMED = 0,  // impulso marcado, esperando que el precio llegue a Av1
   AURA_ST_ACTIVE,     // el precio llegó a Av1 — zona operable (se puede entrar)
   AURA_ST_PAID        // ya pagó (3 velas de retroceso o TP por zona)
};

//+------------------------------------------------------------------+
//| SAuraSetup — un Fibo de zonas áureas en PRECIOS REALES           |
//+------------------------------------------------------------------+
struct SAuraSetup
{
   bool       valid;
   bool       isBuy;       // true = impulso alcista → se buscan compras
   double     p0;          // nivel 0   — donde arrancó el impulso
   double     p1;          // nivel 1   — donde terminó el impulso
   datetime   t0;          // vela del 0
   datetime   t1;          // vela del 1
   datetime   tBreak;      // vela que confirmó el impulso (o el re-marcado de la regla 5)
   datetime   tTouch;      // vela que llegó a Av1 (0 = todavía no)
   double     xExt;        // extremo alcanzado más allá del 0 (precio)
   datetime   tExt;        // vela de ese extremo
   EAuraState state;
   bool       reanchored;  // ya se usó la regla 5 (siguiente Fibo, una sola vez)
};

//+------------------------------------------------------------------+
//| Helpers de niveles — válidos para compra y venta                  |
//+------------------------------------------------------------------+
// Precio del nivel k (k positivo = extensión del lado de las zonas).
double AuraLevel(const SAuraSetup &s, double k)
{
   return s.p0 + k * (s.p0 - s.p1);
}

// Cuántas "unidades de impulso" se alejó el precio x más allá del 0.
double AuraExt(const SAuraSetup &s, double x)
{
   double unit = s.p0 - s.p1;
   if(unit == 0.0) return 0.0;
   return (x - s.p0) / unit;
}

// Zona que corresponde a una extensión.
EAuraZone AuraZoneOf(double ext)
{
   if(ext >= AURA_LVL_NOFASHA) return AURA_Z_NOFASHA;
   if(ext >= AURA_LVL_ENGANO)  return AURA_Z_ENGANO;
   if(ext >= AURA_LVL_FINAL)   return AURA_Z_FINAL;
   if(ext >= AURA_LVL_AV3)     return AURA_Z_AV3;
   if(ext >= AURA_LVL_AV2)     return AURA_Z_AV2;
   if(ext >= AURA_LVL_AV1)     return AURA_Z_AV1;
   return AURA_Z_NONE;
}

string AuraZoneName(EAuraZone z)
{
   switch(z)
   {
      case AURA_Z_AV1:     return "Av1";
      case AURA_Z_AV2:     return "Av2";
      case AURA_Z_AV3:     return "Av3";
      case AURA_Z_FINAL:   return "Última zona";
      case AURA_Z_ENGANO:  return "Engaño";
      case AURA_Z_NOFASHA: return "No Fasha";
   }
   return "-";
}

// % de TP fijo según la zona más lejana alcanzada (0 = se paga por 3 velas, no por %).
double AuraTpPct(EAuraZone z)
{
   switch(z)
   {
      case AURA_Z_AV3:     return AURA_TP_PCT_AV3;
      case AURA_Z_FINAL:   return AURA_TP_PCT_FINAL;
      case AURA_Z_ENGANO:  return AURA_TP_PCT_ENGANO;
      case AURA_Z_NOFASHA: return AURA_TP_PCT_NOFASHA;
   }
   return 0.0;
}

// Precio de TP por zona: Fibo desde el fin del impulso (p1) hasta el extremo x.
// 0 = la zona alcanzada todavía no usa TP por % (Av1/Av2 → pago por 3 velas).
double AuraTpPrice(const SAuraSetup &s, double x)
{
   double pct = AuraTpPct(AuraZoneOf(AuraExt(s, x)));
   if(pct <= 0.0) return 0.0;
   return x - pct * (x - s.p1);
}

//+------------------------------------------------------------------+
//| CAuraFiboEngine — recorre las velas CERRADAS y devuelve el        |
//| último setup vigente. Sin estado entre llamadas: la misma         |
//| historia da siempre el mismo resultado (chart y scanner coinciden)|
//+------------------------------------------------------------------+
class CAuraFiboEngine
{
public:
   CAuraFiboEngine() : m_maxLeg(150), m_n(0) {}

   //| maxLeg — máximo de velas que se mira para cada tramo.
   void SetMaxLeg(int v) { m_maxLeg = MathMax(10, v); }

   //+----------------------------------------------------------------+
   //| Evaluate — rates en orden cronológico (0 = más vieja), SOLO     |
   //| velas cerradas. allowBuy/allowSell: sesgo del símbolo           |
   //| (Pain = solo ventas, Gain = solo compras).                      |
   //| Devuelve false si no hay ningún setup vigente.                  |
   //+----------------------------------------------------------------+
   bool Evaluate(const MqlRates &rates[], int count, ENUM_TIMEFRAMES tf,
                 bool allowBuy, bool allowSell, SAuraSetup &out)
   {
      ZeroMemory(out);
      out.valid = false;
      if(count < 2 * AURA_MIN_CANDLES + 2) return false;

      SAuraSetup sSell, sBuy;
      ZeroMemory(sSell); ZeroMemory(sBuy);
      bool hasSell = allowSell && _Run(rates, count, tf, false, sSell);
      bool hasBuy  = allowBuy  && _Run(rates, count, tf, true,  sBuy);

      if(!hasSell && !hasBuy) return false;
      if(hasSell && !hasBuy) { out = sSell; return true; }
      if(hasBuy && !hasSell) { out = sBuy;  return true; }

      // Las dos direcciones tienen setup: manda el que está en zona (llegó a Av1 y no pagó);
      // si ninguno o los dos, el impulso más reciente.
      bool actS = (sSell.state == AURA_ST_ACTIVE);
      bool actB = (sBuy.state  == AURA_ST_ACTIVE);
      if(actS && !actB) { out = sSell; return true; }
      if(actB && !actS) { out = sBuy;  return true; }
      out = (sSell.tBreak >= sBuy.tBreak) ? sSell : sBuy;
      return true;
   }

private:
   int    m_maxLeg;
   int    m_n;
   // Precios en "espacio venta" (compra = invertidos)
   double m_h[], m_l[], m_o[], m_c[];

   // Setup de trabajo en espacio venta (índices de vela)
   bool       m_valid;
   double     m_s0, m_s1, m_x;
   int        m_i0, m_i1, m_iBrk, m_iTouch, m_iX;
   EAuraState m_state;
   bool       m_reanch;

   bool _IsRed(int j)   const { return m_c[j] < m_o[j]; }   // vela del impulso (espacio venta)
   bool _IsGreen(int j) const { return m_c[j] > m_o[j]; }   // vela del retroceso previo
   double _Lvl(double k) const { return m_s0 + k * (m_s0 - m_s1); }

   //+----------------------------------------------------------------+
   //| _Load — copia las velas al espacio venta                        |
   //+----------------------------------------------------------------+
   void _Load(const MqlRates &r[], int n, bool mirror)
   {
      m_n = n;
      ArrayResize(m_h, n); ArrayResize(m_l, n); ArrayResize(m_o, n); ArrayResize(m_c, n);
      for(int i = 0; i < n; i++)
      {
         if(mirror)
         {
            m_h[i] = -r[i].low;  m_l[i] = -r[i].high;
            m_o[i] = -r[i].open; m_c[i] = -r[i].close;
         }
         else
         {
            m_h[i] = r[i].high;  m_l[i] = r[i].low;
            m_o[i] = r[i].open;  m_c[i] = r[i].close;
         }
      }
   }

   //+----------------------------------------------------------------+
   //| _BodyBreak — la vela j rompe la zona pl con más cuerpo que mecha|
   //| (espacio venta: cierra debajo de pl y la parte del cuerpo que   |
   //| quedó debajo de pl es mayor que la mecha de abajo).             |
   //+----------------------------------------------------------------+
   bool _BodyBreak(int j, double pl) const
   {
      if(m_c[j] >= pl) return false;
      double bodyLow  = MathMin(m_o[j], m_c[j]);
      double bodyHigh = MathMax(m_o[j], m_c[j]);
      double bodyBeyond = MathMin(bodyHigh, pl) - bodyLow;   // cuerpo más allá de la zona
      double wickBeyond = bodyLow - m_l[j];                  // mecha más allá del cuerpo
      return bodyBeyond > wickBeyond;
   }

   //+----------------------------------------------------------------+
   //| _FindRetrace — para el pico h, busca el extremo previo al       |
   //| retroceso (zona): el mínimo más cercano hacia atrás desde el    |
   //| cual hay al menos 3 velas verdes hasta h, sin pasar un máximo   |
   //| más alto que h. Devuelve false si no hay retroceso válido.      |
   //+----------------------------------------------------------------+
   bool _FindRetrace(int h, double &pl) const
   {
      double runMin = DBL_MAX;
      int    greens = 0;
      int    lim    = MathMax(0, h - m_maxLeg);
      for(int p = h; p >= lim; p--)
      {
         if(p < h && m_h[p] > m_h[h]) break;           // salió del retroceso
         if(p < h && _IsGreen(p + 1)) greens++;        // verdes en (p, h]
         if(m_l[p] <= runMin)
         {
            runMin = m_l[p];
            bool swingLow = (p == 0) || (m_l[p - 1] > m_l[p]);
            if(greens >= AURA_MIN_CANDLES && swingLow)
            {
               pl = runMin;
               return true;
            }
         }
      }
      return false;
   }

   //+----------------------------------------------------------------+
   //| _FindImpulseAt — ¿se CONFIRMA un impulso nuevo en la vela t?    |
   //| Devuelve el pico h más reciente cuyo impulso queda confirmado   |
   //| justo en t: rompió la zona con cuerpo y ya tiene 3 velas rojas. |
   //+----------------------------------------------------------------+
   bool _FindImpulseAt(int t, int &hOut)
   {
      double runMax = -DBL_MAX;
      int    lim    = MathMax(0, t - m_maxLeg);
      // Velas rojas en (h, t], llevadas en forma incremental al ir hacia atrás.
      // r1 < r2 < r3 = las 3 rojas más cercanas a h → r3 es la vela donde se completan 3.
      int reds = 0, r1 = -1, r2 = -1, r3 = -1;
      for(int h = t - 1; h >= lim; h--)
      {
         runMax = MathMax(runMax, m_h[h + 1]);          // máximo de (h, t]
         if(_IsRed(h + 1)) { reds++; r3 = r2; r2 = r1; r1 = h + 1; }
         if(m_h[h] < runMax) continue;                  // h tiene que ser el pico del tramo
         if(reds < AURA_MIN_CANDLES) continue;
         int third = r3;

         double pl;
         if(!_FindRetrace(h, pl)) continue;

         // Primera vela que rompe la zona con cuerpo
         int brk = -1;
         for(int j = h + 1; j <= t; j++)
            if(_BodyBreak(j, pl)) { brk = j; break; }
         if(brk < 0) continue;

         // Se confirma recién cuando se cumplen las dos cosas → una sola vez, en esa vela
         if((int)MathMax(brk, third) != t) continue;
         hOut = h;
         return true;
      }
      return false;
   }

   //+----------------------------------------------------------------+
   //| _Step — avanza el setup de trabajo con la vela cerrada t        |
   //+----------------------------------------------------------------+
   void _Step(int t, ENUM_TIMEFRAMES tf)
   {
      int h;
      // Un impulso nuevo reemplaza al setup anterior, salvo que ese esté EN ZONA
      // (llegó a Av1 y todavía no pagó): ahí manda el setup que se está operando.
      if((!m_valid || m_state != AURA_ST_ACTIVE) && _FindImpulseAt(t, h))
      {
         m_valid  = true;
         m_state  = AURA_ST_ARMED;
         m_reanch = false;
         m_i0     = h;
         m_s0     = m_h[h];
         m_i1     = h + 1;
         m_s1     = m_l[h + 1];
         for(int j = h + 2; j <= t; j++)
            if(m_l[j] < m_s1) { m_s1 = m_l[j]; m_i1 = j; }
         m_iBrk   = t;
         m_iTouch = -1;
         m_x      = m_s0;
         m_iX     = h;
         return;
      }
      if(!m_valid) return;

      if(m_state == AURA_ST_ARMED)
      {
         if(m_l[t] < m_s1) { m_s1 = m_l[t]; m_i1 = t; return; }   // el impulso se estira
         if(m_h[t] >= _Lvl(AURA_LVL_AV1))
         {
            m_state  = AURA_ST_ACTIVE;
            m_iTouch = t;
            m_x      = m_h[t];
            m_iX     = t;
         }
         else return;
      }

      if(m_state == AURA_ST_ACTIVE)
      {
         if(m_h[t] > m_x) { m_x = m_h[t]; m_iX = t; }
         // Stop de la estrategia: vela que CIERRA más allá de No Fasha
         if(m_c[t] >= _Lvl(AURA_LVL_NOFASHA)) { m_valid = false; return; }

         double unit = m_s0 - m_s1;
         double ext  = (unit > 0.0) ? (m_x - m_s0) / unit : 0.0;
         if(ext < AURA_LVL_AV3)
         {
            // Av1/Av2: paga con 3 velas de retroceso (rojas) desde el extremo
            int reds = 0;
            for(int j = m_iX; j <= t; j++) if(_IsRed(j)) reds++;
            if(reds < AURA_MIN_CANDLES) return;
            if(tf >= AURA_REANCHOR_MIN_TF && !m_reanch)
            {
               // Regla 5: se marca el siguiente Fibo (una sola vez) — 0 = el extremo
               // alcanzado, 1 = el piso del retroceso de 3 velas.
               m_reanch = true;
               m_state  = AURA_ST_ARMED;
               m_i0     = m_iX;
               m_s0     = m_x;
               m_i1     = m_iX;
               m_s1     = m_l[m_iX];
               for(int j = m_iX + 1; j <= t; j++)
                  if(m_l[j] < m_s1) { m_s1 = m_l[j]; m_i1 = j; }
               m_iBrk   = t;
               m_iTouch = -1;
            }
            else
               m_state = AURA_ST_PAID;
         }
         else
         {
            // Av3 en adelante: paga al llegar al TP fijo de la zona más lejana alcanzada
            double pct = AuraTpPct(AuraZoneOf(ext));
            double tp  = m_x - pct * (m_x - m_s1);
            if(m_l[t] <= tp) m_state = AURA_ST_PAID;
         }
      }
   }

   //+----------------------------------------------------------------+
   //| _Run — recorre toda la historia en una dirección                |
   //+----------------------------------------------------------------+
   bool _Run(const MqlRates &r[], int n, ENUM_TIMEFRAMES tf, bool isBuy, SAuraSetup &out)
   {
      _Load(r, n, isBuy);
      m_valid = false;
      for(int t = 1; t < n; t++) _Step(t, tf);
      if(!m_valid) return false;

      double sg   = isBuy ? -1.0 : 1.0;   // vuelve del espacio venta a precios reales
      out.valid      = true;
      out.isBuy      = isBuy;
      out.p0         = sg * m_s0;
      out.p1         = sg * m_s1;
      out.t0         = r[m_i0].time;
      out.t1         = r[m_i1].time;
      out.tBreak     = r[m_iBrk].time;
      out.tTouch     = (m_iTouch >= 0) ? r[m_iTouch].time : 0;
      out.xExt       = sg * m_x;
      out.tExt       = r[m_iX].time;
      out.state      = m_state;
      out.reanchored = m_reanch;
      return true;
   }
};

//+------------------------------------------------------------------+
//| AuraLoadRates — velas CERRADAS en orden cronológico               |
//| (shift 1 = última cerrada). Devuelve la cantidad copiada o -1.    |
//+------------------------------------------------------------------+
int AuraLoadRates(const string sym, ENUM_TIMEFRAMES tf, int bars, MqlRates &rates[])
{
   ArraySetAsSeries(rates, false);
   int got = CopyRates(sym, tf, 1, bars, rates);
   return got;
}

#endif // AURAX_FIBO_MQH
