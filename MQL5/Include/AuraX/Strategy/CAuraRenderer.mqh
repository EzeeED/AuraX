//+------------------------------------------------------------------+
//| CAuraRenderer.mqh — dibuja el Fibo de zonas áureas en el gráfico |
//| Capa: Strategy (visual)                                           |
//|                                                                  |
//| Prefijo propio (ej. "AUX_FIB_"), hermano del panel ("AUX_TP_…")  |
//| y del overlay ("AUX_BOV_") — nunca anidado: el Clear() de acá    |
//| borra por prefijo y no puede llevarse puestos objetos ajenos.     |
//+------------------------------------------------------------------+
#ifndef AURAX_RENDERER_MQH
#define AURAX_RENDERER_MQH

#include "CAuraFibo.mqh"

#define AURA_RENDER_EXT_BARS 15   // las líneas se extienden N velas a la derecha de la última

class CAuraRenderer
{
public:
   CAuraRenderer() : m_chartId(0), m_digits(5),
      m_clrBase(clrDimGray), m_clrAv(C'30,144,255'), m_clrFinal(clrGold),
      m_clrEngano(clrDarkOrange), m_clrNoFasha(C'225,15,46') {}

   void Init(long chartId, const string pfx, int digits)
   {
      m_chartId = chartId;
      m_pfx     = pfx;
      m_digits  = digits;
   }

   void SetColors(color base, color av, color fin, color engano, color nofasha)
   {
      m_clrBase = base; m_clrAv = av; m_clrFinal = fin;
      m_clrEngano = engano; m_clrNoFasha = nofasha;
   }

   void Clear() { if(StringLen(m_pfx) > 0) ObjectsDeleteAll(m_chartId, m_pfx); }

   //+----------------------------------------------------------------+
   //| Draw — redibuja el Fibo completo del setup                      |
   //| tEnd: hasta dónde se extienden las líneas (a la derecha).       |
   //+----------------------------------------------------------------+
   void Draw(const SAuraSetup &s, datetime tEnd)
   {
      Clear();
      if(!s.valid) return;

      const double lv[8]  = {-1.0, 0.0, AURA_LVL_AV1, AURA_LVL_AV2, AURA_LVL_AV3,
                             AURA_LVL_FINAL, AURA_LVL_ENGANO, AURA_LVL_NOFASHA};
      const string nm[8]  = {"1", "0", "Av1", "Av2", "Av3", "Última zona", "Engaño", "No Fasha"};
      const string tag[8] = {"1", "0", "-0.38", "-0.68", "-1", "-1.618", "-2", "-2.236"};
      color cl[8];
      cl[0] = m_clrBase; cl[1] = m_clrBase;
      cl[2] = m_clrAv;   cl[3] = m_clrAv;   cl[4] = m_clrAv;
      cl[5] = m_clrFinal; cl[6] = m_clrEngano; cl[7] = m_clrNoFasha;

      for(int i = 0; i < 8; i++)
      {
         double px = AuraLevel(s, lv[i]);   // k=-1 → nivel 1 (fin del impulso)
         string ln = m_pfx + "L" + IntegerToString(i);
         _Line(ln, s.t0, px, tEnd, px, cl[i], (i < 2) ? STYLE_DOT : STYLE_SOLID, (i >= 2) ? 2 : 1);
         string label = (i < 2) ? nm[i] : nm[i] + " (" + tag[i] + ")";
         _Text(m_pfx + "T" + IntegerToString(i), tEnd, px,
               label + "  " + DoubleToString(px, m_digits), cl[i]);
      }
      // Diagonal del impulso (mecha a mecha)
      _Line(m_pfx + "IMP", s.t0, s.p0, s.t1, s.p1, m_clrBase, STYLE_DASH, 1);

      // Estado del setup, sobre la línea 0
      _Text(m_pfx + "ST", s.t0, AuraLevel(s, AURA_LVL_AV1 / 2.0), _StateText(s), m_clrAv, ANCHOR_LEFT_LOWER);
   }

private:
   long   m_chartId;
   string m_pfx;
   int    m_digits;
   color  m_clrBase, m_clrAv, m_clrFinal, m_clrEngano, m_clrNoFasha;

   string _StateText(const SAuraSetup &s) const
   {
      string dir = s.isBuy ? "COMPRA" : "VENTA";
      string st;
      if(s.state == AURA_ST_ARMED)       st = "esperando Av1";
      else if(s.state == AURA_ST_ACTIVE) st = "en zona: " + AuraZoneName(AuraZoneOf(AuraExt(s, s.xExt)));
      else                               st = "pagó";
      return "AuraX · " + dir + " · " + st + (s.reanchored ? " · Fibo siguiente" : "");
   }

   void _Line(const string n, datetime t1, double p1, datetime t2, double p2,
              color c, ENUM_LINE_STYLE st, int w)
   {
      if(ObjectFind(m_chartId, n) < 0) ObjectCreate(m_chartId, n, OBJ_TREND, 0, t1, p1, t2, p2);
      ObjectSetInteger(m_chartId, n, OBJPROP_TIME, 0, t1);
      ObjectSetDouble (m_chartId, n, OBJPROP_PRICE, 0, p1);
      ObjectSetInteger(m_chartId, n, OBJPROP_TIME, 1, t2);
      ObjectSetDouble (m_chartId, n, OBJPROP_PRICE, 1, p2);
      ObjectSetInteger(m_chartId, n, OBJPROP_COLOR, c);
      ObjectSetInteger(m_chartId, n, OBJPROP_STYLE, st);
      ObjectSetInteger(m_chartId, n, OBJPROP_WIDTH, w);
      ObjectSetInteger(m_chartId, n, OBJPROP_RAY_RIGHT, false);
      ObjectSetInteger(m_chartId, n, OBJPROP_RAY_LEFT, false);
      ObjectSetInteger(m_chartId, n, OBJPROP_BACK, true);
      ObjectSetInteger(m_chartId, n, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(m_chartId, n, OBJPROP_HIDDEN, true);
   }

   void _Text(const string n, datetime t, double p, const string txt, color c,
              ENUM_ANCHOR_POINT anchor = ANCHOR_LEFT)
   {
      if(ObjectFind(m_chartId, n) < 0) ObjectCreate(m_chartId, n, OBJ_TEXT, 0, t, p);
      ObjectSetInteger(m_chartId, n, OBJPROP_TIME, 0, t);
      ObjectSetDouble (m_chartId, n, OBJPROP_PRICE, 0, p);
      ObjectSetString (m_chartId, n, OBJPROP_TEXT, txt);
      ObjectSetString (m_chartId, n, OBJPROP_FONT, "Segoe UI Semibold");
      ObjectSetInteger(m_chartId, n, OBJPROP_FONTSIZE, 8);
      ObjectSetInteger(m_chartId, n, OBJPROP_COLOR, c);
      ObjectSetInteger(m_chartId, n, OBJPROP_ANCHOR, anchor);
      ObjectSetInteger(m_chartId, n, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(m_chartId, n, OBJPROP_HIDDEN, true);
   }
};

#endif // AURAX_RENDERER_MQH
