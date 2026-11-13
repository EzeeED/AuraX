//+------------------------------------------------------------------+
//| AuraX.mq5 — EA de la estrategia "Zonas Áureas" (Delorrio Capital)|
//| Versión: ver #property version                                    |
//|                                                                  |
//| Una sola EA = scanner + trading (combina EmaRiskPro y EMAScan,   |
//| con otra estrategia):                                            |
//|   1. Valida la licencia "AURX" contra delorrio.com (solo EA).    |
//|   2. Detecta el último impulso SOLO con velas y dibuja el Fibo   |
//|      de zonas áureas (Av1 … No Fasha) — CAuraFibo/CAuraRenderer. |
//|   3. Panel de trading igual al de EmaRiskPro (LOT, MULT, ET, RLC,|
//|      FRAC%, SIM/REAL). Herramienta SEMIAUTOMÁTICA: la primera    |
//|      entrada la hace el trader (INICIAR desde Av1); las demás    |
//|      (recoveries proporcionales) las abre la EA.                 |
//|   4. TP: Av1/Av2 → al cierre de la 3ª vela de retroceso (si está |
//|      en ganancia). Av3 en adelante → % fijo por zona (CAuraFibo).|
//|      La línea TP se puede arrastrar a mano.                      |
//|   5. Stop (FRACCIÓN): vela que CIERRA más allá de No Fasha.      |
//|   6. Scanner de Observación del Mercado (M5 en adelante) con     |
//|      avisos al llegar a Av1 / zonas más lejanas.                 |
//|                                                                  |
//| COMPILAR: solo este archivo (F7). No embebe ningún indicador.    |
//| El logo (MQL5\Images\AuraX: aurax.ico y aurax_logo22.bmp) se     |
//| embebe al compilar.                                              |
//|                                                                  |
//| Prerrequisito MT5: agregar https://delorrio.com en               |
//| Herramientas → Opciones → Asesores Expertos → URLs Web.          |
//+------------------------------------------------------------------+
#property copyright   "Delorrio Capital"
#property link        "https://delorrio.com"
#property icon        "\\Images\\AuraX\\aurax.ico"   // logo de AuraX (Navegador y ventana de propiedades)
#property version     "1.00"
#property description "AuraX — Zonas Áureas: último impulso + Fibo de zonas, scanner y trading (licenciado)"

#include <AuraX/Licensing/CLicenseValidator.mqh>
#include <AuraX/UI/CTradePanel.mqh>
#include <AuraX/UI/CAuraScanPanel.mqh>
#include <AuraX/UI/CToast.mqh>
#include <AuraX/Trading/CBasketManager.mqh>
#include <AuraX/Trading/CBasketOverlay.mqh>
#include <AuraX/Trading/CRecoveryMath.mqh>
#include <AuraX/Strategy/CAuraFibo.mqh>
#include <AuraX/Strategy/CAuraRenderer.mqh>
#include <AuraX/Scanner/CAuraScanner.mqh>

// Logo chico en la barra de título de los paneles (BMP embebido en el .ex5)
#resource "\\Images\\AuraX\\aurax_logo22.bmp"
#define AURX_LOGO_RES "::Images\\AuraX\\aurax_logo22.bmp"

#define AURX_VERSION  "1.00"
#define AURX_TITLE    ("AuraX v" + AURX_VERSION + " · delorrio.com")
#define AURX_PRODUCT  "AURX"     // código de licencia en delorrio.com
#define AURX_MAGIC    780321     // número mágico de las órdenes de AuraX
#define AURX_RECHECK_MIN 60      // re-validar licencia cada N minutos

// ── Inputs ────────────────────────────────────────────────────────
input group "=== Estrategia ==="
input int    InpBars              = 400;    // Velas de historia que se analizan
input int    InpMaxLeg            = 150;    // Máximo de velas por tramo (retroceso / impulso)
input string InpGainPrefix        = "Gain"; // Prefijo de símbolo que solo opera COMPRA (spike arriba)
input string InpPainPrefix        = "Pain"; // Prefijo de símbolo que solo opera VENTA (spike abajo)

