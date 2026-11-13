//+------------------------------------------------------------------+
//| CPanelBase.mqh — Base class para paneles flotantes MQL5          |
//| Capa: UI                                                          |
//|                                                                  |
//| Responsabilidad única: chrome compartido — background, borders   |
//| 1px DarkRed, barra de título, botón TOGGLE (−/+) y CLOSE (x)    |
//| con confirmación doble-click, drag con minimización a título.    |
//|                                                                  |
//| Extraído de CScanPanel.mqh v1.32 (EMAScan v1.65).               |
//| CScanPanel y CTradePanel extienden esta clase.                   |
//|                                                                  |
//| Uso:                                                             |
//|   class CMiPanel : public CPanelBase                             |
//|   {                                                              |
//|      virtual int  _FullPanelH() const override { return ...; }   |
//|      virtual void _OnCollapse()  override { /* ocultar contenido */ } |
//|      virtual void _OnExpand()    override { /* restaurar */ }    |
//|   };                                                             |
//|                                                                  |
//| OnMouseEvent: subclass implementa su propio handler y llama      |
//|   _HandleChromeBtnClick(mx, my) — CLOSE + TOGGLE                |
//|   _HandleDrag(mx, my, leftBtn) — drag completo                  |
//+------------------------------------------------------------------+
#ifndef AURAX_PANELBASE_MQH
#define AURAX_PANELBASE_MQH

//-- Paleta AuraX — tema "Premium azul & negro" (2026-11-13) ───────
// Negro + UN solo azul de acento: el azul marca solo lo importante (línea superior,
// modo activo, acción principal). Los literales C'r,g,b' evitan el orden BGR del hex.
// (Base: tema rojo & negro de EmaRiskPro 9.00 — mismo esquema, otro acento.)
#define EPNL_ACCENT       C'30,144,255'        // azul de acento — línea superior + acción principal
#define EPNL_ACCENT_DEEP  C'18,86,196'         // azul profundo — modo REAL activo / estado ocupado
#define EPNL_ACCENT_TINT  C'8,14,26'           // fondo apenas azulado — fila del símbolo actual
#define EPNL_GOOD         C'43,210,126'        // verde del tema — confirmado / compra / TP
#define EPNL_FONT         "Segoe UI Semibold"  // tipografía de textos del panel
#define EPNL_FONT_BRAND   "Arial Black"        // tipografía de la marca del título
#define EPNL_BRAND_FSZ    8                    // pt de la marca — 9 tapaba "delorrio.com" en el panel de 290 px
#define EPNL_TITLE_FSZ    7                    // pt del texto del título (versión · delorrio.com · reloj)
#define ESCAN_BG          C'11,11,11'          // negro — fondo
#define ESCAN_TITLE_BG    C'11,11,11'          // barra de título negra (la identidad la da la línea roja)
#define ESCAN_BORDER_CLR  C'42,42,42'          // gris — bordes laterales e inferior
#define ESCAN_TITLE_FG    C'168,168,168'       // gris claro — versión · delorrio.com
#define ESCAN_BRAND_FG    C'242,242,242'       // blanco — partes neutras de la marca
#define ESCAN_BTN_FG      C'122,122,122'       // gris — glifos − / ✕ del título
#define ESCAN_BTN_BDR     C'31,31,31'          // gris oscuro — borde sutil de botones
#define ESCAN_DD_BG       C'18,18,18'          // negro elevado — dropdowns y campos
#define ESCAN_DD_FG       C'242,242,242'       // blanco — texto dropdowns
#define ESCAN_DD_BDR      C'31,31,31'          // gris oscuro — borde dropdown
#define ESCAN_SEP_COL     C'31,31,31'          // gris oscuro — separador 1px
// Color de ACCIÓN PRIMARIA de la suite: EMAScan ESCANEAR + EmaRiskPro INICIAR.
// Un solo rol, un solo color en todos los productos (canon docs/ux-principles.md §5).
#define EPNL_PRIMARY_BG   EPNL_ACCENT
#define EPNL_ACCENT_H     2                    // grosor px de la línea roja superior

//-- ZORDER jerárquico ─────────────────────────────────────────────
// BG(9000) < LABEL(9001) < BORDER(9002) < BTN_BG(10000) < BTN_TEXT(10002)
#define ESCAN_Z_BG        9000
#define ESCAN_Z_LABEL     9001
#define ESCAN_Z_BORDER    9002
#define ESCAN_Z_BTN_BG    10000
#define ESCAN_Z_BTN_TEXT  10002

//-- Dimensión compartida ──────────────────────────────────────────
#define ESCAN_TITLE_H     24   // altura px de la barra de título

//-- Popups (dropdown de símbolo y TF) ────────────────────────────
#define ESCAN_POP_ROWS    15   // filas visibles en el popup antes de scroll
#define ESCAN_POP_Z    20000   // Z-order base de los popups (encima de todo el panel)

//+------------------------------------------------------------------+
//| CPanelBase — chrome compartido para todos los paneles flotantes   |
//+------------------------------------------------------------------+
class CPanelBase
{
protected:
   //-- Geometría y estado ─────────────────────────────────────────
   long   m_chartId;
   int    m_x, m_y, m_panelW;
   string m_pfx;    // prefix único por instancia (incluye chartId — GOT-017)
   string m_title;  // texto del título (guardado para restaurar tras close confirm)
   string m_brand[3]; // marca en 3 partes (la del medio en rojo) — vacía = título plano

