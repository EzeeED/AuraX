//+------------------------------------------------------------------+
//| CTradePanel.mqh — Panel de trading para EmaRiskProCore           |
//| Capa: UI                                                          |
//| Extiende CPanelBase (chrome compartido con CScanPanel).          |
//|                                                                  |
//| Agrega: dropdown SYM/TF (navegación de chart), toggle SIM/REAL, |
//| campos de parámetros (LOT, TP%, SL%), botón INICIAR.            |
//|                                                                  |
//| Layout expandido:                                                |
//|   [Título EmaRiskPro   ][−][x]  ← chrome heredado               |
//|   [  EURUSD   ][   M30   ]       ← SYM + TF dropdowns           |
//|   [  SIM  ] · [  REAL  ]         ← modo                         |
//|   LOT: [0.01]  TP%: [45.0]       ← parámetros fila 1           |
//|   MUL: [1.0 ]  SL%: [ 5.0]       ← parámetros fila 2           |
//|   [       INICIAR       ]         ← botón principal             |
//+------------------------------------------------------------------+
#ifndef AURAX_TRADEPANEL_MQH
#define AURAX_TRADEPANEL_MQH

#include "CPanelBase.mqh"
#include <AuraX/Trading/CRecoveryMath.mqh>

//-- Dimensiones trading-specific ──────────────────────────────────
#define TRADE_W_DEFAULT  290
#define TRADE_DD_H        26   // altura fila SYM/TF
#define TRADE_MODE_H      28   // altura fila SIM/REAL
#define TRADE_ROW_H       26   // altura fila parámetros
#define TRADE_MAIN_H      32   // altura botón INICIAR
#define TRADE_STEP_W      20   // ancho columna de botones ▲▼ por campo
// Altura total expandido: título + dropdowns + modo + 3 filas params + botón INICIAR
#define TRADE_FULL_H  (ESCAN_TITLE_H + TRADE_DD_H + TRADE_MODE_H + 3*TRADE_ROW_H + TRADE_MAIN_H)
// Ancho del label fijo (etiqueta "LOT", "MULT", etc.) en cada celda de parámetros
#define TRADE_LBL_W   48

// Colores de estado (sacados de magic numbers en _DrawModeRow / _DrawMainBtn)
// El color "activo" (Simulación ON / INICIAR listo) es configurable via
// SetActiveBtnColor() — llamarlo ANTES de Init(), como SetExcludedTFs.
#define TRADE_ACTIVE_BG EPNL_PRIMARY_BG  // color primario unificado de la suite (v6.20 — antes clrDodgerBlue)
#define TRADE_REAL_BG   EPNL_ACCENT_DEEP // toggle Real activo — rojo lleno: dinero real no pasa desapercibido
#define TRADE_STOP_BG   ESCAN_BG         // botón CERRAR: fondo negro + borde/texto rojo (otra FORMA que INICIAR)
#define TRADE_STOP_FG   EPNL_ACCENT      // texto y borde del botón CERRAR
#define TRADE_WARN_BDR  EPNL_ACCENT      // borde del campo RLC cuando supera lo que el bróker permite (2026-08-04)
#define TRADE_MODE_ON   C'26,26,26'      // fondo de Simulación activa (el borde lleva el color de acción)
#define TRADE_MODE_OFF  C'94,94,94'      // texto del modo inactivo
#define TRADE_LBL_FG    C'124,124,124'   // etiquetas LOT/MULT/ET/RLC/TP/SL
#define TRADE_STEP_BG   C'22,22,22'      // fondo de los botones ▲▼
#define TRADE_NUM_FONT  "Consolas"       // números de los campos: monoespaciada, alinean por dígito

// Cotas de validación de inputs (evitan que un valor pegado/tipeado corrupto
// llegue al motor de trading). RLC tope = BOVL_MAX_REC del overlay (500).
#define TRADE_MAX_RLC   500    // el overlay soporta máx 500 recoveries (v6.50)
#define TRADE_MAX_ET    100    // cadencia máxima razonable
#define TRADE_MAX_MULT  100.0  // multiplicador máximo razonable
#define TRADE_MAX_PCT   1000.0 // TP%/SL% máximo razonable

// GlobalVariable para señalizar cierre al EA loader (GOT-017 adaptado)
#define TRADE_CLOSE_GV    "AURX_CLOSE_"

//+------------------------------------------------------------------+
//| CTradePanel — panel de trading flotante                          |
//+------------------------------------------------------------------+
class CTradePanel : public CPanelBase
{
public:
   CTradePanel() :
      m_tp(45.0), m_sl(5.0), m_lot(0.01), m_lotMax(1.0),
      m_mult(1.0), m_et(1), m_rlc(5), m_maxReachableRlc(-1), m_isSim(true),
      m_iniciarClicked(false), m_symChanged(false), m_tfChanged(false),
      m_modeChanged(false), m_paramsChanged(false), m_geomChanged(false), m_symIdx(0), m_tfIdx(0),
      m_tfCurrent(PERIOD_CURRENT),
      m_symPopupOpen(false), m_tfPopupOpen(false),
      m_symPopupOffset(0), m_tfPopupOffset(0),
      m_tfListCount(0), m_activeBtnBg(TRADE_ACTIVE_BG) {}

   //+----------------------------------------------------------------+
   //| SetActiveBtnColor — color de Simulación activo + botón INICIAR |
   //|                                                                |
   //| Llamar ANTES de Init() (mismo patrón que SetExcludedTFs).      |
   //+----------------------------------------------------------------+
   void   SetActiveBtnColor(const color c) { m_activeBtnBg = c; }

   //+----------------------------------------------------------------+
   //| Init — crea el panel completo                                  |
   //|                                                                |
   //| chartId  — chart donde se dibuja                              |
   //| x, y     — posición inicial (esquina superior izquierda)      |
   //| prefix   — prefijo único por instancia (incluir chartId)      |
   //| title    — texto de la barra de título                        |
   //| defaultTP — valor inicial del campo TP%                       |
   //| defaultSL — valor inicial del campo SL%                       |
   //| lotMin   — mínimo del campo LOT                               |
   //| lotMax   — máximo del campo LOT                               |
   //| panelW   — ancho del panel (default TRADE_W_DEFAULT)          |
   //+----------------------------------------------------------------+
   bool Init(long chartId, int x, int y, const string &prefix,
             const string title = "AuraX",
             double defaultTP = 45.0, double defaultSL = 5.0,
             double lotMin = 0.01, double lotMax = 1.0,
             double defaultMult = 1.0, int defaultET = 1, int defaultRLC = 5,
             int panelW = TRADE_W_DEFAULT);

   // Deinit: heredado de CPanelBase

   //| Procesa eventos de mouse — handler completo (no override).      |
   void OnMouseEvent(int id, long lparam, double dparam,
                     const string &sparam);

   //| Actualiza las etiquetas de los dropdowns (llamar desde OnInit o |
   //| cuando cambia el símbolo/TF del chart).                        |
   void UpdateSymDropdown(const string &sym);
   void UpdateTFDropdown(ENUM_TIMEFRAMES tf);

   //| TFs excluidos del dropdown (llamar ANTES de Init).             |
   void SetExcludedTFs(const string &excludedStr);

   //| Cambia el texto del botón principal (INICIAR, ACTIVO, etc.).   |
   void SetMainButton(const string &label);
   bool IsMainButtonClose() const { return m_mainBtnLabel == "CERRAR"; }

   //| Trae el panel al frente del stack de objetos.                  |
   void BringToFront();

   // ── Consume flags ─────────────────────────────────────────────
   bool ConsumeIniciar()      { if(!m_iniciarClicked) return false; m_iniciarClicked=false; return true; }
   bool ConsumeSymbolChange() { if(!m_symChanged) return false; m_symChanged=false; return true; }
   bool ConsumeTFChange()     { if(!m_tfChanged)  return false; m_tfChanged=false;  return true; }
   bool ConsumeModeChange()   { if(!m_modeChanged)return false; m_modeChanged=false;return true; }
   bool ConsumeParamsChanged(){ if(!m_paramsChanged)return false; m_paramsChanged=false; return true; }
   // true si el último cambio tocó TP/SL/RLC (geometría de la grilla). Consumir DESPUÉS de
   // ConsumeParamsChanged: false ⇒ solo cambió LOT/MULT/ET ⇒ basta refrescar etiquetas (issue #58).
   bool ConsumeGeomChanged()  { if(!m_geomChanged)  return false; m_geomChanged  =false; return true; }
   // ConsumeCloseClick: heredado de CPanelBase