input group "=== Panel ==="
input int    InpPanelX            = 10;     // Panel X (píxeles desde la izquierda)
input int    InpPanelY            = 25;     // Panel Y (píxeles desde arriba)
input string InpExcludedTFs       = "M1,M2,M3,M4"; // TFs ocultos en el dropdown (la estrategia es de M5 en adelante)
input double InpLotMin            = 0.01;   // Lote mínimo del panel
input double InpLotMax            = 100.0;  // Lote máximo del panel (se recorta al máximo del broker)
input double InpDefaultFrac       = 0.0;    // FRAC% — margen extra más allá de No Fasha (% del impulso)
input double InpDefaultMult       = 1.0;    // Multiplicador de recuperación (editable en el panel)
input int    InpDefaultET         = 1;      // Every Trade: cadencia de recuperación (editable en el panel)
input int    InpDefaultRLC        = 5;      // Cantidad de recoveries (con 5 caen casi justo en las zonas)

input group "=== Scanner ==="
input bool   InpScanEnabled       = true;   // Mostrar el scanner de zonas
input string InpScanExcludedTFs   = "";     // TFs excluidos del scan (ej: M5,M6)
input string InpScanExcludedSyms  = "";     // Símbolos excluidos del scan (nombres exactos, coma)
input int    InpScanPairsPerTick  = 6;      // Pares analizados cada medio segundo
input int    InpScanListMin       = 5;      // Releer Observación del Mercado cada N minutos

input group "=== Avisos del scanner ==="
input bool   InpAlertToast        = true;        // Tarjeta en el gráfico
input bool   InpAlertSound        = true;        // Sonido
input string InpAlertSoundFile    = "alert.wav"; // Archivo de sonido (carpeta Sounds)
input bool   InpAlertPush         = true;        // Push a la app móvil MT5 (requiere MetaQuotes ID)

input group "=== Visual ==="
input string InpPrefix            = "AUX_";            // Prefijo de objetos del gráfico
input color  InpColorBase         = clrDimGray;        // Niveles 0 y 1
input color  InpColorAv           = C'30,144,255';     // Av1 / Av2 / Av3
input color  InpColorFinal        = clrGold;           // Última zona
input color  InpColorEngano       = clrDarkOrange;     // Engaño
input color  InpColorNoFasha      = C'225,15,46';      // No Fasha

// ── Globals ───────────────────────────────────────────────────────
CLicenseValidator *g_lic = NULL;
datetime           g_lastLicCheck = 0;

CAuraFiboEngine    g_engine;
SAuraSetup         g_setup;            // Fibo vigente del gráfico
CAuraRenderer      g_render;
datetime           g_lastBar = 0;

CTradePanel        g_panel;
bool               g_panelReady = false;
CBasketManager     g_basket;
CBasketOverlay     g_overlay;
bool               g_basketBuy  = false;
SAuraSetup         g_bk;               // copia del Fibo con el que se abrió el basket
bool               g_tpArmed    = false;
bool               g_candleTpWarned = false;   // SIM: aviso único de "pagó por 3 velas"

CAuraScanner       g_scan;
CAuraScanPanel     g_scanPanel;
bool               g_scanReady  = false;
datetime           g_lastListBuild = 0;

CToast             g_toast;

//+------------------------------------------------------------------+
//| Licencia                                                          |
//+------------------------------------------------------------------+
SLicenseResponse _CheckLicense()
{
   if(g_lic == NULL)
   {
      g_lic = new CLicenseValidator(LICENSE_SERVER, AURX_PRODUCT);
      g_lic.SetVersion(AURX_VERSION);
   }
   g_lastLicCheck = TimeLocal();
   return g_lic.Check();
}

//+------------------------------------------------------------------+
//| Detección + dibujo                                                |
//+------------------------------------------------------------------+
bool _Detect()
{
   MqlRates rates[];
   int got = AuraLoadRates(_Symbol, _Period, InpBars, rates);
   if(got < 50) return false;
   bool allowBuy, allowSell;
   AuraSymbolBias(_Symbol, InpGainPrefix, InpPainPrefix, allowBuy, allowSell);
   g_engine.Evaluate(rates, got, _Period, allowBuy, allowSell, g_setup);
   return true;
}

// Con basket abierto se dibuja el Fibo del basket (no se mueve aunque el detector marque otro).
void _Redraw()
{
   datetime tEnd = iTime(_Symbol, _Period, 0) + AURA_RENDER_EXT_BARS * PeriodSeconds(_Period);
   if(g_basket.IsOpen() && g_bk.valid) g_render.Draw(g_bk, tEnd);
   else                                g_render.Draw(g_setup, tEnd);
}