   bool   m_dragging, m_collapsed;
   int    m_dragOffX, m_dragOffY;
   bool   m_closeClicked, m_closeConfirmPending;
   bool   m_prevLeftBtn;  // estado previo del botón izquierdo (detección de clicks nuevos)
   bool   m_clickArmed;   // false hasta ver el botón izquierdo SUELTO — GOT-018

   //-- Chrome helpers ─────────────────────────────────────────────
   //| Crea o reemplaza par OBJ_RECTANGLE_LABEL + OBJ_LABEL (botón plano).
   //| borderClr == -1 → borde invisible (= bg).
   void _RebuildBtn(string name, int x, int y, int w, int h,
                    string text, color bg, color fg, int fsz = 8,
                    color borderClr = (color)-1);

   //| Crea label OBJ_RECTANGLE_LABEL + OBJ_LABEL con alineación flexible.
   //| leftAlign=true → ANCHOR_LEFT + 4px padding. false → ANCHOR_CENTER.
   void _CreateLabel(string name, int x, int y, int w, int h,
                     string text, color bg, color fg, int fsz = 8,
                     int textYOffset = 0, bool leftAlign = false,
                     color borderClr = (color)-1);

   //| Mueve par rect+label manteniendo el offset relativo del label.
   void _SetObjPos(string name, int x, int y);

   //| Actualiza las 4 líneas BDR_T/B/L/R según m_x, m_y, m_panelW y panelH.
   void _UpdateBorder(int panelH);

   //| Marca de 3 partes al inicio del título + texto del título corrido a su derecha.
   bool   _HasBrand() const { return StringLen(m_brand[0] + m_brand[1] + m_brand[2]) > 0; }
   string _DisplayTitle(const string txt) const;
   void   _DrawBrand();
   void   _MoveTitle();

   //| Desplaza TODOS los objetos del panel (prefijo m_pfx) dx/dy px y actualiza m_x/m_y.
   void   _ShiftPanel(int dx, int dy);

   //| Crea BG + 4 líneas BDR + TITLE label + TOGGLE + CLOSE.
   //| Llamar desde Init() del subclass antes de agregar contenido propio.
   void _InitChrome(int panelH);

   //-- Detección de click nuevo ───────────────────────────────────
   //| true SOLO en el flanco de bajada del botón izquierdo, y solo si el panel
   //| ya vio el botón suelto desde su Init (GOT-018): un cambio de símbolo/TF
   //| re-inicia el indicador/EA con el botón todavía apretado, y sin el rearmado
   //| ese botón viejo se leía como un click nuevo sobre lo que quedó debajo.
   bool _IsNewClick(bool leftBtn)
   {
      bool isNew = leftBtn && !m_prevLeftBtn && m_clickArmed;
      if(!leftBtn) m_clickArmed = true;
      m_prevLeftBtn = leftBtn;
      m_lastWasNewClick = isNew;   // lo lee _HandleDrag: un drag solo arranca en el FLANCO (M-3)
      return isNew;
   }
   bool m_lastWasNewClick;   // resultado del último _IsNewClick — flanco de bajada real

   //| Estado de click a cero: exige un botón suelto antes del próximo click.
   //| Llamar desde Init() del subclass (GOT-018).
   void _ResetClickState() { m_prevLeftBtn = false; m_clickArmed = false; }

   //-- Chrome buttons ─────────────────────────────────────────────
   //| Procesa clicks en CLOSE (doble-click con confirmación) y TOGGLE.
   //| Llamar desde OnMouseEvent del subclass cuando isNewClick=true y
   //| no hay popup abierto ni click en el área de contenido.
   void _HandleChromeBtnClick(int mx, int my);

   //-- Drag ───────────────────────────────────────────────────────
   //| Procesa drag: setup (leftBtn&& !m_dragging), move (m_dragging && leftBtn),
   //| release (!leftBtn). El panel entero se mueve en vivo (_ShiftPanel).
   //| leftBtn: botón izquierdo del mouse en este tick.
   void _HandleDrag(int mx, int my, bool leftBtn);

   //-- Layout virtual ─────────────────────────────────────────────
   //| Altura total del panel expandido. Override en subclasses.
   virtual int  _FullPanelH() const { return ESCAN_TITLE_H; }
   //| Bottom del área visible del panel.
   int _FootTop() const { return m_y + _FullPanelH(); }
   //| true = requiere doble-click para confirmar cierre (default EMAScan).
   //| false = cierre directo en un click (CTradePanel: OBJ_EDIT interfiere con doble-click).
   virtual bool _UseCloseConfirm() const { return true; }

   //| Cantidad de botones en la barra de título (desde la derecha) que NO inician
   //| drag. Base: 2 (TOGGLE+CLOSE). Override si el subclass agrega botones (🔔).
   virtual int _TitleBtnCount() const { return 2; }

   //-- Hooks virtuales para content (override en subclasses) ──────
   virtual void _CloseAllPopups() {}    // no-op en base; override si hay popups
   virtual void _OnCollapse()    {}    // ocultar objetos de contenido al colapsar
   virtual void _OnExpand()      {}    // restaurar objetos de contenido al expandir