   // ── Getters ───────────────────────────────────────────────────
   double GetTP()   const { return m_tp; }
   double GetSL()   const { return m_sl; }
   double GetLot()  const { return m_lot; }
   double GetMult() const { return m_mult; }
   int    GetET()   const { return m_et; }
   int    GetRLC()  const { return m_rlc; }
   // Nivel de recovery más profundo que el bróker deja alcanzar con LOT/MULT/ET/RLC actuales
   // (2026-08-04). -1 = todavía no se calculó o el bróker no publica SYMBOL_VOLUME_LIMIT — en
   // ese caso NO hay techo conocido, no tratar -1 como "cero alcanzable".
   int    GetMaxReachableRlc() const { return m_maxReachableRlc; }
   bool   IsSimulation() const { return m_isSim; }
   void   SetSimulation(bool v) { if(m_isSim == v) return; m_isSim = v; if(!m_collapsed) _DrawModeRow(); ChartRedraw(m_chartId); }
   // Setter usado por el EA para sincronizar RLC desde overlay ([+]/[x] en el gráfico).
   // No setea m_paramsChanged — el overlay ya está actualizado; solo refresca el campo visual.
   // Acepta 0 (M-1, revisión 2026-08-02): borrar el último recovery con ✕ debe verse como
   // RLC=0 en el panel — antes el 0 se rechazaba y el campo mentía mostrando el valor viejo.
   void   SetRLC(int v) { if(v < 0 || v > TRADE_MAX_RLC || v == m_rlc) return; m_rlc = v; _RefreshField("RLC_E", IntegerToString(m_rlc)); _UpdateDepthWarning(); }
   string GetSymbol() const { return (StringLen(m_symLabel) > 0) ? m_symLabel : _Symbol; }
   // TF REAL del panel (A-4, revisión 2026-08-02): antes devolvía _TFAt(m_tfIdx), y si el TF
   // del chart estaba EXCLUIDO del dropdown (default excluye M1..M4), m_tfIdx quedaba en 0
   // (=M5) — elegir otro símbolo saltaba el chart a M5 en silencio, con basket abierto era un
   // CHARTCHANGE a otra temporalidad. m_tfCurrent siempre refleja el TF verdadero.
   ENUM_TIMEFRAMES GetTF() const { return m_tfCurrent; }

protected:
   // ── Layout virtual ─────────────────────────────────────────────
   virtual int  _FullPanelH()       const override { return TRADE_FULL_H; }
   // Cierre directo: los OBJ_EDIT interfieren con la detección de doble-click
   virtual bool _UseCloseConfirm()  const override { return false; }

   // ── Hooks de CPanelBase ────────────────────────────────────────
   virtual void _CloseAllPopups() override;
   virtual void _OnCollapse()    override;
   virtual void _OnExpand()      override;

private:
   // ── Trading state ─────────────────────────────────────────────
   double m_tp, m_sl, m_lot, m_lotMax;
   double m_mult;   // multiplicador de recuperación
   int    m_et;     // every trade (cadencia recovery)
   int    m_rlc;    // recovery lines count
   // Profundidad máxima que el bróker deja alcanzar con LOT/MULT/ET/RLC actuales, contra
   // SYMBOL_VOLUME_LIMIT (reporte PO 2026-08-04, incidente GainX 800 — la grilla se armaba sin
   // saber si el bróker la iba a dejar completar). -1 = sin techo publicado por el bróker (no
   // hay advertencia posible). Recalculado en cada cambio de LOT/MULT/ET/RLC/símbolo.
   int    m_maxReachableRlc;
   bool   m_isSim;
   color  m_activeBtnBg;   // fondo de Simulación activo + INICIAR (configurable, default TRADE_ACTIVE_BG)

   // ── Consume flags ─────────────────────────────────────────────
   bool   m_iniciarClicked, m_symChanged, m_tfChanged, m_modeChanged;
   bool   m_paramsChanged;  // TP/SL/RLC/LOT/MULT modificados — recalcular overlay
   bool   m_geomChanged;    // TP/SL/RLC modificados — la GEOMETRÍA de la grilla cambió (issue #58).
                            // LOT/MULT/ET solo cambian etiquetas: reconstruir la grilla por ellos
                            // borraba los recoveries arrastrados a mano.

   // ── Símbolo dropdown ─────────────────────────────────────────
   int    m_symIdx;            // índice en m_sortedSyms del símbolo seleccionado
   bool   m_symPopupOpen;
   int    m_symPopupOffset;
   string m_symLabel;          // símbolo seleccionado (fuente de verdad — GetSymbol lo lee)
   string m_sortedSyms[];      // todos los símbolos del Market Watch, orden natural

   // ── TF dropdown ───────────────────────────────────────────────
   ENUM_TIMEFRAMES m_tfList[];
   int             m_tfListCount, m_tfIdx;
   ENUM_TIMEFRAMES m_tfCurrent;   // TF real del panel — puede NO estar en el dropdown (A-4)
   bool            m_tfPopupOpen;
   int             m_tfPopupOffset;
   string          m_tfLabel;

   // ── Layout helpers ────────────────────────────────────────────
   int _DDSymW() const { return m_panelW * 3 / 5; }
   int _DDTFW()  const { return m_panelW - _DDSymW(); }
   // Posición Y de cada fila (desde arriba del panel)
   int _YDD()   const { return m_y + ESCAN_TITLE_H; }
   int _YMode() const { return _YDD()   + TRADE_DD_H; }
   int _YRow1() const { return _YMode() + TRADE_MODE_H; }
   int _YRow2() const { return _YRow1() + TRADE_ROW_H; }
   int _YRow3() const { return _YRow2() + TRADE_ROW_H; }
   int _YMain() const { return _YRow3() + TRADE_ROW_H; }

   // ── Content drawing ───────────────────────────────────────────
   void _DrawContent();    // dibuja/redibuja todo el contenido
   void _DrawMainBtn();    // dibuja el botón INICIAR
   void _DrawModeRow();    // dibuja la fila SIM/REAL
   void _DrawParamRow1();  // dibuja fila LOT | MULT (label + OBJ_EDIT)
   void _DrawParamRow2();  // dibuja fila ET  | RLC  (label + OBJ_EDIT)
   void _DrawParamRow3();  // dibuja fila TP% | SL%  (label + OBJ_EDIT)
   void _CreateEdit(string name, int x, int y, int w, int h, const string text);
   void _HandleParamEdit(const string &objName);     // valida + guarda valor editado
   bool _ParseEditValue(string val, double &out);    // sanea texto tipeado; false = no numérico
   void _UpdateDepthWarning();   // recalcula m_maxReachableRlc y marca el campo RLC (2026-08-04)

   // ── TF utilities ──────────────────────────────────────────────
   string          _TFLabel(ENUM_TIMEFRAMES tf) const;
   ENUM_TIMEFRAMES _TFAt(int idx) const;
   int             _TFCount() const { return m_tfListCount; }
   void            _InitTFListFull();

   // ── Popup ─────────────────────────────────────────────────────
   void _OpenSymPopup();
   void _CloseSymPopup();
   void _DrawSymPopup();
   void _OpenTFPopup();
   void _CloseTFPopup();
   void _DrawTFPopup();
   void _BuildSortedSyms();

   // ── Step buttons ▲▼ ──────────────────────────────────────────
   void _HandleStepBtn(int mx, int my);
   void _RefreshField(const string key, const string val);

   string m_mainBtnLabel;
};