//+------------------------------------------------------------------+
//| Niveles del basket                                                |
//+------------------------------------------------------------------+
// Stop (FRACCIÓN): No Fasha + FRAC% del impulso más allá. El basket lo dispara solo
// con la vela CERRADA más allá (regla 10 — "esperar cierre de vela").
double _SlPrice(const SAuraSetup &s)
{
   return AuraLevel(s, AURA_LVL_NOFASHA + g_panel.GetSL() / 100.0);
}

// Extremo alcanzado más allá del 0 desde que arrancó el impulso (incluye la vela en curso).
double _LiveExtreme(const SAuraSetup &s)
{
   int shift = iBarShift(_Symbol, _Period, s.t0);
   if(shift < 0) return s.xExt;
   if(!s.isBuy)
   {
      int hb = iHighest(_Symbol, _Period, MODE_HIGH, shift + 1, 0);
      return (hb >= 0) ? MathMax(s.xExt, iHigh(_Symbol, _Period, hb)) : s.xExt;
   }
   int lb = iLowest(_Symbol, _Period, MODE_LOW, shift + 1, 0);
   return (lb >= 0) ? MathMin(s.xExt, iLow(_Symbol, _Period, lb)) : s.xExt;
}

// TP por zona (Av3 en adelante). 0 = todavía se paga por 3 velas.
double _ZoneTp(const SAuraSetup &s) { return AuraTpPrice(s, _LiveExtreme(s)); }

// Un TP solo se manda si cierra el basket EN GANANCIA: tiene que quedar del lado bueno
// del precio promedio del basket. Claude: decisión de implementación — no validada por
// el dueño (en EmaRiskPro se comparaba contra la 1ª entrada; acá las zonas apuntan a
// cerrar todo el basket cerca de Av2/Av3, que puede quedar por detrás de la 1ª entrada).
bool _TpArmable(double tp, bool isBuy)
{
   if(tp <= 0.0) return false;
   double be = g_basket.GetBreakeven();
   if(be <= 0.0) return true;
   return isBuy ? (tp > be) : (tp < be);
}

bool _DirectionMatchesSymbol(bool isBuy)
{
   bool allowBuy, allowSell;
   AuraSymbolBias(_Symbol, InpGainPrefix, InpPainPrefix, allowBuy, allowSell);
   return isBuy ? allowBuy : allowSell;
}

//+------------------------------------------------------------------+
//| _OpenBasket — INICIAR (primera entrada, la hace el trader)        |
//+------------------------------------------------------------------+
void _OpenBasket()
{
   if(_Period < PERIOD_M5)
   {
      Alert("AuraX: la estrategia es de M5 en adelante — cambiá la temporalidad.");
      return;
   }
   if(!g_setup.valid)
   {
      Alert("AuraX: todavía no hay un impulso marcado en este símbolo/TF.");
      return;
   }
   bool isBuy = g_setup.isBuy;
   if(!_DirectionMatchesSymbol(isBuy))
   {
      Alert("AuraX: ", _Symbol, " opera solo ", isBuy ? "VENTA" : "COMPRA", " por el sesgo del spike.");
      return;
   }
   if(g_setup.state == AURA_ST_PAID)
   {
      Alert("AuraX: este Fibo ya pagó — esperá el próximo impulso.");
      return;
   }

   double entryPx = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                          : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(entryPx <= 0) return;

   // "A partir de Av1 ya se puede entrar": antes de Av1 no se abre.
   if(g_setup.state == AURA_ST_ARMED && AuraExt(g_setup, entryPx) < AURA_LVL_AV1)
   {
      Alert("AuraX: el precio todavía no llegó a Av1 (",
            DoubleToString(AuraLevel(g_setup, AURA_LVL_AV1), _Digits), ") — esperá la zona.");
      return;
   }

   double lot     = g_panel.GetLot();
   int    rlc     = g_panel.GetRLC();
   double slPrice = _SlPrice(g_setup);
   if(isBuy ? entryPx <= slPrice : entryPx >= slPrice)
   {
      Alert("AuraX: el precio ya pasó la FRACCIÓN (No Fasha) — no se abre.");
      return;
   }

   // Guarda de volumen (igual que EmaRiskPro): la grilla tiene que entrar en el límite del bróker.
   {
      double volMin   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      double volMax   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
      double volStep  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
      double volLimit = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_LIMIT);
      int maxReach = MaxReachableRecoveryLevel(lot, g_panel.GetMult(), g_panel.GetET(), rlc,
                                               volMin, volMax, volStep, volLimit);
      if(volLimit > 0.0 && maxReach < rlc)
      {
         Alert(StringFormat("AuraX: el bróker no deja pasar del recovery %d con esta configuración — bajá RLC, MULT o LOT.", maxReach));
         return;
      }
   }

   if(!g_panel.IsSimulation())
   {
      if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) { Alert("AuraX: AutoTrading deshabilitado."); return; }
      if(!SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE)) { Alert("AuraX: símbolo no disponible para operar."); return; }
   }

   double tpPrice = _ZoneTp(g_setup);
   if(tpPrice > 0.0 && (isBuy ? tpPrice <= entryPx : tpPrice >= entryPx)) tpPrice = 0.0;   // se arma solo después

   double recStep = MathAbs(entryPx - slPrice) / (rlc + 1);
   g_basket.SetMode(g_panel.IsSimulation());
   if(!g_basket.Open(_Symbol, isBuy, lot, entryPx, recStep, tpPrice, slPrice, entryPx))
   {
      Print("[AuraX] no se pudo abrir el basket");
      if(!g_panel.IsSimulation()) Alert("AuraX REAL: no se pudo abrir la orden — ver Diario.");
      return;
   }

   g_basketBuy      = isBuy;
   g_bk             = g_setup;
   g_tpArmed        = (tpPrice > 0.0);
   g_candleTpWarned = false;
   g_overlay.Open(entryPx, tpPrice, slPrice, recStep, rlc, isBuy, lot, g_panel.GetMult(), g_panel.GetET());
   g_panel.SetMainButton("CERRAR");
   _Redraw();
   PrintFormat("[AuraX] INICIAR %s %s en %s — FRACCIÓN %s, %d recoveries, TP %s",
               isBuy ? "COMPRA" : "VENTA", _Symbol, DoubleToString(entryPx, _Digits),
               DoubleToString(slPrice, _Digits), rlc,
               tpPrice > 0.0 ? DoubleToString(tpPrice, _Digits) : "por 3 velas de retroceso");
}

