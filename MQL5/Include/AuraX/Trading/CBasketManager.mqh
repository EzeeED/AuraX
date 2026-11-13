//+------------------------------------------------------------------+
//| CBasketManager.mqh                                               |
//| Basket SIM/REAL con TP/SL virtual y grid de recoveries.         |
//|                                                                  |
//| Principio ADR-008: CERO órdenes ni stops al broker.             |
//| Todo se gestiona virtualment en software:                        |
//|   • TP, SL, recoveries, entrada diferida — monitoreados por     |
//|     Update() cada tick; market order sólo cuando precio toca.   |
//|                                                                  |
//| API:                                                             |
//|   Open(sym, isBuy, lot, endpoint, recStep, tpPrice, slPrice      |
//|        [, entryPx])                                              |
//|   ConvertToReal(sym, isBuy) — SIM→REAL (entrada a mercado)      |
//|   Update(sym, isBuy, maxRec, mul) → EBasketResult               |
//|   CloseAll(sym) / Reset()                                        |
//|   GetPnl(sym) / GetStatusText() / GetTPPrice() / GetSLPrice()   |
//+------------------------------------------------------------------+
#ifndef AURAX_BASKETMANAGER_MQH
#define AURAX_BASKETMANAGER_MQH

#include <Trade\Trade.mqh>
#include <AuraX/Trading/CRecoveryMath.mqh>

// Entrada (índice 0) + hasta 500 recoveries (= BOVL_MAX_REC del overlay).
// SIEMPRE = BOVL_MAX_REC + 1: el guard posN>=MAX autoliquida el basket (anti-overflow),
// así que un MAX menor al del overlay cerraría baskets válidos (M2, v5.56; tope 50 en v5.87).
#define CBM_MAX_POS 501  // entrada + 500 recoveries (v6.50; era 151 hasta v6.49)

// Cooldown entre reintentos de un OrderSend REAL que el broker RECHAZÓ (v6.45 — hallazgo en
// logs de producción 2026-08-01/02: un rechazo duro (ej. retcode 10034, límite de volumen
// agregado del símbolo superado por MULT compuesto) se reintentaba en CADA tick sin freno —
// 1580 intentos en 1.5 h machacando al broker con la MISMA orden condenada, sin aviso.
#define CBM_RETRY_COOLDOWN_MS 30000

// Cuánto esperar a que aparezca cada posición de una ráfaga async de recoveries (issue #75-bis)
// antes de darla por rechazada. El fill async normal confirma en el próximo tick (milisegundos);
// 5 s es margen de sobra para latencia real de red sin llegar a confundirse con un rechazo.
#define CBM_RECOPEN_TIMEOUT_MS 5000

// Cooldown del diagnóstico del trigger de recovery (v6.49). 1 s alcanza para ver la evolución
// sin inundar el Journal — la transición a "dispara" se imprime siempre, ignore el cooldown.
#define CBM_RECDIAG_COOLDOWN_MS 1000

// Reporte PO 2026-08-04 (incidente GainX 800): ciclos seguidos sin progreso neto en el MISMO
// punto de la grilla antes de dejar de reintentar esa dirección — la guarda preventiva
// (MaxReachableRecoveryLevel, panel + _OpenBasket) evita el caso común; esto es la red mínima
// para lo que esa guarda no puede ver (SYMBOL_VOLUME_LIMIT sin publicar, rechazo por margen).
#define CBM_RECBURST_MAX_FAIL_STREAK 5

// Cada cuánto barrer el símbolo buscando una posición que confirmó TARDE (fuera de la ventana
// de CBM_RECOPEN_TIMEOUT_MS) y quedó fuera de m_tickets[] — mientras el basket REAL sigue
// abierto, no solo al CERRAR (que es lo único que hacía _CloseForgotten hasta 2026-08-04).
#define CBM_ORPHAN_SCAN_INTERVAL_MS 5000

// Cooldown mínimo entre reintentos de un CloseAll pendiente (v6.81 — hallazgo cruce Journal
// nativo MT5 + log EA, 2026-08-06): PositionClose es ASYNC, confirma en ~250-260ms de
// round-trip; sin freno, Update() reenviaba el MISMO cierre en CADA tick mientras esperaba —
// 3 tandas de cierre en 210ms (t+0/+75/+210ms) para los mismos 4 tickets. La 1ra confirmó y
// cerró bien; la 2da y 3ra llegaron tarde y volvieron con retcode 10036 (POSITION_CLOSED,
// "ya no existe") — ruido inofensivo esta vez, pero tráfico redundante al bróker y Journal
// sucio. 750ms = ~3x el round-trip observado, mismo criterio de margen que ya usa
// CBM_RECOPEN_TIMEOUT_MS sobre su propia async. Solo frena el REINTENTO (m_closePending ya
// true) — el primer CloseAll de cualquier caller (TP/SL hit, botón CERRAR, tope) sale siempre
// inmediato.
#define CBM_CLOSE_RETRY_MS 750

// Tope de candidatos por barrido de _ClaimStragglers — más que suficiente (huérfanas son la
// excepción, no la regla); el resto se agarra en el próximo barrido, CBM_ORPHAN_SCAN_INTERVAL_MS
// después. Literal #define porque MQL5 no acepta un `const int` local para dimensionar un array.
#define CBM_STRAGGLER_SCAN_CAP 64

enum EBasketResult
{
   BASKET_NONE,
   BASKET_TP_HIT,
   BASKET_SL_HIT,
   BASKET_REC_OPENED
};

struct SSimPosition
{
   double openPrice;
   double lot;
   bool   isBuy;
};

class CBasketManager
{
private:
   CTrade            m_trade;
   long              m_magic;     // mágico CONFIGURADO (v6.44) — nunca leerlo de RequestMagic()
   bool              m_isSim;
   bool              m_dirBuy;    // dirección del basket — la usa la guarda de SetTPPrice (issue #55)
   ENUM_TIMEFRAMES   m_tf;

   //--- Geometría del grid (precios absolutos)
   double m_endpoint;   // base del grid de recoveries
   double m_recStep;    // distancia entre niveles de recovery

   //--- Estado SIM
   SSimPosition m_simPos[CBM_MAX_POS];
   int          m_simCount;
   double       m_simTp, m_simSl, m_simNextRec;
   // ADR-043 (reporte PO 2026-08-05): qué habría terminado el basket SIM AHORA MISMO si
   // fuera REAL (BASKET_NONE/TP_HIT/SL_HIT). En SIM el precio MIDE pero no LIQUIDA — el
   // plan solo lo cierra el botón CERRAR (o la conversión a REAL). Foto recalculada por
   // tick en Update(), no pegajosa: si el precio vuelve, esto vuelve a BASKET_NONE.
   EBasketResult m_simHypoExit;

   //--- Estado REAL — posiciones abiertas
   ulong  m_tickets[CBM_MAX_POS];
   int    m_posCount;
   //--- Libro mayor append-only de TODO ticket que este basket abrió (v6.36). m_tickets[] es el
   //    estado vivo y se puede pisar; esto no. Lo usa _CloseForgotten como red anti-huérfanas.
   ulong  m_everTickets[CBM_MAX_POS];
   int    m_everCount;
   double m_tpPrice, m_slPrice, m_nextRecLvl;
   string m_basketSym;   // símbolo del basket — guarda anti trading cruzado al navegar sym/TF (C-3)

   //--- Entrada diferida virtual (ADR-008 — sin orden pendiente al broker)
   double m_virtEntryPx;    // precio objetivo; 0 = sin entrada diferida
   double m_virtEntryLot;   // lote de la entrada diferida
   bool   m_virtEntryUp;    // true → disparar cuando precio SUBE a ese nivel
   // Índice de m_tickets[] RESERVADO para la entrada diferida al armarla. Imprescindible:
   // ConvertToReal arma la entrada (reserva el slot 0) y DESPUÉS agrega los recoveries del SIM
   // en 1..N, así que para cuando la entrada llena, m_posCount-1 ya apunta a un RECOVERY.
   // Escribir ahí pisaba su ticket y esa posición quedaba sin dueño: CloseAll no la cerraba
   // nunca (incidente 2026-08-01 — "ERP Ent #9" quedó abierta). -1 = sin reserva.
   int    m_virtEntrySlot;

   //--- TP dinámico (§10.3 estrategia: 45% del retroceso desde el peor precio)
   double m_entryPrice;     // precio de apertura de la primera posición
   double m_worstPx;        // peor precio adverso tracking
   bool   m_dynTpActive;    // true = TP dinámico activo (post-primer recovery)

   //--- Fibonacci de EXTENSIÓN para entrada diferida (reporte PO 2026-08-04): el TP de zona
   //    (LL/HH) no sabe dónde entró el operador — si la entrada diferida quedó profunda dentro
   //    del rango, el 45% cae del lado perdedor y se queda desarmado PARA SIEMPRE, porque la
   //    fórmula nunca vuelve a mirar la entrada. Este ratchet mide lo FAVORABLE (espejo de
   //    m_worstPx, que mide lo adverso) desde el fill real de la entrada diferida — permite un
   //    TP que se autoarma en cuanto el precio valida la operación, en vez de nunca.
   bool   m_entryWasDeferred;  // esta entrada nació diferida — activa el Fibo de extensión
   double m_favorablePx;       // mejor precio visto desde que la entrada diferida se llenó

   //--- Override de niveles de recovery (drag del usuario en el overlay)
   double m_recLvlOverride[CBM_MAX_POS];  // 1-indexed; 0 = usar fórmula

   //--- Contador secuencial de órdenes enviadas al broker (entry=1, rec1=2, ...)
   int    m_orderCount;

   //--- Dígitos del símbolo activo — se fija en Open()/Restore() para formatear precios en logs
   int    m_digits;

   //--- Fix 5: cache tick size/value para GetPnl() SIM — evita SymbolInfoDouble() por tick
   double m_tickSize;
   double m_tickVal;

   //--- Fix 6: guard post-ConvertToReal para evitar cierre espurio por barra pre-conversión.
   // m_justConverted: suprime TP/SL 1 tick (broker async).
   // m_convertBarTime: bloquea el SL "closed bar" check hasta que cierre una barra nueva
   //   post-conversión — evita que una barra que cerró bajo el SL en fase SIM dispare el SL.
   bool     m_justConverted;
   datetime m_convertBarTime;
   // m_closePending: un CloseAll REAL falló parcialmente (algún PositionClose con error
   //   transitorio). Update() reintenta cada tick hasta cerrar todo — evita huérfanos.
   bool     m_closePending;
   // m_closeRetryNextMs: GetTickCount() del próximo reintento permitido (CBM_CLOSE_RETRY_MS).
   //   0 = sin cooldown activo. Evita reenviar el mismo cierre antes de que confirme el previo.
   uint     m_closeRetryNextMs;
   // m_hitSuspended: en SIM, inhibe TP/SL durante drag del overlay.
   // m_dragGrace: ticks de gracia post-drag antes de reactivar checks (evita disparo inmediato al soltar).
   bool     m_hitSuspended;
   int      m_dragGrace;
   // m_prevBid/m_prevAsk (detección de cruce del TP en SIM) se ELIMINARON en v6.43:
   // SIM y REAL pagan por nivel simple (decisión del PO, Fase 6 2026-08-02).

   // Backoff + aviso único para un OrderSend REAL rechazado por el broker (v6.45).
   // "FailWarned" se resetea al recuperar (próxima orden de ese tipo que SÍ entra), así que
   // un rechazo nuevo — aunque sea el mismo símbolo — vuelve a avisar una vez.
   bool     m_recOpenFailWarned;
   uint     m_recOpenNextTryMs;    // GetTickCount() — 0 = sin cooldown activo
   bool     m_entryOpenFailWarned;
   uint     m_entryOpenNextTryMs;

   //--- Ráfaga de recoveries en ASYNC (issue #75-bis, 2026-08-03, pedido del PO: "tiene que
   //    ser un bot de alta frecuencia" — precedente issue #72, "150 recoveries aplastados al
   //    precio y solo entra la entrada"). Cuando el precio salta varios niveles de golpe, se
   //    disparan TODOS los OrderSend elegibles de una vez (mismo patrón async que CloseAll)
   //    en vez de uno por tick esperando cada confirmación. m_recOpenPendingCount = cuántos
   //    quedan por confirmar (se descubren por ticket nuevo, no por retcode: en async el
   //    Buy()/Sell() devuelve "enviado", no "ejecutado"). m_recOpenPendingSinceMs = cuándo se
   //    disparó la ráfaga — pasado CBM_RECOPEN_TIMEOUT_MS sin que aparezca una posición nueva,
   //    lo que falte se trata como rechazado por el broker (mismo aviso y cooldown de siempre).
   int      m_recOpenPendingCount;
   uint     m_recOpenPendingSinceMs;

