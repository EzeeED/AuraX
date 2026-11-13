//+------------------------------------------------------------------+
//| CToast.mqh — tarjeta de notificación flotante en el chart        |
//| Capa: UI                                                          |
//|                                                                  |
//| Reemplazo NO intrusivo del popup Alert() de MT5 (que roba el     |
//| foco y congela el trabajo con el gráfico): tarjeta en la esquina |
//| inferior derecha del chart con título + hasta 5 líneas de evento |
//| + "+N más". Se auto-oculta a los ~12 s (Tick() desde el OnTimer  |
//| de 500 ms del caller); click en la tarjeta la cierra.            |
//|                                                                  |
//| Compartido por EMAScanCore (novedades del scan) y EmaRiskPro EA  |
//| (señales del detector). OBJ nativos (ADR-001), prefijo           |
//| pfx+"TST_" — hermano de los demás sub-prefijos (ADR-028).        |
//+------------------------------------------------------------------+
#ifndef AURAX_TOAST_MQH
#define AURAX_TOAST_MQH

#define TOAST_MAX_LINES   5    // líneas de evento visibles (el resto → "+N más")
#define TOAST_W           300  // ancho px
#define TOAST_MARGIN      8    // separación del borde del chart
#define TOAST_TITLE_H     22   // alto fila título
#define TOAST_LINE_H      16   // alto fila de evento
#define TOAST_LIFE_TICKS  24   // vida = 24 ticks × 500 ms = 12 s
#define TOAST_BG          C'11,11,11'        // negro del tema premium
#define TOAST_BORDER      C'30,144,255'      // azul de acento del tema AuraX (mismo que EPNL_ACCENT)
#define TOAST_TITLE_FG    C'43,210,126'      // verde — es una oportunidad
#define TOAST_LINE_FG     clrWhite
#define TOAST_Z           30000              // encima del panel y sus popups

class CToast
{
protected:  // CNotifyCenter (EMAScan) hereda el rendering y la geometría
   long   m_chartId;
   string m_pfx;        // prefijo completo de los OBJ del toast (…+"TST_")
   bool   m_visible;
   int    m_lifeTicks;  // ticks de OnTimer restantes antes del auto-hide
   int    m_height;     // alto actual de la tarjeta (para hit-test y reposición)
   int    m_width;      // ancho de la tarjeta (default TOAST_W; ver SetWidth)
   ENUM_BASE_CORNER m_corner;  // esquina del chart donde aparece (configurable por input)

   // Coordenadas SIEMPRE en sistema CORNER_LEFT_UPPER (los OBJ se crean así);
   // la esquina elegida solo decide desde qué borde se calcula la posición.
   int _X() const
   {
      bool left = (m_corner == CORNER_LEFT_UPPER || m_corner == CORNER_LEFT_LOWER);
      if(left) return TOAST_MARGIN;
      return (int)ChartGetInteger(m_chartId, CHART_WIDTH_IN_PIXELS) - m_width - TOAST_MARGIN;
   }
   int _Y() const
   {
      bool top = (m_corner == CORNER_LEFT_UPPER || m_corner == CORNER_RIGHT_UPPER);
      if(top) return TOAST_MARGIN;
      return (int)ChartGetInteger(m_chartId, CHART_HEIGHT_IN_PIXELS) - m_height - TOAST_MARGIN;
   }