//+------------------------------------------------------------------+
//| _RecalcBasket — cambió FRAC% o RLC con el basket abierto          |
//+------------------------------------------------------------------+
void _RecalcBasket()
{
   if(!g_overlay.IsOpen() || !g_basket.IsOpen()) return;
   double baseLot = g_basket.GetBaseLot();
   if(baseLot <= 0.0) baseLot = g_panel.GetLot();
   g_overlay.UpdateDisplay(baseLot, g_panel.GetMult(), g_panel.GetET(), GetPointer(g_basket));
   if(!g_bk.valid) return;

   double slPrice = g_overlay.IsSlDecoupled() ? g_basket.GetSLPrice() : _SlPrice(g_bk);
   g_overlay.Recalculate(g_basket.GetTPPrice(), slPrice, g_panel.GetRLC(), baseLot,
                         g_panel.GetMult(), g_panel.GetET(), GetPointer(g_basket));
}

//+------------------------------------------------------------------+
//| _TickLiveTp — TP por zona (Av3 en adelante), en cada tick         |
//+------------------------------------------------------------------+
void _TickLiveTp()
{
   if(!g_overlay.IsOpen() || g_overlay.IsDragging()) return;
   if(g_overlay.IsTpDecoupled()) return;      // TP arrastrado a mano → se respeta
   if(!g_basket.IsOpen() || !g_bk.valid) return;

   double tp = _ZoneTp(g_bk);
   if(tp <= 0.0) return;                       // Av1/Av2 → paga por 3 velas (_TickCandleTp)

   if(!_TpArmable(tp, g_basketBuy))
   {
      if(g_tpArmed)
      {
         g_tpArmed = false;
         PrintFormat("[AuraX] TP %s desarmado: cerraría el basket en pérdida (promedio %s)",
                     DoubleToString(tp, _Digits), DoubleToString(g_basket.GetBreakeven(), _Digits));
      }
      if(g_basket.GetTPPrice() <= 0.0) g_overlay.ShowTpDisarmed(tp, GetPointer(g_basket));
      return;
   }
   if(!g_tpArmed)
   {
      g_tpArmed = true;
      PrintFormat("[AuraX] TP armado en %s (zona %s)", DoubleToString(tp, _Digits),
                  AuraZoneName(AuraZoneOf(AuraExt(g_bk, _LiveExtreme(g_bk)))));
   }
   g_overlay.UpdateTp(tp, GetPointer(g_basket));
   g_basket.SetTPPrice(tp);
}