   //--- Tope de reintentos sin progreso + reconciliación de huérfanas fuera de ventana
   //    (reporte PO 2026-08-04, incidente GainX 800). Ver CBM_RECBURST_MAX_FAIL_STREAK arriba.
   int      m_recBurstFailStreak;       // ciclos seguidos sin progreso neto en el mismo punto
   int      m_recBurstFailBoundary;     // recsDone donde ocurrió la última falla (-1 = ninguna)
   int      m_recBurstLastFailSize;     // techo del PRÓXIMO intento en ese mismo punto (0 = sin techo)
   bool     m_recBurstIncompleteWarned; // aviso único del ciclo "no confirmaron" (por racha)
   bool     m_recOpenBlocked;           // tope alcanzado: no reintenta más esta dirección
   bool     m_recOpenBlockedWarned;     // aviso único, distinto del de arriba, al bloquear del todo
   uint     m_orphanScanNextMs;         // GetTickCount() del próximo barrido de huérfanas

   //--- Diagnóstico del trigger de recovery (v6.49, issue #72). El PO reportó "150 recoveries
   //    aplastados al precio y solo entra la entrada": el Journal no mostraba NI UN intento ni
   //    un rechazo, así que el trigger nunca evaluó verdadero y no había con qué saber por qué.
   uint     m_recDiagNextMs;    // GetTickCount() del próximo print permitido
   bool     m_recDiagLastTrig;  // último valor de "dispara" — su transición se imprime siempre

   //--- Inyección de precios para el REPLAY del basket (Fase 7 — scripts/EmaRiskPro/
   //    BasketReplay.mq5). Con m_testFeed=true, Update()/GetPnl() leen estos valores en
   //    vez del terminal — es lo que permite reproducir el incidente 2026-08-01 con ticks
   //    sintéticos. En producción NUNCA se activa (default false): cero cambio de conducta.
   bool     m_testFeed;
   double   m_testBid, m_testAsk, m_testClosedPx;

   string _Fmt(double px) const { return DoubleToString(px, m_digits); }

   //--- Nivel de trigger del recovery N (1-based desde endpoint)
   double _RecLevel(bool isBuy, int n)
   {
      return isBuy ? m_endpoint - n * m_recStep
                   : m_endpoint + n * m_recStep;
   }

   // Devuelve el override si existe, si no la fórmula
   double _GetRecLevel(bool isBuy, int n)
   {
      if(n >= 1 && n < CBM_MAX_POS && m_recLvlOverride[n] > 0.0)
         return m_recLvlOverride[n];
      return _RecLevel(isBuy, n);
   }

   ulong _FindNewestTicket(const string sym)
   {
      ulong newest = 0;
      long  magic  = m_magic;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong t = PositionGetTicket(i);
         if(t == 0) continue;
         if(PositionGetInteger(POSITION_MAGIC) != magic) continue;
         if(PositionGetString(POSITION_SYMBOL) != sym) continue;
         if(t > newest) newest = t;
      }
      return newest;
   }

   // Newest ticket no registrado aún en m_tickets[]
   ulong _FindNewestUnusedTicket(const string sym)
   {
      ulong newest = 0;
      long  magic  = m_magic;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong t = PositionGetTicket(i);
         if(t == 0) continue;
         if(PositionGetInteger(POSITION_MAGIC) != magic) continue;
         if(PositionGetString(POSITION_SYMBOL) != sym) continue;
         bool already = false;
         for(int j = 0; j < m_posCount; j++)
            if(m_tickets[j] == t) { already = true; break; }
         if(!already && t > newest) newest = t;
      }
      return newest;
   }

   //--- Anota un ticket en el libro mayor (append-only). m_tickets[] es el estado VIVO del
   //    basket y se puede sobreescribir; esto es la lista de todo lo que ESTE basket llegó a
   //    abrir, y no se pisa nunca.
   void _Remember(ulong ticket)
   {
      if(ticket == 0 || m_everCount >= CBM_MAX_POS) return;
      for(int i = 0; i < m_everCount; i++) if(m_everTickets[i] == ticket) return;
      m_everTickets[m_everCount++] = ticket;
   }

   //--- ¿Este basket abrió alguna vez ese ticket? Filtro de OnCloseRejected (v6.82) — el mismo
   //    libro mayor append-only que usa _Remember, así que un ticket sigue siendo "mío" aunque
   //    m_tickets[] ya lo haya puesto en 0 al confirmarse el cierre.
   bool _OwnsTicket(ulong ticket) const
   {
      for(int i = 0; i < m_everCount; i++) if(m_everTickets[i] == ticket) return true;
      return false;
   }

   //--- Red de seguridad de CloseAll: cierra toda posición viva de este símbolo con NUESTRO
   //    número mágico que no esté en m_tickets[]. Pasó el 2026-08-01: el fill de la entrada
   //    diferida pisó el ticket de un recovery y esa posición quedó viva, sin stop y sin dueño.
   //    Desde v6.37 el mágico es ÚNICO por símbolo+TF (issue #53), así que el barrido por mágico
   //    —el mecanismo canónico de MT5 para propiedad de posiciones— ya no puede tocar el basket
   //    de otro chart; en v6.36 el mágico era fijo (777321) y había que usar solo el libro mayor
   //    de tickets (m_everTickets, que se conserva como segunda red: cubre el caso de un ticket
   //    propio listado bajo otro símbolo por error de bookkeeping).
   //    Devuelve cuántas encontró (0 = el basket estaba bien anotado, caso normal).
   int _CloseForgotten(const string sym)
   {
      int  found = 0;
      long magic = m_magic;
      // Mágico 0 = posiciones MANUALES del usuario: JAMÁS barrer por 0 (v6.44) — si el
      // mágico no está configurado, esta red queda inhabilitada y solo actúa el libro mayor.
      if(magic == 0) return 0;
      // Barrido canónico: mágico + símbolo contra el broker (la verdad).
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong t = PositionGetTicket(i);
         if(t == 0) continue;
         if(PositionGetInteger(POSITION_MAGIC) != magic) continue;
         if(PositionGetString(POSITION_SYMBOL) != sym) continue;
         bool tracked = false;
         for(int j = 0; j < m_posCount; j++)
            if(m_tickets[j] == t) { tracked = true; break; }
         if(tracked) continue;                       // ya lo cierra el bucle principal
         found++;
         PrintFormat("[CBasketManager] HUÉRFANA: ticket %I64u (%s, magic %I64d) vivo y fuera de la lista del basket — cerrando",
                     t, sym, magic);
         m_trade.PositionClose(t);
      }
      // Segunda red: el libro mayor de todo ticket que ESTE basket llegó a abrir.
      for(int i = 0; i < m_everCount; i++)
      {
         ulong t = m_everTickets[i];
         if(t == 0) continue;
         bool tracked = false;
         for(int j = 0; j < m_posCount; j++)
            if(m_tickets[j] == t) { tracked = true; break; }
         if(tracked) continue;
         if(!PositionSelectByTicket(t)) continue;    // ya no existe → nada que hacer
         if(PositionGetInteger(POSITION_MAGIC) == magic &&
            PositionGetString(POSITION_SYMBOL) == sym) continue;   // ya la cerró el barrido de arriba
         found++;
         PrintFormat("[CBasketManager] HUÉRFANA (libro mayor): ticket %I64u se perdió de la lista del basket — cerrando", t);
         m_trade.PositionClose(t);
      }
      return found;
   }

   // Reclama posiciones que confirmaron TARDE — después de que la ventana de
   // CBM_RECOPEN_TIMEOUT_MS ya cerró y la ráfaga las dio por rechazadas (reporte PO 2026-08-04,
   // incidente GainX 800: ráfagas de 18-27 órdenes contra un bróker en su límite hacen plausible
   // que alguna confirme fuera de ventana). A diferencia de _CloseForgotten (que CIERRA lo que
   // encuentra), esto RECLAMA — lo suma a m_tickets[] para que vuelva a contar en
   // GetPnl/GetBreakeven/TP/SL, no lo da de baja.
   // Orden CRONOLÓGICO (POSITION_TIME asc, empate ticket asc) — mismo criterio que
   // AdoptOpenPositions ("la más vieja es la que sigue en la secuencia"): reclamar por
   // ticket-más-alto-primero (como ya hace la reconciliación de la ventana de 5s) puede
   // etiquetar mal qué nivel es cuál si varios tickets confirman casi juntos bajo ráfaga pesada.
   int _ClaimStragglers(const string sym)
   {
      if(m_magic == 0) return 0;   // mágico sin configurar: sin dueño claro, no reclamar nada
      ulong    candT[CBM_STRAGGLER_SCAN_CAP];
      datetime candTm[CBM_STRAGGLER_SCAN_CAP];
      int n = 0;
      for(int i = PositionsTotal() - 1; i >= 0 && n < CBM_STRAGGLER_SCAN_CAP; i--)
      {
         ulong t = PositionGetTicket(i);
         if(t == 0) continue;
         if(PositionGetInteger(POSITION_MAGIC) != m_magic) continue;
         if(PositionGetString(POSITION_SYMBOL) != sym) continue;
         bool already = false;
         for(int j = 0; j < m_posCount; j++)
            if(m_tickets[j] == t) { already = true; break; }
         if(already) continue;
         candT[n]  = t;
         candTm[n] = (datetime)PositionGetInteger(POSITION_TIME);
         n++;
      }
      if(n == 0) return 0;
      // Insertion sort cronológico — n siempre chico (huérfanas son la excepción, no la regla).
      for(int i = 1; i < n; i++)
      {
         ulong    tt = candT[i];
         datetime tm = candTm[i];
         int j = i - 1;
         while(j >= 0 && (candTm[j] > tm || (candTm[j] == tm && candT[j] > tt)))
         {
            candT[j+1]  = candT[j];
            candTm[j+1] = candTm[j];
            j--;
         }
         candT[j+1]  = tt;
         candTm[j+1] = tm;
      }
      int claimed = 0;
      for(int i = 0; i < n && m_posCount < CBM_MAX_POS; i++)
      {
         m_tickets[m_posCount++] = candT[i];
         _Remember(candT[i]);
         claimed++;
         PrintFormat("[Basket REAL] Straggler reclamado fuera de ventana: ticket %I64u (posN=%d)",
                     candT[i], m_posCount);
      }
      if(claimed > 0)
      {
         m_nextRecLvl  = _GetRecLevel(m_dirBuy, m_posCount);
         m_dynTpActive = true;
      }
      return claimed;
   }

   bool _OpenReal(const string sym, bool isBuy, double lot)
   {
      // Fix 3: detectar filling mode del símbolo en lugar de hardcodear IOC
      ENUM_ORDER_TYPE_FILLING filling = ORDER_FILLING_IOC;
      long fillingMode = SymbolInfoInteger(sym, SYMBOL_FILLING_MODE);
      if((fillingMode & SYMBOL_FILLING_IOC) == 0)
         filling = ORDER_FILLING_FOK;
      m_trade.SetTypeFilling(filling);

      // Fix 1: redondear al lotStep y normalizar con la cantidad de decimales correcta
      double minLot  = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
      double maxLot  = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
      double lotStep = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
      double lotOrig = lot;  // guardar original para log diagnóstico
      if(minLot > 0.0 && lot < minLot) lot = minLot;
      if(maxLot > 0.0 && lot > maxLot) lot = maxLot;
      if(lotStep > 0.0) lot = MathRound(lot / lotStep) * lotStep;
      int lotDecimals = 2;
      if(lotStep >= 0.1)       lotDecimals = 1;
      else if(lotStep >= 0.01) lotDecimals = 2;
      else if(lotStep > 0.0)   lotDecimals = 3;
      lot = NormalizeDouble(lot, lotDecimals);

      // Validación final: si el lote ajustado sigue siendo inválido, abortar
      if(minLot > 0.0 && lot < minLot)
      {
         PrintFormat("[CBasketManager] ABORT: lote %.2f < minLot %.2f (sym=%s)", lot, minLot, sym);
         return false;
      }
      if(maxLot > 0.0 && lot > maxLot)
      {
         PrintFormat("[CBasketManager] ABORT: lote %.2f > maxLot %.2f (sym=%s)", lot, maxLot, sym);
         return false;
      }

      string comment = StringFormat("AUX Ent #%d", ++m_orderCount);
      PrintFormat("[CBasketManager] OrderSend: %s lot=%.2f (orig=%.2f, min=%.2f, max=%.2f, step=%.4f) %s",
                  isBuy ? "BUY" : "SELL", lot, lotOrig, minLot, maxLot, lotStep, sym);
      bool ok = isBuy ? m_trade.Buy(lot, sym, 0.0, 0.0, 0.0, comment)
                      : m_trade.Sell(lot, sym, 0.0, 0.0, 0.0, comment);
      if(!ok)
      {
         m_orderCount--;  // revertir si falló
         PrintFormat("[CBasketManager] OrderSend FAILED: retcode=%d (%s) err=%d sym=%s lot=%.2f",
                     m_trade.ResultRetcode(), m_trade.ResultRetcodeDescription(), GetLastError(), sym, lot);
      }
      return ok;
   }

   void _ResetState()
   {
      m_dirBuy   = false;
      m_simCount = 0; m_simTp = 0; m_simSl = 0; m_simNextRec = 0;
      m_simHypoExit = BASKET_NONE;
      m_posCount = 0; m_tpPrice = 0; m_slPrice = 0; m_nextRecLvl = 0;
      m_basketSym = "";
      m_endpoint = 0; m_recStep = 0;
      m_virtEntryPx  = 0; m_virtEntryLot = 0; m_virtEntryUp = false; m_virtEntrySlot = -1;
      m_entryPrice = 0; m_worstPx = 0; m_dynTpActive = false;
      m_entryWasDeferred = false; m_favorablePx = 0;
      m_orderCount   = 0;
      m_digits       = 0;
      m_tickSize     = 0.0;
      m_tickVal      = 0.0;
      m_justConverted  = false;
      m_convertBarTime = 0;
      m_closePending   = false;
      m_closeRetryNextMs = 0;
      m_hitSuspended   = false;
      m_dragGrace      = 0;
      m_recOpenFailWarned   = false;
      m_recOpenNextTryMs    = 0;
      m_recOpenPendingCount   = 0;
      m_recOpenPendingSinceMs = 0;
      m_entryOpenFailWarned = false;
      m_entryOpenNextTryMs  = 0;
      m_recDiagNextMs       = 0;
      m_recDiagLastTrig     = false;
      m_recBurstFailStreak       = 0;
      m_recBurstFailBoundary     = -1;
      m_recBurstLastFailSize     = 0;
      m_recBurstIncompleteWarned = false;
      m_recOpenBlocked           = false;
      m_recOpenBlockedWarned     = false;
      m_orphanScanNextMs         = 0;
      m_everCount    = 0;
      ArrayInitialize(m_tickets, 0);
      ArrayInitialize(m_everTickets, 0);
      ArrayInitialize(m_recLvlOverride, 0.0);
   }