   //-- Collapse / Expand ──────────────────────────────────────────
   //| Base: BG + BORDER + toggle text. Llama _OnCollapse/_OnExpand.
   virtual void _Collapse();
   virtual void _Expand();

   //-- Utilidades compartidas ─────────────────────────────────────
   //| Comparación natural de strings: "FX Vol 2" < "FX Vol 10" (ordena
   //| segmentos numéricos por valor, no lexicográficamente). Usado por
   //| CScanPanel y CTradePanel para ordenar símbolos del Market Watch.
   int _NatCmp(const string &a, const string &b);

public:
   //-- Rectángulo visible del panel — lo consume el hit-test de exclusión del
   //   overlay (issue #56): ningún click dentro de estos límites debe agarrar
   //   una línea de precio. Colapsado = solo la barra de título.
   int PanelX() const { return m_x; }
   int PanelY() const { return m_y; }
   int PanelW() const { return m_panelW; }
   int PanelH() const { return m_collapsed ? ESCAN_TITLE_H : _FullPanelH(); }

   CPanelBase() :
      m_chartId(0), m_x(0), m_y(0), m_panelW(0),
      m_dragging(false), m_collapsed(false),
      m_dragOffX(0), m_dragOffY(0),
      m_closeClicked(false), m_closeConfirmPending(false),
      // m_clickArmed nace en true: una subclase que no llame a _ResetClickState()
      // se comporta exactamente como antes (el gate de drag queda inerte).
      m_prevLeftBtn(false), m_clickArmed(true), m_lastWasNewClick(false) {}

   //| Borra todos los objetos del panel (ObjectsDeleteAll por prefijo).
   virtual void Deinit();

   //| true si el usuario confirmó cerrar el panel (doble click en "x").
   bool ConsumeCloseClick();

   //| Actualiza el texto de la barra de título en caliente (reloj de scan, estado).
   //| OBJ_LABEL sí repinta con ObjectSetString (el gotcha de no-repaint es de
   //| OBJ_BUTTON — ver _RebuildBtn). No pisa m_title: _Collapse lo restaura y el
   //| caller periódico lo vuelve a escribir en el próximo ciclo.
   void SetTitleText(const string txt)
   {
      ObjectSetString(m_chartId, m_pfx + "TITLE_T", OBJPROP_TEXT, _DisplayTitle(txt));
   }

   //| Marca del título en 3 partes, ej. ("EMA","RISK","PRO") — la del medio va en rojo.
   //| Llamar ANTES de Init() (mismo patrón que SetExcludedTFs). Si el título empieza
   //| con la marca (sin importar mayúsculas), esa parte no se repite en el texto.
   void SetBrand(const string a, const string b, const string c)
   {
      m_brand[0] = a; m_brand[1] = b; m_brand[2] = c;
   }
};