//+------------------------------------------------------------------+
//| _TickCandleTp — Av1/Av2: paga al cierre de la 3ª vela de          |
//| retroceso (por color, no necesariamente seguidas), si el basket   |
//| está en ganancia. Se evalúa una vez por vela nueva.               |
//+------------------------------------------------------------------+
void _TickCandleTp()
{
   if(!g_basket.IsOpen() || !g_bk.valid) return;
   if(g_overlay.IsTpDecoupled()) return;       // el trader puso su TP a mano

   // Extremo y su vela, solo con velas CERRADAS
   int shift0 = iBarShift(_Symbol, _Period, g_bk.t0);
   if(shift0 < 1) return;
   int xb = g_basketBuy ? iLowest(_Symbol, _Period, MODE_LOW, shift0, 1)
                        : iHighest(_Symbol, _Period, MODE_HIGH, shift0, 1);
   if(xb < 1) return;
   double x = g_basketBuy ? MathMin(g_bk.xExt, iLow(_Symbol, _Period, xb))
                          : MathMax(g_bk.xExt, iHigh(_Symbol, _Period, xb));
   if(AuraExt(g_bk, x) >= AURA_LVL_AV3) return;   // Av3 en adelante → TP por zona

   int retrace = 0;   // venta: rojas / compra: verdes, desde la vela del extremo
   for(int s = xb; s >= 1; s--)
   {
      double o = iOpen(_Symbol, _Period, s), c = iClose(_Symbol, _Period, s);
      if(g_basketBuy ? (c > o) : (c < o)) retrace++;
   }
   if(retrace < AURA_MIN_CANDLES) return;

   double pnl = g_basket.GetPnl(_Symbol);
   if(pnl <= 0.0) return;

   if(g_basket.IsSim())
   {
      // SIM mide pero no liquida (mismo criterio que EmaRiskPro): aviso único
      if(!g_candleTpWarned)
      {
         g_candleTpWarned = true;
         g_toast.ShowOne("AuraX — SIM", "Pagó por 3 velas de retroceso (+" + DoubleToString(pnl, 2) + ")");
         Print("[AuraX] SIM: pagó por 3 velas de retroceso — PnL ", DoubleToString(pnl, 2));
      }
      return;
   }
   g_overlay.Close();
   g_panel.SetMainButton("INICIAR");
   g_basket.CloseAll(_Symbol, "TP: 3 velas de retroceso");
   _Redraw();
}

//+------------------------------------------------------------------+
//| _AdoptBasket — re-adopción tras navegar/recompilar/reiniciar      |
//+------------------------------------------------------------------+
void _AdoptBasket()
{
   if(!g_basket.IsOpen())
   {
      bool isBuy = false;
      if(g_basket.AdoptOpenPositions(_Symbol, isBuy) <= 0) return;
      g_basketBuy = isBuy;
   }
   else
   {
      if(g_overlay.IsOpen()) return;
      if(g_basket.GetSymbol() != _Symbol) return;
   }

   g_tpArmed = false;
   g_panel.SetSimulation(false);
   g_panel.SetMainButton("CERRAR");

   // Fibo del basket: el del gráfico si va en la misma dirección
   ZeroMemory(g_bk);
   g_bk.valid = false;
   if(g_setup.valid && g_setup.isBuy == g_basketBuy) g_bk = g_setup;

   double entry = g_basket.GetEntryPrice();
   double sl    = g_bk.valid ? _SlPrice(g_bk) : 0.0;
   if(sl > 0.0) g_basket.SetSLPrice(sl);

   int    posN    = g_basket.GetPosCount();
   int    rlc     = MathMax(g_panel.GetRLC(), posN - 1);
   double recStep = (sl > 0.0 && rlc > 0) ? MathAbs(entry - sl) / (rlc + 1) : 0.0;
   if(recStep <= 0.0) rlc = 0;
   double baseLot = g_basket.GetBaseLot();
   if(baseLot <= 0.0) baseLot = g_panel.GetLot();
   g_overlay.Open(entry, 0.0, sl, recStep, rlc, g_basketBuy, baseLot, g_panel.GetMult(), g_panel.GetET());
   g_overlay.RestoreRecLevels(g_basket);
   _Redraw();
   PrintFormat("[AuraX] Basket REENGANCHADO: %d posiciones %s en %s — TP se re-arma solo",
               posN, g_basketBuy ? "COMPRA" : "VENTA", _Symbol);
}