public:
   CBasketManager() : m_magic(0), m_isSim(true), m_tf(PERIOD_CURRENT),
                      m_virtEntryPx(0), m_virtEntryLot(0), m_virtEntryUp(false),
                      m_entryPrice(0), m_worstPx(0), m_dynTpActive(false),
                      m_justConverted(false), m_convertBarTime(0)
   {
      _ResetState();
      m_trade.SetDeviationInPoints(20);
      m_trade.SetTypeFilling(ORDER_FILLING_IOC);  // default; _OpenReal() lo sobreescribe por símbolo
   }

   void SetMode(bool isSim)              { m_isSim = isSim; }
   void SetTF(ENUM_TIMEFRAMES tf)        { m_tf = tf; }
   // Inhibe chequeo TP/SL en SIM durante drag del overlay.
   // Al soltar (v=false): activa gracia de 3 ticks para evitar disparo inmediato post-release.
   void SuspendHitChecks(bool v)
   {
      m_hitSuspended = v;
      if(!v) m_dragGrace = 3;
   }
   // El mágico se guarda ACÁ además de configurarse en CTrade (fix v6.44, reporte del PO
   // 2026-08-02: "cambié de temporalidad y volví — veo las operaciones pero no tengo overlay").
   // CTrade::RequestMagic() devuelve el mágico de la ÚLTIMA ORDEN ENVIADA, no el configurado:
   // recién arrancado el EA (sin órdenes todavía) devolvía 0 → AdoptOpenPositions no reconocía
   // NINGUNA posición como propia (re-adopción muerta) y _CloseForgotten podía barrer mágico 0
   // — que es el de las posiciones MANUALES del usuario.
   void SetMagic(int magic)              { m_magic = magic; m_trade.SetExpertMagicNumber(magic); }
   void Reset()               { _ResetState(); }

   //| Modo REPLAY (Fase 7): inyecta el tick que Update()/GetPnl() verán en vez del
   //| terminal. SOLO para BasketReplay.mq5 — no llamar desde el EA. closedPx = close
   //| de la última vela cerrada (0 = sin vela → el SL no puede confirmar por vela).
   void SetTestTick(double bid, double ask, double closedPx = 0.0)
   {
      m_testFeed     = true;
      m_testBid      = bid;
      m_testAsk      = ask;
      m_testClosedPx = closedPx;
   }

   //| SOLO para BasketReplay.mq5 — no llamar desde el EA. Simula la confirmación de una entrada
   //| diferida (2026-08-04) sin pasar por _OpenReal, que mandaría una orden real: fuerza el
   //| mismo estado que deja el fill real (m_entryWasDeferred=true, m_favorablePx=fillPx) para
   //| poder testear el ratchet de GetFavorablePx() de forma determinística.
   void SetTestDeferredFilled(double fillPx)
   {
      m_entryWasDeferred = true;
      m_favorablePx      = fillPx;
   }

   // endpoint = base del grid de recoveries
   // recStep  = distancia entre niveles (precio absoluto)
   // tpPrice  = TP virtual | slPrice = SL virtual (FRACCIÓN)
   bool Open(const string sym, bool isBuy, double lot,
             double endpoint, double recStep,
             double tpPrice, double slPrice, double entryPx = 0.0)
   {
      double px = (entryPx > 0.0) ? entryPx
                                   : (isBuy ? SymbolInfoDouble(sym, SYMBOL_ASK)
                                            : SymbolInfoDouble(sym, SYMBOL_BID));
      // Guard: precio no disponible (símbolo no listo / desconexión) → no abrir.
      // Sin esto el grid de recoveries se construiría sobre precio 0.
      if(px <= 0.0)
      {
         PrintFormat("[CBasketManager] Open abortado: precio no disponible para %s", sym);
         return false;
      }

      _ResetState();
      m_basketSym = sym;   // los niveles del basket pertenecen a ESTE símbolo (C-3)
      m_dirBuy   = isBuy;
      m_digits   = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
      // Fix 5: cachear tick size/value para GetPnl() SIM
      m_tickSize = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
      m_tickVal  = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
      m_endpoint = endpoint;
      m_recStep  = recStep;

      m_entryPrice = px;
      m_worstPx    = px;

      if(m_isSim)
      {
         m_simPos[0].openPrice = px;
         m_simPos[0].lot       = lot;
         m_simPos[0].isBuy     = isBuy;
         m_simCount   = 1;
         m_simTp      = tpPrice;
         m_simSl      = slPrice;
         m_simNextRec = _RecLevel(isBuy, 1);
         PrintFormat("[Basket SIM] %s %.2f @ %s TP=%s SL=%s step=%s",
                     isBuy ? "BUY" : "SELL", lot, _Fmt(px), _Fmt(tpPrice), _Fmt(slPrice), _Fmt(recStep));
         return true;
      }

      if(!_OpenReal(sym, isBuy, lot)) return false;
      ulong ticket = _FindNewestTicket(sym);
      if(ticket == 0) { Print("[Basket REAL] Ticket no encontrado"); return false; }
      m_tickets[0] = ticket;
      _Remember(ticket);
      m_posCount   = 1;
      m_tpPrice    = tpPrice;
      m_slPrice    = slPrice;
      m_nextRecLvl = _RecLevel(isBuy, 1);
      PrintFormat("[Basket REAL] %s %.2f @ %s TP=%s SL=%s",
                  isBuy ? "BUY" : "SELL", lot, _Fmt(px), _Fmt(tpPrice), _Fmt(slPrice));
      return true;
   }

   EBasketResult Update(const string sym, bool isBuy, int maxRec, double mul, int et = 1)
   {
      // Cierre pendiente (un CloseAll REAL falló parcialmente): reintentar hasta
      // cerrar TODO antes de evaluar cualquier otra cosa. Evita posiciones huérfanas.
      if(m_closePending)
      {
         // Freno (v6.81): no reenviar mientras el envío async previo puede seguir en vuelo —
         // ver CBM_CLOSE_RETRY_MS. Recién vencido el cooldown se reconcilia y se reintenta.
         if(GetTickCount() < m_closeRetryNextMs) return BASKET_NONE;

         // Reconciliar recoveries en vuelo ANTES de reintentar el cierre (hallazgo de code
         // review, 2026-08-04): sin esto, una orden de recovery en ráfaga async (v6.61) que
         // confirma DESPUÉS de que el resto del basket ya cerró quedaba fuera de m_tickets[]
         // — CloseAll() no la ve (no está anotada) y _CloseForgotten puede no encontrar
         // TODAVÍA nada (el broker aún no la publicó como posición) en ese mismo tick. Con
         // allClosed=true de casualidad, _ResetState() borraba m_recOpenPendingCount y la
         // posición quedaba huérfana — sin TP/SL, a merced del próximo basket que abriera en
         // ese símbolo (mágico determinístico por símbolo, ADR-041). Mismo mecanismo de
         // reconciliación que ya usa el camino normal (líneas de abajo), acá antes de cerrar.
         if(!m_isSim && m_recOpenPendingCount > 0)
         {
            ulong t = _FindNewestUnusedTicket(sym);
            while(t != 0 && m_recOpenPendingCount > 0 && m_posCount < CBM_MAX_POS)
            {
               m_tickets[m_posCount] = t;
               _Remember(t);
               m_posCount++;
               m_recOpenPendingCount--;
               PrintFormat("[Basket REAL] REC#%d confirmado durante cierre pendiente — se suma al cierre", m_posCount - 1);
               t = (m_recOpenPendingCount > 0) ? _FindNewestUnusedTicket(sym) : 0;
            }
            // Ventana agotada (mismo timeout de siempre) sin confirmar el resto: el broker ya
            // rechazó esas — dejar de esperarlas, que CloseAll() cierre lo que sí hay.
            if(m_recOpenPendingCount > 0 && GetTickCount() - m_recOpenPendingSinceMs > CBM_RECOPEN_TIMEOUT_MS)
               m_recOpenPendingCount = 0;
         }
         CloseAll(sym, "reintento de cierre pendiente");
         return BASKET_NONE;
      }

      // Navegación sym/TF con basket abierto (C-3): los niveles TP/SL/recovery pertenecen
      // a OTRO símbolo — evaluar bid/ask del nuevo dispararía cierres y recoveries espurios
      // (incluso abrir un recovery REAL en el símbolo equivocado). No operar hasta volver.
      if(m_basketSym != "" && sym != m_basketSym) return BASKET_NONE;

      double bid = m_testFeed ? m_testBid : SymbolInfoDouble(sym, SYMBOL_BID);
      double ask = m_testFeed ? m_testAsk : SymbolInfoDouble(sym, SYMBOL_ASK);
      // Precio no disponible (desconexión / símbolo no listo): no evaluar este tick.
      if(bid <= 0.0 || ask <= 0.0) return BASKET_NONE;

      // Fix 6: grace period de 1 tick tras ConvertToReal — suprimir chequeo TP/SL
      // para evitar cierre espurio mientras el broker publica la posición (async).
      if(m_justConverted)
      {
         m_justConverted = false;
         PrintFormat("[Basket REAL] Grace tick post-ConvertToReal: TP/SL check suprimido. m_posCount=%d", m_posCount);
         return BASKET_NONE;
      }

      // Fix 6b: avanzar guard de barra cerrada post-conversión.
      // Cuando la barra actual (bar[1]) es posterior a la que existía al convertir, ya es seguro evaluar SL.
      if(m_convertBarTime > 0 && iTime(sym, m_tf, 1) > m_convertBarTime)
      {
         PrintFormat("[Basket REAL] Nueva barra post-conversión confirmada — SL check desbloqueado.");
         m_convertBarTime = 0;
      }

      // Entrada diferida virtual: esperar a que el precio llegue al nivel.
      // NO retorna (issue #53): mientras la entrada espera, los recoveries heredados del SIM
      // ya están abiertos de verdad en el broker — el TP y el SL de abajo se les siguen
      // evaluando. Hasta v6.36 este bloque cortaba todo: posiciones vivas sin stop ni
      // objetivo durante toda la espera (17 s en el incidente; podía ser para siempre).
      if(!m_isSim && m_virtEntryPx > 0.0)
      {
         double mktPx  = isBuy ? ask : bid;
         bool triggered = m_virtEntryUp ? (mktPx >= m_virtEntryPx)
                                        : (mktPx <= m_virtEntryPx);
         // El estado "ESPERANDO <precio>" ya se muestra en el overlay/panel vía GetStatusText.
         // No se imprime por tick para no ensuciar el Journal (ADR-024).
         // Cooldown tras un rechazo (v6.45, mismo patrón que el recovery): un rechazo duro
         // del broker no debe reintentarse en cada tick.
         if(triggered && GetTickCount() < m_entryOpenNextTryMs) return BASKET_NONE;
         if(triggered)
         {
            PrintFormat("[Basket REAL] Entrada diferida disparada @ %s (objetivo %s)",
                        _Fmt(mktPx), _Fmt(m_virtEntryPx));
            if(_OpenReal(sym, isBuy, m_virtEntryLot))
            {
               m_entryOpenFailWarned = false;   // recuperado
               // Fix 2: usar ResultOrder() primero; solo fallback a búsqueda si falla
               ulong ticket = m_trade.ResultOrder();
               if(ticket == 0) ticket = _FindNewestUnusedTicket(sym);
               // Llenar el slot RESERVADO al armar (v6.36). Hasta v6.35 esto escribía en
               // m_tickets[m_posCount-1] asumiendo que el reservado era el último; si
               // ConvertToReal agregó recoveries después de armar, ese índice apunta a un
               // recovery y su ticket quedaba pisado → posición sin dueño (incidente 2026-08-01).
               int slot = (m_virtEntrySlot >= 0 && m_virtEntrySlot < CBM_MAX_POS)
                          ? m_virtEntrySlot : (m_posCount - 1);
               if(ticket > 0 && slot >= 0)
               {
                  m_tickets[slot] = ticket;
                  _Remember(ticket);
                  // Re-anclar grid al fill real (puede diferir del objetivo por slippage)
                  if(PositionSelectByTicket(ticket))
                  {
                     double fillPx = PositionGetDouble(POSITION_PRICE_OPEN);
                     double delta  = fillPx - m_endpoint;
                     if(MathAbs(delta) > SymbolInfoDouble(sym, SYMBOL_POINT))
                     {
                        // Re-anclar por TRASLADO (Fase 5): todo se corre por delta, incluidos
                        // los overrides y el PRÓXIMO nivel pendiente. Hasta v6.39 acá se
                        // reseteaba a _GetRecLevel(1) — con recoveries del SIM ya abiertos, el
                        // nivel 1 quedaba atrás del precio y disparaba un recovery espurio al
                        // instante. 0 = desarmado: no se traslada (0+delta armaría un nivel falso).
                        if(m_tpPrice > 0.0) m_tpPrice += delta;
                        if(m_slPrice > 0.0) m_slPrice += delta;
                        m_endpoint    = fillPx;
                        m_entryPrice  = fillPx;
                        for(int k = 1; k < CBM_MAX_POS; k++)
                           if(m_recLvlOverride[k] > 0.0) m_recLvlOverride[k] += delta;
                        if(m_nextRecLvl > 0.0) m_nextRecLvl += delta;
                     }
                     // Arranca el Fibonacci de EXTENSIÓN (reporte PO 2026-08-04): esta entrada
                     // nació diferida — el TP se mide desde acá en vez de desde la zona (ver
                     // _FiboTpExtension en EmaRiskPro.mq5). m_favorablePx arranca en el fill
                     // real, mismo punto que _TickLiveTp usará como "0%" antes de que el precio
                     // se estire.
                     m_entryWasDeferred = true;
                     m_favorablePx      = fillPx;
                  }
                  m_virtEntryPx   = 0;  // solo limpiar cuando posición confirmada con ticket válido
                  m_virtEntrySlot = -1;
               }
               else
                  PrintFormat("[Basket REAL] Entrada diferida: _OpenReal OK pero sin ticket (retcode=%d) — reintento",
                              m_trade.ResultRetcode());
            }
            else
            {
               if(!m_entryOpenFailWarned)
               {
                  m_entryOpenFailWarned = true;
                  PrintFormat("[Basket REAL] Entrada diferida RECHAZADA @ %s (retcode=%d) — reintentando cada %d s.",
                              _Fmt(mktPx), m_trade.ResultRetcode(), CBM_RETRY_COOLDOWN_MS / 1000);
               }
               m_entryOpenNextTryMs = GetTickCount() + CBM_RETRY_COOLDOWN_MS;
            }
         }
      }

      // Reconciliar una ráfaga de recoveries en vuelo (issue #75-bis): en async, Buy()/Sell()
      // devuelve "enviado" al toque, no "ejecutado" — el ticket real aparece recién cuando el
      // broker confirma, uno o varios ticks después. NO retornar mientras haya pendientes:
      // misma lección de v6.60, el TP/SL de las posiciones YA abiertas se sigue evaluando igual.
      if(!m_isSim && m_recOpenPendingCount > 0)
      {
         int posCountBefore = m_posCount;
         ulong t = _FindNewestUnusedTicket(sym);
         while(t != 0 && m_recOpenPendingCount > 0 && m_posCount < CBM_MAX_POS)
         {
            m_tickets[m_posCount] = t;
            _Remember(t);
            m_posCount++;
            m_recOpenPendingCount--;
            PrintFormat("[Basket REAL] REC#%d confirmado (ráfaga async) ticket=%I64u", m_posCount - 1, t);
            t = (m_recOpenPendingCount > 0) ? _FindNewestUnusedTicket(sym) : 0;
         }
         // Progreso real (al menos una confirmó): la racha de fallos en este punto ya no aplica
         // (reporte PO 2026-08-04, incidente GainX 800 — ver CBM_RECBURST_MAX_FAIL_STREAK).
         if(m_posCount > posCountBefore)
         {
            m_recBurstFailStreak       = 0;
            m_recBurstFailBoundary     = -1;
            m_recBurstLastFailSize     = 0;
            m_recBurstIncompleteWarned = false;
            m_recOpenBlocked           = false;
            m_recOpenBlockedWarned     = false;
         }
         if(m_recOpenPendingCount > 0 && GetTickCount() - m_recOpenPendingSinceMs > CBM_RECOPEN_TIMEOUT_MS)
         {
            // Mismo punto de la grilla que la última falla → es la MISMA causa, suma a la
            // racha. Punto distinto → hubo progreso desde entonces, racha nueva desde 1.
            if(m_recBurstFailBoundary == m_posCount - 1) m_recBurstFailStreak++;
            else                                          m_recBurstFailStreak = 1;
            m_recBurstFailBoundary = m_posCount - 1;
            m_recBurstLastFailSize = m_recOpenPendingCount;   // techo del PRÓXIMO intento acá

            // Aviso único por racha (antes: incondicional cada 30s, sin freno — mismo defecto
            // que v6.45 ya había cerrado para el otro camino de rechazo, RECOVERY BLOQUEADO).
            if(!m_recBurstIncompleteWarned)
            {
               m_recBurstIncompleteWarned = true;
               PrintFormat("[CBasketManager] RÁFAGA DE RECOVERY INCOMPLETA: %d de los disparados no confirmaron en %d s — el broker rechazó el resto (mismo motivo de siempre: límite de volumen u otro rechazo duro). Reintentando cada %d s (racha %d/%d en el nivel %d).",
                           m_recOpenPendingCount, CBM_RECOPEN_TIMEOUT_MS / 1000, CBM_RETRY_COOLDOWN_MS / 1000,
                           m_recBurstFailStreak, CBM_RECBURST_MAX_FAIL_STREAK, m_recBurstFailBoundary + 1);
            }
            m_recOpenPendingCount = 0;
            m_recOpenNextTryMs    = GetTickCount() + CBM_RETRY_COOLDOWN_MS;

            if(m_recBurstFailStreak >= CBM_RECBURST_MAX_FAIL_STREAK && !m_recOpenBlocked)
            {
               m_recOpenBlocked = true;
               if(!m_recOpenBlockedWarned)
               {
                  m_recOpenBlockedWarned = true;
                  PrintFormat("[CBasketManager] GRILLA DETENIDA: %d intentos seguidos sin confirmar ni un recovery más allá del nivel %d — dejo de reintentar esta dirección. El TP/SL de lo YA abierto se sigue vigilando igual. Revisar el límite de volumen del bróker (SYMBOL_VOLUME_LIMIT) o bajar MULT/RLC desde el panel.",
                              CBM_RECBURST_MAX_FAIL_STREAK, m_recBurstFailBoundary + 1);
               }
            }
         }
         if(m_recOpenPendingCount == 0)
         {
            // Ráfaga cerrada (confirmada entera o dada por rechazada en lo que faltó) —
            // recalcular el próximo nivel pendiente desde lo que realmente quedó vivo.
            m_nextRecLvl  = _GetRecLevel(isBuy, m_posCount);
            m_dynTpActive = true;
         }
      }

      // Reclamo de huérfanas fuera de ventana (reporte PO 2026-08-04): una posición que
      // confirma DESPUÉS de que CBM_RECOPEN_TIMEOUT_MS ya cerró la ventana de arriba quedaba
      // invisible para m_posCount hasta CERRAR (_CloseForgotten solo corría ahí) — y de
      // m_posCount dependen GetPnl/GetBreakeven/TP/SL en vivo. Cadencia baja: barre
      // PositionsTotal(), no se justifica en cada tick.
      if(!m_isSim && m_basketSym != "" && GetTickCount() >= m_orphanScanNextMs)
      {
         m_orphanScanNextMs = GetTickCount() + CBM_ORPHAN_SCAN_INTERVAL_MS;
         if(_ClaimStragglers(sym) > 0)
         {
            m_recBurstFailStreak   = 0;
            m_recBurstFailBoundary = -1;
            m_recBurstLastFailSize = 0;
            m_recOpenBlocked       = false;
         }
      }

      double tp    = m_isSim ? m_simTp      : m_tpPrice;
      double sl    = m_isSim ? m_simSl      : m_slPrice;
      double nextR = m_isSim ? m_simNextRec : m_nextRecLvl;
      int    posN  = m_isSim ? m_simCount   : m_posCount;

      // Inhibir TP/SL durante drag del overlay (m_hitSuspended) y gracia post-drag — en SIM
      // y en REAL (issue #55): hasta v6.37 la expresión era `!m_isSim || (...)`, o sea que en
      // REAL daba true SIEMPRE — el overlay llamaba SuspendHitChecks creyendo protegerse y la
      // protección no existía justo en el modo con dinero real.
      bool hitChecksOk = (!m_hitSuspended && m_dragGrace == 0);
      if(m_dragGrace > 0) m_dragGrace--;

      // ADR-043: la foto "qué habría terminado el basket AHORA si fuera REAL" se recalcula
      // por tick. Durante drag/gracia queda en NONE (no se evalúa, igual que en REAL).
      m_simHypoExit = BASKET_NONE;

      // TP virtual — tp==0 significa sin TP definido (DESARMADO).
      // SIM y REAL MIDEN con el MISMO criterio: nivel simple (decisión del PO, Fase 6,
      // 2026-08-02 — la simulación es la herramienta de medición y tiene que medir lo mismo
      // que ejecuta). Pero medir ≠ liquidar (ADR-043, reporte PO 2026-08-05,
      // docs/SimularSeCierra.mp4): SIM es PLANIFICACIÓN — el precio nunca cierra el plan,
      // solo lo registra en m_simHypoExit ("si esto fuera REAL, ya habría pagado"). Hasta
      // v6.72 este bloque también hacía CloseAll en SIM y el plan se borraba solo mientras
      // el usuario recalculaba entradas/lote. (Hasta v6.42 SIM exigía CRUCE del nivel;
      // eso hoy lo cubren las guardas del drag: empuje al soltar #54, TP perdedor
      // rechazado #55, suspensión durante drag.)
      bool tpHitOk = hitChecksOk && (isBuy ? (bid >= tp) : (ask <= tp));
      if(tp > 0.0 && tpHitOk)
      {
         if(m_isSim)
            m_simHypoExit = BASKET_TP_HIT;   // ADR-043: medir, no liquidar
         else
         {
            CloseAll(sym, StringFormat("TP hit (tp=%s bid=%s ask=%s isBuy=%s)", _Fmt(tp), _Fmt(bid), _Fmt(ask), isBuy ? "true" : "false"));
            return BASKET_TP_HIT;
         }
      }

      // Recovery trigger. Con entrada diferida pendiente NO se abren recoveries nuevos:
      // la grilla cuelga de una entrada que todavía no existe (issue #53).
      int recsDone = posN - 1;

      // ── DIAGNÓSTICO del trigger (v6.49, issue #72) ────────────────────────────
      // NO es un fix: es instrumentación. Imprime la decisión COMPLETA — incluido el caso
      // en que la grilla ni se evalúa — porque el síntoma reportado es justamente que no
      // pasa nada: sin esto no se distingue "el nivel está lejos" de "la grilla está
      // apagada" de "el nivel que el basket cree tener no es el que el usuario ve dibujado".
      // Por eso también dice si nextR viene del ARRASTRE del overlay o de la fórmula.
      //
      // Gateado con IS_DEBUG (decisión del PO 2026-08-02): resolvió el #72 en dos pasadas,
      // pero una línea por segundo mientras haya un basket abierto es demasiado ruido para
      // dejarlo prendido en producción. Para volver a usarlo: descomentar `#define IS_DEBUG`
      // en Experts/EmaRiskPro/EmaRiskPro.mq5 y recompilar el par Core→EA.
      // OJO (ADR-030): IS_DEBUG activo NO pasa los gates de release.ps1 — es para diagnóstico
      // local, nunca para un build que se publique.
#ifdef IS_DEBUG
      {
         bool _gridOn  = (m_virtEntryPx <= 0.0 && recsDone < maxRec && nextR > 0.0);
         bool _trigNow = _gridOn && (isBuy ? (bid <= nextR) : (ask >= nextR));
         bool _isOvr   = (posN >= 1 && posN < CBM_MAX_POS && m_recLvlOverride[posN] > 0.0);
         if(_trigNow != m_recDiagLastTrig || GetTickCount() >= m_recDiagNextMs)
         {
            m_recDiagLastTrig = _trigNow;
            m_recDiagNextMs   = GetTickCount() + CBM_RECDIAG_COOLDOWN_MS;
            string _why = "";
            if(!_gridOn)
               _why = (m_virtEntryPx > 0.0) ? " (entrada diferida pendiente)"
                    : (recsDone >= maxRec)  ? " (grilla AGOTADA: recsDone>=maxRec)"
                                            : " (sin próximo nivel: nextR=0)";
            PrintFormat("[CBasketManager] REC-DIAG %s %s: nextR=%s (%s) bid=%s ask=%s | posN=%d recsDone=%d maxRec=%d | grilla=%s%s | dispara=%s",
                        sym, isBuy ? "BUY" : "SELL",
                        _Fmt(nextR), _isOvr ? "ARRASTRADO" : "fórmula",
                        _Fmt(bid), _Fmt(ask),
                        posN, recsDone, maxRec,
                        _gridOn ? "activa" : "INACTIVA", _why,
                        _trigNow ? "SI" : "no");
         }
      }
#endif
      // recsDone/posN/nextR se recalculan sobre la marcha en el bloque de abajo (SIM abre la
      // ráfaga entera en el momento; REAL solo dispara — el bloque de reconciliación de arriba
      // es el que hace avanzar m_posCount tick a tick a medida que el broker confirma).
      // !m_recOpenBlocked (2026-08-04): tras CBM_RECBURST_MAX_FAIL_STREAK fallos seguidos en el
      // mismo punto, dejar de intentar esta dirección — se reactiva sola con cualquier progreso
      // (una confirmación real, o un huérfano reclamado). No afecta TP/SL, solo la apertura de
      // recoveries nuevos.
      if(m_virtEntryPx <= 0.0 && recsDone < maxRec && nextR > 0.0 && !m_recOpenBlocked
         && (m_isSim || m_recOpenPendingCount == 0))
      {
         bool recTrig = isBuy ? (bid <= nextR) : (ask >= nextR);
         if(recTrig)
         {
            double baseLot = m_isSim ? m_simPos[0].lot
                                     : (PositionSelectByTicket(m_tickets[0])
                                        ? PositionGetDouble(POSITION_VOLUME) : 0.01);
            // Normalización del BROKER también en SIM (Fase 5): min/max/step reales. Sin esto,
            // con MULT>1 el SIM componía lotes que el broker jamás ejecutaría y la ganancia
            // simulada divergía de la real. REAL re-normaliza igual en _OpenReal (idempotente).
            double nMin  = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
            double nMax  = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
            double nStep = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);

            // Ráfaga (issue #75-bis, 2026-08-03 — pedido del PO: "tiene que ser un bot de alta
            // frecuencia... si hay un overlay para que entre y no lo hace es una oportunidad
            // perdida"). Cuántos niveles pendientes YA quedaron del lado adverso del precio
            // AHORA MISMO, no solo el próximo — los niveles son un prefijo monótono (cada uno
            // más lejos que el anterior), así que basta con avanzar mientras el trigger siga
            // dando true; el primero que falla corta la ráfaga.
            int burstCount = 0;
            {
               int k = recsDone + 1;
               while(k <= maxRec && posN + burstCount < CBM_MAX_POS)
               {
                  double lvl  = _GetRecLevel(isBuy, k);
                  bool   trig = isBuy ? (bid <= lvl) : (ask >= lvl);
                  if(!trig) break;
                  burstCount++;
                  k++;
               }
            }
            if(burstCount == 0) burstCount = 1;   // recTrig ya confirmó el primero arriba
            // Tope: si el último fallo fue justo en este punto (recsDone), no pedir MÁS de lo
            // que ya falló acá — sin esto el burst recalculado crece solo (2026-08-04, incidente
            // GainX 800: 18→26→27+ en el mismo punto, nunca confirmaba nada más allá del 11).
            if(m_recBurstFailBoundary == recsDone && m_recBurstLastFailSize > 0)
               burstCount = (int)MathMin(burstCount, m_recBurstLastFailSize);

            if(m_isSim)
            {
               // SIM no tiene latencia de broker que simular — abre la ráfaga entera de una,
               // mismo criterio de trigger que REAL (Fase 6: el SIM mide lo mismo que ejecuta).
               for(int i = 0; i < burstCount; i++)
               {
                  if(posN >= CBM_MAX_POS) { CloseAll(sym, StringFormat("tope de posiciones SIM (posN=%d)", posN)); return BASKET_SL_HIT; }
                  double lot = RecoveryLotAt(baseLot, mul, et, recsDone + 1, nMin, nMax, nStep);

                  double px = isBuy ? ask : bid;
                  m_simPos[posN].openPrice = px;
                  m_simPos[posN].lot       = lot;
                  m_simPos[posN].isBuy     = isBuy;
                  m_simCount++;
                  posN = m_simCount;
                  recsDone++;
                  PrintFormat("[Basket SIM] REC#%d @ %s lot=%.2f", recsDone, _Fmt(px), lot);
               }
               m_simNextRec  = _GetRecLevel(isBuy, recsDone + 1);
               m_worstPx     = nextR;
               m_dynTpActive = true;
               return BASKET_REC_OPENED;
            }

            if(posN >= CBM_MAX_POS)
            {
               CloseAll(sym, StringFormat("tope de posiciones REAL (posN=%d)", posN));
               return BASKET_SL_HIT;
            }
            // Cooldown tras un rechazo (v6.45): sin esto, un rechazo DURO del broker (mismo
            // lot, misma condición → mismo rechazo) se reintentaba en cada tick, sin límite.
            // Confirmado en producción: 1580 intentos en 1.5 h sobre un solo símbolo. El
            // backoff no impide que la orden eventualmente entre (si el usuario baja MULT/RLC
            // a mano, o el broker libera el límite) — solo espacia los intentos.
            if(GetTickCount() >= m_recOpenNextTryMs)
            {
               // Disparo ASYNC de TODA la ráfaga de una vez (issue #75-bis) — mismo patrón que
               // CloseAll: todos los OrderSend salen en paralelo, sin esperar la confirmación
               // de cada uno. El ticket real se adopta en el bloque de reconciliación de arriba,
               // en los próximos ticks. El techo de velocidad pasa a ser el round-trip real al
               // broker (~200 ms-1 s por orden, visto en Journal) — no hay margen de código para
               // ganar más que eso; en async esas N órdenes viajan al mismo tiempo, no en fila.
               m_trade.SetAsyncMode(true);
               int fired = 0;
               for(int i = 0; i < burstCount; i++)
               {
                  double lot = RecoveryLotAt(baseLot, mul, et, recsDone + 1 + i, nMin, nMax, nStep);
                  if(_OpenReal(sym, isBuy, lot)) fired++;
               }
               m_trade.SetAsyncMode(false);

               if(fired > 0)
               {
                  m_recOpenFailWarned    = false;   // recuperado: el próximo rechazo vuelve a avisar
                  m_recOpenPendingCount   = fired;
                  m_recOpenPendingSinceMs = GetTickCount();
                  PrintFormat("[Basket REAL] Ráfaga de %d recovery(s) disparada (async, nivel %d..%d) — confirmando en los próximos ticks",
                              fired, recsDone + 1, recsDone + fired);
               }
               else
               {
                  if(!m_recOpenFailWarned)
                  {
                     m_recOpenFailWarned = true;
                     PrintFormat("[CBasketManager] RECOVERY BLOQUEADO: el broker rechazó el envío en %s (retcode=%d) — reintentando cada %d s SIN cortar el chequeo de TP/SL. Revisar límite de volumen del símbolo (SYMBOL_VOLUME_LIMIT) o bajar MULT/RLC desde el panel.",
                                 sym, m_trade.ResultRetcode(), CBM_RETRY_COOLDOWN_MS / 1000);
                  }
                  m_recOpenNextTryMs = GetTickCount() + CBM_RETRY_COOLDOWN_MS;
               }
            }
            // Ni abrió (SIM ya retornó arriba) ni disparó nada nuevo este tick (en cooldown,
            // rechazado, o ya hay una ráfaga pendiente) → NO retornar: seguir de largo hacia el
            // ratchet y el chequeo de TP/SL de abajo (misma lección de v6.60).
         }
      }

      // Ratchet del peor precio adverso (lo usa el EA cuando la grilla está agotada: "el fibo
      // acompaña" debajo del último recovery). NO calcula TP — eso es del EA (SetTPPrice).
      if(m_dynTpActive)
      {
         double adversoPx = isBuy ? bid : ask;
         bool newWorst = isBuy ? (adversoPx < m_worstPx) : (adversoPx > m_worstPx);
         if(newWorst) m_worstPx = adversoPx;
      }

      // Ratchet del MEJOR precio (espejo del de arriba, reporte PO 2026-08-04): solo corre para
      // baskets que nacieron con entrada diferida — independiente de m_dynTpActive, que recién
      // se prende después del primer ciclo de recovery y dejaría esta ventana sin medir justo
      // cuando más importa (entrada diferida recién llenada, todavía sin ningún recovery).
      if(m_entryWasDeferred)
      {
         double favPx  = isBuy ? bid : ask;
         bool   newFav = isBuy ? (favPx > m_favorablePx) : (favPx < m_favorablePx);
         if(newFav) m_favorablePx = favPx;
      }

      // SL basket — cierra solo si la ÚLTIMA vela cerrada también cruzó el SL
      // (evita que mechas intrabar disparen el SL — §10.4 estrategia)
      // En SIM (ADR-043): mismo criterio de medición, pero REGISTRA (m_simHypoExit) en vez
      // de cerrar — el plan solo lo termina el botón CERRAR. También inhibido durante
      // drag y gracia post-drag (hitChecksOk), igual que el TP.
      // A-2 (diseño, INTENCIONAL): tras SIM→REAL el SL queda bloqueado hasta que cierre una
      // barra NUEVA (m_convertBarTime). La barra en curso al convertir pudo haber cerrado bajo
      // el SL durante la fase SIM; dispararlo de inmediato sería un cierre espurio. El SL de
      // esta estrategia es por cierre de vela (no intrabar), así que el delay máx de 1 barra
      // post-conversión es coherente con la regla anti-mecha — NO es un bug.
      // sl==0 significa SIN stop (basket re-adoptado con niveles aún no re-armados, issue #53).
      // Sin este gate, en venta `ask >= 0` es siempre true y el basket cerraría al primer tick.
      bool slTouched = (sl > 0.0) && (isBuy ? (bid <= sl) : (ask >= sl));
      if(hitChecksOk && slTouched && m_convertBarTime == 0)
      {
         double closedPx   = 0.0;
         bool   haveClosed = false;
         if(m_testFeed) { closedPx = m_testClosedPx; haveClosed = (closedPx > 0.0); }
         else
         {
            double closedBar[1];
            if(CopyClose(sym, m_tf, 1, 1, closedBar) > 0) { closedPx = closedBar[0]; haveClosed = true; }
         }
         if(haveClosed)
         {
            bool closeBeyond = isBuy ? (closedPx <= sl) : (closedPx >= sl);
            if(closeBeyond)
            {
               if(m_isSim)
                  m_simHypoExit = BASKET_SL_HIT;   // ADR-043: medir, no liquidar
               else
               {
                  CloseAll(sym, StringFormat("SL hit (sl=%s closedPx=%s isBuy=%s)", _Fmt(sl), _Fmt(closedPx), isBuy ? "true" : "false"));
                  return BASKET_SL_HIT;
               }
            }
         }
      }

      return BASKET_NONE;
   }

   // reason: diagnóstico (issue #53) — qué disparó el cierre (TP/SL/maxpos/reintento/manual).
   // Nunca vacío desde un call site nuevo; los viejos ("") se identifican como pre-instrumentación.
   void CloseAll(const string sym, const string reason = "")
   {
      // El log va ANTES del early-return de SIM (ADR-043 §observabilidad): hasta v6.72 un
      // basket SIM desaparecía en silencio absoluto y la única evidencia posible era un
      // video del PO. Si un SIM vuelve a cerrarse, el Journal dice quién y por qué.
      if(reason != "")
         PrintFormat("[CBasketManager] CloseAll invocado — motivo: %s (sim=%s posCount=%d)",
                     reason, m_isSim ? "true" : "false", m_isSim ? m_simCount : m_posCount);
      if(m_isSim) { _ResetState(); return; }
      // Entrada diferida virtual: sólo limpiar (sin orden que cancelar)
      m_virtEntryPx = 0;

      // Cierre ASÍNCRONO: dispara todos los PositionClose en paralelo (no espera la respuesta
      // del broker por cada uno) → cerrar 15 posiciones es casi instantáneo en vez de ~1.5s.
      // El modo async devuelve true al ENVIAR (no al ejecutar), así que NO marcamos el ticket
      // como cerrado acá: la confirmación la hace el reintento del próximo tick comparando con
      // PositionSelectByTicket (la posición desaparece cuando el cierre se ejecuta).
      m_trade.SetAsyncMode(true);
      bool allClosed = true;
      for(int i = 0; i < m_posCount; i++)
      {
         if(m_tickets[i] <= 0) continue;                       // ya cerrado en un intento previo
         if(!PositionSelectByTicket(m_tickets[i])) { m_tickets[i] = 0; continue; } // ya no existe
         if(!m_trade.PositionClose(m_tickets[i]))
            PrintFormat("[CBasketManager] CloseAll: envío falló ticket %d err=%d — reintento próximo tick",
                        m_tickets[i], GetLastError());
         allClosed = false;   // async: enviado ≠ confirmado → siempre verificar en el reintento
      }
      // RED DE SEGURIDAD (v6.36): barrer TODA posición del símbolo con nuestro número mágico,
      // esté o no en m_tickets[]. El bucle de arriba solo cierra lo que el basket tiene anotado;
      // si la anotación se corrompe, esa posición queda viva, sin stop y sin dueño — pasó el
      // 2026-08-01 ("ERP Ent #9"). Defensa independiente del bookkeeping: el broker es la verdad.
      if(_CloseForgotten(sym) > 0) allClosed = false;   // hubo huérfanas → confirmar en el reintento

      m_trade.SetAsyncMode(false);   // restaurar modo síncrono para entradas/recoveries

      if(allClosed)   // no había nada que cerrar (todos los tickets ya 0 / inexistentes)
      {
         m_closePending = false;
         _ResetState();
      }
      else
      {
         m_closePending     = true;   // Update() reintenta hasta confirmar el cierre de todo
         m_closeRetryNextMs = GetTickCount() + CBM_CLOSE_RETRY_MS;
         Print("[CBasketManager] CloseAll: cierres enviados (async) — confirmando en próximos ticks");
      }
   }

   // Recibe el resultado async de un PositionClose desde OnTradeTransaction (EmaRiskPro.mq5,
   // v6.82). Antes de esto, un cierre rechazado por un motivo REAL (no un duplicado tardío del
   // propio freno de reintento) era invisible: Update() solo veía que el ticket seguía vivo y
   // reintentaba a ciegas, sin loguear jamás el retcode. TRADE_RETCODE_POSITION_CLOSED (10036)
   // es el único rechazo "benigno" confirmado en producción (2026-08-06): el broker ya había
   // cerrado ese ticket con un envío anterior. Cualquier otro retcode es una señal real.
   void OnCloseRejected(ulong ticket, uint retcode, const string &comment)
   {
      if(!_OwnsTicket(ticket)) return;
      if(retcode == TRADE_RETCODE_POSITION_CLOSED) return;
      PrintFormat("[CBasketManager] Cierre RECHAZADO ticket %d retcode=%u (%s) — revisar manualmente",
                  ticket, retcode, comment);
   }

   double GetPnl(const string sym)
   {
      // Símbolo distinto al del basket (navegación, C-3): bid/ask y tickVal cacheado
      // no corresponden → el PnL sería basura. 0 hasta volver al símbolo del basket.
      if(m_basketSym != "" && sym != m_basketSym) return 0.0;
      double pnl = 0.0;
      if(m_isSim)
      {
         double bid = m_testFeed ? m_testBid : SymbolInfoDouble(sym, SYMBOL_BID);
         double ask = m_testFeed ? m_testAsk : SymbolInfoDouble(sym, SYMBOL_ASK);
         // Fix 5: usar valores cacheados en lugar de SymbolInfoDouble() por tick
         double ts  = m_tickSize;
         double tv  = m_tickVal;
         if(ts <= 0.0) return 0.0;
         double cf = tv / ts;
         for(int i = 0; i < m_simCount; i++)
         {
            double px   = m_simPos[i].isBuy ? bid : ask;
            double diff = m_simPos[i].isBuy ? (px - m_simPos[i].openPrice)
                                            : (m_simPos[i].openPrice - px);
            pnl += diff * m_simPos[i].lot * cf;
         }
      }
      else
      {
         // Entrada diferida armada pero aún sin fill (m_virtEntryPx>0): el slot reservado
         // legítimamente no tiene ticket todavía — no es un cierre externo, es la espera normal.
         if(m_virtEntryPx > 0.0) return pnl;

         // Fix 4: detectar posiciones cerradas externamente
         int activePosCount = 0;
         for(int i = 0; i < m_posCount; i++)
         {
            if(m_tickets[i] > 0 && PositionSelectByTicket(m_tickets[i]))
            {
               pnl += PositionGetDouble(POSITION_PROFIT);
               activePosCount++;
            }
         }
         if(activePosCount < m_posCount)
            PrintFormat("[Basket REAL] Advertencia: %d posiciones esperadas, %d activas (cerradas externamente?)",
                        m_posCount, activePosCount);
      }
      return pnl;
   }

   string GetStatusText(const string sym, bool isBuy)
   {
      double tp   = m_isSim ? m_simTp    : m_tpPrice;
      double sl   = m_isSim ? m_simSl    : m_slPrice;
      int    recs = (m_isSim ? m_simCount : m_posCount) - 1;
      double pnl  = GetPnl(sym);
      string pend = (m_virtEntryPx > 0.0)
                    ? StringFormat(" | ESPERANDO %s", _Fmt(m_virtEntryPx)) : "";
      // 2026-08-04: grilla topeada tras varios rechazos seguidos en el mismo punto — visible acá
      // sin agregar UI nueva (mismo criterio que el sufijo ESPERANDO de arriba).
      if(m_recOpenBlocked) pend += " | GRILLA DETENIDA (bróker)";
      string tpStr = (tp > 0.0) ? _Fmt(tp) : "---";
      return StringFormat("%s | P&L $%.2f | REC %d | TP %s | SL %s%s",
                          m_isSim ? "SIM" : "REAL", pnl, recs, tpStr, _Fmt(sl), pend);
   }

   // Convierte el basket SIM activo a REAL (ADR-008: sin órdenes al broker).
   // entryOverride: precio del overlay (puede estar desacoplado).
   //   - Si difiere del mercado → entrada diferida VIRTUAL: Update() la disparará
   //     con una market order cuando el precio llegue.
   //   - Si está en mercado → market order inmediata.
   // Recoveries ya disparados en SIM → siempre market (precio ya pasó).
   bool ConvertToReal(const string sym, bool isBuy, double entryOverride = 0.0)
   {
      if(!m_isSim || m_simCount == 0) return false;
      // Símbolo distinto al del basket (navegación, C-3): convertir abriría órdenes REALES
      // en el símbolo equivocado con niveles del otro. Bloquear hasta volver.
      if(m_basketSym != "" && sym != m_basketSym) return false;

      m_tpPrice    = m_simTp;
      m_slPrice    = m_simSl;
      m_nextRecLvl = m_simNextRec;
      m_isSim      = false;

      int    opened       = 0;   // total resueltas (a mercado O diferidas armadas) — gatea el revert a SIM
      int    marketOpened = 0;   // de las anteriores, las que SÍ salieron a mercado ahora
      int    deferredArmed = 0;  // de las anteriores, las que quedaron ARMADAS esperando precio

      for(int i = 0; i < m_simCount; i++)
      {
         double lot = m_simPos[i].lot;

         // Si la ENTRADA (i==0) no llenó, NO abrir recoveries: m_tickets[0] DEBE ser la entrada,
         // o el baseLot/grid saldría inflado (un recovery con lote×MULT usado como base). Abortar
         // → opened==0 revierte a SIM intacto. (Fix correctitud: fill parcial de la entrada.)
         if(i > 0 && m_posCount == 0) break;

         // NUEVA LÓGICA (solo para la entrada i==0): entrada diferida si se arrastra ENTRY
         if(i == 0 && entryOverride > 0.0)
         {
            // Respeta el feed inyectado por BasketReplay (mismo patrón que Update()/GetPnl(),
            // líneas 471-472/892-893) — sin esto, testear la dirección del trigger diferido
            // dependía del precio REAL del terminal en el momento de correr el script.
            double mktPx = m_testFeed ? (isBuy ? m_testAsk : m_testBid)
                                      : (isBuy ? SymbolInfoDouble(sym, SYMBOL_ASK)
                                               : SymbolInfoDouble(sym, SYMBOL_BID));

            // Si el overlay entry es diferente del precio actual → crear entrada diferida
            if(MathAbs(entryOverride - mktPx) > SymbolInfoDouble(sym, SYMBOL_POINT))
            {
               // Usar infraestructura de entrada diferida existente
               m_virtEntryPx   = entryOverride;
               m_virtEntryLot  = lot;
               // Dirección del trigger: de dónde quedó la línea respecto del precio, NO de si
               // es compra o venta (bug reportado 2026-08-04). Con `isBuy` acá, un BUY con la
               // entrada abajo del mercado (el pullback más común) esperaba que el precio SUBA
               // a un nivel que ya tenía debajo — la condición nacía cumplida y disparaba a
               // mercado en el primer tick, sin esperar nada. Espejo del criterio que ya usa
               // UpdateVirtualEntry() (`m_entry > mktPx`, drag en REAL) — antes se contradecían.
               m_virtEntryUp   = (entryOverride > mktPx);
               m_virtEntrySlot = m_posCount;  // ESTE slot queda reservado para la entrada (v6.36)
               m_posCount++;             // Contar como "ejecutada" (no revertir a SIM)
               opened++;
               deferredArmed++;

               PrintFormat("[Basket REAL] Entrada diferida armada: %s a %s (mercado: %s)",
                           isBuy ? "BUY" : "SELL", _Fmt(entryOverride), _Fmt(mktPx));
               continue;  // Saltar _OpenReal() para esta iteración
            }
         }

         // Entrada al mercado inmediata: la posición real se abre al precio actual.
         // (El usuario eligió "entrar ya" en vez de diferir al entry original del SIM.)
         // C-3 (diseño): solo el fill de la ENTRADA (i==0) re-ancla el grid. Los recoveries
         // i>0 que ya se dispararon en SIM se abren a mercado; su trigger es histórico (no
         // re-disparan). Los recoveries FUTUROS cuelgan de _GetRecLevel desde el endpoint
         // re-anclado a la entrada → correctos. El TP dinámico se preserva (m_dynTpActive
         // y m_tpPrice=m_simTp ya reflejan los ajustes de la fase SIM).
         if(_OpenReal(sym, isBuy, lot))
         {
            // Fix 2: usar ResultOrder() primero; solo fallback a búsqueda si falla
            ulong ticket = m_trade.ResultOrder();
            if(ticket == 0) ticket = _FindNewestUnusedTicket(sym);
            if(ticket > 0 && m_posCount < CBM_MAX_POS)
            {
               m_tickets[m_posCount++] = ticket;
               _Remember(ticket);
               opened++;
               marketOpened++;

               // Re-anclar grid al precio de fill real (puede diferir del SIM entry por spread/tiempo)
               if(i == 0 && PositionSelectByTicket(ticket))
               {
                  double fillPx = PositionGetDouble(POSITION_PRICE_OPEN);
                  double delta  = fillPx - m_endpoint;
                  if(MathAbs(delta) > SymbolInfoDouble(sym, SYMBOL_POINT))
                  {
                     double oldEp  = m_endpoint;
                     m_endpoint   += delta;
                     if(m_tpPrice > 0.0) m_tpPrice += delta;  // preservar 0 (desarmado — _TickLiveTp lo arma)
                     if(m_slPrice > 0.0) m_slPrice += delta;
                     // Trasladar el próximo nivel pendiente, NO resetearlo a nivel 1 (Fase 5):
                     // con recoveries del SIM ya abiertos, el nivel 1 queda atrás del precio y
                     // dispararía un recovery espurio en el primer tick post-conversión.
                     if(m_nextRecLvl > 0.0) m_nextRecLvl += delta;
                     m_entryPrice  = fillPx;
                     m_worstPx     = fillPx;
                     for(int k = 1; k < CBM_MAX_POS; k++)
                     if(m_recLvlOverride[k] > 0.0) m_recLvlOverride[k] += delta;
                  PrintFormat("[Basket REAL] Grid re-anclado: SIM %s → fill %s (Δ%s)  TP=%s  SL=%s",
                                 _Fmt(oldEp), _Fmt(fillPx), _Fmt(delta), _Fmt(m_tpPrice), _Fmt(m_slPrice));
                  }
               }
            }
         }
      }

      // M1: si NADA se concretó (ningún fill ni entrada diferida armada), NO destruir el
      // estado SIM. Revertir a SIM intacto — el EA revierte el toggle del panel y avisa.
      // (m_simTp/Sl/NextRec siguen intactos; el endpoint solo se tocó en paths con opened>0.)
      if(opened == 0)
      {
         m_isSim       = true;
         m_virtEntryPx = 0;
         Print("[Basket] ConvertToReal: 0 ejecuciones — basket permanece en SIM");
         return false;
      }

      m_simCount   = 0;
      m_simTp      = 0;
      m_simSl      = 0;
      m_simNextRec = 0;

      // Fix 6: activar grace period y guard de barra cerrada post-conversión.
      // m_justConverted salta 1 tick (broker async).
      // m_convertBarTime bloquea el SL "closed bar" check hasta que cierre una barra nueva.
      m_justConverted  = true;
      m_convertBarTime = iTime(sym, m_tf, 1);

      // Log honesto (bug reportado 2026-08-04): antes decía "N ejecutadas a mercado" contando
      // también las diferidas armadas, que NO salieron a mercado — quedan esperando a que el
      // precio llegue a la línea. Es la única traza de qué pasó de verdad en la conversión.
      if(deferredArmed > 0)
         PrintFormat("[Basket REAL] SIM→REAL: %d a mercado + %d en espera (entrada diferida)  TP=%s  SL=%s",
                     marketOpened, deferredArmed, _Fmt(m_tpPrice), _Fmt(m_slPrice));
      else
         PrintFormat("[Basket REAL] SIM→REAL: %d ejecutadas a mercado  TP=%s  SL=%s",
                     marketOpened, _Fmt(m_tpPrice), _Fmt(m_slPrice));
      return true;
   }

   int    GetPositionCount()    { return m_isSim ? m_simCount : m_posCount; }
   bool   IsOpen()              { return GetPositionCount() > 0 || m_virtEntryPx > 0.0; }
   bool   HasVirtualEntry()     { return m_virtEntryPx > 0.0; }
   bool   IsSim()               { return m_isSim; }
   double GetTPPrice()          { return m_isSim ? m_simTp  : m_tpPrice;  }
   double GetSLPrice()          { return m_isSim ? m_simSl  : m_slPrice;  }
   // ADR-043: qué habría terminado el basket en el tick actual si fuera REAL
   // (BASKET_NONE/TP_HIT/SL_HIT). Solo significativo en SIM — en REAL un hit cierra de
   // verdad y esto queda en NONE. Lo consume BasketReplay; habilita la futura señal
   // visual "el precio ya superó tu TP, el plan sigue abierto" sin tocar el motor.
   EBasketResult GetSimHypoExit() const { return m_simHypoExit; }
   double GetVirtEntryPx()      { return m_virtEntryPx; }
   // m_entryPrice se cachea en Open() (SIM y REAL) y se actualiza al fill real / recovery.
   // Sin PositionSelectByTicket → sin side-effect sobre la posición seleccionada del terminal (M-2).
   double GetEntryPrice()       { return m_entryPrice; }

   //+----------------------------------------------------------------+
   //| GetBreakeven — precio promedio ponderado por lote de TODO lo    |
   //| vivo (entrada + recoveries ejecutados). Es el nivel real de     |
   //| "ni gano ni pierdo" del basket — distinto de GetEntryPrice(),   |
   //| que es SOLO el primer fill y nunca se mueve al abrir recoveries |
   //| (issue #74-bis, 2026-08-03).                                    |
   //|                                                                 |
   //| Por qué importa: con MULT>1 cada recovery pesa más que el       |
   //| anterior, así que el breakeven real se aleja del entry naked a  |
   //| medida que la grilla se llena — un TP ya en zona de ganancia    |
   //| real puede seguir del "lado perdedor" del entry original.       |
   //+----------------------------------------------------------------+
   double GetBreakeven()
   {
      int n = m_isSim ? m_simCount : m_posCount;
      if(n <= 0) return m_entryPrice;

      double sumPxLot = 0.0, sumLot = 0.0;
      for(int i = 0; i < n; i++)
      {
         double px, lot;
         if(m_isSim)
         {
            px  = m_simPos[i].openPrice;
            lot = m_simPos[i].lot;
         }
         else
         {
            if(m_tickets[i] == 0 || !PositionSelectByTicket(m_tickets[i])) continue;
            px  = PositionGetDouble(POSITION_PRICE_OPEN);
            lot = PositionGetDouble(POSITION_VOLUME);
         }
         sumPxLot += px * lot;
         sumLot   += lot;
      }
      return (sumLot > 0.0) ? sumPxLot / sumLot : m_entryPrice;
   }

   // Símbolo dueño del basket. "" = sin basket. Lo usa el EA para saber si el basket que
   // sobrevivió a un cambio de TF es de ESTE chart o del anterior (#53).
   string GetSymbol() const     { return m_basketSym; }

   // Posiciones vivas del basket (entrada + recoveries).
   int    GetPosCount() const   { return m_isSim ? m_simCount : m_posCount; }

   // Nivel del recovery n (1-based) tal como lo dejó el usuario al arrastrarlo.
   // 0 = ese nivel sigue en la fórmula. Lo lee el overlay al reengancharse (#53).
   double GetRecOverride(int n) const
   {
      return (n >= 1 && n < CBM_MAX_POS) ? m_recLvlOverride[n] : 0.0;
   }

   // Precio real de apertura de la posición idx (0 = entrada, 1..N = recoveries).
   // 0 = esa posición no existe o ya no está viva. Lo usa el overlay para dibujar los
   // recoveries YA EJECUTADOS donde de verdad entraron, no donde diga la fórmula (#53).
   double GetPosPrice(int idx)
   {
      if(idx < 0 || idx >= CBM_MAX_POS) return 0.0;
      if(m_isSim)
         return (idx < m_simCount) ? m_simPos[idx].openPrice : 0.0;
      if(idx >= m_posCount || m_tickets[idx] == 0) return 0.0;
      return PositionSelectByTicket(m_tickets[idx]) ? PositionGetDouble(POSITION_PRICE_OPEN) : 0.0;
   }
   // Lote real de la posición idx (0=entrada, 1..N=recoveries) tal como se ejecutó/abrió —
   // no lo que RecoveryLotAt() daría con el LOT/MULT vigentes AHORA. Espejo exacto de
   // GetPosPrice() (mismo idx, misma rama SIM/REAL). 0.0 = esa posición no existe o ya no
   // está viva. Lo usa el overlay para no re-tasar en dólares (DD/TP Target) una posición
   // ya ejecutada a otro tamaño (reporte PO 2026-08-06: "no me dan los números, el Target" —
   // bajar MULT con recoveries ya llenos recalculaba su ganancia proyectada como si pesaran
   // el MULT nuevo, no el real).
   double GetPosLot(int idx)
   {
      if(idx < 0 || idx >= CBM_MAX_POS) return 0.0;
      if(m_isSim)
         return (idx < m_simCount) ? m_simPos[idx].lot : 0.0;
      if(idx >= m_posCount || m_tickets[idx] == 0) return 0.0;
      return PositionSelectByTicket(m_tickets[idx]) ? PositionGetDouble(POSITION_VOLUME) : 0.0;
   }
   double GetRecStep()          { return m_recStep;   }
   double GetEndpoint()         { return m_endpoint;  }
   // Diagnóstico/test (BasketReplay, 2026-08-04): dirección armada del trigger de la entrada
   // diferida — permite verificar la corrección del bug de dirección (issue reportado
   // 2026-08-04: disparaba a mercado al instante) SIN pasar por Update()/_OpenReal, que
   // enviaría una orden real al primer tick si la dirección estuviera mal.
   bool   GetVirtualEntryUp()   { return m_virtEntryUp; }
   // Peor precio adverso (ratchet). Desde v6.35 el EA ya NO lo usa para el 0% del TP (ese ancla
   // es el extremo vivo de la zona, ADR-032 enmendado); queda como estado del basket / diagnóstico.
   double GetWorstPx()          { return m_worstPx;   }
   // Fibonacci de extensión para entrada diferida (2026-08-04) — ver EmaRiskPro.mq5::_TickLiveTp.
   bool   WasEntryDeferred()    { return m_entryWasDeferred; }
   double GetFavorablePx()      { return m_favorablePx; }
   // Recoveries ya abiertos (0 = solo entry). Clamp ≥0: IsOpen() puede ser true con solo
   // virtEntry (posCount=0) → evita devolver -1.
   int    GetActivatedRecCount(){ return MathMax(GetPositionCount() - 1, 0); }
   // Nivel de la orden ACTIVA más profunda (entry si no hay recovery). 0% del TP fibo compartido.
   double GetLastActivatedLevel()
   {
      if(m_isSim) return (m_simCount > 0) ? m_simPos[m_simCount - 1].openPrice : m_entryPrice;
      if(m_posCount > 0 && PositionSelectByTicket(m_tickets[m_posCount - 1]))
         return PositionGetDouble(POSITION_PRICE_OPEN);
      return m_entryPrice;
   }

   // Actualiza TP/SL en caliente — overlay es la fuente de verdad visual.
   // Guarda CENTRAL del TP (issue #55, lección ADR-032: la guarda va después de TODAS las
   // ramas): un TP del lado perdedor SE RECHAZA acá, venga de donde venga — drag, recálculo
   // o tick. El chequeo de pago lo leería como "ya llegamos" y cerraría el basket entero en
   // pérdida (incidente 2026-08-01). tp=0 (desarmar) siempre se acepta.
   //
   // La referencia es GetBreakeven(), NO GetEntryPrice() (issue #74-bis, 2026-08-03): el
   // entry naked es el primer fill y nunca se mueve al abrir recoveries, así que con MULT>1
   // rechazaba TPs que ya estaban en zona de ganancia real — el basket podía tener varios
   // recoveries ejecutados y seguir "en pérdida" según esta guarda aunque el usuario ya
   // estuviera en positivo.
   void SetTPPrice(double tp)
   {
      if(tp > 0.0 && m_entryPrice > 0.0 && GetPositionCount() > 0)
      {
         double be     = GetBreakeven();
         bool   losing = m_dirBuy ? (tp <= be) : (tp >= be);
         if(losing)
         {
            PrintFormat("[CBasketManager] TP %s RECHAZADO: lado perdedor del breakeven %s (entrada %s) — se conserva el vigente",
                        _Fmt(tp), _Fmt(be), _Fmt(m_entryPrice));
            return;
         }
      }
      if(m_isSim) m_simTp = tp; else m_tpPrice = tp;
   }
   // Guarda CENTRAL del SL (issue #74-ter, 2026-08-03): un SL que el precio YA cruzó se
   // RECHAZA acá, venga de donde venga — reenganche (_AdoptBasket), recálculo por tick
   // (_TickLiveSl) o drag del overlay. El chequeo de SL-hit lo leería como "ya llegó" y
   // cerraría el basket entero en el primer tick (Journal 2026-08-03, FlipX 4 M6: 112
   // ventas cerradas 1 seg después de reenganchar — el SL se recalculó y armó sin chequear
   // que la última vela cerrada ya lo había cruzado). Espejo de la guarda de SetTPPrice,
   // misma lección del incidente 2026-08-01 (§8): la guarda va en el setter, no en cada
   // caller. sl=0 (desarmar) siempre se acepta.
   void SetSLPrice(double sl)
   {
      if(sl > 0.0 && m_basketSym != "" && GetPositionCount() > 0)
      {
         double bid = m_testFeed ? m_testBid : SymbolInfoDouble(m_basketSym, SYMBOL_BID);
         double ask = m_testFeed ? m_testAsk : SymbolInfoDouble(m_basketSym, SYMBOL_ASK);
         bool   alreadyHit = m_dirBuy ? (bid <= sl) : (ask >= sl);
         if(alreadyHit)
         {
            PrintFormat("[CBasketManager] SL %s RECHAZADO: ya cruzado por el precio actual (bid=%s ask=%s) — se conserva el vigente (%s)",
                        _Fmt(sl), _Fmt(bid), _Fmt(ask), _Fmt(m_isSim ? m_simSl : m_slPrice));
            return;
         }
      }
      if(m_isSim) m_simSl = sl; else m_slPrice = sl;
   }

   // Actualiza el precio y la dirección del trigger de entrada diferida.
   // Llamar al terminar el drag de la línea ENTRY en modo REAL (solo cuando virtEntryPx > 0).
   void UpdateVirtualEntry(double newPx, bool newVirtUp)
   {
      if(m_isSim || m_virtEntryPx <= 0.0) return;
      m_virtEntryPx = newPx;
      m_virtEntryUp = newVirtUp;
      PrintFormat("[Basket REAL] Virtual entry movida → %s (%s)", _Fmt(newPx), newVirtUp ? "sube" : "baja");
   }

   // Re-ancla la entrada SIMULADA al precio donde el usuario soltó la línea ENTRY (reporte
   // 2026-08-04): antes m_simPos[0]/m_endpoint quedaban clavados en el precio del INICIAR y
   // el drag solo movía la línea del overlay — la simulación medía riesgo/DD desde un punto
   // que el usuario ya había abandonado. Peor: si ese SIM se pasaba a REAL con la entrada
   // diferida (ConvertToReal), el re-anclaje post-fill calculaba su delta contra este mismo
   // m_endpoint desactualizado — corrompiendo TP, SL y cada nivel de recovery por el tamaño
   // del arrastre, no solo por el slippage real (incidente reportado: 115 pts de corrimiento
   // en vez de 25 pts de slippage genuino).
   // NO toca TP/SL/recoveries: esos ya se re-anclan aparte (TP/SL son líneas independientes
   // con su propio drag; los niveles de recovery no ejecutados ya se empujan como overrides
   // absolutos en el mismo _CommitDrag del overlay vía SetRecoveryLevel).
   void SetSimEntryPrice(double newEntry)
   {
      if(!m_isSim || m_simCount == 0 || newEntry <= 0.0) return;
      if(m_simPos[0].openPrice == newEntry) return;
      double oldEntry = m_simPos[0].openPrice;
      m_simPos[0].openPrice = newEntry;
      m_endpoint             = newEntry;
      m_entryPrice           = newEntry;
      m_worstPx              = newEntry;
      PrintFormat("[Basket SIM] Entrada re-anclada por arrastre: %s → %s", _Fmt(oldEntry), _Fmt(newEntry));
   }

   // Re-ancla el precio de un recovery SIMULADO YA LLENADO (idx 1-based: 1=REC#1, 2=REC#2...,
   // igual convención que SetRecoveryLevel/m_simPos) al punto donde el usuario lo arrastró
   // (reporte 2026-08-04). Distinto de SetRecoveryLevel: ese solo escribe el override de un
   // nivel FUTURO (usado para calcular el próximo trigger) — no toca m_simPos[], así que
   // arrastrar una pata YA abierta y empujarla por ahí movía la línea pero GetPnl/GetBreakeven
   // seguían leyendo el precio original de m_simPos[idx].openPrice. Esto corrige eso.
   void SetSimLegPrice(int idx, double newPx)
   {
      if(!m_isSim || idx <= 0 || idx >= m_simCount || newPx <= 0.0) return;
      if(m_simPos[idx].openPrice == newPx) return;
      double oldPx = m_simPos[idx].openPrice;
      m_simPos[idx].openPrice = newPx;
      PrintFormat("[Basket SIM] REC#%d re-anclado por arrastre: %s → %s", idx, _Fmt(oldPx), _Fmt(newPx));
   }

   // Sincroniza trigger de recovery N desde drag del usuario en overlay.
   // Si n es el próximo recovery pendiente, actualiza nextRecLvl inmediatamente.
   void SetRecoveryLevel(int n, double px)
   {
      if(n < 1 || n >= CBM_MAX_POS) return;
      m_recLvlOverride[n] = px;
      int posN = m_isSim ? m_simCount : m_posCount;
      if(n == posN)  // n = siguiente recovery pendiente
      {
         if(m_isSim) m_simNextRec = px;
         else        m_nextRecLvl = px;
      }
   }

   // Lote de la PRIMERA posición viva (base de la grilla). 0 si no hay posiciones.
   double GetBaseLot()
   {
      if(m_isSim) return (m_simCount > 0) ? m_simPos[0].lot : 0.0;
      if(m_posCount > 0 && m_tickets[0] > 0 && PositionSelectByTicket(m_tickets[0]))
         return PositionGetDouble(POSITION_VOLUME);
      return 0.0;
   }

   //+----------------------------------------------------------------+
   //| AdoptOpenPositions — re-adopción del basket (issue #53).        |
   //|                                                                |
   //| Reconstruye el estado REAL desde las posiciones VIVAS del      |
   //| broker con NUESTRO número mágico (único por símbolo+TF desde   |
   //| v6.37): tras navegar, recompilar o reiniciar MT5 el basket     |
   //| vuelve a estar bajo control — CERRAR las cierra, el TP/SL se   |
   //| re-evalúa. Devuelve cuántas adoptó (0 = no había nada).        |
   //|                                                                |
   //| TP y SL quedan DESARMADOS (0): el EA los re-arma desde la      |
   //| estructura viva (_TickLiveTp/_TickLiveSl). Inventar un nivel   |
   //| acá podría cerrar el basket en pérdida en el primer tick —     |
   //| exactamente el incidente del 2026-08-01. Por lo mismo la       |
   //| grilla queda sin próximo nivel (m_nextRecLvl=0): no se abre    |
   //| ningún recovery nuevo hasta que el usuario o el flujo normal   |
   //| (drag / edición de RLC / SL vivo) re-armen los niveles.        |
   //|                                                                |
   //| El sucesor del Restore() borrado en v5.89: aquel recibía los   |
   //| tickets por parámetro (no descubría nada); éste descubre.      |
   //+----------------------------------------------------------------+
   int AdoptOpenPositions(const string sym, bool &isBuy)
   {
      // Diagnóstico permanente (issue #53, reabierto 2026-08-02): un TF-flip rápido dejó un
      // basket REAL "abierto" sin que este método imprimiera RE-ADOPTADO — hay que ver, la
      // próxima vez que pase, en qué estado entra la función (un print por llamada, no por tick).
      if(IsOpen())
      {
         PrintFormat("[CBasketManager] AdoptOpenPositions(%s): ya estaba abierto (posCount=%d simCount=%d isSim=%s virtEntry=%s magic=%I64d) — no se re-adopta",
                     sym, m_posCount, m_simCount, m_isSim ? "true" : "false", _Fmt(m_virtEntryPx), m_magic);
         return 0;
      }
      long magic = m_magic;
      if(magic == 0) return 0;   // sin mágico configurado no hay identidad que adoptar (v6.44)

      // Recolectar tickets nuestros de este símbolo, con su hora de apertura
      ulong    tks[];
      datetime tms[];
      int n = 0;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong t = PositionGetTicket(i);
         if(t == 0) continue;
         if(PositionGetInteger(POSITION_MAGIC) != magic) continue;
         if(PositionGetString(POSITION_SYMBOL) != sym) continue;
         ArrayResize(tks, n + 1);
         ArrayResize(tms, n + 1);
         tks[n] = t;
         tms[n] = (datetime)PositionGetInteger(POSITION_TIME);
         n++;
      }
      if(n == 0)
      {
         PrintFormat("[CBasketManager] AdoptOpenPositions(%s): 0 posiciones con magic=%I64d — nada que adoptar", sym, magic);
         return 0;
      }

      // Orden cronológico de apertura: la más VIEJA es la entrada — ancla del grid,
      // referencia de _TpArmable y base del lote. Empate de hora → menor ticket.
      for(int a = 0; a < n - 1; a++)
         for(int b = a + 1; b < n; b++)
            if(tms[b] < tms[a] || (tms[b] == tms[a] && tks[b] < tks[a]))
            {
               ulong    tt = tks[a]; tks[a] = tks[b]; tks[b] = tt;
               datetime dt = tms[a]; tms[a] = tms[b]; tms[b] = dt;
            }

      _ResetState();
      m_isSim     = false;
      m_basketSym = sym;
      m_digits    = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
      m_tickSize  = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
      m_tickVal   = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);

      int adopted = 0;
      for(int i = 0; i < n && i < CBM_MAX_POS; i++)
      {
         if(!PositionSelectByTicket(tks[i])) continue;   // se cerró entre el listado y acá
         double op = PositionGetDouble(POSITION_PRICE_OPEN);
         if(adopted == 0)
         {
            isBuy        = ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
            m_dirBuy     = isBuy;
            m_entryPrice = op;
            m_endpoint   = op;
            m_worstPx    = op;
         }
         else
            m_worstPx = isBuy ? MathMin(m_worstPx, op) : MathMax(m_worstPx, op);
         m_tickets[adopted] = tks[i];
         _Remember(tks[i]);
         adopted++;
      }
      if(adopted == 0) { _ResetState(); return 0; }

      m_posCount    = adopted;
      m_orderCount  = adopted;          // los comments "ERP Ent #N" continúan la numeración
      m_dynTpActive = (adopted > 1);
      PrintFormat("[CBasketManager] RE-ADOPTADO: %d posiciones vivas de %s (magic %I64d, entrada %s) — TP/SL desarmados hasta re-armarse desde la estructura",
                  adopted, sym, magic, _Fmt(m_entryPrice));
      return adopted;
   }
};

#endif // AURAX_BASKETMANAGER_MQH