//+------------------------------------------------------------------+
//| Init                                                              |
//+------------------------------------------------------------------+
bool CTradePanel::Init(long chartId, int x, int y, const string &prefix,
                       const string title,
                       double defaultTP, double defaultSL,
                       double lotMin, double lotMax,
                       double defaultMult, int defaultET, int defaultRLC,
                       int panelW)
{
   m_chartId  = chartId;
   m_x        = x;
   m_y        = y;
   m_panelW   = (panelW > 100) ? panelW : TRADE_W_DEFAULT;
   m_pfx      = prefix + "TP_" + IntegerToString(chartId) + "_"; // GOT-017
   m_title    = title;
   m_tp       = defaultTP;
   m_sl       = defaultSL;
   m_lot      = lotMin;
   m_lotMax   = lotMax;
   m_mult     = defaultMult;
   m_et       = defaultET;
   m_rlc      = defaultRLC;
   m_isSim    = true;
   m_dragging = false;
   m_collapsed = false;
   _ResetClickState();   // GOT-018: el próximo click exige ver el botón suelto primero
   m_closeClicked = false;
   m_closeConfirmPending = false;
   m_iniciarClicked = false;
   m_symChanged = m_tfChanged = m_modeChanged = false;
   m_symPopupOpen = m_tfPopupOpen = false;
   m_symPopupOffset = m_tfPopupOffset = 0;
   m_symLabel = _Symbol;
   m_tfLabel  = _TFLabel(_Period);
   m_tfCurrent = _Period;   // TF real del chart, aunque esté excluido del dropdown (A-4)
   m_symIdx = 0;
   m_mainBtnLabel = "INICIAR";
   if(m_tfListCount == 0) _InitTFListFull();

   // Chrome compartido (BG, bordes, título, TOGGLE, CLOSE)
   _InitChrome(_FullPanelH());

   // SYM + TF dropdowns
   _RebuildBtn(m_pfx + "SYM",
               m_x, _YDD(), _DDSymW(), TRADE_DD_H,
               m_symLabel, ESCAN_DD_BG, ESCAN_DD_FG, 8, ESCAN_DD_BDR);
   _RebuildBtn(m_pfx + "TF",
               m_x + _DDSymW(), _YDD(), _DDTFW(), TRADE_DD_H,
               m_tfLabel, ESCAN_DD_BG, ESCAN_DD_FG, 8, ESCAN_DD_BDR);
   // Separador DD_SEP
   {
      string s = m_pfx + "DD_SEP";
      if(ObjectFind(m_chartId, s) < 0) ObjectCreate(m_chartId, s, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(m_chartId, s, OBJPROP_XDISTANCE,   m_x + _DDSymW());
      ObjectSetInteger(m_chartId, s, OBJPROP_YDISTANCE,   _YDD());
      ObjectSetInteger(m_chartId, s, OBJPROP_XSIZE,       1);
      ObjectSetInteger(m_chartId, s, OBJPROP_YSIZE,       TRADE_DD_H);
      ObjectSetInteger(m_chartId, s, OBJPROP_BGCOLOR,     ESCAN_SEP_COL);
      ObjectSetInteger(m_chartId, s, OBJPROP_COLOR,       ESCAN_SEP_COL);
      ObjectSetInteger(m_chartId, s, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(m_chartId, s, OBJPROP_CORNER,      CORNER_LEFT_UPPER);
      ObjectSetInteger(m_chartId, s, OBJPROP_SELECTABLE,  false);
      ObjectSetInteger(m_chartId, s, OBJPROP_ZORDER,      ESCAN_Z_BTN_BG + 1);
   }

   // Contenido de trading
   _DrawContent();

   ChartSetInteger(m_chartId, CHART_EVENT_MOUSE_MOVE,  1);
   ChartSetInteger(m_chartId, CHART_EVENT_MOUSE_WHEEL, 1);
   ChartRedraw(m_chartId);
   return true;
}

//+------------------------------------------------------------------+
//| _DrawContent — dibuja todo el contenido expandido                |
//+------------------------------------------------------------------+
void CTradePanel::_DrawContent()
{
   _DrawModeRow();
   _DrawParamRow1();
   _DrawParamRow2();
   _DrawParamRow3();
   _DrawMainBtn();
}

void CTradePanel::_DrawModeRow()
{
   int hw = m_panelW / 2;
   color simBg   = m_isSim  ? TRADE_MODE_ON  : ESCAN_BG;
   color simFg   = m_isSim  ? ESCAN_DD_FG    : TRADE_MODE_OFF;
   color simBdr  = m_isSim  ? m_activeBtnBg  : ESCAN_DD_BDR;
   color realBg  = !m_isSim ? TRADE_REAL_BG  : ESCAN_BG;
   color realFg  = !m_isSim ? ESCAN_DD_FG    : TRADE_MODE_OFF;
   _RebuildBtn(m_pfx+"SIM",  m_x,      _YMode(), hw,           TRADE_MODE_H, "SIMULACIÓN", simBg,  simFg,  8, simBdr);
   _RebuildBtn(m_pfx+"REAL", m_x + hw, _YMode(), m_panelW - hw, TRADE_MODE_H, "REAL",       realBg, realFg, 8, ESCAN_DD_BDR);
}

// Layout por fila: [LABEL 42px][EDIT ew][▲▼ TRADE_STEP_W] × 2 columnas = hw × 2 = m_panelW
void CTradePanel::_DrawParamRow1()
{
   int hw  = m_panelW / 2;
   int ew  = hw - TRADE_LBL_W - TRADE_STEP_W;
   int bh  = TRADE_ROW_H / 2;
   int bx1 = m_x + TRADE_LBL_W + ew;
   int bx2 = m_x + hw + TRADE_LBL_W + ew;
   _CreateLabel(m_pfx+"LOT_N",  m_x,                    _YRow1(), TRADE_LBL_W, TRADE_ROW_H, "LOT",  ESCAN_BG, TRADE_LBL_FG, 7, 0, true, ESCAN_DD_BDR);
   _CreateEdit (m_pfx+"LOT_E",  m_x + TRADE_LBL_W,      _YRow1(), ew, TRADE_ROW_H, DoubleToString(m_lot, 2));
   _RebuildBtn(m_pfx+"LOT_U",   bx1, _YRow1(),           TRADE_STEP_W, bh, "▲", TRADE_STEP_BG, EPNL_ACCENT, 7, ESCAN_DD_BDR);
   _RebuildBtn(m_pfx+"LOT_D",   bx1, _YRow1() + bh,      TRADE_STEP_W, bh, "▼", TRADE_STEP_BG, EPNL_ACCENT, 7, ESCAN_DD_BDR);
   _CreateLabel(m_pfx+"MULT_N", m_x + hw,                _YRow1(), TRADE_LBL_W, TRADE_ROW_H, "MULT", ESCAN_BG, TRADE_LBL_FG, 7, 0, true, ESCAN_DD_BDR);
   _CreateEdit (m_pfx+"MULT_E", m_x + hw + TRADE_LBL_W,  _YRow1(), ew, TRADE_ROW_H, DoubleToString(m_mult, 2));
   _RebuildBtn(m_pfx+"MULT_U",  bx2, _YRow1(),           TRADE_STEP_W, bh, "▲", TRADE_STEP_BG, EPNL_ACCENT, 7, ESCAN_DD_BDR);
   _RebuildBtn(m_pfx+"MULT_D",  bx2, _YRow1() + bh,      TRADE_STEP_W, bh, "▼", TRADE_STEP_BG, EPNL_ACCENT, 7, ESCAN_DD_BDR);
}

void CTradePanel::_DrawParamRow2()
{
   int hw  = m_panelW / 2;
   int ew  = hw - TRADE_LBL_W - TRADE_STEP_W;
   int bh  = TRADE_ROW_H / 2;
   int bx1 = m_x + TRADE_LBL_W + ew;
   int bx2 = m_x + hw + TRADE_LBL_W + ew;
   _CreateLabel(m_pfx+"ET_N",  m_x,                    _YRow2(), TRADE_LBL_W, TRADE_ROW_H, "ET",  ESCAN_BG, TRADE_LBL_FG, 7, 0, true, ESCAN_DD_BDR);
   _CreateEdit (m_pfx+"ET_E",  m_x + TRADE_LBL_W,      _YRow2(), ew, TRADE_ROW_H, IntegerToString(m_et));
   _RebuildBtn(m_pfx+"ET_U",   bx1, _YRow2(),           TRADE_STEP_W, bh, "▲", TRADE_STEP_BG, EPNL_ACCENT, 7, ESCAN_DD_BDR);
   _RebuildBtn(m_pfx+"ET_D",   bx1, _YRow2() + bh,      TRADE_STEP_W, bh, "▼", TRADE_STEP_BG, EPNL_ACCENT, 7, ESCAN_DD_BDR);
   _CreateLabel(m_pfx+"RLC_N", m_x + hw,                _YRow2(), TRADE_LBL_W, TRADE_ROW_H, "RLC", ESCAN_BG, TRADE_LBL_FG, 7, 0, true, ESCAN_DD_BDR);
   _CreateEdit (m_pfx+"RLC_E", m_x + hw + TRADE_LBL_W,  _YRow2(), ew, TRADE_ROW_H, IntegerToString(m_rlc));
   _RebuildBtn(m_pfx+"RLC_U",  bx2, _YRow2(),           TRADE_STEP_W, bh, "▲", TRADE_STEP_BG, EPNL_ACCENT, 7, ESCAN_DD_BDR);
   _RebuildBtn(m_pfx+"RLC_D",  bx2, _YRow2() + bh,      TRADE_STEP_W, bh, "▼", TRADE_STEP_BG, EPNL_ACCENT, 7, ESCAN_DD_BDR);
}

void CTradePanel::_DrawParamRow3()
{
   int hw  = m_panelW / 2;
   int ew  = hw - TRADE_LBL_W - TRADE_STEP_W;
   int bh  = TRADE_ROW_H / 2;
   int bx1 = m_x + TRADE_LBL_W + ew;
   int bx2 = m_x + hw + TRADE_LBL_W + ew;
   // AuraX: el TP lo deciden las zonas del Fibo (porcentajes fijos por zona, decisión del
   // dueño 2026-11-13) — el campo TP% de EmaRiskPro se saca. Solo queda FRACCIÓN (el stop):
   // margen extra más allá de la zona No Fasha, en % del impulso (0 = justo en No Fasha).
   _CreateLabel(m_pfx+"SL_N", m_x,                    _YRow3(), TRADE_LBL_W, TRADE_ROW_H, "FRAC %", ESCAN_BG, TRADE_LBL_FG, 7, 0, true, ESCAN_DD_BDR);
   _CreateEdit (m_pfx+"SL_E", m_x + TRADE_LBL_W,      _YRow3(), ew, TRADE_ROW_H, DoubleToString(m_sl, 1));
   _RebuildBtn(m_pfx+"SL_U",  bx1, _YRow3(),           TRADE_STEP_W, bh, "▲", TRADE_STEP_BG, EPNL_ACCENT, 7, ESCAN_DD_BDR);
   _RebuildBtn(m_pfx+"SL_D",  bx1, _YRow3() + bh,      TRADE_STEP_W, bh, "▼", TRADE_STEP_BG, EPNL_ACCENT, 7, ESCAN_DD_BDR);
}

//+------------------------------------------------------------------+
//| _CreateEdit — crea un OBJ_EDIT editable para parámetros          |
//+------------------------------------------------------------------+
void CTradePanel::_CreateEdit(string name, int x, int y, int w, int h, const string text)
{
   if(ObjectFind(m_chartId, name) >= 0) ObjectDelete(m_chartId, name);
   ObjectCreate(m_chartId, name, OBJ_EDIT, 0, 0, 0);
   ObjectSetInteger(m_chartId, name, OBJPROP_XDISTANCE,    x);
   ObjectSetInteger(m_chartId, name, OBJPROP_YDISTANCE,    y);
   ObjectSetInteger(m_chartId, name, OBJPROP_XSIZE,        w);
   ObjectSetInteger(m_chartId, name, OBJPROP_YSIZE,        h);
   ObjectSetString (m_chartId, name, OBJPROP_TEXT,         text);
   ObjectSetInteger(m_chartId, name, OBJPROP_COLOR,        ESCAN_DD_FG);
   ObjectSetInteger(m_chartId, name, OBJPROP_BGCOLOR,      ESCAN_DD_BG);
   ObjectSetInteger(m_chartId, name, OBJPROP_BORDER_COLOR, ESCAN_BTN_BDR);
   ObjectSetInteger(m_chartId, name, OBJPROP_FONTSIZE,     9);
   ObjectSetString (m_chartId, name, OBJPROP_FONT,         TRADE_NUM_FONT);
   ObjectSetInteger(m_chartId, name, OBJPROP_CORNER,       CORNER_LEFT_UPPER);
   ObjectSetInteger(m_chartId, name, OBJPROP_ALIGN,        ALIGN_RIGHT);
   ObjectSetInteger(m_chartId, name, OBJPROP_READONLY,     false);
   ObjectSetInteger(m_chartId, name, OBJPROP_ZORDER,       ESCAN_Z_BTN_TEXT);
}

//+------------------------------------------------------------------+
//| _ParseEditValue — sanea el texto tipeado en un OBJ_EDIT (v5.88)   |
//|                                                                  |
//| Teclado español: la coma decimal ("0,5") cortaba StringToDouble  |
//| en la coma → el valor se rechazaba en silencio y el campo volvía |
//| al anterior (parecía "tipeo 1 y pone 0.01"). Coma→punto + trim.  |
//| Retorna false si el texto no es numérico (B-1, v5.89): distingue |
//| "abc" (rechazar) de "0" tipeado a propósito (válido, ej. SL off).|
//+------------------------------------------------------------------+
bool CTradePanel::_ParseEditValue(string val, double &out)
{
   StringReplace(val, ",", ".");
   StringTrimLeft(val);
   StringTrimRight(val);
   if(StringLen(val) == 0) return false;
   ushort c0 = StringGetCharacter(val, 0);
   if(!((c0 >= '0' && c0 <= '9') || c0 == '.' || c0 == '-' || c0 == '+')) return false;
   // Al menos UN dígito (revisión 2026-08-02): "-", "+" o "." solos pasaban el chequeo del
   // primer carácter y StringToDouble los convierte en 0.0 — en el campo SL un "-" tipeado
   // por error DESHABILITABA el stop en silencio.
   bool hasDigit = false;
   for(int i = 0; i < StringLen(val); i++)
   {
      ushort c = StringGetCharacter(val, i);
      if(c >= '0' && c <= '9') { hasDigit = true; break; }
   }
   if(!hasDigit) return false;
   out = StringToDouble(val);
   return true;
}

// Decimales de display del lote según el VOLUME_STEP del broker (mismo criterio que
// CBasketManager::_OpenReal) — con step 0.1 mostrar "0.10", con step 0.001 no ocultar el tercero.
int _LotDecimals(double lotStep)
{
   if(lotStep >= 0.1)  return 1;
   if(lotStep >= 0.01) return 2;
   if(lotStep >  0.0)  return 3;
   return 2;
}

//+------------------------------------------------------------------+
//| _HandleParamEdit — valida y guarda el valor editado              |
//|                                                                  |
//| Política v5.88: CLAMP al rango válido en vez de rechazo silencioso|
//| — lo tipeado fuera de rango se ajusta al límite más cercano y el  |
//| campo muestra el valor EFECTIVO (predecible para el usuario).     |
//| Solo un texto no numérico (v<=0 donde no aplica) conserva el      |
//| valor anterior.                                                   |
//+------------------------------------------------------------------+
void CTradePanel::_HandleParamEdit(const string &objName)
{
   if(StringFind(objName, m_pfx) != 0) return;  // no es nuestro objeto
   double v  = 0.0;
   bool   ok = _ParseEditValue(ObjectGetString(m_chartId, objName, OBJPROP_TEXT), v);

   // Los flags se setean SOLO si el valor efectivo cambió (issue #58): ENDEDIT se emite
   // con solo entrar y salir de un campo, y hasta v6.37 eso disparaba la reconstrucción
   // de la grilla — borrando los recoveries arrastrados a mano — sin ningún cambio real.
   if(objName == m_pfx + "LOT_E")
   {
      // Validar rango mínimo/máximo Y step del símbolo actual (issue #63): el broker
      // ejecuta redondeado al VOLUME_STEP — mostrar otra cosa deja todo el riesgo
      // proyectado del overlay (DD, TP-Target) calculado sobre un lote que no existe.
      string sym = GetSymbol();  // Usar símbolo del dropdown, no _Symbol del gráfico
      double minLot    = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
      double brokerMax = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
      double lotStep   = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);

      double lotMaxEff = (brokerMax > 0.0) ? MathMin(m_lotMax, brokerMax) : m_lotMax;
      double minEff    = (minLot > 0.0) ? minLot : 0.01;

      double old = m_lot;
      if(ok && v > 0.0)
      {
         double clamped = MathMax(minEff, MathMin(v, lotMaxEff));
         if(lotStep > 0.0) clamped = MathRound(clamped / lotStep) * lotStep;
         m_lot = NormalizeDouble(clamped, _LotDecimals(lotStep));
      }
      ObjectSetString(m_chartId, objName, OBJPROP_TEXT, DoubleToString(m_lot, _LotDecimals(lotStep)));
      if(m_lot != old) m_paramsChanged = true;
   }
   else if(objName == m_pfx + "MULT_E")
   {
      double old = m_mult;
      if(ok && v > 0.0) m_mult = NormalizeDouble(MathMax(1.0, MathMin(v, TRADE_MAX_MULT)), 2);
      ObjectSetString(m_chartId, objName, OBJPROP_TEXT, DoubleToString(m_mult, 2));
      if(m_mult != old) m_paramsChanged = true;
   }
   else if(objName == m_pfx + "ET_E")
   {
      int old = m_et;
      if(ok && v > 0.0) m_et = (int)MathMax(1, MathMin((int)v, TRADE_MAX_ET));
      ObjectSetString(m_chartId, objName, OBJPROP_TEXT, IntegerToString(m_et));
      if(m_et != old) m_paramsChanged = true;
   }
   else if(objName == m_pfx + "RLC_E")
   {
      // 0 tipeado es válido (M-1): "sin recoveries" es un plan legítimo.
      int old = m_rlc;
      if(ok && v >= 0.0) m_rlc = (int)MathMax(0, MathMin((int)v, TRADE_MAX_RLC));
      ObjectSetString(m_chartId, objName, OBJPROP_TEXT, IntegerToString(m_rlc));
      if(m_rlc != old) { m_paramsChanged = true; m_geomChanged = true; }
   }
   else if(objName == m_pfx + "TP_E")
   {
      // Clamp inferior 1.0 igual que el ▼ (revisión 2026-08-02): tipear 0.04 dejaba TP% en
      // 0.0 tras el redondeo — TP de zona colapsado al extremo, inconsistente con los botones.
      double old = m_tp;
      if(ok && v > 0.0) m_tp = NormalizeDouble(MathMax(1.0, MathMin(v, TRADE_MAX_PCT)), 1);
      ObjectSetString(m_chartId, objName, OBJPROP_TEXT, DoubleToString(m_tp, 1));
      if(m_tp != old) { m_paramsChanged = true; m_geomChanged = true; }
   }
   else if(objName == m_pfx + "SL_E")
   {
      // "0" tipeado a propósito es válido (SL deshabilitado); texto no numérico NO (B-1).
      double old = m_sl;
      if(ok && v >= 0.0) m_sl = NormalizeDouble(MathMin(v, TRADE_MAX_PCT), 1);
      ObjectSetString(m_chartId, objName, OBJPROP_TEXT, DoubleToString(m_sl, 1));
      if(m_sl != old) { m_paramsChanged = true; m_geomChanged = true; }
   }
   _UpdateDepthWarning();   // LOT/MULT/ET/RLC pudieron cambiar — recalcular profundidad alcanzable
   ChartRedraw(m_chartId);
}

//+------------------------------------------------------------------+
//| _UpdateDepthWarning — profundidad máxima alcanzable contra el     |
//| volumen agregado que el bróker permite (reporte PO 2026-08-04,    |
//| incidente GainX 800: con LOT/MULT/RLC/ET que exigen más volumen   |
//| del que el bróker deja, la grilla nunca completaba y el reintento |
//| crecía sin freno). Se calcula ANTES de INICIAR, no reaccionando   |
//| después — misma cuenta que usa la guarda de _OpenBasket().        |
//+------------------------------------------------------------------+
void CTradePanel::_UpdateDepthWarning()
{
   string sym      = GetSymbol();
   double volMin    = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double volMax    = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   double volStep   = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   double volLimit  = SymbolInfoDouble(sym, SYMBOL_VOLUME_LIMIT);
   m_maxReachableRlc = MaxReachableRecoveryLevel(m_lot, m_mult, m_et, m_rlc,
                                                  volMin, volMax, volStep, volLimit);
   if(m_collapsed) return;
   // volLimit<=0 = el bróker no publica el techo — MaxReachableRecoveryLevel ya devuelve m_rlc
   // en ese caso (sin límite conocido), así que "capped" queda false solo, sin chequeo extra.
   bool  capped = (m_maxReachableRlc < m_rlc);
   color bdr    = capped ? TRADE_WARN_BDR : ESCAN_BTN_BDR;
   if(ObjectFind(m_chartId, m_pfx + "RLC_E") >= 0)
   {
      ObjectSetInteger(m_chartId, m_pfx + "RLC_E", OBJPROP_BORDER_COLOR, bdr);
      string tip = capped
         ? StringFormat("El bróker no deja pasar del nivel %d con este LOT/MULT/ET (RLC configurado: %d). Bajá RLC, MULT o LOT para que la grilla pueda completarse.",
                        m_maxReachableRlc, m_rlc)
         : "";
      ObjectSetString(m_chartId, m_pfx + "RLC_E", OBJPROP_TOOLTIP, tip);
   }
}

void CTradePanel::_DrawMainBtn()
{
   // INICIAR: rojo lleno (listo para abrir). CERRAR (basket abierto): negro con borde y
   // texto rojo — cambia la FORMA, no solo el texto, para no confundirlos de un vistazo.
   // El glifo es solo visual: el estado se sigue leyendo de m_mainBtnLabel.
   bool  isClose = (m_mainBtnLabel == "CERRAR");
   color btnBg   = isClose ? TRADE_STOP_BG : m_activeBtnBg;
   color btnFg   = isClose ? TRADE_STOP_FG : ESCAN_DD_FG;
   color btnBdr  = isClose ? TRADE_STOP_FG : m_activeBtnBg;
   string glyph  = isClose ? "■  " : "▶  ";
   _RebuildBtn(m_pfx + "MAIN", m_x, _YMain(), m_panelW, TRADE_MAIN_H,
               glyph + m_mainBtnLabel, btnBg, btnFg, 10, btnBdr);
}

//+------------------------------------------------------------------+
//| SetMainButton / BringToFront / UpdateDropdowns                   |
//+------------------------------------------------------------------+
void CTradePanel::SetMainButton(const string &label)
{
   m_mainBtnLabel = label;
   if(!m_collapsed) _DrawMainBtn();
}

void CTradePanel::BringToFront()
{
   if(ObjectFind(m_chartId, m_pfx + "BG") >= 0)
      ObjectSetInteger(m_chartId, m_pfx + "BG", OBJPROP_ZORDER, ESCAN_Z_BG);
}

void CTradePanel::UpdateSymDropdown(const string &sym)
{
   m_symLabel = sym;

   // ← NUEVO: Revalidar Lot si el nuevo símbolo tiene mínimo más alto
   double newMinLot = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   if(newMinLot > 0.0 && m_lot < newMinLot)
   {
      m_lot = NormalizeDouble(newMinLot, 2);
      if(!m_collapsed)
         ObjectSetString(m_chartId, m_pfx + "LOT_E", OBJPROP_TEXT, DoubleToString(m_lot, 2));
      PrintFormat("[Panel] Lot re-validado por cambio de símbolo: %s → minLot=%s",
                  sym, DoubleToString(newMinLot, 2));
   }
   _UpdateDepthWarning();   // specs del símbolo cambiaron — recalcular profundidad alcanzable

   if(m_collapsed) return;
   _RebuildBtn(m_pfx + "SYM", m_x, _YDD(), _DDSymW(), TRADE_DD_H,
               sym, ESCAN_DD_BG, ESCAN_DD_FG, 8, ESCAN_DD_BDR);
   ChartRedraw(m_chartId);
}

void CTradePanel::UpdateTFDropdown(ENUM_TIMEFRAMES tf)
{
   m_tfCurrent = tf;   // el TF real SIEMPRE se registra, esté o no en el dropdown (A-4)
   for(int i = 0; i < _TFCount(); i++)
      if(_TFAt(i) == tf) { m_tfIdx = i; break; }
   m_tfLabel = _TFLabel(tf);
   if(m_collapsed) return;
   _RebuildBtn(m_pfx + "TF", m_x + _DDSymW(), _YDD(), _DDTFW(), TRADE_DD_H,
               m_tfLabel, ESCAN_DD_BG, ESCAN_DD_FG, 8, ESCAN_DD_BDR);
   ChartRedraw(m_chartId);
}

//+------------------------------------------------------------------+
//| Hooks — colapso / expansión / drag                               |
//+------------------------------------------------------------------+
void CTradePanel::_CloseAllPopups()
{
   _CloseSymPopup();
   _CloseTFPopup();
}

void CTradePanel::_OnCollapse()
{
   ObjectDelete(m_chartId, m_pfx + "SYM");    ObjectDelete(m_chartId, m_pfx + "SYM_T");
   ObjectDelete(m_chartId, m_pfx + "TF");     ObjectDelete(m_chartId, m_pfx + "TF_T");
   ObjectDelete(m_chartId, m_pfx + "SIM");    ObjectDelete(m_chartId, m_pfx + "SIM_T");
   ObjectDelete(m_chartId, m_pfx + "REAL");   ObjectDelete(m_chartId, m_pfx + "REAL_T");
   ObjectDelete(m_chartId, m_pfx+"LOT_N");  ObjectDelete(m_chartId, m_pfx+"LOT_N_T");  ObjectDelete(m_chartId, m_pfx+"LOT_E");   ObjectDelete(m_chartId, m_pfx+"LOT_U");  ObjectDelete(m_chartId, m_pfx+"LOT_U_T");  ObjectDelete(m_chartId, m_pfx+"LOT_D");  ObjectDelete(m_chartId, m_pfx+"LOT_D_T");
   ObjectDelete(m_chartId, m_pfx+"MULT_N"); ObjectDelete(m_chartId, m_pfx+"MULT_N_T"); ObjectDelete(m_chartId, m_pfx+"MULT_E");  ObjectDelete(m_chartId, m_pfx+"MULT_U"); ObjectDelete(m_chartId, m_pfx+"MULT_U_T"); ObjectDelete(m_chartId, m_pfx+"MULT_D"); ObjectDelete(m_chartId, m_pfx+"MULT_D_T");
   ObjectDelete(m_chartId, m_pfx+"ET_N");   ObjectDelete(m_chartId, m_pfx+"ET_N_T");   ObjectDelete(m_chartId, m_pfx+"ET_E");    ObjectDelete(m_chartId, m_pfx+"ET_U");   ObjectDelete(m_chartId, m_pfx+"ET_U_T");   ObjectDelete(m_chartId, m_pfx+"ET_D");   ObjectDelete(m_chartId, m_pfx+"ET_D_T");
   ObjectDelete(m_chartId, m_pfx+"RLC_N");  ObjectDelete(m_chartId, m_pfx+"RLC_N_T");  ObjectDelete(m_chartId, m_pfx+"RLC_E");   ObjectDelete(m_chartId, m_pfx+"RLC_U");  ObjectDelete(m_chartId, m_pfx+"RLC_U_T");  ObjectDelete(m_chartId, m_pfx+"RLC_D");  ObjectDelete(m_chartId, m_pfx+"RLC_D_T");
   ObjectDelete(m_chartId, m_pfx+"TP_N");   ObjectDelete(m_chartId, m_pfx+"TP_N_T");   ObjectDelete(m_chartId, m_pfx+"TP_E");    ObjectDelete(m_chartId, m_pfx+"TP_U");   ObjectDelete(m_chartId, m_pfx+"TP_U_T");   ObjectDelete(m_chartId, m_pfx+"TP_D");   ObjectDelete(m_chartId, m_pfx+"TP_D_T");
   ObjectDelete(m_chartId, m_pfx+"SL_N");   ObjectDelete(m_chartId, m_pfx+"SL_N_T");   ObjectDelete(m_chartId, m_pfx+"SL_E");    ObjectDelete(m_chartId, m_pfx+"SL_U");   ObjectDelete(m_chartId, m_pfx+"SL_U_T");   ObjectDelete(m_chartId, m_pfx+"SL_D");   ObjectDelete(m_chartId, m_pfx+"SL_D_T");
   ObjectDelete(m_chartId, m_pfx + "MAIN");   ObjectDelete(m_chartId, m_pfx + "MAIN_T");
   if(ObjectFind(m_chartId, m_pfx + "DD_SEP") >= 0)
   {
      ObjectSetInteger(m_chartId, m_pfx + "DD_SEP", OBJPROP_XSIZE, 0);
      ObjectSetInteger(m_chartId, m_pfx + "DD_SEP", OBJPROP_YSIZE, 0);
   }
}

void CTradePanel::_OnExpand()
{
   _RebuildBtn(m_pfx + "SYM",
               m_x, _YDD(), _DDSymW(), TRADE_DD_H,
               m_symLabel, ESCAN_DD_BG, ESCAN_DD_FG, 8, ESCAN_DD_BDR);
   _RebuildBtn(m_pfx + "TF",
               m_x + _DDSymW(), _YDD(), _DDTFW(), TRADE_DD_H,
               m_tfLabel, ESCAN_DD_BG, ESCAN_DD_FG, 8, ESCAN_DD_BDR);
   if(ObjectFind(m_chartId, m_pfx + "DD_SEP") >= 0)
   {
      ObjectSetInteger(m_chartId, m_pfx + "DD_SEP", OBJPROP_XSIZE, 1);
      ObjectSetInteger(m_chartId, m_pfx + "DD_SEP", OBJPROP_YSIZE, TRADE_DD_H);
   }
   _DrawContent();
}


//+------------------------------------------------------------------+
//| OnMouseEvent                                                      |
//+------------------------------------------------------------------+
void CTradePanel::OnMouseEvent(int id, long lparam, double dparam,
                                const string &sparam)
{
   // Campo editable confirmado (Enter o click fuera del OBJ_EDIT)
   if(id == CHARTEVENT_OBJECT_ENDEDIT)
   {
      _HandleParamEdit(sparam);
      return;
   }

   if(id == CHARTEVENT_MOUSE_WHEEL)
   {
      int delta = (int)dparam;
      if(m_symPopupOpen)
      {
         int total = ArraySize(m_sortedSyms);
         if(delta > 0 && m_symPopupOffset > 0)
            { m_symPopupOffset--; _DrawSymPopup(); }
         else if(delta < 0 && m_symPopupOffset + ESCAN_POP_ROWS < total)
            { m_symPopupOffset++; _DrawSymPopup(); }
      }
      else if(m_tfPopupOpen)
      {
         int count = _TFCount();
         if(delta > 0 && m_tfPopupOffset > 0)
            { m_tfPopupOffset--; _DrawTFPopup(); }
         else if(delta < 0 && m_tfPopupOffset + ESCAN_POP_ROWS < count)
            { m_tfPopupOffset++; _DrawTFPopup(); }
      }
      return;
   }

   if(id == CHARTEVENT_MOUSE_MOVE)
   {
      int  mx      = (int)lparam;
      int  my      = (int)dparam;
      bool leftBtn = ((int)StringToInteger(sparam) & 1) != 0;

      {
         // Deshabilitar scroll del chart sobre panel Y popup abierto
         bool over = m_dragging || m_symPopupOpen || m_tfPopupOpen ||
                     (mx >= m_x && mx <= m_x + m_panelW
                      && my >= m_y && my <= m_y + _FullPanelH());
         ChartSetInteger(m_chartId, CHART_MOUSE_SCROLL, !over);
      }

      // Flanco de bajada con rearmado — GOT-018 (un botón que venía apretado
      // desde antes del Init no dispara: tapaba INICIAR bajo el popup TF).
      bool newClick = _IsNewClick(leftBtn);

      if(newClick && !m_dragging)
      {
         // Popup SYM abierto
         if(m_symPopupOpen)
         {
            int popY       = _YDD() + TRADE_DD_H;
            int rowH       = TRADE_ROW_H;
            int total      = ArraySize(m_sortedSyms);
            bool needScroll = (total > ESCAN_POP_ROWS);
            int popRows    = MathMin(ESCAN_POP_ROWS, total - m_symPopupOffset);
            int fullH      = popRows * rowH + (needScroll ? TRADE_DD_H : 0);
            bool clickedPop = (mx >= m_x && mx < m_x + _DDSymW()
                               && my >= popY && my < popY + fullH);
            if(clickedPop)
            {
               // Click en botones ▲▼
               if(needScroll && my >= popY + popRows * rowH)
               {
                  if(mx < m_x + _DDSymW() / 2)
                     { if(m_symPopupOffset > 0) { m_symPopupOffset--; _DrawSymPopup(); } }
                  else
                     { if(m_symPopupOffset + ESCAN_POP_ROWS < total) { m_symPopupOffset++; _DrawSymPopup(); } }
                  return;
               }
               // Click en fila
               int idx = (my - popY) / rowH + m_symPopupOffset;
               if(idx >= 0 && idx < total)
               {
                  m_symLabel   = m_sortedSyms[idx];
                  m_symIdx     = idx;
                  m_symChanged = true;

                  // ← NUEVO: Revalidar Lot si el nuevo símbolo tiene mínimo más alto
                  double newMinLot = SymbolInfoDouble(m_symLabel, SYMBOL_VOLUME_MIN);
                  if(newMinLot > 0.0 && m_lot < newMinLot)
                  {
                     m_lot = NormalizeDouble(newMinLot, 2);
                     ObjectSetString(m_chartId, m_pfx + "LOT_E", OBJPROP_TEXT, DoubleToString(m_lot, 2));
                     PrintFormat("[Panel] Lot re-validado por cambio de símbolo: %s → minLot=%s",
                                 m_symLabel, DoubleToString(newMinLot, 2));
                  }
                  _UpdateDepthWarning();   // specs del símbolo cambiaron

                  if(!m_collapsed)
                     _RebuildBtn(m_pfx + "SYM", m_x, _YDD(), _DDSymW(), TRADE_DD_H,
                                 m_symLabel, ESCAN_DD_BG, ESCAN_DD_FG, 8, ESCAN_DD_BDR);
               }
            }
            _CloseSymPopup();
            return;
         }

         // Popup TF abierto
         if(m_tfPopupOpen)
         {
            int popY       = _YDD() + TRADE_DD_H;
            int rowH       = TRADE_ROW_H;
            int count      = _TFCount();
            int popX       = m_x + _DDSymW();
            int popW       = _DDTFW();
            bool needScroll = (count > ESCAN_POP_ROWS);
            int popRows    = MathMin(ESCAN_POP_ROWS, count - m_tfPopupOffset);
            int fullH      = popRows * rowH + (needScroll ? TRADE_DD_H : 0);
            bool clickedPop = (mx >= popX && mx <= popX + popW
                               && my >= popY && my < popY + fullH);
            if(clickedPop)
            {
               // Click en botones ▲▼
               if(needScroll && my >= popY + popRows * rowH)
               {
                  if(mx < popX + popW / 2)
                     { if(m_tfPopupOffset > 0) { m_tfPopupOffset--; _DrawTFPopup(); } }
                  else
                     { if(m_tfPopupOffset + ESCAN_POP_ROWS < count) { m_tfPopupOffset++; _DrawTFPopup(); } }
                  return;
               }
               // Click en fila
               int idx = (my - popY) / rowH + m_tfPopupOffset;
               if(idx >= 0 && idx < count)
               {
                  m_tfIdx     = idx;
                  m_tfCurrent = _TFAt(idx);   // elección explícita del usuario (A-4)
                  m_tfLabel   = _TFLabel(_TFAt(idx));
                  m_tfChanged = true;
                  if(!m_collapsed)
                     _RebuildBtn(m_pfx + "TF", m_x + _DDSymW(), _YDD(), _DDTFW(), TRADE_DD_H,
                                 m_tfLabel, ESCAN_DD_BG, ESCAN_DD_FG, 8, ESCAN_DD_BDR);
               }
            }
            _CloseTFPopup();
            return;
         }

         // Chrome (CLOSE + TOGGLE) — heredado de CPanelBase
         _HandleChromeBtnClick(mx, my);

         if(!m_collapsed)
         {
            // SYM dropdown
            if(mx >= m_x && mx < m_x + _DDSymW()
               && my >= _YDD() && my < _YDD() + TRADE_DD_H)
            {
               _OpenSymPopup();
            }
            // TF dropdown
            else if(mx >= m_x + _DDSymW() && mx <= m_x + m_panelW
                    && my >= _YDD() && my < _YDD() + TRADE_DD_H)
            {
               _OpenTFPopup();
            }
            // SIM
            else if(mx >= m_x && mx < m_x + m_panelW/2
                    && my >= _YMode() && my < _YMode() + TRADE_MODE_H)
            {
               if(!m_isSim) { m_isSim = true; m_modeChanged = true; _DrawModeRow(); ChartRedraw(m_chartId); }
            }
            // REAL
            else if(mx >= m_x + m_panelW/2 && mx <= m_x + m_panelW
                    && my >= _YMode() && my < _YMode() + TRADE_MODE_H)
            {
               if(m_isSim) { m_isSim = false; m_modeChanged = true; _DrawModeRow(); ChartRedraw(m_chartId); }
            }
            // Botones ▲▼ de parámetros
            else if(my >= _YRow1() && my < _YRow3() + TRADE_ROW_H)
            {
               _HandleStepBtn(mx, my);
            }
            // INICIAR
            else if(mx >= m_x && mx <= m_x + m_panelW
                    && my >= _YMain() && my < _YMain() + TRADE_MAIN_H)
            {
               m_iniciarClicked = true;
            }
         }
      }

      _HandleDrag(mx, my, leftBtn);
      return;
   }

   // Cerrar popup al click fuera
   if(id == CHARTEVENT_CLICK)
   {
      // Este evento llega al SOLTAR: confirma el rearmado aunque MT5 no haya
      // mandado el MOUSE_MOVE de release (GOT-018).
      m_clickArmed = true;
      int cx = (int)lparam, cy = (int)dparam;
      if(m_symPopupOpen || m_tfPopupOpen)
      {
         if(cx < m_x || cx > m_x + m_panelW || cy < m_y)
            _CloseAllPopups();
      }
   }
}

//+------------------------------------------------------------------+
//| SetExcludedTFs                                                    |
//+------------------------------------------------------------------+
void CTradePanel::SetExcludedTFs(const string &excludedStr)
{
   const ENUM_TIMEFRAMES ALL[21] = {
      PERIOD_M1,PERIOD_M2,PERIOD_M3,PERIOD_M4,PERIOD_M5,PERIOD_M6,
      PERIOD_M10,PERIOD_M12,PERIOD_M15,PERIOD_M20,PERIOD_M30,
      PERIOD_H1,PERIOD_H2,PERIOD_H3,PERIOD_H4,PERIOD_H6,
      PERIOD_H8,PERIOD_H12,PERIOD_D1,PERIOD_W1,PERIOD_MN1
   };
   string excl[];
   int nExcl = StringSplit(excludedStr, ',', excl);
   for(int i = 0; i < nExcl; i++) { StringTrimLeft(excl[i]); StringTrimRight(excl[i]); StringToUpper(excl[i]); }
   m_tfListCount = 0;
   ArrayResize(m_tfList, 21);
   for(int i = 0; i < 21; i++)
   {
      string label = _TFLabel(ALL[i]);
      bool excluded = false;
      for(int j = 0; j < nExcl; j++) if(excl[j] == label) { excluded = true; break; }
      if(!excluded) m_tfList[m_tfListCount++] = ALL[i];
   }
   ArrayResize(m_tfList, m_tfListCount);
}

//+------------------------------------------------------------------+
//| TF utilities                                                      |
//+------------------------------------------------------------------+
string CTradePanel::_TFLabel(ENUM_TIMEFRAMES tf) const
{
   switch(tf)
   {
      case PERIOD_M1:  return "M1";   case PERIOD_M2:  return "M2";
      case PERIOD_M3:  return "M3";   case PERIOD_M4:  return "M4";
      case PERIOD_M5:  return "M5";   case PERIOD_M6:  return "M6";
      case PERIOD_M10: return "M10";  case PERIOD_M12: return "M12";
      case PERIOD_M15: return "M15";  case PERIOD_M20: return "M20";
      case PERIOD_M30: return "M30";  case PERIOD_H1:  return "H1";
      case PERIOD_H2:  return "H2";   case PERIOD_H3:  return "H3";
      case PERIOD_H4:  return "H4";   case PERIOD_H6:  return "H6";
      case PERIOD_H8:  return "H8";   case PERIOD_H12: return "H12";
      case PERIOD_D1:  return "D1";   case PERIOD_W1:  return "W1";
      case PERIOD_MN1: return "MN";
      default: return EnumToString(tf);
   }
}

ENUM_TIMEFRAMES CTradePanel::_TFAt(int idx) const
{
   if(idx < 0 || idx >= m_tfListCount) return PERIOD_H4;
   return m_tfList[idx];
}

void CTradePanel::_InitTFListFull()
{
   const ENUM_TIMEFRAMES ALL[21] = {
      PERIOD_M1,PERIOD_M2,PERIOD_M3,PERIOD_M4,PERIOD_M5,PERIOD_M6,
      PERIOD_M10,PERIOD_M12,PERIOD_M15,PERIOD_M20,PERIOD_M30,
      PERIOD_H1,PERIOD_H2,PERIOD_H3,PERIOD_H4,PERIOD_H6,
      PERIOD_H8,PERIOD_H12,PERIOD_D1,PERIOD_W1,PERIOD_MN1
   };
   m_tfListCount = 21;
   ArrayResize(m_tfList, 21);
   ArrayCopy(m_tfList, ALL);
}

//+------------------------------------------------------------------+
//| Popup SYM                                                         |
//+------------------------------------------------------------------+
void CTradePanel::_BuildSortedSyms()
{
   int total = SymbolsTotal(true);
   ArrayResize(m_sortedSyms, total);
   for(int i = 0; i < total; i++) m_sortedSyms[i] = SymbolName(i, true);
   // Insertion sort con orden natural (_NatCmp heredado): "GainX 600" < "GainX 1200"
   for(int i = 1; i < total; i++)
   {
      string key = m_sortedSyms[i]; int j = i - 1;
      while(j >= 0 && _NatCmp(m_sortedSyms[j], key) > 0)
         { m_sortedSyms[j+1] = m_sortedSyms[j]; j--; }
      m_sortedSyms[j+1] = key;
   }
}

void CTradePanel::_OpenSymPopup()
{
   _CloseTFPopup();
   _BuildSortedSyms();
   int total = ArraySize(m_sortedSyms);
   // Centrar en el símbolo actual
   m_symIdx = 0;
   for(int i = 0; i < total; i++)
      if(m_sortedSyms[i] == m_symLabel) { m_symIdx = i; break; }
   m_symPopupOffset = m_symIdx - ESCAN_POP_ROWS / 2;
   if(m_symPopupOffset < 0) m_symPopupOffset = 0;
   if(m_symPopupOffset + ESCAN_POP_ROWS > total)
      m_symPopupOffset = MathMax(0, total - ESCAN_POP_ROWS);
   m_symPopupOpen = true;
   ChartSetInteger(m_chartId, CHART_MOUSE_SCROLL, false);
   _DrawSymPopup();
}

void CTradePanel::_CloseSymPopup()
{
   m_symPopupOpen = false;
   ObjectsDeleteAll(m_chartId, m_pfx + "SPP_");
   if(!m_tfPopupOpen) ChartSetInteger(m_chartId, CHART_MOUSE_SCROLL, true);
}

void CTradePanel::_DrawSymPopup()
{
   ObjectsDeleteAll(m_chartId, m_pfx + "SPP_");
   int total      = ArraySize(m_sortedSyms);
   int rowH       = TRADE_ROW_H;
   bool needScroll = (total > ESCAN_POP_ROWS);
   int popRows    = MathMin(ESCAN_POP_ROWS, total - m_symPopupOffset);
   int popY       = _YDD() + TRADE_DD_H;
   int popW       = _DDSymW();
   int popH       = popRows * rowH + (needScroll ? TRADE_DD_H : 0);

   // Background — bloquea mouse scroll del chart mientras popup abierto
   string bgN = m_pfx + "SPP_BG";
   ObjectCreate(m_chartId, bgN, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(m_chartId, bgN, OBJPROP_CORNER,      CORNER_LEFT_UPPER);
   ObjectSetInteger(m_chartId, bgN, OBJPROP_XDISTANCE,   m_x);
   ObjectSetInteger(m_chartId, bgN, OBJPROP_YDISTANCE,   popY);
   ObjectSetInteger(m_chartId, bgN, OBJPROP_XSIZE,       popW);
   ObjectSetInteger(m_chartId, bgN, OBJPROP_YSIZE,       popH);
   ObjectSetInteger(m_chartId, bgN, OBJPROP_BGCOLOR,     ESCAN_DD_BG);
   ObjectSetInteger(m_chartId, bgN, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(m_chartId, bgN, OBJPROP_SELECTABLE,  false);
   ObjectSetInteger(m_chartId, bgN, OBJPROP_ZORDER,      ESCAN_POP_Z - 1);

   for(int i = 0; i < ESCAN_POP_ROWS; i++)
   {
      int    sIdx = m_symPopupOffset + i;
      if(sIdx >= total) break;
      string s    = m_pfx + "SPP_" + IntegerToString(i);
      color  bg   = (sIdx == m_symIdx) ? EPNL_ACCENT : ESCAN_DD_BG;
      _CreateLabel(s, m_x, popY + i*rowH, popW, rowH,
                   m_sortedSyms[sIdx], bg, ESCAN_DD_FG, 8, 0, true, ESCAN_DD_BDR);
      ObjectSetInteger(m_chartId, s,      OBJPROP_ZORDER, ESCAN_POP_Z);
      ObjectSetInteger(m_chartId, s+"_T", OBJPROP_ZORDER, ESCAN_POP_Z + 1);
   }

   string upN = m_pfx + "SPP_UP"; string dnN = m_pfx + "SPP_DN";
   if(needScroll)
   {
      int scrollY = popY + popRows * rowH;
      _RebuildBtn(upN, m_x,          scrollY, popW/2, TRADE_DD_H, "▲", ESCAN_DD_BG, ESCAN_DD_FG);
      _RebuildBtn(dnN, m_x + popW/2, scrollY, popW/2, TRADE_DD_H, "▼", ESCAN_DD_BG, ESCAN_DD_FG);
      ObjectSetInteger(m_chartId, upN, OBJPROP_ZORDER, ESCAN_POP_Z);
      ObjectSetInteger(m_chartId, dnN, OBJPROP_ZORDER, ESCAN_POP_Z);
      if(m_symPopupOffset == 0)
         ObjectSetInteger(m_chartId, upN, OBJPROP_XSIZE, 0);
      if(m_symPopupOffset + ESCAN_POP_ROWS >= total)
         ObjectSetInteger(m_chartId, dnN, OBJPROP_XSIZE, 0);
   }
   ChartRedraw(m_chartId);
}

//+------------------------------------------------------------------+
//| Popup TF                                                          |
//+------------------------------------------------------------------+
void CTradePanel::_OpenTFPopup()
{
   _CloseSymPopup();
   // Centrar en el TF actual
   m_tfPopupOffset = 0;
   if(m_tfIdx >= ESCAN_POP_ROWS)
      m_tfPopupOffset = m_tfIdx - ESCAN_POP_ROWS + 1;
   m_tfPopupOpen = true;
   ChartSetInteger(m_chartId, CHART_MOUSE_SCROLL, false);
   _DrawTFPopup();
}

void CTradePanel::_CloseTFPopup()
{
   m_tfPopupOpen = false;
   ObjectsDeleteAll(m_chartId, m_pfx + "TPP_");
   if(!m_symPopupOpen) ChartSetInteger(m_chartId, CHART_MOUSE_SCROLL, true);
}

void CTradePanel::_DrawTFPopup()
{
   ObjectsDeleteAll(m_chartId, m_pfx + "TPP_");
   int count      = _TFCount();
   int rowH       = TRADE_ROW_H;
   bool needScroll = (count > ESCAN_POP_ROWS);
   int popRows    = MathMin(ESCAN_POP_ROWS, count - m_tfPopupOffset);
   int popY       = _YDD() + TRADE_DD_H;
   int popX       = m_x + _DDSymW();
   int popW       = _DDTFW();
   int popH       = popRows * rowH + (needScroll ? TRADE_DD_H : 0);

   string bgN = m_pfx + "TPP_BG";
   ObjectCreate(m_chartId, bgN, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(m_chartId, bgN, OBJPROP_CORNER,      CORNER_LEFT_UPPER);
   ObjectSetInteger(m_chartId, bgN, OBJPROP_XDISTANCE,   popX);
   ObjectSetInteger(m_chartId, bgN, OBJPROP_YDISTANCE,   popY);
   ObjectSetInteger(m_chartId, bgN, OBJPROP_XSIZE,       popW);
   ObjectSetInteger(m_chartId, bgN, OBJPROP_YSIZE,       popH);
   ObjectSetInteger(m_chartId, bgN, OBJPROP_BGCOLOR,     ESCAN_DD_BG);
   ObjectSetInteger(m_chartId, bgN, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(m_chartId, bgN, OBJPROP_SELECTABLE,  false);
   ObjectSetInteger(m_chartId, bgN, OBJPROP_ZORDER,      ESCAN_POP_Z - 1);

   for(int i = 0; i < ESCAN_POP_ROWS; i++)
   {
      int    tIdx = m_tfPopupOffset + i;
      if(tIdx >= count) break;
      string s    = m_pfx + "TPP_" + IntegerToString(i);
      color  bg   = (tIdx == m_tfIdx) ? EPNL_ACCENT : ESCAN_DD_BG;
      _CreateLabel(s, popX, popY + i*rowH, popW, rowH,
                   _TFLabel(_TFAt(tIdx)), bg, ESCAN_DD_FG, 8, 0, true, ESCAN_DD_BDR);
      ObjectSetInteger(m_chartId, s,      OBJPROP_ZORDER, ESCAN_POP_Z);
      ObjectSetInteger(m_chartId, s+"_T", OBJPROP_ZORDER, ESCAN_POP_Z + 1);
   }

   string upN = m_pfx + "TPP_UP"; string dnN = m_pfx + "TPP_DN";
   if(needScroll)
   {
      int scrollY = popY + popRows * rowH;
      _RebuildBtn(upN, popX,          scrollY, popW/2, TRADE_DD_H, "▲", ESCAN_DD_BG, ESCAN_DD_FG);
      _RebuildBtn(dnN, popX + popW/2, scrollY, popW/2, TRADE_DD_H, "▼", ESCAN_DD_BG, ESCAN_DD_FG);
      ObjectSetInteger(m_chartId, upN, OBJPROP_ZORDER, ESCAN_POP_Z);
      ObjectSetInteger(m_chartId, dnN, OBJPROP_ZORDER, ESCAN_POP_Z);
      if(m_tfPopupOffset == 0)
         ObjectSetInteger(m_chartId, upN, OBJPROP_XSIZE, 0);
      if(m_tfPopupOffset + ESCAN_POP_ROWS >= count)
         ObjectSetInteger(m_chartId, dnN, OBJPROP_XSIZE, 0);
   }
   ChartRedraw(m_chartId);
}

//+------------------------------------------------------------------+
//| _RefreshField — actualiza texto de un OBJ_EDIT sin recrearlo    |
//+------------------------------------------------------------------+
void CTradePanel::_RefreshField(const string key, const string val)
{
   ObjectSetString(m_chartId, m_pfx + key, OBJPROP_TEXT, val);
   ChartRedraw(m_chartId);
}

//+------------------------------------------------------------------+
//| _HandleStepBtn — incrementa/decrementa parámetros con ▲▼        |
//|                                                                  |
//| Pasos: LOT=0.01, MULT=0.01, ET=1, RLC=1, TP%=1.0, SL%=1.0     |
//+------------------------------------------------------------------+
void CTradePanel::_HandleStepBtn(int mx, int my)
{
   if(m_collapsed) return;
   int hw  = m_panelW / 2;
   int ew  = hw - TRADE_LBL_W - TRADE_STEP_W;
   int bh  = TRADE_ROW_H / 2;

   // Columna izquierda: X del bloque ▲▼
   int bx1 = m_x + TRADE_LBL_W + ew;
   // Columna derecha
   int bx2 = m_x + hw + TRADE_LBL_W + ew;

   // Verifica si mx cae dentro de la columna de step buttons
   bool inLeft  = (mx >= bx1 && mx < bx1 + TRADE_STEP_W);
   bool inRight = (mx >= bx2 && mx < bx2 + TRADE_STEP_W);
   if(!inLeft && !inRight) return;

   // LOT / MULT — fila 1
   if(my >= _YRow1() && my < _YRow1() + TRADE_ROW_H)
   {
      bool up = (my < _YRow1() + bh);
      if(inLeft)
      {
         // El paso del lote es el VOLUME_STEP del BROKER, no 0.01 fijo (issue #63): en un
         // símbolo con min=0.1/step=0.1 el ▼ mostraba 0.01 y el broker ejecutaba 0.10 —
         // todo el riesgo proyectado del overlay quedaba 10× abajo de la posición real.
         string sym     = GetSymbol();
         double minLot  = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
         double lotStep = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
         if(lotStep <= 0.0) lotStep = 0.01;
         double minEff  = (minLot > 0.0) ? minLot : lotStep;
         double old     = m_lot;
         double v       = MathMax(minEff, MathMin(m_lotMax, m_lot + (up ? lotStep : -lotStep)));
         m_lot = NormalizeDouble(MathRound(v / lotStep) * lotStep, _LotDecimals(lotStep));
         _RefreshField("LOT_E", DoubleToString(m_lot, _LotDecimals(lotStep)));
         if(m_lot != old) m_paramsChanged = true;
      }
      else
      {
         double old = m_mult;
         m_mult = NormalizeDouble(MathMax(1.0, MathMin(TRADE_MAX_MULT, m_mult + (up ? 0.01 : -0.01))), 2);
         _RefreshField("MULT_E", DoubleToString(m_mult, 2));
         if(m_mult != old) m_paramsChanged = true;
      }
      _UpdateDepthWarning();
      return;
   }
   // ET / RLC — fila 2
   if(my >= _YRow2() && my < _YRow2() + TRADE_ROW_H)
   {
      bool up = (my < _YRow2() + bh);
      if(inLeft)
      {
         int old = m_et;
         if(up) { if(m_et < TRADE_MAX_ET) m_et++; } else if(m_et > 1) m_et--;
         _RefreshField("ET_E", IntegerToString(m_et));
         if(m_et != old) m_paramsChanged = true;
      }
      else
      {
         int old = m_rlc;
         if(up) { if(m_rlc < TRADE_MAX_RLC) m_rlc++; } else if(m_rlc > 0) m_rlc--;   // hasta 0 (M-1)
         _RefreshField("RLC_E", IntegerToString(m_rlc));
         if(m_rlc != old) { m_paramsChanged = true; m_geomChanged = true; }
      }
      _UpdateDepthWarning();
      return;
   }
   // FRAC% — fila 3 (columna izquierda; el TP% no existe en AuraX)
   if(my >= _YRow3() && my < _YRow3() + TRADE_ROW_H && inLeft)
   {
      bool up = (my < _YRow3() + bh);
      double old = m_sl;
      m_sl = NormalizeDouble(MathMax(0.0, MathMin(TRADE_MAX_PCT, m_sl + (up ? 1.0 : -1.0))), 1);
      _RefreshField("SL_E", DoubleToString(m_sl, 1));
      if(m_sl != old) { m_paramsChanged = true; m_geomChanged = true; }
      return;
   }
}

#endif // AURAX_TRADEPANEL_MQH