void _CloseBasket()
{
   g_overlay.Close();
   g_panel.SetMainButton("INICIAR");
   g_basket.CloseAll(_Symbol, "botón CERRAR");
   _Redraw();
}

void _TickBasket()
{
   if(!g_basket.IsOpen()) return;
   int maxRec = g_overlay.IsOpen() ? g_overlay.GetRecCount() : g_panel.GetRLC();
   EBasketResult res = g_basket.Update(_Symbol, g_basketBuy, maxRec, g_panel.GetMult(), g_panel.GetET());
   if(res == BASKET_TP_HIT || res == BASKET_SL_HIT)
   {
      g_overlay.Close();
      g_panel.SetMainButton("INICIAR");
      _Redraw();
   }
}

//+------------------------------------------------------------------+
//| Scanner                                                           |
//+------------------------------------------------------------------+
void _ScanTick()
{
   if(!g_scanReady) return;
   if(TimeLocal() - g_lastListBuild >= InpScanListMin * 60)
   {
      g_scan.BuildList();
      g_lastListBuild = TimeLocal();
   }
   g_scan.Step(MathMax(1, InpScanPairsPerTick));
   g_scan.RefreshPrices();
   g_scanPanel.Refresh(g_scan);
   g_scanPanel.SetTitleText("Scanner · " + IntegerToString(g_scan.Count()) + " pares");

   string news[];
   int n = g_scan.ConsumeNews(news);
   if(n <= 0) return;
   if(InpAlertToast) g_toast.Show("AuraX — zona alcanzada", news, n);
   if(InpAlertSound) PlaySound(InpAlertSoundFile);
   if(InpAlertPush && TerminalInfoInteger(TERMINAL_NOTIFICATIONS_ENABLED))
   {
      string all = "AuraX: ";
      for(int i = 0; i < n; i++) all += (i > 0 ? " | " : "") + news[i];
      SendNotification(StringSubstr(all, 0, 255));
   }
   for(int i = 0; i < n; i++) Print("[AuraX scan] ", news[i]);
}

//+------------------------------------------------------------------+
//| OnInit                                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   PrintFormat("[AuraX] %s iniciando en %s %s (terminal build %d)",
               AURX_TITLE, _Symbol, EnumToString(_Period), (int)TerminalInfoInteger(TERMINAL_BUILD));

   SLicenseResponse r = _CheckLicense();
   if(!r.valid)
   {
      Print("[AuraX] licencia inválida — la EA se quita del gráfico. Detalle: " + r.message);
      Alert(AURX_TITLE + ": " + r.message);
      return INIT_FAILED;
   }

   if(StringLen(InpPrefix) > 0) ObjectsDeleteAll(0, InpPrefix);   // restos de una sesión que se cortó

   g_render.Init(ChartID(), InpPrefix + "FIB_", _Digits);
   g_render.SetColors(InpColorBase, InpColorAv, InpColorFinal, InpColorEngano, InpColorNoFasha);
   g_engine.SetMaxLeg(InpMaxLeg);
   ZeroMemory(g_setup); g_setup.valid = false;
   ZeroMemory(g_bk);    g_bk.valid    = false;

   g_toast.Init(ChartID(), InpPrefix);
   if(r.update_available)
      g_toast.ShowOne("AuraX — actualización", "v" + r.latest_version + " disponible en delorrio.com/members");

   g_basket.SetMagic(AURX_MAGIC);
   g_basket.SetTF(_Period);

   g_panelReady = false;
   g_scanReady  = false;
   g_lastBar    = 0;
   EventSetMillisecondTimer(500);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| OnTimer — paneles (lazy), overlay, scanner y licencia             |
