//+------------------------------------------------------------------+
//| CBasketOverlay.mqh — Overlay interactivo del basket en gráfico  |
//| Versión: 3.3                                                     |
//|                                                                  |
//| Estética:                                                       |
//|   - Líneas con color por tipo: ENTRY naranja, TP verde,        |
//|     SL carmesí, recoveries gris (ámbar/gold si ya se abrieron). |
//|   - Etiquetas informativas a la izquierda, ancladas al primer   |
//|     bar visible (siguen el scroll):                            |
//|       "REC #1 | precio | Lot: 0.01 | DD: $-0.83 | TP Tar: $1.03"|
//|   - Grips (glifo blanco centrado, Arial Bold 10, fondo color): |
//|       ↕ izq = mover (gris) · ✕ der = cerrar (rojo) ·           |
//|       + = agregar recovery (verde), centrado en X, junto al    |
//|       último recovery.                                          |
//|   - Recoveries ya ejecutados (gold) no son arrastrables ni      |
//|     removibles — son posiciones reales (v5.41).                 |
//|                                                                  |
//| Cálculo de DD/TP-target/lot: interno (planificación pura desde  |
//|   geometría del grid), sin getters per-nivel de CBasketManager. |
//|   Portado de CSimOverlay.mqh.                                   |
//|                                                                  |
//| Interacción: hit-test del cursor en MOUSE_MOVE (modelo del      |
//|   panel CPanelBase). NO usa drag nativo de OBJ_HLINE.          |
//+------------------------------------------------------------------+
#include <AuraX/Trading/CRecoveryMath.mqh>

#define BOVL_MAX_REC    500    // máx recoveries (v6.50) — acoplado a TRADE_MAX_RLC (panel) y CBM_MAX_POS=N+1 (basket)
#define BOVL_BTN_W      18     // ancho handle (glifo único centrado)
#define BOVL_BTN_H      15     // alto handle — 2px extra para que el bounding box de ↕/✕ no sobresalga
#define BOVL_LEFT_X      3     // X del grip mover (↕) desde el margen IZQUIERDO
#define BOVL_RIGHT_X     3     // X del grip cerrar (✕) desde el margen DERECHO
#define BOVL_GLYPH_CLOSE "✕"  // cerrar recovery
#define BOVL_GLYPH_ADD   "+"  // agregar recovery
#define BOVL_GLYPH_DRAG  "↕"  // arrastrar nivel
#define BOVL_LBL_MARGIN  3.0   // % del rango visible para anclar la etiqueta

// Clase de nivel en arrastre
#define BOVL_DK_NONE    0
#define BOVL_DK_ENTRY   1
#define BOVL_DK_TP      2
#define BOVL_DK_SL      3
#define BOVL_DK_REC     4

// Colores de líneas — jerarquía visual: ENTRY (naranja) > TP/SL (verde/carmesí) > recoveries (gris/ámbar)
// Tema "premium rojo & negro" (2026-10-30). Literales C'r,g,b' (el hex de MQL5 es BGR).
#define BOVL_CLR_ENTRY    C'255,255,255'  // entrada — blanco: el nivel ancla, neutro y prominente
#define BOVL_CLR_TP       C'43,210,126'   // TP — verde (objetivo de ganancia)
#define BOVL_CLR_TP_DIS   C'160,160,160'  // TP DESARMADO — gris: visible y arrastrable, NO operativo
#define BOVL_CLR_SL       C'225,15,46'    // SL / fracción — el rojo de acento del tema
#define BOVL_CLR_REC_OPEN C'245,184,0'    // recovery ya abierto — dorado, no compite con TP/SL
#define BOVL_CLR_REC_FUT  C'125,125,125'  // recovery futuro — gris (más claro: sobre negro se perdía)

// Handles: fondo de color vivo + glifo blanco → máximo contraste sobre el gráfico.
#define BOVL_BG_CLOSE   C'17,17,17'        // ✕ — fondo negro (el glifo lleva el color)
#define BOVL_BG_ADD     C'17,17,17'        // + — fondo negro
#define BOVL_BG_DRAG    C'17,17,17'        // ↕ — fondo negro
#define BOVL_FG_CLOSE   C'225,15,46'       // ✕ — rojo de acento
#define BOVL_FG_ADD     C'230,230,230'     // + — blanco
#define BOVL_FG_DRAG    C'154,154,154'     // ↕ — gris
#define BOVL_H_BDR      C'58,58,58'        // borde sutil de los grips

// Etiquetas de nivel: [CLAVE] en caja del color de la línea + [detalle] en caja negra,
// ancladas en píxeles a la derecha del grip ↕ (legibles encima de las velas).
#define BOVL_TAG_X        (BOVL_LEFT_X + BOVL_BTN_W + 4)  // X px de la etiqueta
#define BOVL_TAG_PAD      6               // padding horizontal dentro de cada caja
#define BOVL_TAG_FSZ      8               // tamaño de letra (pt)
#define BOVL_TAG_KEY_FONT "Segoe UI Semibold"
#define BOVL_TAG_TXT_FONT "Consolas"      // números alineados por dígito
#define BOVL_TAG_BG       C'14,14,14'     // fondo de la caja de detalle
#define BOVL_TAG_TXT_FG   C'230,230,230'  // texto del detalle
#define BOVL_KEY_DARK     C'10,10,10'     // texto de la clave sobre colores claros
#define BOVL_KEY_LIGHT    C'255,255,255'  // texto de la clave sobre colores oscuros
#define BOVL_TAG_Z        4800            // debajo de los grips (4900) y del panel (9000)
#define BOVL_PX_GAP       4               // separación caja de precio ↔ grip ✕ (borde derecho)

class CBasketOverlay
{
private:
   long            m_chartId;
   string          m_pfx;
   int             m_digits;
   string          m_symbol;
   ENUM_TIMEFRAMES m_period;
   bool            m_open;
   bool            m_preview;       // true = preview antes de INICIAR (visual read-only)
   bool            m_recCountChanged; // setteado por _AddRecovery/_RemoveRecovery; consumido por el EA
   bool            m_isBuy;

   double m_entry;
   double m_tp;   bool m_tpEnabled;
   // true = TP operativo (verde, el basket lo evalúa) / false = DESARMADO (gris punteado,
   // el basket tiene tp=0). Reporte del PO 2026-08-02 ("a veces no veo la línea de tp para
   // arrastrar"): hasta v6.39 un TP desarmado no dibujaba NADA — ahora siempre hay línea.
   bool   m_tpArmedVis;
   double m_sl;   bool m_slEnabled;

   double m_rec[BOVL_MAX_REC];
   bool   m_recDecoupled[BOVL_MAX_REC];
   bool   m_tpDecoupled;   // true = el usuario arrastró el TP a mano → no auto-actualizar (no snap-back)
   bool   m_slDecoupled;   // true = el usuario arrastró el SL a mano → _TickLiveSl no lo pisa (no snap-back)
   bool   m_entryDecoupled; // true = el usuario arrastró el ENTRY a mano → SIM→REAL difiere a ese precio (issue #53)
   int    m_recCount;

   // Parámetros y métricas de planificación
   double m_baseLot;
   double m_mul;
   int    m_et;           // every-trade: cadencia con que sube el multiplicador (debe espejar el basket)
   double m_lotAt    [BOVL_MAX_REC + 1];
   double m_ddAtRec  [BOVL_MAX_REC + 1];
   double m_tpTarAtRec[BOVL_MAX_REC + 1];
   double m_ddAtFrac;
   int    m_openedRecs;   // recoveries ya abiertos (color amarillo)
   double m_pnl;          // P&L live para la etiqueta de entrada
   bool   m_isReal;       // true = mostrar P&L en la etiqueta de entrada
   bool   m_entryLocked; // true = posición real ejecutada — ENTRY no arrastrable

   bool     m_entryCloseClicked; // flag: usuario hizo ✕ en la línea ENTRY

   // Cache del tiempo de ancla de etiquetas (primer bar visible + margen)
   datetime m_anchorCache;
   bool     m_anchorDirty;

   // Máquina de estados del arrastre (modelo CPanelBase)
   bool   m_dragging;
   int    m_dragKind;
   int    m_dragRec;
   bool   m_prevLeftBtn;
   bool   m_clickArmed;   // false hasta ver el botón izquierdo SUELTO — GOT-018
   uint   m_lastDragMs;   // GetTickCount del último evento de drag — watchdog A-2

   // Rectángulo EXCLUIDO del hit-test — el panel de trading (issue #56). El EA lo
   // actualiza cada timer (el panel se puede arrastrar). Ningún click adentro puede
   // agarrar una línea ni pegarle a un grip. x2<x1 = sin exclusión.
   int    m_exclX1, m_exclY1, m_exclX2, m_exclY2;
   // AuraX: segundo rectángulo excluido — el panel del scanner (va al lado del de trading).
   int    m_excl2X1, m_excl2Y1, m_excl2X2, m_excl2Y2;

   bool _InExclusion(int mx, int my) const
   {
      bool in1 = m_exclX2 >= m_exclX1
                 && mx >= m_exclX1 && mx <= m_exclX2
                 && my >= m_exclY1 && my <= m_exclY2;
      bool in2 = m_excl2X2 >= m_excl2X1
                 && mx >= m_excl2X1 && mx <= m_excl2X2
                 && my >= m_excl2Y1 && my <= m_excl2Y2;
      return in1 || in2;
   }

   //| true SOLO en el flanco de bajada del botón izquierdo, y solo si el overlay
   //| ya vio el botón suelto desde su Init/Open (GOT-018): un botón que venía
   //| apretado desde antes (INICIAR, o un re-init por cambio de símbolo/TF) no
   //| debe agarrar una línea ni pegarle a los grips.
   bool _IsNewClick(bool leftBtn)
   {
      bool isNew = leftBtn && !m_prevLeftBtn && m_clickArmed;
      if(!leftBtn) m_clickArmed = true;
      m_prevLeftBtn = leftBtn;
      return isNew;
   }

   //--- Nombres -----------------------------------------------------
   string _N(const string t)    const { return m_pfx + "BOV_" + t; }
   string _RecN(int i)          const { return _N("R"   + IntegerToString(i)); }
   string _MvN(const string t)  const { return _N("MV_" + t); }
   string _MvNT(const string t) const { return _N("MVT_"+ t); }
   string _ClN(const string t)  const { return _N("CL_" + t); }
   string _ClNT(const string t) const { return _N("CLT_"+ t); }
   string _RMvN(int i)          const { return _MvN("R" + IntegerToString(i)); }
   string _RMvNT(int i)         const { return _MvNT("R"+ IntegerToString(i)); }
   string _RClN(int i)          const { return _ClN("R" + IntegerToString(i)); }
   string _RClNT(int i)         const { return _ClNT("R"+ IntegerToString(i)); }
   string _TxtN(const string t) const { return _N("TXT_" + t); }
   string _RTxtN(int i)         const { return _TxtN("R" + IntegerToString(i)); }

   string _Px(double price) const { return DoubleToString(price, m_digits); }

