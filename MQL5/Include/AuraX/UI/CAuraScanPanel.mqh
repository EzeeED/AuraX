//+------------------------------------------------------------------+
//| CAuraScanPanel.mqh — panel del scanner de zonas áureas           |
//| Capa: UI · extiende CPanelBase (mismo chrome que el de trading:  |
//| arrastrable entero, colapsar, cerrar).                            |
//|                                                                  |
//| Muestra los pares con Fibo vigente, ordenados:                    |
//|   1. EN ZONA (llegó a Av1 y no pagó) — la zona más lejana primero |
//|   2. ESPERANDO Av1 — el más cerca de Av1 primero                  |
//| Click en una fila → el gráfico va a ese símbolo y TF.             |
//+------------------------------------------------------------------+
#ifndef AURAX_SCANPANEL_MQH
#define AURAX_SCANPANEL_MQH

#include "CPanelBase.mqh"
#include <AuraX/Scanner/CAuraScanner.mqh>

#define ASP_W         290
#define ASP_ROW_H     20
#define ASP_HEAD_H    20
#define ASP_ROWS      12      // filas visibles
#define ASP_FULL_H    (ESCAN_TITLE_H + ASP_HEAD_H + ASP_ROWS * ASP_ROW_H)
#define ASP_FG        C'230,230,230'
#define ASP_FG_DIM    C'124,124,124'
#define ASP_BUY       C'43,210,126'
#define ASP_SELL      C'225,15,46'

class CAuraScanPanel : public CPanelBase
{
public:
   CAuraScanPanel() : m_navClicked(false), m_shown(0) {}

   bool Init(long chartId, int x, int y, const string &prefix, const string title)
   {
      m_chartId = chartId;
      m_x = x; m_y = y; m_panelW = ASP_W;
      m_pfx   = prefix + "SP_" + IntegerToString(chartId) + "_";   // único por chart (GOT-017)
      m_title = title;
      _ResetClickState();
      _InitChrome(ASP_FULL_H);
      _DrawHeader();
      ChartSetInteger(m_chartId, CHART_EVENT_MOUSE_MOVE, 1);
      ChartRedraw(m_chartId);
      return true;
   }

   //| Redibuja las filas desde el scanner.
   void Refresh(CAuraScanner &scan)
   {
      if(m_collapsed) return;
      _Collect(scan);
      for(int r = 0; r < ASP_ROWS; r++)
      {
         if(r < m_shown) _DrawRow(r);
         else            _ClearRow(r);
      }
   }

   void OnMouseEvent(int id, long lparam, double dparam, const string &sparam)
   {
      if(id != CHARTEVENT_MOUSE_MOVE) return;
      int  mx = (int)lparam, my = (int)dparam;
      bool leftBtn = ((int)StringToInteger(sparam) & 1) != 0;
      bool inside  = (mx >= m_x && mx <= m_x + m_panelW && my >= m_y && my <= m_y + PanelH());
      if(inside || m_dragging) ChartSetInteger(m_chartId, CHART_MOUSE_SCROLL, false);

      bool newClick = _IsNewClick(leftBtn);
      if(newClick && !m_dragging && inside)
      {
         if(my < m_y + ESCAN_TITLE_H) _HandleChromeBtnClick(mx, my);
         else if(!m_collapsed)
         {
            int r = (my - (m_y + ESCAN_TITLE_H + ASP_HEAD_H)) / ASP_ROW_H;
            if(my >= m_y + ESCAN_TITLE_H + ASP_HEAD_H && r >= 0 && r < m_shown)
            {
               m_navSym     = m_sym[r];
               m_navTf      = m_tf[r];
               m_navClicked = true;
            }
         }
      }
      _HandleDrag(mx, my, leftBtn);
   }

   //| Cierra solo el scanner. NO usa Deinit() de la base: ese apaga los eventos de
   //| mouse del gráfico y dejaría sin mouse al panel de trading y a las líneas.
   void Hide() { if(StringLen(m_pfx) > 0) ObjectsDeleteAll(m_chartId, m_pfx); m_shown = 0; }

   bool            ConsumeNavigate() { bool v = m_navClicked; m_navClicked = false; return v; }
   string          NavSymbol() const { return m_navSym; }
   ENUM_TIMEFRAMES NavTF() const     { return m_navTf; }

protected:
   virtual int  _FullPanelH() const override { return ASP_FULL_H; }
   virtual void _OnCollapse() override
   {
      ObjectsDeleteAll(m_chartId, m_pfx + "H_");
      ObjectsDeleteAll(m_chartId, m_pfx + "R");
   }
   virtual void _OnExpand() override { _DrawHeader(); m_shown = 0; }

private:
   bool            m_navClicked;
   string          m_navSym;
   ENUM_TIMEFRAMES m_navTf;
   int             m_shown;
   string          m_sym[ASP_ROWS];
   ENUM_TIMEFRAMES m_tf[ASP_ROWS];
   string          m_txtDir[ASP_ROWS], m_txtState[ASP_ROWS];
   color           m_clrDir[ASP_ROWS];
   bool            m_hot[ASP_ROWS];