//+------------------------------------------------------------------+
void OnTimer()
{
   g_toast.Tick();

   if(!g_panelReady)
   {
      g_panel.SetExcludedTFs(InpExcludedTFs);    // ANTES de Init()
      g_panel.SetBrand("AURA", "X", " ");          // marca del título — ANTES de Init()
      g_panel.SetLogo(AURX_LOGO_RES);              // logo — ANTES de Init()
      if(g_panel.Init(ChartID(), InpPanelX, InpPanelY, InpPrefix, AURX_TITLE,
                      0.0, InpDefaultFrac, InpLotMin, InpLotMax,
                      InpDefaultMult, InpDefaultET, InpDefaultRLC))
      {
         g_panel.SetMainButton("INICIAR");
         g_panel.UpdateSymDropdown(_Symbol);
         g_panel.UpdateTFDropdown(_Period);
         g_overlay.Init(ChartID(), InpPrefix, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS), _Symbol, _Period);
         g_panelReady = true;
         if(_Detect()) { g_lastBar = iTime(_Symbol, _Period, 0); }
         _AdoptBasket();
         _Redraw();
      }
      if(InpScanEnabled && !g_scanReady)
      {
         g_scanPanel.SetBrand("AURA", "X", " ");
         g_scanPanel.SetLogo(AURX_LOGO_RES);
         g_scanPanel.Init(ChartID(), InpPanelX + TRADE_W_DEFAULT + 10, InpPanelY, InpPrefix, "Scanner");
         g_scan.Configure(InpBars, InpMaxLeg, InpScanExcludedTFs, InpScanExcludedSyms,
                          InpGainPrefix, InpPainPrefix);
         g_scan.BuildList();
         g_lastListBuild = TimeLocal();
         g_scanReady = true;
      }
      ChartRedraw();
      return;
   }

   // Sin ticks (mercado quieto / fin de semana) igual se detecta la primera vez
   if(g_lastBar == 0 && _Detect()) { g_lastBar = iTime(_Symbol, _Period, 0); _Redraw(); }

   g_panel.BringToFront();
   g_overlay.SetExclusionRect(g_panel.PanelX(), g_panel.PanelY(),
                              g_panel.PanelX() + g_panel.PanelW(),
                              g_panel.PanelY() + g_panel.PanelH());
   if(g_scanReady)
      g_overlay.SetExclusionRect2(g_scanPanel.PanelX(), g_scanPanel.PanelY(),
                                  g_scanPanel.PanelX() + g_scanPanel.PanelW(),
                                  g_scanPanel.PanelY() + g_scanPanel.PanelH());
   g_overlay.TickDragWatchdog(g_basket);
   if(g_basket.IsOpen())
   {
      g_overlay.SetLive(g_basket.GetPnl(_Symbol), !g_panel.IsSimulation(), g_basket.GetPositionCount() - 1);
      if(!g_basket.HasVirtualEntry()) g_overlay.SyncEntryPrice(g_basket.GetEntryPrice());
      g_overlay.SetEntryLocked(!g_panel.IsSimulation() && !g_basket.HasVirtualEntry()
                               && g_basket.GetPositionCount() > 0);
      if(!g_overlay.IsDragging()) g_overlay.Refresh();
   }
   else if(g_panel.IsMainButtonClose())
   {
      g_overlay.Close();
      g_panel.SetMainButton("INICIAR");
      _Redraw();
   }

   _ScanTick();
   ChartRedraw();

   if(TimeLocal() - g_lastLicCheck >= AURX_RECHECK_MIN * 60)
   {
      SLicenseResponse r = _CheckLicense();
      if(!r.valid)
      {
         Alert(AURX_TITLE + ": licencia " + r.status + " — " + r.message);
         EventKillTimer();
         ExpertRemove();
      }
   }
}

//+------------------------------------------------------------------+
//| OnTick                                                            |
//+------------------------------------------------------------------+
void OnTick()
{
   datetime bar0 = iTime(_Symbol, _Period, 0);
   bool newBar = (bar0 != g_lastBar);
   if(newBar && _Detect())
   {
      g_lastBar = bar0;
      _Redraw();
   }
   if(!g_panelReady) return;

   _TickBasket();
   _TickLiveTp();
   if(newBar) _TickCandleTp();
}

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type != TRADE_TRANSACTION_REQUEST) return;
   if(result.retcode == TRADE_RETCODE_DONE) return;
   g_basket.OnCloseRejected(request.position, result.retcode, result.comment);
}

//+------------------------------------------------------------------+
//| OnDeinit                                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   bool wasSim = g_panel.IsSimulation();
   g_toast.Deinit();
   g_overlay.Close();
   g_panel.Deinit();
   g_scanPanel.Deinit();
   g_render.Clear();

   if(reason == REASON_CHARTCHANGE)
   {
      if(g_basket.IsOpen() && g_basket.IsSim())
         Print("[AuraX] Cambio de símbolo/TF con basket SIM abierto — la simulación se descarta.");
      else if(g_basket.IsOpen())
         PrintFormat("[AuraX] Cambio de símbolo/TF con basket REAL — las posiciones siguen y se re-adoptan al volver a %s.", _Symbol);
      g_panelReady = false;
      g_scanReady  = false;
   }
   else
   {
      if(g_basket.IsOpen())
      {
         if(wasSim) g_basket.CloseAll(_Symbol, "EA removida con basket SIM abierto");
         else Alert("AuraX: EA removida con posiciones REALES abiertas en ", _Symbol,
                    ". Quedan sin gestión automática — cerralas o volvé a poner la EA.");
      }
      Comment("");
   }
   if(g_lic != NULL) { delete g_lic; g_lic = NULL; }
}