   double _CF() const
   {
      double ts = SymbolInfoDouble(m_symbol, SYMBOL_TRADE_TICK_SIZE);
      double tv = SymbolInfoDouble(m_symbol, SYMBOL_TRADE_TICK_VALUE);
      return (ts > 0.0) ? tv / ts : 0.0;
   }

   // Precio del nivel k: 0=entry, 1..recCount=recovery#k
   double _LevelPx(int k) const { return (k == 0) ? m_entry : m_rec[k-1]; }

   //+----------------------------------------------------------------+
   //| _ComputeLevels — lot/DD/TP-target por nivel (planificación)   |
   //+----------------------------------------------------------------+
   void _ComputeLevels(CBasketManager *basket = NULL)
   {
      double cf = _CF();
      // Lot del recovery k: RecoveryLotAt (CRecoveryMath.mqh) — fuente única compartida con
      // CBasketManager::Update() desde 2026-08-04. Antes esta fórmula estaba duplicada acá
      // (issue original: divergía y el overlay podía mostrar una ganancia que el bróker no daba).
      //
      // Refinamiento 2026-08-06 (reporte PO: "no me dan los números, fijate el TP" — Target $):
      // esa fuente única asumía LOT/MULT constantes durante toda la vida del basket. Nada lo
      // impide: el usuario puede bajar MULT con recoveries YA llenos, y la fórmula recalculaba
      // TODOS los niveles (incluidos los ejecutados) con el MULT nuevo — el Target $ dejaba de
      // representar la grilla real. Los niveles YA EJECUTADOS (idx <= m_openedRecs) ahora leen
      // su lote real vía basket.GetPosLot(idx); solo los TODAVÍA no disparados (planificación)
      // usan la fórmula con los parámetros vigentes. basket==NULL (p.ej. durante un drag en
      // curso, o al abrir con m_openedRecs=0) conserva el comportamiento de fórmula de siempre.
      double vMin  = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_MIN);
      double vMax  = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_MAX);
      double vStep = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_STEP);
      double realLot0 = (basket != NULL) ? basket.GetPosLot(0) : 0.0;
      m_lotAt[0] = (realLot0 > 0.0) ? realLot0 : m_baseLot;
      for(int k = 1; k <= m_recCount; k++)
      {
         double realLot = (basket != NULL && k <= m_openedRecs) ? basket.GetPosLot(k) : 0.0;
         m_lotAt[k] = (realLot > 0.0) ? realLot
                                       : RecoveryLotAt(m_baseLot, m_mul, m_et, k, vMin, vMax, vStep);
      }

      for(int n = 1; n <= m_recCount; n++)
      {
         double dd = 0.0;
         for(int k = 0; k < n; k++)
         {
            double diff = m_isBuy ? (_LevelPx(n) - _LevelPx(k))
                                  : (_LevelPx(k) - _LevelPx(n));
            dd += diff * m_lotAt[k] * cf;
         }
         m_ddAtRec[n] = dd;
      }

      for(int n = 0; n <= m_recCount; n++)
      {
         double g = 0.0;
         if(m_tpEnabled)
            for(int k = 0; k <= n; k++)
            {
               double diff = m_isBuy ? (m_tp - _LevelPx(k)) : (_LevelPx(k) - m_tp);
               g += diff * m_lotAt[k] * cf;
            }
         m_tpTarAtRec[n] = g;
      }

      m_ddAtFrac = 0.0;
      if(m_slEnabled)
         for(int k = 0; k <= m_recCount; k++)
         {
            double diff = m_isBuy ? (m_sl - _LevelPx(k)) : (_LevelPx(k) - m_sl);
            m_ddAtFrac += diff * m_lotAt[k] * cf;
         }
   }

   //+----------------------------------------------------------------+
   //| _AnchorTime — tiempo del primer bar visible + margen          |
   //| Mantiene la etiqueta ~margen% desde el borde izquierdo.       |
   //+----------------------------------------------------------------+
   datetime _AnchorTime()
   {
      if(!m_anchorDirty && m_anchorCache != 0) return m_anchorCache;
      long vis   = ChartGetInteger(m_chartId, CHART_VISIBLE_BARS);
      long first = ChartGetInteger(m_chartId, CHART_FIRST_VISIBLE_BAR);
      if(vis <= 0) { m_anchorCache = TimeCurrent(); m_anchorDirty = false; return m_anchorCache; }
      int margin = (int)MathMax(2, vis * BOVL_LBL_MARGIN / 100.0);
      int bar    = (int)(first - margin);
      if(bar < 0) bar = (int)first;
      datetime t = iTime(m_symbol, m_period, bar);
      m_anchorCache = (t > 0) ? t : TimeCurrent();
      m_anchorDirty = false;
      return m_anchorCache;
   }

   //+----------------------------------------------------------------+
   //| Conversión precio↔píxel                                       |
   //+----------------------------------------------------------------+
   int _PriceToY(double price) const
   {
      int fb = (int)ChartGetInteger(m_chartId, CHART_FIRST_VISIBLE_BAR);
      datetime t = iTime(m_symbol, m_period, fb);
      if(t <= 0) t = TimeCurrent();
      int x = 0, y = 0;
      if(!ChartTimePriceToXY(m_chartId, 0, t, price, x, y)) return -1;
      return y - BOVL_BTN_H / 2;
   }

   double _YToPrice(int yPix) const
   {
      int      sub   = 0;
      datetime t     = 0;
      double   price = 0.0;
      if(!ChartXYToTimePrice(m_chartId, 100, yPix, sub, t, price)) return -1;
      return price;
   }

   int _ChartW() const { return (int)ChartGetInteger(m_chartId, CHART_WIDTH_IN_PIXELS); }

   bool _HitLeft(int mx, int my, int y) const
   {
      if(y < 0) return false;
      return mx >= BOVL_LEFT_X && mx <= BOVL_LEFT_X + BOVL_BTN_W
             && my >= y && my <= y + BOVL_BTN_H;
   }
   bool _HitRight(int mx, int my, int y, int xOff) const
   {
      if(y < 0) return false;
      int x0 = _ChartW() - xOff - BOVL_BTN_W;
      return mx >= x0 && mx <= x0 + BOVL_BTN_W
             && my >= y && my <= y + BOVL_BTN_H;
   }
   // Hit-test del grip [+] centrado horizontalmente (mismo cálculo que _DrawAddBtn).
   bool _HitCenter(int mx, int my, int y) const
   {
      if(y < 0) return false;
      int x0 = (_ChartW() - BOVL_BTN_W) / 2;
      return mx >= x0 && mx <= x0 + BOVL_BTN_W
             && my >= y && my <= y + BOVL_BTN_H;
   }

   //+----------------------------------------------------------------+
   //| _MkHLine — línea horizontal (detrás de velas, no nativa)      |
   //+----------------------------------------------------------------+
   void _MkHLine(const string name, double price, color clr, int style, int width)
   {
      ObjectDelete(m_chartId, name);
      if(!ObjectCreate(m_chartId, name, OBJ_HLINE, 0, 0, price)) return;
      ObjectSetInteger(m_chartId, name, OBJPROP_COLOR,      clr);
      ObjectSetInteger(m_chartId, name, OBJPROP_WIDTH,      width);
      ObjectSetInteger(m_chartId, name, OBJPROP_STYLE,      style);
      ObjectSetInteger(m_chartId, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(m_chartId, name, OBJPROP_BACK,       true);   // detrás de las velas
      ObjectSetInteger(m_chartId, name, OBJPROP_HIDDEN,     true);
      ObjectSetString(m_chartId,  name, OBJPROP_TEXT,       "");
   }

   void _MvHLine(const string name, double price)
   {
      if(ObjectFind(m_chartId, name) >= 0)
         ObjectSetDouble(m_chartId, name, OBJPROP_PRICE, price);
   }

   //+----------------------------------------------------------------+
   //| _Tag — etiqueta de nivel: [CLAVE] + [detalle], en píxeles      |
   //|                                                                |
   //| Va sobre la línea, a la derecha del grip ↕. Reemplaza el texto |
   //| suelto anterior (OBJ_TEXT), que no se leía encima de las velas.|
   //| name es la base: crea name_K/_KT (clave), name_D/_DT (detalle) |
   //| y name_P/_PT (precio, a la derecha junto al grip ✕).           |
   //+----------------------------------------------------------------+
   void _Tag(const string name, double price, const string key, const string detail,
             color clr, color keyFg)
   {
      int y  = _PriceToY(price);   // top del grip: la etiqueta tiene su mismo alto
      int kw = _TextW(key,    BOVL_TAG_KEY_FONT) + 2 * BOVL_TAG_PAD;
      int dw = _TextW(detail, BOVL_TAG_TXT_FONT) + 2 * BOVL_TAG_PAD;
      _TagBox (name + "_K",  CORNER_LEFT_UPPER, BOVL_TAG_X,      y, kw, clr, clr);
      _TagText(name + "_KT", CORNER_LEFT_UPPER, BOVL_TAG_X + kw / 2, y, key, keyFg, BOVL_TAG_KEY_FONT);
      _TagBox (name + "_D",  CORNER_LEFT_UPPER, BOVL_TAG_X + kw, y, dw, BOVL_TAG_BG, clr);
      _TagText(name + "_DT", CORNER_LEFT_UPPER, BOVL_TAG_X + kw + dw / 2, y, detail, BOVL_TAG_TXT_FG, BOVL_TAG_TXT_FONT);

      // Precio del nivel a la derecha (la escala de MT5 no muestra los OBJ_HLINE del overlay).
      // Esquina derecha: sigue al borde del gráfico solo, aunque se redimensione la ventana.
      string px  = _Px(price);
      int    pw  = _TextW(px, BOVL_TAG_TXT_FONT) + 2 * BOVL_TAG_PAD;
      int    pxR = BOVL_RIGHT_X + BOVL_BTN_W + BOVL_PX_GAP;   // borde derecho de la caja
      _TagBox (name + "_P",  CORNER_RIGHT_UPPER, pxR + pw,     y, pw, clr, clr);
      _TagText(name + "_PT", CORNER_RIGHT_UPPER, pxR + pw / 2, y, px, keyFg, BOVL_TAG_TXT_FONT);
      _ShowTag(name, y >= 0);
   }

   //| Reubica una etiqueta existente en Y (scroll/zoom) sin redibujarla.
   void _MvTag(const string name, double price)
   {
      if(ObjectFind(m_chartId, name + "_K") < 0) return;
      int y = _PriceToY(price);
      _ShowTag(name, y >= 0);
      if(y < 0) return;
      ObjectSetInteger(m_chartId, name + "_K",  OBJPROP_YDISTANCE, y);
      ObjectSetInteger(m_chartId, name + "_D",  OBJPROP_YDISTANCE, y);
      ObjectSetInteger(m_chartId, name + "_P",  OBJPROP_YDISTANCE, y);
      ObjectSetInteger(m_chartId, name + "_KT", OBJPROP_YDISTANCE, y + BOVL_BTN_H / 2);
      ObjectSetInteger(m_chartId, name + "_DT", OBJPROP_YDISTANCE, y + BOVL_BTN_H / 2);
      ObjectSetInteger(m_chartId, name + "_PT", OBJPROP_YDISTANCE, y + BOVL_BTN_H / 2);
   }

   void _DelTag(const string name)
   {
      ObjectDelete(m_chartId, name + "_K");  ObjectDelete(m_chartId, name + "_KT");
      ObjectDelete(m_chartId, name + "_D");  ObjectDelete(m_chartId, name + "_DT");
      ObjectDelete(m_chartId, name + "_P");  ObjectDelete(m_chartId, name + "_PT");
   }

   //| Fuera del rango visible se oculta (no se borra) para poder volver con _MvTag.
   void _ShowTag(const string name, bool visible)
   {
      long tf = visible ? OBJ_ALL_PERIODS : OBJ_NO_PERIODS;
      ObjectSetInteger(m_chartId, name + "_K",  OBJPROP_TIMEFRAMES, tf);
      ObjectSetInteger(m_chartId, name + "_KT", OBJPROP_TIMEFRAMES, tf);
      ObjectSetInteger(m_chartId, name + "_D",  OBJPROP_TIMEFRAMES, tf);
      ObjectSetInteger(m_chartId, name + "_DT", OBJPROP_TIMEFRAMES, tf);
      ObjectSetInteger(m_chartId, name + "_P",  OBJPROP_TIMEFRAMES, tf);
      ObjectSetInteger(m_chartId, name + "_PT", OBJPROP_TIMEFRAMES, tf);
   }

   int _TextW(const string txt, const string font) const
   {
      uint w = 0, h = 0;
      TextSetFont(font, -BOVL_TAG_FSZ * 10);   // negativo = décimas de punto
      TextGetSize(txt, w, h);
      return (int)w;
   }

   //| Caja de etiqueta. x es la distancia al borde de la esquina hasta el lado IZQUIERDO
   //| de la caja (así ancla MT5 los OBJ_RECTANGLE_LABEL en cualquier esquina).
   void _TagBox(const string name, ENUM_BASE_CORNER corner, int x, int y, int w, color bg, color bdr)
   {
      if(ObjectFind(m_chartId, name) < 0)
         ObjectCreate(m_chartId, name, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(m_chartId, name, OBJPROP_CORNER,      corner);
      ObjectSetInteger(m_chartId, name, OBJPROP_XDISTANCE,   x);
      ObjectSetInteger(m_chartId, name, OBJPROP_YDISTANCE,   (y < 0 ? 0 : y));
      ObjectSetInteger(m_chartId, name, OBJPROP_XSIZE,       w);
      ObjectSetInteger(m_chartId, name, OBJPROP_YSIZE,       BOVL_BTN_H);
      ObjectSetInteger(m_chartId, name, OBJPROP_BGCOLOR,     bg);
      ObjectSetInteger(m_chartId, name, OBJPROP_COLOR,       bdr);
      ObjectSetInteger(m_chartId, name, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(m_chartId, name, OBJPROP_SELECTABLE,  false);
      ObjectSetInteger(m_chartId, name, OBJPROP_HIDDEN,      true);
      ObjectSetInteger(m_chartId, name, OBJPROP_ZORDER,      BOVL_TAG_Z);
   }

   void _TagText(const string name, ENUM_BASE_CORNER corner, int xc, int y, const string txt,
                 color fg, const string font)
   {
      if(ObjectFind(m_chartId, name) < 0)
         ObjectCreate(m_chartId, name, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(m_chartId, name, OBJPROP_CORNER,     corner);
      ObjectSetInteger(m_chartId, name, OBJPROP_XDISTANCE,  xc);
      ObjectSetInteger(m_chartId, name, OBJPROP_YDISTANCE,  (y < 0 ? 0 : y) + BOVL_BTN_H / 2);
      ObjectSetInteger(m_chartId, name, OBJPROP_ANCHOR,     ANCHOR_CENTER);
      ObjectSetString (m_chartId, name, OBJPROP_TEXT,       txt);
      ObjectSetString (m_chartId, name, OBJPROP_FONT,       font);
      ObjectSetInteger(m_chartId, name, OBJPROP_FONTSIZE,   BOVL_TAG_FSZ);
      ObjectSetInteger(m_chartId, name, OBJPROP_COLOR,      fg);
      ObjectSetInteger(m_chartId, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(m_chartId, name, OBJPROP_HIDDEN,     true);
      ObjectSetInteger(m_chartId, name, OBJPROP_ZORDER,     BOVL_TAG_Z + 1);
   }

   bool _IsRightCorner(ENUM_BASE_CORNER corner) const
   {
      return corner == CORNER_RIGHT_UPPER || corner == CORNER_RIGHT_LOWER;
   }

   //+----------------------------------------------------------------+
   //| _MkHandle / _MvHandle — grips pixelados                        |
   //+----------------------------------------------------------------+
   void _MkHandle(const string name, const string nameT,
                  ENUM_BASE_CORNER corner, int xOff, int y,
                  color bg, const string txt, color fg)
   {
      if(y < 0) return;
      ObjectDelete(m_chartId, name);
      ObjectDelete(m_chartId, nameT);
      if(!ObjectCreate(m_chartId, name, OBJ_RECTANGLE_LABEL, 0, 0, 0)) return;
      ObjectSetInteger(m_chartId, name, OBJPROP_CORNER,      corner);
      // Un OBJ_RECTANGLE_LABEL se ancla SIEMPRE por su esquina superior izquierda: en las
      // esquinas derechas hay que sumarle su ancho, si no la caja queda casi toda fuera del
      // gráfico (los ✕ se veían como un glifo suelto). Así coincide con _HitRight.
      ObjectSetInteger(m_chartId, name, OBJPROP_XDISTANCE,   _IsRightCorner(corner) ? xOff + BOVL_BTN_W : xOff);
      ObjectSetInteger(m_chartId, name, OBJPROP_YDISTANCE,   y);
      ObjectSetInteger(m_chartId, name, OBJPROP_XSIZE,       BOVL_BTN_W);
      ObjectSetInteger(m_chartId, name, OBJPROP_YSIZE,       BOVL_BTN_H);
      ObjectSetInteger(m_chartId, name, OBJPROP_BGCOLOR,     bg);
      // El ✕ lleva borde rojo: es la acción destructiva del overlay y tiene que encontrarse rápido.
      ObjectSetInteger(m_chartId, name, OBJPROP_COLOR,       txt == BOVL_GLYPH_CLOSE ? BOVL_FG_CLOSE : BOVL_H_BDR);
      ObjectSetInteger(m_chartId, name, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(m_chartId, name, OBJPROP_SELECTABLE,  false);
      ObjectSetInteger(m_chartId, name, OBJPROP_ZORDER,      4900);
      if(!ObjectCreate(m_chartId, nameT, OBJ_LABEL, 0, 0, 0)) return;
      ObjectSetInteger(m_chartId, nameT, OBJPROP_CORNER,     corner);
      // Glifo centrado: ANCHOR_CENTER en el punto medio del rectángulo.
      // BTN_H=15 da margen suficiente para que el bounding box Unicode no sobresalga.
      ObjectSetInteger(m_chartId, nameT, OBJPROP_XDISTANCE,  xOff + BOVL_BTN_W / 2);
      ObjectSetInteger(m_chartId, nameT, OBJPROP_YDISTANCE,  y + BOVL_BTN_H / 2);
      ObjectSetInteger(m_chartId, nameT, OBJPROP_ANCHOR,     ANCHOR_CENTER);
      ObjectSetInteger(m_chartId, nameT, OBJPROP_COLOR,      fg);
      ObjectSetInteger(m_chartId, nameT, OBJPROP_FONTSIZE,   9);
      ObjectSetString(m_chartId,  nameT, OBJPROP_FONT,       "Arial Bold");
      ObjectSetString(m_chartId,  nameT, OBJPROP_TEXT,       txt);
      ObjectSetInteger(m_chartId, nameT, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(m_chartId, nameT, OBJPROP_ZORDER,     4901);
   }

   void _MvHandle(const string name, const string nameT, int y)
   {
      if(y < 0) { ObjectDelete(m_chartId, name); ObjectDelete(m_chartId, nameT); return; }
      if(ObjectFind(m_chartId, name)  >= 0)
         ObjectSetInteger(m_chartId, name,  OBJPROP_YDISTANCE, y);
      if(ObjectFind(m_chartId, nameT) >= 0)
         ObjectSetInteger(m_chartId, nameT, OBJPROP_YDISTANCE, y + BOVL_BTN_H / 2); // ANCHOR_CENTER
   }

   color _RecColor(int n) const
   {
      return (n <= m_openedRecs) ? BOVL_CLR_REC_OPEN : BOVL_CLR_REC_FUT;
   }

   //+----------------------------------------------------------------+
   //| _DrawLabels — (re)dibuja todas las etiquetas de texto          |
   //+----------------------------------------------------------------+
   void _DrawLabels()
   {
      string dir = m_isBuy ? "BUY" : "SELL";

      string entryDet = "@ " + _Px(m_entry);
      if(m_isReal) entryDet += StringFormat("  ·  P&L $%.2f", m_pnl);
      _Tag(_TxtN("ENTRY"), m_entry, StringFormat("%s %.2f", dir, m_baseLot), entryDet,
           BOVL_CLR_ENTRY, BOVL_KEY_DARK);

      if(m_tpEnabled)
      {
         int oc = MathMin(m_openedRecs, m_recCount);
         if(m_tpArmedVis)
            _Tag(_TxtN("TP"), m_tp, "TP",
                 StringFormat("%s  ·  Target $%.2f", _Px(m_tp), m_tpTarAtRec[oc]),
                 BOVL_CLR_TP, BOVL_KEY_DARK);
         else
            _Tag(_TxtN("TP"), m_tp, "TP OFF",
                 StringFormat("%s  ·  se activa del lado ganador", _Px(m_tp)),
                 BOVL_CLR_TP_DIS, BOVL_KEY_DARK);
      }
      if(m_slEnabled)
         _Tag(_TxtN("SL"), m_sl, "FRACCIÓN",
              StringFormat("%s  ·  DD $%.2f", _Px(m_sl), m_ddAtFrac),
              BOVL_CLR_SL, BOVL_KEY_LIGHT);

      // Las órdenes ACTIVAS (n <= m_openedRecs) son un CONJUNTO: comparten el mismo TP y su DD/TP
      // es el del conjunto (valor en el nivel activo más profundo). Las PENDIENTES muestran su
      // propio nivel (qué pasaría si se activan hasta ahí). ADR-032.
      for(int n = 1; n <= m_recCount; n++)
      {
         bool   active = (n <= m_openedRecs && m_openedRecs >= 1);
         int    vi     = active ? m_openedRecs : n;   // índice del valor a mostrar
         string state  = active ? "CONJUNTO  ·  " : (m_recDecoupled[n-1] ? "FIJO  ·  " : "");
         _Tag(_RTxtN(n), m_rec[n-1], "REC " + IntegerToString(n),
              StringFormat("%s%s  ·  Lot %.2f  ·  DD $%.2f  ·  TP $%.2f",
                           state, _Px(m_rec[n-1]), m_lotAt[n], m_ddAtRec[vi], m_tpTarAtRec[vi]),
              _RecColor(n), (n <= m_openedRecs) ? BOVL_KEY_DARK : BOVL_KEY_LIGHT);
      }
   }

   //+----------------------------------------------------------------+
   //| _DrawRec — línea + handles + etiqueta de recovery i (0-based) |
   //+----------------------------------------------------------------+
   void _DrawRec(int i)
   {
      int    n     = i + 1;
      color  clr   = _RecColor(n);
      int    style = m_recDecoupled[i] ? STYLE_DASH : STYLE_DOT;
      int    width = m_recDecoupled[i] ? 2 : 1;
      _MkHLine(_RecN(i), m_rec[i], clr, style, width);
      int  y      = _PriceToY(m_rec[i]);
      bool future = (i >= m_openedRecs);
      // Recoveries ya ejecutados en REAL (gold, i < m_openedRecs): ni arrastrables (↕) ni
      // removibles (✕) — posición real a precio real, y removerla individualmente rompería
      // la secuencia de la grilla del basket (entry + recoveries consecutivos). El único
      // cierre es vía el ✕ de la línea ENTRY (cierra todo). (Diseño v5.41, restaurado v5.56.)
      // En SIM (2026-08-04) sí conservan ↕ — re-precian la simulación in situ — pero nunca ✕:
      // "remover" una pata ya abierta necesita la arquitectura de lápida (pendiente, Pase 4).
      if(!m_preview && (future || !m_isReal))
         _MkHandle(_RMvN(i), _RMvNT(i), CORNER_LEFT_UPPER, BOVL_LEFT_X, y, BOVL_BG_DRAG, BOVL_GLYPH_DRAG, BOVL_FG_DRAG);
      if(!m_preview && future)
         _MkHandle(_RClN(i), _RClNT(i), CORNER_RIGHT_UPPER, BOVL_RIGHT_X, y, BOVL_BG_CLOSE, BOVL_GLYPH_CLOSE, BOVL_FG_CLOSE);
   }

   void _DrawAllRecs()
   {
      for(int i = 0; i < m_recCount; i++) _DrawRec(i);
      _DrawAddBtn();
   }

   void _DeleteAllRecs()
   {
      for(int i = 0; i < BOVL_MAX_REC; i++)
      {
         ObjectDelete(m_chartId, _RecN(i));
         ObjectDelete(m_chartId, _RMvN(i));  ObjectDelete(m_chartId, _RMvNT(i));
         ObjectDelete(m_chartId, _RClN(i));  ObjectDelete(m_chartId, _RClNT(i));
         _DelTag(_RTxtN(i+1));
      }
      ObjectDelete(m_chartId, _N("ADD")); ObjectDelete(m_chartId, _N("ADDT"));
   }

   double _AddRefPrice() const
   {
      // Sin recoveries (M-1, revisión 2026-08-02): el ➕ vive a mitad de camino entry→SL (o a
      // un offset chico si no hay SL) — antes desaparecía PARA SIEMPRE al borrar el último
      // recovery, porque todo su dibujo estaba gateado por m_recCount > 0.
      if(m_recCount <= 0)
      {
         double gap0 = m_slEnabled ? MathAbs(m_entry - m_sl) * 0.5 : MathAbs(m_entry) * 0.002;
         return m_isBuy ? m_entry - gap0 : m_entry + gap0;
      }
      // [+] cerca del último recovery, del lado donde se agregaría el siguiente
      // (BUY: más abajo / SELL: más arriba). gap = ~media distancia entre recoveries.
      double spacing = MathAbs(m_entry - m_rec[m_recCount-1]) / m_recCount;
      double gap = spacing * 0.5;
      return m_isBuy ? m_rec[m_recCount-1] - gap : m_rec[m_recCount-1] + gap;
   }

   void _DrawAddBtn()
   {
      if(m_preview) return;   // no [+] en preview read-only
      int y = _PriceToY(_AddRefPrice());
      // [+] centrado horizontalmente en el gráfico (offset desde el corner izquierdo).
      int xc = (_ChartW() - BOVL_BTN_W) / 2;
      _MkHandle(_N("ADD"), _N("ADDT"), CORNER_LEFT_UPPER,
                xc, y, BOVL_BG_ADD, BOVL_GLYPH_ADD, BOVL_FG_ADD);
   }

   //+----------------------------------------------------------------+
   //| _Redistribute — recoveries acoplados uniformes entry→sl        |
   //|                                                                |
   //| Un recovery se mueve solo si: (a) NO fue arrastrado a mano      |
   //| (m_recDecoupled=false) y (b) NO fue ejecutado todavía           |
   //| (índice >= m_openedRecs). Los recoveries ya abiertos son        |
   //| posiciones reales a precio fijo — no se redistribuyen.          |
   //+----------------------------------------------------------------+
   void _Redistribute()
   {
      if(m_recCount <= 0 || !m_slEnabled) return;
      int coupled = 0;
      for(int i = m_openedRecs; i < m_recCount; i++)
         if(!m_recDecoupled[i]) coupled++;
      if(coupled == 0) return;
      double step = MathAbs(m_entry - m_sl) / (coupled + 1);
      int slot = 1;
      for(int i = m_openedRecs; i < m_recCount; i++)
      {
         if(m_recDecoupled[i]) continue;
         m_rec[i] = m_isBuy ? m_entry - slot * step : m_entry + slot * step;
         slot++;
      }
   }

   //+----------------------------------------------------------------+
   //| _ApplyDrag — mueve el DIBUJO del nivel en arrastre (issue #54). |
   //|                                                                |
   //| SOLO visual: acá NO se empuja nada al basket. Hasta v6.37 cada |
   //| MOUSE_MOVE con el botón apretado escribía los niveles en el    |
   //| basket (~30 veces/segundo) y el trigger de recovery corría con |
   //| ellos: arrastrar el stop hacia la entrada comprimía la grilla   |
   //| contra el precio y la disparaba ENTERA a mercado, mid-drag     |
   //| (incidente 2026-08-01: 9 recoveries en 20 s). El empuje único  |
   //| ocurre al SOLTAR, en _CommitDrag.                              |
   //+----------------------------------------------------------------+
   //+----------------------------------------------------------------+
   //| _ClampRecPrice — nunca deja un recovery del lado ya disparado  |
   //|                                                                |
   //| El trigger real (CBasketManager::Update) es                    |
   //|   BUY:  bid <= nivel     SELL: ask >= nivel                   |
   //| Clampear al precio contrario (BUY: bid, SELL: ask) con un tick |
   //| de margen garantiza que, apenas soltado, esa condición siga    |
   //| dando false — el nivel llega HASTA el precio, no lo cruza.     |
   //+----------------------------------------------------------------+
   double _ClampRecPrice(double price)
   {
      double tick = SymbolInfoDouble(m_symbol, SYMBOL_TRADE_TICK_SIZE);
      if(tick <= 0.0) tick = SymbolInfoDouble(m_symbol, SYMBOL_POINT);
      if(m_isBuy)
      {
         double bid = SymbolInfoDouble(m_symbol, SYMBOL_BID);
         if(bid > 0.0 && price > bid - tick) price = bid - tick;
      }
      else
      {
         double ask = SymbolInfoDouble(m_symbol, SYMBOL_ASK);
         if(ask > 0.0 && price < ask + tick) price = ask + tick;
      }
      return price;
   }

   void _ApplyDrag(double price, CBasketManager *basket = NULL)
   {
      if(price <= 0) return;
      switch(m_dragKind)
      {
         case BOVL_DK_TP:
            m_tp = price;
            m_tpDecoupled = true;   // arrastre manual → el EA deja de auto-mover el TP (no vuelve solo)
            _MvHLine(_N("TP"), price);
            break;
         case BOVL_DK_ENTRY:
         {
            // A-4: con SL habilitado, los recoveries se redistribuyen uniformes entry→SL.
            // Sin SL, _Redistribute no haría nada → trasladamos los recoveries futuros
            // acoplados por el mismo delta del entry para que sigan colgando de él.
            double entryDelta = price - m_entry;
            m_entry = price;
            m_entryDecoupled = true;   // arrastre manual → SIM→REAL respeta este precio (entrada diferida)
            _MvHLine(_N("ENTRY"), price);
            if(m_slEnabled)
               _Redistribute();
            else
               for(int i = m_openedRecs; i < m_recCount; i++)
                  if(!m_recDecoupled[i]) m_rec[i] += entryDelta;
            // Clamp de los recoveries FUTUROS que _Redistribute()/el shift de arriba ACABAN de
            // recalcular (2026-08-04, mismo mecanismo que v6.57 le puso al drag directo de un
            // REC): sin este clamp podrían terminar del lado YA CRUZADO del precio vivo — la
            // misma cascada de disparo en cadena que v6.38 (issue #54) mató al drag directo,
            // reabierta acá por otra puerta. Los desacoplados (`[FIJO]`) quedan afuera: esta
            // línea no los tocó (el usuario los fijó en otro momento, a propósito).
            for(int i = m_openedRecs; i < m_recCount; i++)
               if(!m_recDecoupled[i]) m_rec[i] = _ClampRecPrice(m_rec[i]);
            for(int i = 0; i < m_recCount; i++)
               _MvHLine(_RecN(i), m_rec[i]);
            break;
         }
         case BOVL_DK_SL:
            m_sl = price;
            m_slDecoupled = true;   // arrastre manual → el EA deja de auto-mover el SL (no vuelve solo)
            _MvHLine(_N("SL"), price);
            _Redistribute();
            for(int i = 0; i < m_recCount; i++)
               _MvHLine(_RecN(i), m_rec[i]);
            break;
         case BOVL_DK_REC:
            if(m_dragRec >= 0 && m_dragRec < m_recCount)
            {
               // Clampeado contra el precio vivo (pedido del PO 2026-08-03): sin esto, un
               // recovery arrastrado del otro lado del precio dispara ENTERO el gesto de
               // "apilar contra el precio" — que es justo lo que v6.38 (issue #54) mató a
               // propósito, porque arrastrar el stop comprimía la grilla contra el precio
               // y la disparaba a mercado mid-drag (9 recoveries en 20 s). El clamp evita
               // llegar a esa condición: la línea se frena en el precio, nunca la cruza.
               // Una pata YA EJECUTADA en SIM (2026-08-04) no tiene trigger que proteger —
               // el usuario está corrigiendo dónde dice que entró, no armando un nivel nuevo.
               if(m_dragRec >= m_openedRecs) price = _ClampRecPrice(price);
               m_rec[m_dragRec] = price;
               m_recDecoupled[m_dragRec] = true;
               _MvHLine(_RecN(m_dragRec), price);
               ObjectSetInteger(m_chartId, _RecN(m_dragRec), OBJPROP_STYLE, STYLE_DASH);
               ObjectSetInteger(m_chartId, _RecN(m_dragRec), OBJPROP_WIDTH, 2);
            }
            break;
      }
      _ComputeLevels(basket);
      _DrawLabels();
      Refresh();
   }

   //+----------------------------------------------------------------+
   //| _CommitDrag — empuje ÚNICO al basket al soltar (issue #54).     |
   //|                                                                |
   //| TP: guarda del lado perdedor también en el camino MANUAL       |
   //| (issue #55) — un TP del lado perdedor cerraría todo en pérdida |
   //| al reactivarse los chequeos. Si el drag lo dejó ahí, NO se     |
   //| aplica: la línea vuelve al TP vigente y el auto-tracking       |
   //| retoma el control (m_tpDecoupled=false).                       |
   //|                                                                 |
   //| Referencia: GetBreakeven(), NO GetEntryPrice() (issue #74-bis,  |
   //| 2026-08-03) — con recoveries ejecutados el entry naked ya no es |
   //| el precio de "empatar", y esta guarda rechazaba arrastres que   |
   //| en realidad estaban en zona de ganancia real.                  |
   //+----------------------------------------------------------------+
   void _CommitDrag(CBasketManager &basket)
   {
      switch(m_dragKind)
      {
         case BOVL_DK_TP:
         {
            double be     = basket.GetBreakeven();
            bool   losing = (be > 0.0) && (m_isBuy ? (m_tp <= be) : (m_tp >= be));
            if(losing)
            {
               double prev = basket.GetTPPrice();
               PrintFormat("[Overlay] TP arrastrado a %s: lado PERDEDOR del breakeven %s — NO se aplica, vuelve el TP automático",
                           _Px(m_tp), _Px(be));
               m_tpDecoupled = false;
               if(prev > 0.0)
               {
                  m_tp = prev;
                  _MvHLine(_N("TP"), prev);
                  _MvHandle(_MvN("TP"), _MvNT("TP"), _PriceToY(prev));
               }
            }
            else
            {
               basket.SetTPPrice(m_tp);
               if(!m_tpArmedVis)   // el usuario ARMÓ a mano una línea que estaba desarmada (gris)
               {
                  m_tpArmedVis = true;
                  ObjectSetInteger(m_chartId, _N("TP"), OBJPROP_COLOR, BOVL_CLR_TP);
                  ObjectSetInteger(m_chartId, _N("TP"), OBJPROP_STYLE, STYLE_SOLID);
                  ObjectSetInteger(m_chartId, _N("TP"), OBJPROP_WIDTH, 2);
                  PrintFormat("[Overlay] TP armado A MANO en %s (era una línea desarmada)", _Px(m_tp));
               }
            }
            break;
         }
         case BOVL_DK_SL:
         {
            // SetSLPrice ya rechaza a nivel central un SL ya cruzado por el precio (2026-08-03,
            // espejo de la guarda del TP arriba). Acá solo se refleja el rechazo en la línea:
            // si lo que quedó en el basket no es lo que arrastramos, volvió al vigente.
            basket.SetSLPrice(m_sl);
            double applied = basket.GetSLPrice();
            if(applied != m_sl)
            {
               PrintFormat("[Overlay] SL arrastrado a %s: ya cruzado por el precio — NO se aplica, vuelve el SL vigente %s",
                           _Px(m_sl), _Px(applied));
               m_sl = applied;
               _MvHLine(_N("SL"), applied);
               _MvHandle(_MvN("SL"), _MvNT("SL"), _PriceToY(applied));
            }
            for(int i = m_openedRecs; i < m_recCount; i++)
               basket.SetRecoveryLevel(i+1, m_rec[i]);
            break;
         }
         case BOVL_DK_ENTRY:
            // En SIM, la entrada simulada se re-ancla al punto donde se soltó la línea (reporte
            // 2026-08-04): antes solo se movía la línea y la medición (DD/breakeven/riesgo)
            // seguía calculándose desde el precio del INICIAR — y ese mismo ancla vieja
            // contaminaba el re-anclaje post-fill si el basket pasaba a REAL con la entrada
            // diferida. No-op en REAL (SetSimEntryPrice se guarda sola con !m_isSim).
            basket.SetSimEntryPrice(m_entry);
            for(int i = m_openedRecs; i < m_recCount; i++)
               basket.SetRecoveryLevel(i+1, m_rec[i]);
            break;
         case BOVL_DK_REC:
            if(m_dragRec >= 0 && m_dragRec < m_recCount)
            {
               // Pata YA EJECUTADA en SIM (2026-08-04): re-anclar la posición simulada misma
               // (SetSimLegPrice), no el override de nivel futuro — SetRecoveryLevel no toca
               // m_simPos[], así que GetPnl/GetBreakeven seguirían midiendo desde el precio
               // viejo aunque la línea mostrara el nuevo.
               if(!m_isReal && m_dragRec < m_openedRecs)
                  basket.SetSimLegPrice(m_dragRec+1, m_rec[m_dragRec]);
               else
                  basket.SetRecoveryLevel(m_dragRec+1, m_rec[m_dragRec]);
            }
            break;
      }
      _ComputeLevels(GetPointer(basket));
      _DrawLabels();
   }

   //+----------------------------------------------------------------+
   //| _TryStartDrag / _TryClickAction — hit-test de grips           |
   //+----------------------------------------------------------------+
   bool _TryStartDrag(int mx, int my)
   {
      // Entrada bloqueada solo cuando la posición real fue ejecutada (no durante deferred entry).
      if(!m_entryLocked && _HitLeft(mx, my, _PriceToY(m_entry)))
         { m_dragKind = BOVL_DK_ENTRY; m_dragRec = -1; return true; }
      if(m_tpEnabled && _HitLeft(mx, my, _PriceToY(m_tp)))
         { m_dragKind = BOVL_DK_TP; m_dragRec = -1; return true; }
      if(m_slEnabled && _HitLeft(mx, my, _PriceToY(m_sl)))
         { m_dragKind = BOVL_DK_SL; m_dragRec = -1; return true; }
      // Recoveries: los FUTUROS (i >= m_openedRecs) siempre son arrastrables. En REAL, un
      // recovery ya ejecutado es una posición real a precio real — mover la línea no movería
      // la posición, se bloquea. En SIM (2026-08-04) también son arrastrables: re-precian la
      // simulación in situ (SetSimLegPrice) — el DD/breakeven tienen que medir desde donde el
      // usuario dice que entró, no desde un punto que ya abandonó.
      int dragStart = m_isReal ? m_openedRecs : 0;
      for(int i = dragStart; i < m_recCount; i++)
         if(_HitLeft(mx, my, _PriceToY(m_rec[i])))
            { m_dragKind = BOVL_DK_REC; m_dragRec = i; return true; }
      return false;
   }

   bool _TryClickAction(int mx, int my, CBasketManager &basket)
   {
      // ✕ en la línea ENTRY → señal de cierre del basket al EA
      if(_HitRight(mx, my, _PriceToY(m_entry), BOVL_RIGHT_X))
      {
         m_entryCloseClicked = true;
         return true;
      }
      if(_HitCenter(mx, my, _PriceToY(_AddRefPrice())))
      {
         _AddRecovery(basket);
         return true;
      }
      // Solo recoveries FUTUROS (i >= m_openedRecs): ✕ elimina el nivel del plan.
      // Los ya ejecutados (gold) son posiciones reales y NO tienen grip ✕ (ver _DrawRec):
      // removerlos individualmente rompería la secuencia de la grilla del basket. El ✕ de
      // la línea ENTRY es la única vía de cierre de posiciones reales (cierra todo). (v5.56)
      for(int i = m_openedRecs; i < m_recCount; i++)
         if(_HitRight(mx, my, _PriceToY(m_rec[i]), BOVL_RIGHT_X))
         {
            _RemoveRecovery(i, basket);
            return true;
         }
      return false;
   }

   void _AddRecovery(CBasketManager &basket)
   {
      if(m_recCount >= BOVL_MAX_REC) return;
      if(m_recCount == 0 && !m_slEnabled)
      {
         // Sin SL no hay geometría entry→SL donde ubicar el primer nivel (M-1).
         Print("[Overlay] no se puede agregar un recovery sin SL habilitado");
         return;
      }
      m_recCountChanged = true;
      // B-5: preservar los flags FIJO de recoveries arrastrados a mano; solo inicializar el nuevo.
      // (antes reseteaba TODOS los m_recDecoupled, perdiendo posiciones custom del usuario)
      m_recDecoupled[m_recCount] = false;
      m_recCount++;
      _Redistribute();
      _ComputeLevels(GetPointer(basket));
      _DeleteAllRecs();
      _DrawAllRecs();
      _DrawLabels();
      for(int i = 0; i < m_recCount; i++) basket.SetRecoveryLevel(i+1, m_rec[i]);
      ChartRedraw(m_chartId);
   }

   void _RemoveRecovery(int idx, CBasketManager &basket)
   {
      m_recCountChanged = true;
      _DeleteAllRecs();
      for(int j = idx; j < m_recCount-1; j++)
      {
         m_rec[j] = m_rec[j+1];
         m_recDecoupled[j] = m_recDecoupled[j+1];
      }
      m_recCount--;
      _Redistribute();
      _ComputeLevels(GetPointer(basket));
      _DrawAllRecs();
      _DrawLabels();
      for(int j = 0; j < m_recCount; j++) basket.SetRecoveryLevel(j+1, m_rec[j]);
      if(m_recCount < BOVL_MAX_REC) basket.SetRecoveryLevel(m_recCount+1, 0.0);
      ChartRedraw(m_chartId);
   }

   //+----------------------------------------------------------------+
   //| _OnMouseMove — máquina de estados del arrastre                |
   //+----------------------------------------------------------------+
   bool _OnMouseMove(int mx, int my, bool leftBtn, CBasketManager &basket)
   {
      bool newClick = _IsNewClick(leftBtn);

      if(!leftBtn && m_dragging)
      {
         m_dragging = false;
         _CommitDrag(basket);   // empuje ÚNICO al basket (issue #54) — durante el drag solo se dibujó
         // Al soltar drag de ENTRY en REAL: sincronizar trigger virtual del basket
         // con la nueva posición de la línea (price + dirección relativa al mercado).
         if(m_dragKind == BOVL_DK_ENTRY)
         {
            double mktPx = m_isBuy ? SymbolInfoDouble(m_symbol, SYMBOL_ASK)
                                   : SymbolInfoDouble(m_symbol, SYMBOL_BID);
            basket.UpdateVirtualEntry(m_entry, m_entry > mktPx);
         }
         m_dragKind = BOVL_DK_NONE;
         basket.SuspendHitChecks(false);
         ChartSetInteger(m_chartId, CHART_MOUSE_SCROLL, true);
         return true;
      }
      if(m_dragging && leftBtn)
      {
         m_lastDragMs = GetTickCount();
         basket.SuspendHitChecks(true);
         _ApplyDrag(_YToPrice(my), GetPointer(basket));
         return true;
      }
      if(newClick)
      {
         // El rectángulo del panel es zona EXCLUIDA (issue #56): sus controles ocupan
         // x∈[panel] y los grips ↕ viven en x∈[3,21] — sin esto, un click en el borde
         // del panel agarraba una línea de precio y el siguiente movimiento la arrastraba.
         if(_InExclusion(mx, my)) return false;
         if(_TryClickAction(mx, my, basket)) return true;
         if(_TryStartDrag(mx, my))
         {
            m_dragging   = true;
            m_lastDragMs = GetTickCount();
            basket.SuspendHitChecks(true);
            ChartSetInteger(m_chartId, CHART_MOUSE_SCROLL, false);
            return true;
         }
      }
      return false;
   }

public:
    CBasketOverlay() : m_chartId(0), m_open(false), m_preview(false), m_recCountChanged(false),
                       m_recCount(0),
                       m_tpEnabled(false), m_tpArmedVis(true), m_slEnabled(false),
                       m_isBuy(true), m_entry(0), m_tp(0), m_sl(0),
                       m_baseLot(0.01), m_mul(1.0), m_et(1), m_ddAtFrac(0),
                       m_openedRecs(0), m_pnl(0), m_isReal(false), m_entryLocked(false),
                       m_entryCloseClicked(false),
                       m_symbol(""), m_period(PERIOD_CURRENT),
                       m_anchorCache(0), m_anchorDirty(true),
                       m_tpDecoupled(false), m_slDecoupled(false), m_entryDecoupled(false),
                       m_dragging(false), m_dragKind(BOVL_DK_NONE),
                       m_dragRec(-1), m_prevLeftBtn(false), m_clickArmed(false),
                       m_lastDragMs(0),
                       m_exclX1(0), m_exclY1(0), m_exclX2(-1), m_exclY2(-1),
                      m_excl2X1(0), m_excl2Y1(0), m_excl2X2(-1), m_excl2Y2(-1)
    {
       // MQL5 no zero-inicializa arrays miembro. ArrayInitialize cubre los arrays
       // numéricos; m_recDecoupled es bool[] (sin overload de ArrayInitialize) → loop.
       ArrayInitialize(m_rec,        0.0);
       ArrayInitialize(m_lotAt,      0.0);
       ArrayInitialize(m_ddAtRec,    0.0);
       ArrayInitialize(m_tpTarAtRec, 0.0);
       for(int i = 0; i < BOVL_MAX_REC; i++) m_recDecoupled[i] = false;
    }

   ~CBasketOverlay() { if(m_open) Close(); }

   void Init(long chartId, const string &pfx, int digits,
             const string &symbol, ENUM_TIMEFRAMES period)
   {
      m_chartId = chartId;
      m_pfx     = pfx;
      m_digits  = digits;
      m_symbol  = symbol;
      m_period  = period;
      m_prevLeftBtn = false; m_clickArmed = false;   // GOT-018
   }

   //+----------------------------------------------------------------+
   //| Open — crear overlay al abrir basket                           |
   //+----------------------------------------------------------------+
   void Open(double entry, double tp, double sl, double recStep,
             int rlc, bool isBuy, double baseLot, double mul, int et)
   {
      if(m_open) Close();
      m_open             = true;
      m_preview          = false;
      m_recCountChanged  = false;
      m_isBuy            = isBuy;
      m_entry      = entry;
      m_tp         = tp;  m_tpEnabled = (tp > 0.0);  m_tpArmedVis = true;
      m_sl         = sl;  m_slEnabled = (sl > 0.0);
      m_recCount   = MathMin(rlc, BOVL_MAX_REC);
      m_baseLot    = baseLot;
      m_mul        = (mul > 0.0) ? mul : 1.0;
      m_et         = (et > 0) ? et : 1;
      m_openedRecs = 0;
      m_pnl        = 0.0;
      m_isReal     = false;
      m_entryLocked = false;
      m_tpDecoupled = false;
      m_slDecoupled = false;
      m_entryDecoupled = false;
      m_dragging   = false; m_dragKind = BOVL_DK_NONE; m_dragRec = -1;
      // El overlay nace bajo el cursor con INICIAR todavía apretado: exigir
      // un botón suelto antes de aceptar el próximo click (GOT-018).
      m_prevLeftBtn = false; m_clickArmed = false;
      m_anchorCache = 0; m_anchorDirty = true;
      for(int i = 0; i < m_recCount; i++)
      {
         m_recDecoupled[i] = false;
         m_rec[i] = isBuy ? entry - (i+1)*recStep : entry + (i+1)*recStep;
      }
      _ComputeLevels();

      _MkHLine(_N("ENTRY"), m_entry, BOVL_CLR_ENTRY, STYLE_SOLID, 1);
      _MkHandle(_MvN("ENTRY"), _MvNT("ENTRY"), CORNER_LEFT_UPPER, BOVL_LEFT_X,
                _PriceToY(m_entry), BOVL_BG_DRAG, BOVL_GLYPH_DRAG, BOVL_FG_DRAG);
      _MkHandle(_ClN("ENTRY"), _ClNT("ENTRY"), CORNER_RIGHT_UPPER, BOVL_RIGHT_X,
                _PriceToY(m_entry), BOVL_BG_CLOSE, BOVL_GLYPH_CLOSE, BOVL_FG_CLOSE);
      if(m_tpEnabled)
      {
         _MkHLine(_N("TP"), m_tp, BOVL_CLR_TP, STYLE_SOLID, 2);
         int y = _PriceToY(m_tp);
         _MkHandle(_MvN("TP"), _MvNT("TP"), CORNER_LEFT_UPPER, BOVL_LEFT_X, y, BOVL_BG_DRAG, BOVL_GLYPH_DRAG, BOVL_FG_DRAG);
      }
      if(m_slEnabled)
      {
         _MkHLine(_N("SL"), m_sl, BOVL_CLR_SL, STYLE_SOLID, 2);
         int y = _PriceToY(m_sl);
         _MkHandle(_MvN("SL"), _MvNT("SL"), CORNER_LEFT_UPPER, BOVL_LEFT_X, y, BOVL_BG_DRAG, BOVL_GLYPH_DRAG, BOVL_FG_DRAG);
      }
      _DrawAllRecs();
      _DrawLabels();
      ChartRedraw(m_chartId);
   }

   //+----------------------------------------------------------------+
   //| Close — eliminar todos los objetos                             |
   //+----------------------------------------------------------------+
   void Close()
   {
      if(!m_open) return;
      ObjectsDeleteAll(m_chartId, m_pfx + "BOV_");
      m_open            = false;
      m_preview         = false;
      m_recCountChanged = false;
      m_recCount        = 0;
      m_dragging        = false; m_dragKind = BOVL_DK_NONE;
      ChartSetInteger(m_chartId, CHART_MOUSE_SCROLL, true);
      ChartRedraw(m_chartId);
   }

   // Bloquea/desbloquea el drag del ENTRY.
   void SetEntryLocked(bool v) { m_entryLocked = v; }

   // Zona excluida del hit-test — el rectángulo del panel (issue #56). x2<x1 la desactiva.
   void SetExclusionRect(int x1, int y1, int x2, int y2)
   {
      m_exclX1 = x1; m_exclY1 = y1; m_exclX2 = x2; m_exclY2 = y2;
   }
   // AuraX: rectángulo del panel scanner (x2<x1 la desactiva).
   void SetExclusionRect2(int x1, int y1, int x2, int y2)
   {
      m_excl2X1 = x1; m_excl2Y1 = y1; m_excl2X2 = x2; m_excl2Y2 = y2;
   }

   //+----------------------------------------------------------------+
   //| TickDragWatchdog — llamar desde OnTimer (A-2, revisión          |
   //| 2026-08-02). MT5 no emite MOUSE_MOVE fuera del gráfico: soltar  |
   //| el botón afuera dejaba el drag PEGADO para siempre — hit-checks |
   //| suspendidos, TP sin auto-tracking, y al volver el cursor con el |
   //| botón apretado la línea se teletransportaba. Si no hay eventos  |
   //| de drag por >3 s, se suelta acá: commit en la ÚLTIMA posición   |
   //| vista y estado limpio. (Trade-off documentado: sostener un drag |
   //| inmóvil >3 s también lo suelta — preferible al estado pegado.)  |
   //+----------------------------------------------------------------+
   void TickDragWatchdog(CBasketManager &basket)
   {
      if(!m_open || !m_dragging) return;
      if(GetTickCount() - m_lastDragMs < 3000) return;
      Print("[Overlay] drag sin eventos por 3 s (¿botón soltado fuera del gráfico?) — se suelta en la última posición");
      m_dragging = false;
      _CommitDrag(basket);
      if(m_dragKind == BOVL_DK_ENTRY)
      {
         double mktPx = m_isBuy ? SymbolInfoDouble(m_symbol, SYMBOL_ASK)
                                : SymbolInfoDouble(m_symbol, SYMBOL_BID);
         basket.UpdateVirtualEntry(m_entry, m_entry > mktPx);
      }
      m_dragKind = BOVL_DK_NONE;
      basket.SuspendHitChecks(false);
      ChartSetInteger(m_chartId, CHART_MOUSE_SCROLL, true);
      ChartRedraw(m_chartId);
   }

   // Actualiza baseLot y mul en el overlay y redibuja labels (sin tocar precios).
   // Llamar siempre al cambiar LOT/MULT en el panel, incluso si no hay datos de impulso.
   // basket: para que _ComputeLevels() preserve el lote REAL de los niveles ya ejecutados
   // (reporte PO 2026-08-06) — sin él, cambiar MULT con recoveries ya llenos recalculaba
   // su Target $ como si pesaran el MULT nuevo.
   void UpdateDisplay(double baseLot, double mul, int et, CBasketManager *basket = NULL)
   {
      if(!m_open) return;
      m_baseLot = baseLot;
      m_mul     = (mul > 0.0) ? mul : 1.0;
      m_et      = (et > 0) ? et : 1;
      _ComputeLevels(basket);
      _DrawLabels();
      ChartRedraw(m_chartId);
   }

   //+----------------------------------------------------------------+
   //| SetLive — actualiza P&L / recoveries abiertos y redibuja      |
   //| Llamar desde OnTimer cada tick mientras el basket está abierto.|
   //+----------------------------------------------------------------+
   void SetLive(double pnl, bool isReal, int openedRecs)
   {
      if(!m_open) return;
      m_pnl        = pnl;
      m_isReal     = isReal;
      m_openedRecs = MathMax(0, MathMin(openedRecs, m_recCount));
      m_anchorDirty = true;
      _DrawLabels();
      Refresh();
   }

   //+----------------------------------------------------------------+
   //| SyncEntryPrice — re-ancla la línea ENTRY al precio real del    |
   //| basket (reporte 2026-08-04: tras una entrada diferida disparar |
   //| en REAL, o un re-ancla de la entrada simulada en SIM, la línea |
   //| se quedaba en el precio del objetivo/INICIAR mientras la       |
   //| posición real estaba en otro lado). Llamar cada tick desde el  |
   //| EA con basket.GetEntryPrice() — no-op si no cambió o si el     |
   //| usuario está arrastrando la línea en ese instante.             |
   //+----------------------------------------------------------------+
   void SyncEntryPrice(double px)
   {
      if(!m_open || px <= 0.0 || m_entry == px) return;
      if(m_dragging && m_dragKind == BOVL_DK_ENTRY) return;   // no pisar un drag en curso
      m_entry = px;
      _MvHLine(_N("ENTRY"), px);
      if(!m_entryLocked) _MvHandle(_MvN("ENTRY"), _MvNT("ENTRY"), _PriceToY(px));
      _MvHandle(_ClN("ENTRY"), _ClNT("ENTRY"), _PriceToY(px));
      _DrawLabels();
   }

   //+----------------------------------------------------------------+
   //| Refresh — reubica grips (Y) y reancla etiquetas (scroll)      |
   //+----------------------------------------------------------------+
   void Refresh()
   {
      if(!m_open) return;
      m_anchorDirty = true;

      _MvHandle(_MvN("ENTRY"), _MvNT("ENTRY"), m_entryLocked ? -1 : _PriceToY(m_entry));
      _MvHandle(_ClN("ENTRY"), _ClNT("ENTRY"), _PriceToY(m_entry));
      _MvTag(_TxtN("ENTRY"), m_entry);

      if(m_tpEnabled)
      {
         int y = _PriceToY(m_tp);
         _MvHandle(_MvN("TP"), _MvNT("TP"), y);
         _MvTag(_TxtN("TP"), m_tp);
      }
      if(m_slEnabled)
      {
         int y = _PriceToY(m_sl);
         _MvHandle(_MvN("SL"), _MvNT("SL"), y);
         _MvTag(_TxtN("SL"), m_sl);
      }
      for(int i = 0; i < m_recCount; i++)
      {
         int  y      = _PriceToY(m_rec[i]);
         bool future = (i >= m_openedRecs);
         // Ejecutado en REAL: ocultar ambos grips (posición real, ni se arrastra ni se quita
         // individualmente). Ejecutado en SIM (2026-08-04): conserva ↕ (re-precia la
         // simulación) pero nunca ✕ (esa cirugía es del Pase 4, pendiente).
         int gyMv = (!future && m_isReal) ? -1 : y;
         int gyCl = future ? y : -1;
         _MvHandle(_RMvN(i), _RMvNT(i), gyMv);
         _MvHandle(_RClN(i), _RClNT(i), gyCl);
         _MvTag(_RTxtN(i+1), m_rec[i]);
      }
      if(!m_preview)
         _MvHandle(_N("ADD"), _N("ADDT"), _PriceToY(_AddRefPrice()));

      // Self-heal de grips (M-5, revisión 2026-08-02): _MvHandle BORRA el grip cuando el
      // nivel sale del rango visible y mover no lo recrea — antes solo un CHART_CHANGE lo
      // devolvía. Si falta alguno esperado con su nivel visible, se reconstruyen todos.
      bool grpMissing = (!m_entryLocked && _PriceToY(m_entry) >= 0
                         && ObjectFind(m_chartId, _MvN("ENTRY")) < 0)
                     || (m_tpEnabled && _PriceToY(m_tp) >= 0
                         && ObjectFind(m_chartId, _MvN("TP")) < 0)
                     || (m_slEnabled && _PriceToY(m_sl) >= 0
                         && ObjectFind(m_chartId, _MvN("SL")) < 0);
      // En SIM las filas ejecutadas también tienen grip ↕ (2026-08-04) — escanear desde 0 para
      // que el self-heal las alcance igual; en REAL solo las futuras lo tienen (como antes).
      int selfHealStart = m_isReal ? m_openedRecs : 0;
      for(int i = selfHealStart; i < m_recCount && !grpMissing; i++)
         if(_PriceToY(m_rec[i]) >= 0 && ObjectFind(m_chartId, _RMvN(i)) < 0)
            grpMissing = true;
      if(grpMissing && !m_preview) _RedrawHandles();

      ChartRedraw(m_chartId);
   }

   // Recrea los objetos de todos los handles (MkHandle, no MvHandle).
   // Necesario en CHARTEVENT_CHART_CHANGE: el cambio de tab puede causar y<0 → MvHandle
   // borra los objetos; al volver MvHandle no puede recrearlos (solo mueve existentes).
   void _RedrawHandles()
   {
      if(!m_entryLocked)
         _MkHandle(_MvN("ENTRY"), _MvNT("ENTRY"), CORNER_LEFT_UPPER, BOVL_LEFT_X,
                   _PriceToY(m_entry), BOVL_BG_DRAG, BOVL_GLYPH_DRAG, BOVL_FG_DRAG);
      _MkHandle(_ClN("ENTRY"), _ClNT("ENTRY"), CORNER_RIGHT_UPPER, BOVL_RIGHT_X,
                _PriceToY(m_entry), BOVL_BG_CLOSE, BOVL_GLYPH_CLOSE, BOVL_FG_CLOSE);
      if(m_tpEnabled)
         _MkHandle(_MvN("TP"), _MvNT("TP"), CORNER_LEFT_UPPER, BOVL_LEFT_X,
                   _PriceToY(m_tp), BOVL_BG_DRAG, BOVL_GLYPH_DRAG, BOVL_FG_DRAG);
      if(m_slEnabled)
         _MkHandle(_MvN("SL"), _MvNT("SL"), CORNER_LEFT_UPPER, BOVL_LEFT_X,
                   _PriceToY(m_sl), BOVL_BG_DRAG, BOVL_GLYPH_DRAG, BOVL_FG_DRAG);
      _DrawAllRecs();
   }

   //+----------------------------------------------------------------+
   //| OnEvent — procesa eventos. Devuelve true si consumió.         |
   //+----------------------------------------------------------------+
   bool OnEvent(int id, long lp, double dp, const string &sp,
                CBasketManager &basket)
   {
      if(!m_open) return false;
      if(id == CHARTEVENT_CHART_CHANGE) { _RedrawHandles(); Refresh(); return false; }
      // Preview: solo refrescar ante cambios de chart y permitir dismiss por ✕ de ENTRY.
      // Toda interacción de drag/[+]/[x] está bloqueada — el usuario opera solo desde el panel.
      if(m_preview)
      {
         if(id == CHARTEVENT_MOUSE_MOVE)
         {
            int  mx      = (int)lp;
            int  my      = (int)dp;
            bool leftBtn = ((int)StringToInteger(sp) & 1) != 0;
            bool newClick = _IsNewClick(leftBtn);
            if(newClick && _HitRight(mx, my, _PriceToY(m_entry), BOVL_RIGHT_X))
               m_entryCloseClicked = true;
         }
         return false;
      }
      if(id == CHARTEVENT_MOUSE_MOVE)
      {
         int  mx      = (int)lp;
         int  my      = (int)dp;
         bool leftBtn = ((int)StringToInteger(sp) & 1) != 0;
         return _OnMouseMove(mx, my, leftBtn, basket);
      }
      return false;
   }

   //+----------------------------------------------------------------+
   //| RestoreRecLevels — redibuja la grilla con los niveles del basket|
   //|                                                                 |
   //| Al reenganchar tras un cambio de TF (#53) el overlay se abre    |
   //| con geometría de FÓRMULA, pero el basket conserva los niveles   |
   //| que el usuario arrastró: sin esto el overlay dibuja una grilla  |
   //| que el basket no usa — líneas en cualquier lado.                |
   //|                                                                 |
   //| Cada nivel restaurado queda DESACOPLADO: es una posición manual |
   //| del usuario y _Redistribute no debe moverla.                    |
   //+----------------------------------------------------------------+
   void RestoreRecLevels(CBasketManager &basket)
   {
      if(!m_open || m_recCount <= 0) return;

      // Los recoveries YA EJECUTADOS van en su precio REAL de apertura, no donde diga la
      // fórmula: son posiciones vivas en el broker y la línea tiene que caer sobre ellas.
      // El recovery n es la posición n del basket (la 0 es la entrada).
      int opened = basket.GetPosCount() - 1;
      if(opened < 0) opened = 0;
      if(opened > m_recCount) opened = m_recCount;
      m_openedRecs = opened;

      bool any = false;
      for(int i = 0; i < m_recCount; i++)
      {
         // Ejecutado → precio real. Futuro → lo que el usuario haya arrastrado (0 = fórmula).
         double px = (i < opened) ? basket.GetPosPrice(i + 1)
                                  : basket.GetRecOverride(i + 1);
         if(px <= 0.0) continue;
         m_rec[i]          = px;
         m_recDecoupled[i] = true;
         any = true;
      }
      if(!any) return;
      _DeleteAllRecs();
      _DrawAllRecs();
      _DrawLabels();
      Refresh();
   }

   bool   IsOpen()    const { return m_open;  }
   bool   IsPreview() const { return m_open && m_preview; }
   bool   IsDragging() const { return m_dragging; }   // el EA no auto-recalcula mientras se arrastra una línea
   bool   IsTpDecoupled() const { return m_tpDecoupled; }  // TP arrastrado a mano → el EA no lo auto-mueve
   bool   IsSlDecoupled() const { return m_slDecoupled; }  // SL arrastrado a mano → el EA no lo auto-mueve
   bool   IsEntryDecoupled() const { return m_entryDecoupled; } // ENTRY arrastrado a mano → SIM→REAL difiere a ese precio (issue #53)
   double GetEntry()  const { return m_entry; }
   // M3: nº de recoveries del plan (refleja [+]/✕ del usuario). El EA lo usa como maxRec
   // en basket.Update() → el basket abre exactamente los recoveries que el overlay muestra.
   int    GetRecCount() const { return m_recCount; }
   // Devuelve true (una vez) si el usuario hizo ✕ en la línea ENTRY → EA debe cerrar el basket (o dismiss preview).
   bool   ConsumeEntryCloseClick() { bool v = m_entryCloseClicked; m_entryCloseClicked = false; return v; }
   // Devuelve true (una vez) si [+]/[x] cambió el recCount — EA sincroniza panel RLC.
   bool   ConsumeRecCountChanged() { bool v = m_recCountChanged; m_recCountChanged = false; return v; }

   //+----------------------------------------------------------------+
   //| OpenPreview — preview visual antes de INICIAR (read-only)      |
   //| Mismo flujo que Open() pero sin grip drag en ENTRY y sin       |
   //| botones en recoveries. El usuario opera solo desde el panel.   |
   //+----------------------------------------------------------------+
   void OpenPreview(double entry, double tp, double sl, double recStep,
                    int rlc, bool isBuy, double baseLot, double mul, int et)
   {
      if(m_open) Close();
      m_open            = true;
      m_preview         = true;
      m_recCountChanged = false;
      m_isBuy           = isBuy;
      m_entry           = entry;
      m_tp              = tp;  m_tpEnabled = (tp > 0.0);  m_tpArmedVis = true;
      m_sl              = sl;  m_slEnabled = (sl > 0.0);
      m_recCount        = MathMin(rlc, BOVL_MAX_REC);
      m_baseLot         = baseLot;
      m_mul             = (mul > 0.0) ? mul : 1.0;
      m_et              = (et > 0) ? et : 1;
      m_openedRecs      = 0;
      m_pnl             = 0.0;
      m_isReal          = false;
      m_entryLocked     = true;  // preview: ENTRY no arrastrable
      m_tpDecoupled     = false;
      m_slDecoupled     = false;
      m_entryDecoupled  = false;
      m_dragging        = false; m_dragKind = BOVL_DK_NONE; m_dragRec = -1;
      // Preview: nace bajo el cursor con el botón del panel todavía apretado (GOT-018).
      m_prevLeftBtn     = false; m_clickArmed = false;
      m_anchorCache     = 0; m_anchorDirty = true;
      for(int i = 0; i < m_recCount; i++)
      {
         m_recDecoupled[i] = false;
         m_rec[i] = isBuy ? entry - (i+1)*recStep : entry + (i+1)*recStep;
      }
      _ComputeLevels();
      _MkHLine(_N("ENTRY"), m_entry, BOVL_CLR_ENTRY, STYLE_SOLID, 1);
      // Preview: solo ✕ para dismiss — sin grip drag (read-only)
      _MkHandle(_ClN("ENTRY"), _ClNT("ENTRY"), CORNER_RIGHT_UPPER, BOVL_RIGHT_X,
                _PriceToY(m_entry), BOVL_BG_CLOSE, BOVL_GLYPH_CLOSE, BOVL_FG_CLOSE);
      if(m_tpEnabled)
         _MkHLine(_N("TP"), m_tp, BOVL_CLR_TP, STYLE_SOLID, 2);
      if(m_slEnabled)
         _MkHLine(_N("SL"), m_sl, BOVL_CLR_SL, STYLE_SOLID, 2);
      _DrawAllRecs();
      _DrawLabels();
      ChartRedraw(m_chartId);
   }

   //+----------------------------------------------------------------+
   //| Recalculate — actualiza TP/SL/recoveries desde nuevos params   |
   //| Llamar cuando el usuario cambia TP%, SL%, RLC o LOT en el     |
   //| panel mientras el basket está abierto.                         |
   //+----------------------------------------------------------------+
   void Recalculate(double tp, double sl, int rlc, double baseLot,
                    double mul, int et, CBasketManager *basket = NULL)
   {
      if(!m_open) return;

      // TP — nivel a 0 = la línea SE VA (M-4, revisión 2026-08-02): antes m_tpEnabled quedaba
      // false pero el OBJ_HLINE verde seguía dibujado — una línea de objetivo fantasma que ya
      // no estaba armada y cuyo grip no respondía. Ídem SL.
      m_tp = tp; m_tpEnabled = (tp > 0.0);
      if(m_tpEnabled) _MvHLine(_N("TP"), tp);
      else
      {
         ObjectDelete(m_chartId, _N("TP"));
         ObjectDelete(m_chartId, _MvN("TP"));  ObjectDelete(m_chartId, _MvNT("TP"));
         _DelTag(_TxtN("TP"));
      }
      if(basket != NULL) basket.SetTPPrice(tp);

      // SL — SetSLPrice puede rechazar (guarda central, 2026-08-03: SL ya cruzado por el
      // precio). Empujar al basket ANTES de fijar la línea y usar lo que quedó aplicado
      // (GetSLPrice) evita que la línea muestre un nivel que el basket en realidad rechazó.
      if(basket != NULL) basket.SetSLPrice(sl);
      double slApplied = (basket != NULL) ? basket.GetSLPrice() : sl;
      m_sl = slApplied; m_slEnabled = (slApplied > 0.0);
      if(m_slEnabled) _MvHLine(_N("SL"), slApplied);
      else
      {
         ObjectDelete(m_chartId, _N("SL"));
         ObjectDelete(m_chartId, _MvN("SL"));  ObjectDelete(m_chartId, _MvNT("SL"));
         _DelTag(_TxtN("SL"));
      }

      // Lot / multiplicador / cadencia ET (etiquetas)
      m_baseLot = baseLot;
      m_mul     = (mul > 0.0) ? mul : 1.0;
      m_et      = (et > 0) ? et : 1;

      // Recoveries (issue #58): los niveles arrastrados a mano ([FIJO]) SOBREVIVEN — solo se
      // redistribuyen los acoplados (_Redistribute ya salta desacoplados y ejecutados). Hasta
      // v6.37 se reconstruía TODO desde la fórmula: colocar 5 recoveries a mano y tocar
      // cualquier campo del panel los devolvía a la fórmula sin aviso.
      // Los ya ejecutados (índice < m_openedRecs) conservan su precio real — no se tocan.
      // RLC nunca baja por debajo de los recoveries ya abiertos.
      int newRlc = MathMax(m_openedRecs, MathMin(rlc, BOVL_MAX_REC));
      if(!m_slEnabled && newRlc > m_recCount)
      {
         // Sin SL no hay geometría entry→SL para ubicar niveles nuevos: crecer acá los
         // colapsaría todos sobre la entrada (step=0). No crecer en silencio.
         PrintFormat("[Overlay] RLC no puede crecer sin SL habilitado — se conservan %d niveles", m_recCount);
         newRlc = m_recCount;
      }
      _DeleteAllRecs();
      for(int i = m_recCount; i < newRlc; i++) m_recDecoupled[i] = false;   // niveles NUEVOS nacen acoplados
      m_recCount = newRlc;
      _Redistribute();
      if(basket != NULL)
         for(int i = m_openedRecs; i < m_recCount; i++)
            basket.SetRecoveryLevel(i+1, m_rec[i]);
      // Recalcula lots/DD/TP-target con baseLot y mul actualizados — los niveles YA
      // ejecutados conservan su lote real dentro de _ComputeLevels (2026-08-06).
      _ComputeLevels(basket);
      _DrawAllRecs();
      _DrawLabels();
      Refresh();
   }

   //+----------------------------------------------------------------+
   //| UpdateTp — mueve SOLO la línea TP (tracking de zona en vivo).  |
   //| No toca SL ni recoveries (no resetea drags ni reconstruye      |
   //| objetos). No-op si el TP no cambió → evita flicker en el timer.|
   //| Si el basket abrió con TP DESARMADO (tp=0 al Open, v5.85) la   |
   //| línea+grip no existen → crearlos al armarse el primer TP válido.|
   //+----------------------------------------------------------------+
   void UpdateTp(double tp, CBasketManager *basket = NULL)
   {
      if(!m_open || tp <= 0.0) return;
      if(m_tp == tp && m_tpEnabled && m_tpArmedVis) return;   // sin cambio de precio NI de estado
      m_tp = tp;
      if(!m_tpEnabled)
      {
         // Primer TP válido tras abrir desarmado → crear línea + grip de drag.
         m_tpEnabled = true;
         _MkHLine(_N("TP"), tp, BOVL_CLR_TP, STYLE_SOLID, 2);
         _MkHandle(_MvN("TP"), _MvNT("TP"), CORNER_LEFT_UPPER, BOVL_LEFT_X,
                   _PriceToY(tp), BOVL_BG_DRAG, BOVL_GLYPH_DRAG, BOVL_FG_DRAG);
      }
      else
      {
         _MvHLine(_N("TP"), tp);
         if(!m_tpArmedVis)   // venía DESARMADA (gris) → restaurar el estilo operativo
         {
            ObjectSetInteger(m_chartId, _N("TP"), OBJPROP_COLOR, BOVL_CLR_TP);
            ObjectSetInteger(m_chartId, _N("TP"), OBJPROP_STYLE, STYLE_SOLID);
            ObjectSetInteger(m_chartId, _N("TP"), OBJPROP_WIDTH, 2);
         }
         _MvHandle(_MvN("TP"), _MvNT("TP"), _PriceToY(tp));  // el grip ↕ sigue la línea → drag alineado
      }
      m_tpArmedVis = true;
      _ComputeLevels(basket);   // refresca el target $ del TP con el nuevo precio
      _DrawLabels();
      ChartRedraw(m_chartId);
   }

   //+----------------------------------------------------------------+
   //| ShowTpDisarmed — línea del TP en estado DESARMADO (v6.40).      |
   //| Reporte del PO 2026-08-02: "a veces no veo la línea de tp para  |
   //| arrastrar". Hasta v6.39 un TP desarmado no dibujaba nada: no    |
   //| había línea que arrastrar ni forma de saber por qué. Gris       |
   //| punteada = visible, arrastrable, y NO operativa (el basket      |
   //| tiene tp=0 — no evalúa pago). Se arma sola al volverse válida   |
   //| (UpdateTp) o a mano si el drag la suelta del lado ganador.      |
   //+----------------------------------------------------------------+
   void ShowTpDisarmed(double tp, CBasketManager *basket = NULL)
   {
      if(!m_open || tp <= 0.0) return;
      if(m_tp == tp && m_tpEnabled && !m_tpArmedVis) return;   // sin cambios
      m_tp = tp;
      if(!m_tpEnabled)
      {
         m_tpEnabled = true;
         _MkHLine(_N("TP"), tp, BOVL_CLR_TP_DIS, STYLE_DOT, 1);
         _MkHandle(_MvN("TP"), _MvNT("TP"), CORNER_LEFT_UPPER, BOVL_LEFT_X,
                   _PriceToY(tp), BOVL_BG_DRAG, BOVL_GLYPH_DRAG, BOVL_FG_DRAG);
      }
      else
      {
         _MvHLine(_N("TP"), tp);
         if(m_tpArmedVis)   // venía operativa → estilo desarmado
         {
            ObjectSetInteger(m_chartId, _N("TP"), OBJPROP_COLOR, BOVL_CLR_TP_DIS);
            ObjectSetInteger(m_chartId, _N("TP"), OBJPROP_STYLE, STYLE_DOT);
            ObjectSetInteger(m_chartId, _N("TP"), OBJPROP_WIDTH, 1);
         }
         _MvHandle(_MvN("TP"), _MvNT("TP"), _PriceToY(tp));
      }
      m_tpArmedVis = false;
      _ComputeLevels(basket);
      _DrawLabels();
      ChartRedraw(m_chartId);
   }

   //+----------------------------------------------------------------+
   //| UpdateSl — SL en vivo pre-T3 (v5.83): mueve línea+grip y        |
   //| redistribuye los recoveries futuros NO desacoplados entry→SL,  |
   //| empujando cada nivel al basket (mismo flujo que el drag de SL).|
   //| No-op si el SL no cambió → solo trabaja cuando el extremo de   |
   //| la zona T2 realmente se extendió (sin flicker por tick).       |
   //+----------------------------------------------------------------+
   void UpdateSl(double sl, CBasketManager &basket)
   {
      if(!m_open || sl <= 0.0 || m_sl == sl) return;
      m_sl = sl; m_slEnabled = true;
      basket.SetSLPrice(sl);
      _MvHLine(_N("SL"), sl);
      _MvHandle(_MvN("SL"), _MvNT("SL"), _PriceToY(sl));  // el grip ↕ sigue la línea → drag alineado
      _Redistribute();
      for(int i = m_openedRecs; i < m_recCount; i++)
      {
         _MvHLine(_RecN(i), m_rec[i]);
         basket.SetRecoveryLevel(i+1, m_rec[i]);
      }
      _ComputeLevels(GetPointer(basket));
      _DrawLabels();
      Refresh();          // grips de recoveries siguen sus líneas redistribuidas
      ChartRedraw(m_chartId);
   }

   //+----------------------------------------------------------------+
   //| MovePreviewEntry — mueve el ENTRY del PREVIEW al precio actual. |
   //| Solo en preview (sin basket): no hay INICIAR, así que el entry  |
   //| sigue el mercado en vivo. Actualiza m_entry y mueve la línea;   |
   //| el ✕ y los recoveries los reposiciona Recalculate()/Refresh()   |
   //| desde m_entry. No-op si no cambió (evita trabajo en el timer).  |
   //+----------------------------------------------------------------+
   void MovePreviewEntry(double entry)
   {
      if(!m_open || !m_preview || entry <= 0.0 || m_entry == entry) return;
      m_entry       = entry;
      m_anchorDirty = true;
      _MvHLine(_N("ENTRY"), entry);
   }
};