   int _Y(int r) const { return m_y + ESCAN_TITLE_H + ASP_HEAD_H + r * ASP_ROW_H; }

   void _DrawHeader()
   {
      int y = m_y + ESCAN_TITLE_H;
      _CreateLabel(m_pfx + "H_SYM", m_x,       y, 120, ASP_HEAD_H, "SÍMBOLO", ESCAN_BG, ASP_FG_DIM, 7, 0, true);
      _CreateLabel(m_pfx + "H_TF",  m_x + 120, y, 40,  ASP_HEAD_H, "TF",      ESCAN_BG, ASP_FG_DIM, 7, 0, true);
      _CreateLabel(m_pfx + "H_DIR", m_x + 160, y, 55,  ASP_HEAD_H, "LADO",    ESCAN_BG, ASP_FG_DIM, 7, 0, true);
      _CreateLabel(m_pfx + "H_ST",  m_x + 215, y, ASP_W - 215, ASP_HEAD_H, "ZONA", ESCAN_BG, ASP_FG_DIM, 7, 0, true);
   }

   //| Puntaje de orden: en zona primero (más lejos = más arriba), después
   //| esperando (más cerca de Av1 = más arriba). Pagados no se muestran.
   double _Score(const SAuraScanRow &r) const
   {
      if(r.setup.state == AURA_ST_ACTIVE)
         return 1000.0 + AuraExt(r.setup, r.setup.xExt);
      return 100.0 + r.posNow;   // posNow < 0.38 mientras espera
   }

   void _Collect(CAuraScanner &scan)
   {
      int n = scan.Count();
      double best[]; int idx[];
      ArrayResize(best, 0); ArrayResize(idx, 0);
      SAuraScanRow row;
      for(int i = 0; i < n; i++)
      {
         scan.GetRow(i, row);
         if(!row.setup.valid || row.setup.state == AURA_ST_PAID) continue;
         int k = ArraySize(best);
         ArrayResize(best, k + 1); ArrayResize(idx, k + 1);
         best[k] = _Score(row); idx[k] = i;
      }
      // Orden descendente por puntaje (selección simple — pocas filas)
      int c = ArraySize(best);
      m_shown = MathMin(ASP_ROWS, c);
      for(int r = 0; r < m_shown; r++)
      {
         int bi = r;
         for(int j = r + 1; j < c; j++) if(best[j] > best[bi]) bi = j;
         double tb = best[r]; best[r] = best[bi]; best[bi] = tb;
         int    ti = idx[r];  idx[r]  = idx[bi];  idx[bi]  = ti;

         scan.GetRow(idx[r], row);
         m_sym[r]    = row.sym;
         m_tf[r]     = row.tf;
         m_txtDir[r] = row.setup.isBuy ? "COMPRA" : "VENTA";
         m_clrDir[r] = row.setup.isBuy ? ASP_BUY : ASP_SELL;
         m_hot[r]    = (row.setup.state == AURA_ST_ACTIVE);
         m_txtState[r] = m_hot[r] ? AuraZoneName(AuraZoneOf(AuraExt(row.setup, row.setup.xExt)))
                                  : StringFormat("precio %.2f", -row.posNow);
      }
   }

   void _DrawRow(int r)
   {
      string p  = m_pfx + "R" + IntegerToString(r) + "_";
      color  bg = m_hot[r] ? EPNL_ACCENT_TINT : ESCAN_BG;
      color  fg = m_hot[r] ? ASP_FG : ASP_FG_DIM;
      _SetCell(p + "S", m_x,       _Y(r), 120, m_sym[r],                bg, fg);
      _SetCell(p + "T", m_x + 120, _Y(r), 40,  AuraTFLabel(m_tf[r]),     bg, fg);
      _SetCell(p + "D", m_x + 160, _Y(r), 55,  m_txtDir[r],             bg, m_clrDir[r]);
      _SetCell(p + "Z", m_x + 215, _Y(r), ASP_W - 215, m_txtState[r],   bg, m_hot[r] ? EPNL_ACCENT : fg);
   }

   void _ClearRow(int r) { ObjectsDeleteAll(m_chartId, m_pfx + "R" + IntegerToString(r) + "_"); }

   //| Crea la celda la primera vez; después solo cambia texto y colores
   //| (OBJ_LABEL repinta con ObjectSetString — sin parpadeo).
   void _SetCell(const string name, int x, int y, int w, const string txt, color bg, color fg)
   {
      if(ObjectFind(m_chartId, name) < 0)
      {
         _CreateLabel(name, x, y, w, ASP_ROW_H, txt, bg, fg, 8, 0, true, ESCAN_SEP_COL);
         return;
      }
      ObjectSetInteger(m_chartId, name, OBJPROP_BGCOLOR, bg);
      ObjectSetString (m_chartId, name + "_T", OBJPROP_TEXT, txt);
      ObjectSetInteger(m_chartId, name + "_T", OBJPROP_COLOR, fg);
   }
};

#endif // AURAX_SCANPANEL_MQH