//+------------------------------------------------------------------+
//| OnChartEvent — panel de trading, scanner y líneas del basket      |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lp, const double &dp, const string &sp)
{
   if(id == CHARTEVENT_OBJECT_CLICK && StringFind(sp, InpPrefix + "TST_") == 0) { g_toast.Hide(); return; }
   if(id == CHARTEVENT_CLICK && g_toast.HandleClick((int)lp, (int)dp)) return;
   if(!g_panelReady) return;

   bool overlayConsumed = g_overlay.OnEvent(id, lp, dp, sp, g_basket);
   if(g_overlay.ConsumeEntryCloseClick())
   {
      if(g_basket.IsOpen())
      {
         if(!g_basket.IsSim() && !MQLInfoInteger(MQL_TESTER))
            if(MessageBox("¿Cerrar TODAS las posiciones reales del basket en " + _Symbol + "?",
                          "AuraX", MB_OKCANCEL | MB_ICONWARNING) == IDCANCEL) return;
         _CloseBasket();
      }
      else g_overlay.Close();
      return;
   }
   if(overlayConsumed) return;

   g_panel.OnMouseEvent(id, lp, dp, sp);
   if(g_scanReady)
   {
      g_scanPanel.OnMouseEvent(id, lp, dp, sp);
      if(g_scanPanel.ConsumeNavigate())
      {
         ChartSetSymbolPeriod(ChartID(), g_scanPanel.NavSymbol(), g_scanPanel.NavTF());
         return;
      }
      if(g_scanPanel.ConsumeCloseClick())
      {
         g_scanPanel.Hide();         // se cierra solo el scanner; la EA sigue
         g_overlay.SetExclusionRect2(0, 0, -1, -1);
         g_scanReady = false;
      }
   }

   if(g_panel.ConsumeParamsChanged())
   {
      if(g_basket.IsOpen() && g_overlay.IsOpen())
      {
         if(g_panel.ConsumeGeomChanged()) _RecalcBasket();
         else g_overlay.UpdateDisplay(g_panel.GetLot(), g_panel.GetMult(), g_panel.GetET(), GetPointer(g_basket));
      }
      else g_panel.ConsumeGeomChanged();
   }
   if(g_overlay.ConsumeRecCountChanged()) g_panel.SetRLC(g_overlay.GetRecCount());

   if(g_panel.ConsumeCloseClick())
   {
      if(!MQLInfoInteger(MQL_TESTER))
         if(MessageBox("¿Cerrar AuraX?", "AuraX", MB_OKCANCEL | MB_ICONQUESTION) == IDCANCEL) return;
      if(g_basket.IsOpen()) { g_basket.CloseAll(_Symbol, "cierre del panel (X)"); g_overlay.Close(); }
      EventKillTimer();
      ExpertRemove();
      return;
   }

   if(g_panel.ConsumeIniciar())
   {
      if(g_basket.IsOpen()) _CloseBasket();
      else                  _OpenBasket();
   }

   if(g_panel.ConsumeModeChange())
   {
      if(g_basket.IsOpen() && !g_panel.IsSimulation())
      {
         if(g_basket.IsSim())
         {
            double entryPrice = g_overlay.IsEntryDecoupled() ? g_overlay.GetEntry() : 0.0;
            if(!g_basket.ConvertToReal(_Symbol, g_basketBuy, entryPrice))
            {
               g_panel.SetSimulation(true);
               Alert("AuraX: no se pudo pasar a REAL (sin ejecución). Sigue en SIM — ver Diario.");
            }
         }
      }
      else if(g_basket.IsOpen() && g_panel.IsSimulation() && !g_basket.IsSim())
         g_panel.SetSimulation(false);   // REAL → SIM no se permite con posiciones reales
   }

   if(g_panel.ConsumeSymbolChange())
      ChartSetSymbolPeriod(ChartID(), g_panel.GetSymbol(), g_panel.GetTF());
   else if(g_panel.ConsumeTFChange())
      ChartSetSymbolPeriod(ChartID(), _Symbol, g_panel.GetTF());
}