//+------------------------------------------------------------------+
//| _InitChrome — crea BG, 4 bordes, TITLE, TOGGLE, CLOSE            |
//+------------------------------------------------------------------+
void CPanelBase::_InitChrome(int panelH)
{
   //-- Background
   string bgName = m_pfx + "BG";
   if(ObjectFind(m_chartId, bgName) < 0)
      ObjectCreate(m_chartId, bgName, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(m_chartId, bgName, OBJPROP_XDISTANCE,   m_x);
   ObjectSetInteger(m_chartId, bgName, OBJPROP_YDISTANCE,   m_y);
   ObjectSetInteger(m_chartId, bgName, OBJPROP_XSIZE,       m_panelW);
   ObjectSetInteger(m_chartId, bgName, OBJPROP_YSIZE,       panelH);
   ObjectSetInteger(m_chartId, bgName, OBJPROP_BGCOLOR,     ESCAN_BG);
   ObjectSetInteger(m_chartId, bgName, OBJPROP_COLOR,       ESCAN_BG);
   ObjectSetInteger(m_chartId, bgName, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(m_chartId, bgName, OBJPROP_CORNER,      CORNER_LEFT_UPPER);
   ObjectSetInteger(m_chartId, bgName, OBJPROP_SELECTABLE,  false);
   ObjectSetInteger(m_chartId, bgName, OBJPROP_ZORDER,      ESCAN_Z_BG);

   //-- 4 líneas de borde exterior 1px (esquinas redondeadas: top/bottom sin vértices)
   const string bdrLines[4] = {m_pfx+"BDR_T", m_pfx+"BDR_B", m_pfx+"BDR_L", m_pfx+"BDR_R"};
   for(int li = 0; li < 4; li++)
   {
      if(ObjectFind(m_chartId, bdrLines[li]) < 0)
         ObjectCreate(m_chartId, bdrLines[li], OBJ_RECTANGLE_LABEL, 0, 0, 0);
      // La línea superior es la firma roja del tema; las otras tres, gris discreto.
      color bdrClr = (li == 0) ? EPNL_ACCENT : ESCAN_BORDER_CLR;
      ObjectSetInteger(m_chartId, bdrLines[li], OBJPROP_BGCOLOR,     bdrClr);
      ObjectSetInteger(m_chartId, bdrLines[li], OBJPROP_COLOR,       bdrClr);
      ObjectSetInteger(m_chartId, bdrLines[li], OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(m_chartId, bdrLines[li], OBJPROP_CORNER,      CORNER_LEFT_UPPER);
      ObjectSetInteger(m_chartId, bdrLines[li], OBJPROP_SELECTABLE,  false);
      ObjectSetInteger(m_chartId, bdrLines[li], OBJPROP_ZORDER,      ESCAN_Z_BORDER);
   }
   _UpdateBorder(panelH);

   //-- Barra de título (fondo DarkRed + texto blanco bold italic)
   // leftAlign=true: con ANCHOR_CENTER el texto se centraba sobre TODO m_panelW,
   // pero los últimos ~2*ESCAN_TITLE_H px están ocupados por TOGGLE/CLOSE — un
   // título largo (ej. "EmaRiskPro v6.71 · delorrio.com") quedaba con la cola
   // tapada detrás de esos botones. Alineado a la izquierda usa el ancho útil
   // completo antes de los botones.
   _CreateLabel(m_pfx + "TITLE", m_x, m_y, m_panelW, ESCAN_TITLE_H,
                _DisplayTitle(m_title), ESCAN_TITLE_BG, ESCAN_TITLE_FG, EPNL_TITLE_FSZ, 0, true, ESCAN_SEP_COL);
   _DrawBrand();

   //-- TOGGLE "−" (2° desde la derecha) + CLOSE "x" (extremo derecho)
   _RebuildBtn(m_pfx + "TOGGLE",
               m_x + m_panelW - 2*ESCAN_TITLE_H, m_y, ESCAN_TITLE_H, ESCAN_TITLE_H,
               "-", ESCAN_TITLE_BG, ESCAN_BTN_FG, 10, ESCAN_BTN_BDR);
   _RebuildBtn(m_pfx + "CLOSE",
               m_x + m_panelW - ESCAN_TITLE_H, m_y, ESCAN_TITLE_H, ESCAN_TITLE_H,
               "✕", ESCAN_TITLE_BG, ESCAN_BTN_FG, 9, ESCAN_BTN_BDR);
}

//+------------------------------------------------------------------+
//| Deinit                                                            |
//+------------------------------------------------------------------+
void CPanelBase::Deinit()
{
   ChartSetInteger(m_chartId, CHART_EVENT_MOUSE_MOVE, 0);
   ChartSetInteger(m_chartId, CHART_MOUSE_SCROLL,     1);
   if(StringLen(m_pfx) > 0)
      ObjectsDeleteAll(m_chartId, m_pfx);
}

//+------------------------------------------------------------------+
//| ConsumeCloseClick                                                 |
//+------------------------------------------------------------------+
bool CPanelBase::ConsumeCloseClick()
{
   if(!m_closeClicked) return false;
   m_closeClicked = false;
   return true;
}

//+------------------------------------------------------------------+
//| _Collapse — base: BG + border + toggle. Llama _OnCollapse.       |
//+------------------------------------------------------------------+
void CPanelBase::_Collapse()
{
   m_collapsed           = true;
   m_closeConfirmPending = false;
   ObjectSetString(m_chartId, m_pfx + "TITLE_T", OBJPROP_TEXT, _DisplayTitle(m_title));
   _CloseAllPopups();
   _OnCollapse();   // subclass borra su contenido
   ObjectSetInteger(m_chartId, m_pfx + "BG", OBJPROP_YSIZE, ESCAN_TITLE_H);
   _UpdateBorder(ESCAN_TITLE_H);
   _RebuildBtn(m_pfx + "TOGGLE",
               m_x + m_panelW - 2*ESCAN_TITLE_H, m_y, ESCAN_TITLE_H, ESCAN_TITLE_H,
               "+", ESCAN_TITLE_BG, ESCAN_BTN_FG, 10, ESCAN_BTN_BDR);
   ChartRedraw(m_chartId);
}

//+------------------------------------------------------------------+
//| _Expand — base: BG + border + toggle. Llama _OnExpand.           |
//+------------------------------------------------------------------+
void CPanelBase::_Expand()
{
   m_collapsed           = false;
   m_closeConfirmPending = false;
   ObjectSetString(m_chartId, m_pfx + "TITLE_T", OBJPROP_TEXT, _DisplayTitle(m_title));
   ObjectSetInteger(m_chartId, m_pfx + "BG", OBJPROP_YSIZE, _FullPanelH());
   _UpdateBorder(_FullPanelH());
   _OnExpand();     // subclass restaura su contenido
   _RebuildBtn(m_pfx + "TOGGLE",
               m_x + m_panelW - 2*ESCAN_TITLE_H, m_y, ESCAN_TITLE_H, ESCAN_TITLE_H,
               "-", ESCAN_TITLE_BG, ESCAN_BTN_FG, 10, ESCAN_BTN_BDR);
   ChartRedraw(m_chartId);
}

//+------------------------------------------------------------------+
//| _HandleChromeBtnClick — CLOSE (doble-click) + TOGGLE             |
//|                                                                  |
//| Llamar desde OnMouseEvent del subclass cuando isNewClick=true.   |
//| No llama ChartRedraw — el caller es responsable si es necesario. |
//+------------------------------------------------------------------+
void CPanelBase::_HandleChromeBtnClick(int mx, int my)
{
   bool onCloseBtn = (mx >= m_x + m_panelW - ESCAN_TITLE_H && mx <= m_x + m_panelW
                      && my >= m_y && my < m_y + ESCAN_TITLE_H);

   // Cancelar confirmación si el click es fuera del botón CLOSE
   if(m_closeConfirmPending && !onCloseBtn)
   {
      m_closeConfirmPending = false;
      ObjectSetString(m_chartId, m_pfx + "TITLE_T", OBJPROP_TEXT, _DisplayTitle(m_title));
      _RebuildBtn(m_pfx + "CLOSE",
                  m_x + m_panelW - ESCAN_TITLE_H, m_y, ESCAN_TITLE_H, ESCAN_TITLE_H,
                  "✕", ESCAN_TITLE_BG, ESCAN_BTN_FG, 9, ESCAN_BTN_BDR);
      ChartRedraw(m_chartId);
   }

   if(onCloseBtn)
   {
      if(!_UseCloseConfirm())
      {
         // Cierre directo sin confirmación (ej. CTradePanel con OBJ_EDIT)
         m_closeConfirmPending = false;
         m_closeClicked        = true;
      }
      else if(!m_closeConfirmPending)
      {
         m_closeConfirmPending = true;
         ObjectSetString(m_chartId, m_pfx + "TITLE_T", OBJPROP_TEXT,
                         _HasBrand() ? "¿Cerrar?  [✓]=Sí  |  otro=No"
                                     : "¿Cerrar " + m_title + "?  [✓]=Sí  |  otro=No");
         _RebuildBtn(m_pfx + "CLOSE",
                     m_x + m_panelW - ESCAN_TITLE_H, m_y, ESCAN_TITLE_H, ESCAN_TITLE_H,
                     "?", clrOrange, clrBlack, 10, ESCAN_BTN_BDR);
         ChartRedraw(m_chartId);
      }
      else
      {
         m_closeConfirmPending = false;
         m_closeClicked        = true;
      }
   }
   else if(mx >= m_x + m_panelW - 2*ESCAN_TITLE_H
           && mx < m_x + m_panelW - ESCAN_TITLE_H
           && my >= m_y && my < m_y + ESCAN_TITLE_H)
   {
      if(m_collapsed) _Expand(); else _Collapse();
   }
}

//+------------------------------------------------------------------+
//| _HandleDrag — setup, move y release del drag                     |
//|                                                                  |
//| El panel completo (chrome + contenido) se mueve EN VIVO con el   |
//| mouse: se desplazan los objetos existentes, sin borrar ni        |
//| recrear nada. Antes el contenido se ocultaba durante el drag y   |
//| se redibujaba al soltar (pedido PO 2026-10-30: moverlo entero).  |
//| leftBtn: estado actual del botón izquierdo.                      |
//+------------------------------------------------------------------+
void CPanelBase::_HandleDrag(int mx, int my, bool leftBtn)
{
   // Setup: inicio del drag (botón recién presionado sobre el título, fuera de TOGGLE/CLOSE).
   // m_clickArmed: un botón que venía apretado desde antes del Init no arrastra (GOT-018).
   // m_lastWasNewClick (M-3, revisión 2026-08-02): el drag arranca SOLO en el flanco de
   // bajada — pasar por encima del título con el botón ya apretado no debe agarrar el panel.
   if(leftBtn && !m_dragging && m_clickArmed && m_lastWasNewClick)
   {
      bool overTitleBtns = (mx >= m_x + m_panelW - _TitleBtnCount()*ESCAN_TITLE_H
                            && mx <= m_x + m_panelW
                            && my >= m_y && my <= m_y + ESCAN_TITLE_H);
      if(!overTitleBtns
         && mx >= m_x && mx <= m_x + m_panelW
         && my >= m_y && my < m_y + ESCAN_TITLE_H)
      {
         m_dragging  = true;
         m_dragOffX  = mx - m_x;
         m_dragOffY  = my - m_y;
         _CloseAllPopups();   // los popups no se arrastran: se cierran al agarrar el panel
      }
   }

   // Move: arrastre activo — todo el panel sigue al mouse
   if(m_dragging && leftBtn)
   {
      _ShiftPanel((mx - m_dragOffX) - m_x, (my - m_dragOffY) - m_y);
      ChartRedraw(m_chartId);
   }

   // Release: soltar el botón
   if(!leftBtn && m_dragging)
   {
      m_dragging = false;
      // Cancelar confirmación de cierre si hubo drag
      if(m_closeConfirmPending)
      {
         m_closeConfirmPending = false;
         ObjectSetString(m_chartId, m_pfx + "TITLE_T", OBJPROP_TEXT, _DisplayTitle(m_title));
         _RebuildBtn(m_pfx + "CLOSE",
                     m_x + m_panelW - ESCAN_TITLE_H, m_y, ESCAN_TITLE_H, ESCAN_TITLE_H,
                     "✕", ESCAN_TITLE_BG, ESCAN_BTN_FG, 9, ESCAN_BTN_BDR);
      }
      // M-2 (revisión 2026-08-02): si el drag terminó fuera del gráfico, traer el panel de
      // vuelta al área visible — antes quedaba inaccesible y no había forma de recuperarlo.
      int cw = (int)ChartGetInteger(m_chartId, CHART_WIDTH_IN_PIXELS);
      int ch = (int)ChartGetInteger(m_chartId, CHART_HEIGHT_IN_PIXELS);
      if(cw > 0 && ch > 0)
      {
         int nx = MathMax(0, MathMin(m_x, cw - m_panelW));
         int ny = MathMax(0, MathMin(m_y, ch - ESCAN_TITLE_H));
         _ShiftPanel(nx - m_x, ny - m_y);
      }
      bool over = (mx >= m_x && mx <= m_x + m_panelW
                   && my >= m_y && my <= _FootTop());
      ChartSetInteger(m_chartId, CHART_MOUSE_SCROLL, !over);
      ChartRedraw(m_chartId);
   }
}

//+------------------------------------------------------------------+
//| _ShiftPanel — mueve todos los objetos del panel dx/dy píxeles    |
//|                                                                  |
//| Recorre los objetos del chart con prefijo m_pfx (único por panel |
//| y chart — GOT-017; el overlay y el detector usan prefijos        |
//| hermanos, ADR-028) y suma el desplazamiento. Un objeto creado a  |
//| mitad del drag (ej. refresco del scan) también se mueve, porque  |
//| se lo encuentra por prefijo en cada paso.                        |
//+------------------------------------------------------------------+
void CPanelBase::_ShiftPanel(int dx, int dy)
{
   if(dx == 0 && dy == 0) return;
   m_x += dx;
   m_y += dy;
   int total = ObjectsTotal(m_chartId, 0, -1);
   for(int i = 0; i < total; i++)
   {
      string n = ObjectName(m_chartId, i, 0, -1);
      if(StringFind(n, m_pfx) != 0) continue;
      ENUM_OBJECT t = (ENUM_OBJECT)ObjectGetInteger(m_chartId, n, OBJPROP_TYPE);
      if(t != OBJ_LABEL && t != OBJ_RECTANGLE_LABEL && t != OBJ_EDIT && t != OBJ_BUTTON)
         continue;   // solo objetos posicionados en píxeles
      ObjectSetInteger(m_chartId, n, OBJPROP_XDISTANCE,
                       ObjectGetInteger(m_chartId, n, OBJPROP_XDISTANCE) + dx);
      ObjectSetInteger(m_chartId, n, OBJPROP_YDISTANCE,
                       ObjectGetInteger(m_chartId, n, OBJPROP_YDISTANCE) + dy);
   }
}

//+------------------------------------------------------------------+
//| _RebuildBtn — OBJ_RECTANGLE_LABEL + OBJ_LABEL planos (sin relieve)|
//+------------------------------------------------------------------+
void CPanelBase::_RebuildBtn(string name, int x, int y, int w, int h,
                              string text, color bg, color fg, int fsz,
                              color borderClr)
{
   ObjectDelete(m_chartId, name);
   ObjectDelete(m_chartId, name + "_T");

   ObjectCreate(m_chartId, name, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(m_chartId, name, OBJPROP_XDISTANCE,   x);
   ObjectSetInteger(m_chartId, name, OBJPROP_YDISTANCE,   y);
   ObjectSetInteger(m_chartId, name, OBJPROP_XSIZE,       w);
   ObjectSetInteger(m_chartId, name, OBJPROP_YSIZE,       h);
   ObjectSetInteger(m_chartId, name, OBJPROP_BGCOLOR,     bg);
   color bdr = (borderClr == (color)-1) ? bg : borderClr;
   ObjectSetInteger(m_chartId, name, OBJPROP_COLOR,       bdr);
   ObjectSetInteger(m_chartId, name, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(m_chartId, name, OBJPROP_CORNER,      CORNER_LEFT_UPPER);
   ObjectSetInteger(m_chartId, name, OBJPROP_SELECTABLE,  false);
   ObjectSetInteger(m_chartId, name, OBJPROP_ZORDER,      ESCAN_Z_BTN_BG);

   string lname = name + "_T";
   ObjectCreate(m_chartId, lname, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(m_chartId, lname, OBJPROP_XDISTANCE,  x + w / 2);
   ObjectSetInteger(m_chartId, lname, OBJPROP_YDISTANCE,  y + h / 2);
   ObjectSetInteger(m_chartId, lname, OBJPROP_ANCHOR,     ANCHOR_CENTER);
   ObjectSetString (m_chartId, lname, OBJPROP_TEXT,       text);
   ObjectSetInteger(m_chartId, lname, OBJPROP_COLOR,      fg);
   ObjectSetInteger(m_chartId, lname, OBJPROP_FONTSIZE,   fsz);
   ObjectSetString (m_chartId, lname, OBJPROP_FONT,       EPNL_FONT);
   ObjectSetInteger(m_chartId, lname, OBJPROP_CORNER,     CORNER_LEFT_UPPER);
   ObjectSetInteger(m_chartId, lname, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(m_chartId, lname, OBJPROP_ZORDER,     ESCAN_Z_BTN_TEXT);
}

//+------------------------------------------------------------------+
//| _CreateLabel — OBJ_RECTANGLE_LABEL + OBJ_LABEL con alineación   |
//+------------------------------------------------------------------+
void CPanelBase::_CreateLabel(string name, int x, int y, int w, int h,
                               string text, color bg, color fg, int fsz,
                               int textYOffset, bool leftAlign, color borderClr)
{
   if(ObjectFind(m_chartId, name) >= 0) ObjectDelete(m_chartId, name);
   ObjectCreate(m_chartId, name, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(m_chartId, name, OBJPROP_XDISTANCE,   x);
   ObjectSetInteger(m_chartId, name, OBJPROP_YDISTANCE,   y);
   ObjectSetInteger(m_chartId, name, OBJPROP_XSIZE,       w);
   ObjectSetInteger(m_chartId, name, OBJPROP_YSIZE,       h);
   ObjectSetInteger(m_chartId, name, OBJPROP_BGCOLOR,     bg);
   color actualBorder = (borderClr == (color)-1) ? bg : borderClr;
   ObjectSetInteger(m_chartId, name, OBJPROP_COLOR,       actualBorder);
   ObjectSetInteger(m_chartId, name, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(m_chartId, name, OBJPROP_CORNER,      CORNER_LEFT_UPPER);
   ObjectSetInteger(m_chartId, name, OBJPROP_SELECTABLE,  false);
   ObjectSetInteger(m_chartId, name, OBJPROP_ZORDER,      ESCAN_Z_LABEL);

   string lname = name + "_T";
   if(ObjectFind(m_chartId, lname) >= 0) ObjectDelete(m_chartId, lname);
   ObjectCreate(m_chartId, lname, OBJ_LABEL, 0, 0, 0);
   int textX, textY;
   ENUM_ANCHOR_POINT anch;
   if(leftAlign)
   {
      textX = x + 4;
      textY = y + h / 2;
      anch  = ANCHOR_LEFT;
   }
   else
   {
      textX = x + w / 2;
      textY = y + h / 2 + textYOffset;
      anch  = ANCHOR_CENTER;
   }
   ObjectSetInteger(m_chartId, lname, OBJPROP_XDISTANCE,  textX);
   ObjectSetInteger(m_chartId, lname, OBJPROP_YDISTANCE,  textY);
   ObjectSetInteger(m_chartId, lname, OBJPROP_ANCHOR,     anch);
   ObjectSetString (m_chartId, lname, OBJPROP_TEXT,       text);
   ObjectSetInteger(m_chartId, lname, OBJPROP_COLOR,      fg);
   ObjectSetInteger(m_chartId, lname, OBJPROP_FONTSIZE,   fsz);
   ObjectSetString (m_chartId, lname, OBJPROP_FONT,       EPNL_FONT);
   ObjectSetInteger(m_chartId, lname, OBJPROP_CORNER,     CORNER_LEFT_UPPER);
   ObjectSetInteger(m_chartId, lname, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(m_chartId, lname, OBJPROP_ZORDER,     ESCAN_Z_BTN_TEXT);
}

//+------------------------------------------------------------------+
//| _SetObjPos — mueve par rect+label preservando offset relativo    |
//+------------------------------------------------------------------+
void CPanelBase::_SetObjPos(string name, int x, int y)
{
   int dx = x - (int)ObjectGetInteger(m_chartId, name, OBJPROP_XDISTANCE);
   int dy = y - (int)ObjectGetInteger(m_chartId, name, OBJPROP_YDISTANCE);
   ObjectSetInteger(m_chartId, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(m_chartId, name, OBJPROP_YDISTANCE, y);
   string lname = name + "_T";
   if(ObjectFind(m_chartId, lname) >= 0)
   {
      ObjectSetInteger(m_chartId, lname, OBJPROP_XDISTANCE,
         (int)ObjectGetInteger(m_chartId, lname, OBJPROP_XDISTANCE) + dx);
      ObjectSetInteger(m_chartId, lname, OBJPROP_YDISTANCE,
         (int)ObjectGetInteger(m_chartId, lname, OBJPROP_YDISTANCE) + dy);
   }
}

//+------------------------------------------------------------------+
//| _UpdateBorder — reposiciona las 4 líneas BDR_T/B/L/R            |
//+------------------------------------------------------------------+
void CPanelBase::_UpdateBorder(int panelH)
{
   // Top: sin px de vértice → efecto esquinas redondeadas
   ObjectSetInteger(m_chartId, m_pfx+"BDR_T", OBJPROP_XDISTANCE, m_x);
   ObjectSetInteger(m_chartId, m_pfx+"BDR_T", OBJPROP_YDISTANCE, m_y - 1);
   ObjectSetInteger(m_chartId, m_pfx+"BDR_T", OBJPROP_XSIZE,     m_panelW);
   ObjectSetInteger(m_chartId, m_pfx+"BDR_T", OBJPROP_YSIZE,     EPNL_ACCENT_H);
   // Bottom
   ObjectSetInteger(m_chartId, m_pfx+"BDR_B", OBJPROP_XDISTANCE, m_x);
   ObjectSetInteger(m_chartId, m_pfx+"BDR_B", OBJPROP_YDISTANCE, m_y + panelH);
   ObjectSetInteger(m_chartId, m_pfx+"BDR_B", OBJPROP_XSIZE,     m_panelW);
   ObjectSetInteger(m_chartId, m_pfx+"BDR_B", OBJPROP_YSIZE,     1);
   // Left
   ObjectSetInteger(m_chartId, m_pfx+"BDR_L", OBJPROP_XDISTANCE, m_x - 1);
   ObjectSetInteger(m_chartId, m_pfx+"BDR_L", OBJPROP_YDISTANCE, m_y);
   ObjectSetInteger(m_chartId, m_pfx+"BDR_L", OBJPROP_XSIZE,     1);
   ObjectSetInteger(m_chartId, m_pfx+"BDR_L", OBJPROP_YSIZE,     panelH);
   // Right
   ObjectSetInteger(m_chartId, m_pfx+"BDR_R", OBJPROP_XDISTANCE, m_x + m_panelW);
   ObjectSetInteger(m_chartId, m_pfx+"BDR_R", OBJPROP_YDISTANCE, m_y);
   ObjectSetInteger(m_chartId, m_pfx+"BDR_R", OBJPROP_XSIZE,     1);
   ObjectSetInteger(m_chartId, m_pfx+"BDR_R", OBJPROP_YSIZE,     panelH);
}

//+------------------------------------------------------------------+
//| _DisplayTitle — título sin la marca repetida al inicio           |
//+------------------------------------------------------------------+
string CPanelBase::_DisplayTitle(const string txt) const
{
   if(!_HasBrand()) return txt;
   string word = m_brand[0] + m_brand[1] + m_brand[2];
   string head = StringSubstr(txt, 0, StringLen(word));
   string a = head, b = word;
   StringToLower(a); StringToLower(b);
   if(a != b) return txt;
   string rest = StringSubstr(txt, StringLen(word));
   StringTrimLeft(rest);
   return rest;
}

//+------------------------------------------------------------------+
//| _DrawBrand — marca de 3 partes + corre el texto del título       |
//+------------------------------------------------------------------+
void CPanelBase::_DrawBrand()
{
   if(!_HasBrand()) return;
   const color clr[3] = {ESCAN_BRAND_FG, EPNL_ACCENT, ESCAN_BRAND_FG};
   for(int i = 0; i < 3; i++)
   {
      string n = m_pfx + "BRAND_" + IntegerToString(i);
      if(ObjectFind(m_chartId, n) < 0) ObjectCreate(m_chartId, n, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(m_chartId, n, OBJPROP_ANCHOR,     ANCHOR_LEFT);
      ObjectSetString (m_chartId, n, OBJPROP_TEXT,       m_brand[i]);
      ObjectSetInteger(m_chartId, n, OBJPROP_COLOR,      clr[i]);
      ObjectSetInteger(m_chartId, n, OBJPROP_FONTSIZE,   EPNL_BRAND_FSZ);
      ObjectSetString (m_chartId, n, OBJPROP_FONT,       EPNL_FONT_BRAND);
      ObjectSetInteger(m_chartId, n, OBJPROP_CORNER,     CORNER_LEFT_UPPER);
      ObjectSetInteger(m_chartId, n, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(m_chartId, n, OBJPROP_ZORDER,     ESCAN_Z_BTN_TEXT);
   }
   _MoveTitle();
}

//+------------------------------------------------------------------+
//| _MoveTitle — ubica fondo del título, marca y texto en m_x/m_y    |
//+------------------------------------------------------------------+
void CPanelBase::_MoveTitle()
{
   _SetObjPos(m_pfx + "TITLE", m_x, m_y);
   if(!_HasBrand()) return;
   const int padX = 8;   // margen izquierdo de la marca
   const int gap  = 5;   // separación marca → texto
   int x  = m_x + padX;
   int yc = m_y + ESCAN_TITLE_H / 2;
   TextSetFont(EPNL_FONT_BRAND, -EPNL_BRAND_FSZ * 10);   // negativo = décimas de punto
   for(int i = 0; i < 3; i++)
   {
      string n = m_pfx + "BRAND_" + IntegerToString(i);
      ObjectSetInteger(m_chartId, n, OBJPROP_XDISTANCE, x);
      ObjectSetInteger(m_chartId, n, OBJPROP_YDISTANCE, yc);
      uint w = 0, h = 0;
      TextGetSize(m_brand[i], w, h);
      x += (int)w;
   }
   ObjectSetInteger(m_chartId, m_pfx + "TITLE_T", OBJPROP_XDISTANCE, x + gap);
   ObjectSetInteger(m_chartId, m_pfx + "TITLE_T", OBJPROP_YDISTANCE, yc);
}

//+------------------------------------------------------------------+
//| _NatCmp — comparación natural: "FX Vol 2" < "FX Vol 10"         |
//|                                                                  |
//| Compara char a char; cuando ambos lados tienen un dígito, lee el|
//| segmento numérico completo y compara por valor. Retorna -1/0/1. |
//+------------------------------------------------------------------+
int CPanelBase::_NatCmp(const string &a, const string &b)
{
   int ai = 0, bi = 0;
   int al = StringLen(a), bl = StringLen(b);
   while(ai < al && bi < bl)
   {
      ushort ca = StringGetCharacter(a, ai);
      ushort cb = StringGetCharacter(b, bi);
      if(ca >= '0' && ca <= '9' && cb >= '0' && cb <= '9')
      {
         long na = 0, nb = 0;
         while(ai < al && StringGetCharacter(a, ai) >= '0' && StringGetCharacter(a, ai) <= '9')
            na = na * 10 + (StringGetCharacter(a, ai++) - '0');
         while(bi < bl && StringGetCharacter(b, bi) >= '0' && StringGetCharacter(b, bi) <= '9')
            nb = nb * 10 + (StringGetCharacter(b, bi++) - '0');
         if(na != nb) return (na < nb) ? -1 : 1;
      }
      else
      {
         if(ca != cb) return (ca < cb) ? -1 : 1;
         ai++; bi++;
      }
   }
   if(al != bl) return (al < bl) ? -1 : 1;
   return 0;
}

#endif // AURAX_PANELBASE_MQH