   //| Rect de fondo o label de texto — create-once por nombre, propiedades siempre.
   void _Rect(const string name, int x, int y, int w, int h, color bg)
   {
      if(ObjectFind(m_chartId, name) < 0)
         ObjectCreate(m_chartId, name, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(m_chartId, name, OBJPROP_XDISTANCE,   x);
      ObjectSetInteger(m_chartId, name, OBJPROP_YDISTANCE,   y);
      ObjectSetInteger(m_chartId, name, OBJPROP_XSIZE,       w);
      ObjectSetInteger(m_chartId, name, OBJPROP_YSIZE,       h);
      ObjectSetInteger(m_chartId, name, OBJPROP_BGCOLOR,     bg);
      ObjectSetInteger(m_chartId, name, OBJPROP_COLOR,       bg);
      ObjectSetInteger(m_chartId, name, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(m_chartId, name, OBJPROP_CORNER,      CORNER_LEFT_UPPER);
      ObjectSetInteger(m_chartId, name, OBJPROP_SELECTABLE,  false);
      ObjectSetInteger(m_chartId, name, OBJPROP_ZORDER,      TOAST_Z);
   }

   void _Text(const string name, int x, int y, const string txt, color fg, int fsz, const string font)
   {
      if(ObjectFind(m_chartId, name) < 0)
         ObjectCreate(m_chartId, name, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(m_chartId, name, OBJPROP_XDISTANCE,  x);
      ObjectSetInteger(m_chartId, name, OBJPROP_YDISTANCE,  y);
      ObjectSetInteger(m_chartId, name, OBJPROP_CORNER,     CORNER_LEFT_UPPER);
      ObjectSetInteger(m_chartId, name, OBJPROP_ANCHOR,     ANCHOR_LEFT_UPPER);
      ObjectSetString (m_chartId, name, OBJPROP_TEXT,       txt);
      ObjectSetString (m_chartId, name, OBJPROP_FONT,       font);
      ObjectSetInteger(m_chartId, name, OBJPROP_FONTSIZE,   fsz);
      ObjectSetInteger(m_chartId, name, OBJPROP_COLOR,      fg);
      ObjectSetInteger(m_chartId, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(m_chartId, name, OBJPROP_ZORDER,     TOAST_Z + 1);
   }

public:
   CToast() : m_chartId(0), m_visible(false), m_lifeTicks(0), m_height(0),
              m_width(TOAST_W), m_corner(CORNER_LEFT_LOWER) {}

   void Init(long chartId, const string basePfx,
             ENUM_BASE_CORNER corner = CORNER_LEFT_LOWER)
   {
      m_chartId = chartId;
      m_pfx     = basePfx + "TST_";
      m_corner  = corner;
   }

   //| Ancho de la tarjeta/lista (pedido PO v2.22: el centro 🔔 usa el 80% del
   //| ancho del panel para que las filas por símbolo entren sin truncarse).
   //| Llamar tras Init(); mínimo TOAST_W para no romper el chip/hit-test.
   void SetWidth(int w) { m_width = MathMax(w, TOAST_W); }

   //| Muestra (o reemplaza) la tarjeta con un lote de líneas y reinicia su vida.
   void Show(const string title, const string &lines[], int count)
   {
      if(StringLen(m_pfx) == 0 || count <= 0) return;
      Hide();  // delete+recreate por Show (no por tick) — evita labels huérfanos de lotes previos

      int shown = MathMin(count, TOAST_MAX_LINES);
      int extra = count - shown;                      // → fila "+N más"
      m_height  = TOAST_TITLE_H + (shown + (extra > 0 ? 1 : 0)) * TOAST_LINE_H + 6;

      int x = _X(), y = _Y();
      _Rect(m_pfx + "BDR", x - 1, y - 1, m_width + 2, m_height + 2, TOAST_BORDER);
      _Rect(m_pfx + "BG",  x,     y,     m_width,     m_height,     TOAST_BG);
      _Text(m_pfx + "TTL", x + 8, y + 3, title, TOAST_TITLE_FG, 9, "Arial Bold");
      for(int i = 0; i < shown; i++)
         _Text(m_pfx + "L" + IntegerToString(i), x + 8, y + TOAST_TITLE_H + i * TOAST_LINE_H,
               lines[i], TOAST_LINE_FG, 8, "Arial");
      if(extra > 0)
         _Text(m_pfx + "MORE", x + 8, y + TOAST_TITLE_H + shown * TOAST_LINE_H,
               "…y " + IntegerToString(extra) + " más (ver 🔔 del panel)", clrSilver, 8, "Arial");

      m_visible   = true;
      m_lifeTicks = TOAST_LIFE_TICKS;
      ChartRedraw(m_chartId);
   }

   //| Conveniencia para un solo evento (EmaRiskPro EA).
   void ShowOne(const string title, const string line)
   {
      string one[1];
      one[0] = line;
      Show(title, one, 1);
   }

   //| Llamar desde el OnTimer de 500 ms del caller: countdown de vida + reposición
   //| (sigue el resize del chart sin recrear objetos).
   void Tick()
   {
      if(!m_visible) return;
      m_lifeTicks--;
      if(m_lifeTicks <= 0) { Hide(); return; }
      int x = _X(), y = _Y();
      ObjectSetInteger(m_chartId, m_pfx + "BDR", OBJPROP_XDISTANCE, x - 1);
      ObjectSetInteger(m_chartId, m_pfx + "BDR", OBJPROP_YDISTANCE, y - 1);
      ObjectSetInteger(m_chartId, m_pfx + "BG",  OBJPROP_XDISTANCE, x);
      ObjectSetInteger(m_chartId, m_pfx + "BG",  OBJPROP_YDISTANCE, y);
      // Los labels cuelgan del BG: reubicar solo si el chart cambió de tamaño es
      // más caro que setear siempre — son ≤7 objetos cada 500 ms.
      ObjectSetInteger(m_chartId, m_pfx + "TTL", OBJPROP_XDISTANCE, x + 8);
      ObjectSetInteger(m_chartId, m_pfx + "TTL", OBJPROP_YDISTANCE, y + 3);
      for(int i = 0; i < TOAST_MAX_LINES; i++)
      {
         string n = m_pfx + "L" + IntegerToString(i);
         if(ObjectFind(m_chartId, n) < 0) break;
         ObjectSetInteger(m_chartId, n, OBJPROP_XDISTANCE, x + 8);
         ObjectSetInteger(m_chartId, n, OBJPROP_YDISTANCE, y + TOAST_TITLE_H + i * TOAST_LINE_H);
      }
      if(ObjectFind(m_chartId, m_pfx + "MORE") >= 0)
      {
         ObjectSetInteger(m_chartId, m_pfx + "MORE", OBJPROP_XDISTANCE, x + 8);
         // MORE va tras la última línea visible — su Y original era relativo a shown;
         // recomputarlo con el alto total es equivalente:
         ObjectSetInteger(m_chartId, m_pfx + "MORE", OBJPROP_YDISTANCE, y + m_height - 6 - TOAST_LINE_H);
      }
   }

   //| Click dentro de la tarjeta → la cierra. Llamar desde OnChartEvent
   //| (CHARTEVENT_MOUSE_MOVE con click nuevo o CHARTEVENT_CLICK) con coords px.
   //| Retorna true si consumió el click.
   bool HandleClick(int mx, int my)
   {
      if(!m_visible) return false;
      int x = _X(), y = _Y();
      if(mx >= x && mx <= x + m_width && my >= y && my <= y + m_height)
      {
         Hide();
         return true;
      }
      return false;
   }

   void Hide()
   {
      if(StringLen(m_pfx) == 0) return;
      m_visible = false;
      ObjectsDeleteAll(m_chartId, m_pfx);
      ChartRedraw(m_chartId);
   }

   void Deinit() { Hide(); }
};

#endif // AURAX_TOAST_MQH
