//+------------------------------------------------------------------+
//| CRecoveryMath.mqh — fórmula ÚNICA del lote de un nivel de         |
//| recovery, y la profundidad máxima que el bróker deja alcanzar.    |
//|                                                                  |
//| FUENTE ÚNICA DE VERDAD: hasta 2026-08-04 la fórmula del lote      |
//| (baseLot × mul^floor(k/et), normalizada a min/max/step del        |
//| símbolo) vivía duplicada en CBasketManager::Update() (dos veces — |
//| ráfaga SIM y ráfaga REAL) y en CBasketOverlay::_ComputeLevels().  |
//| Tres copias que solo podían divergir. Esto las une en una.        |
//|                                                                  |
//| Reporte del PO 2026-08-04 (incidente GainX 800, ver CHANGELOG     |
//| v6.63): con LOT/MULT/RLC/ET que exigen más volumen agregado del   |
//| que el bróker permite (SYMBOL_VOLUME_LIMIT), la grilla nunca      |
//| completaba y el reintento crecía sin freno. MaxReachableLevel()   |
//| es el cálculo que evita armar una grilla que el bróker no puede   |
//| sostener — corrido ANTES de INICIAR, no reaccionando después.     |
//|                                                                  |
//| Matiz 2026-08-06 (reporte PO: "no me dan los números, el         |
//| Target"): esta fórmula asume LOT/MULT constantes durante toda la |
//| vida del basket — pero nada lo impide en el panel. Si el usuario |
//| los cambia con recoveries YA ejecutados, RecoveryLotAt() con el  |
//| valor NUEVO ya no es el lote real de esos niveles. El Target $ / |
//| DD $ que muestra el overlay corrige esto leyendo el lote real vía|
//| CBasketManager::GetPosLot() para los niveles ya llenos — esta    |
//| fórmula sigue siendo la única fuente para los niveles TODAVÍA no |
//| disparados (ver CBasketOverlay::_ComputeLevels).                 |
//+------------------------------------------------------------------+
#ifndef AURAX_RECOVERYMATH_MQH
#define AURAX_RECOVERYMATH_MQH

// Lote del recovery de nivel k (1-based: 1=REC#1, 2=REC#2...). Espejo exacto de la fórmula
// que ya usaba CBasketManager::Update() — expN = floor(k/et), NO geométrico puro mul^k (eso
// diverge cuando et>1 y mostraría lotes/DD/TP-target falsos).
double RecoveryLotAt(double baseLot, double mul, int et, int levelIndex1Based,
                      double volMin, double volMax, double volStep)
{
   int    expN = (et > 0) ? levelIndex1Based / et : levelIndex1Based;
   double lot  = baseLot;
   if(mul > 0.0) for(int i = 0; i < expN; i++) lot *= mul;
   if(volMin  > 0.0 && lot < volMin) lot = volMin;
   if(volMax  > 0.0 && lot > volMax) lot = volMax;
   if(volStep > 0.0) lot = MathRound(lot / volStep) * volStep;
   return NormalizeDouble(lot, 3);
}

// Nivel de recovery más profundo que la grilla puede llegar a abrir sin superar el volumen
// agregado que el bróker permite para el símbolo (SYMBOL_VOLUME_LIMIT — volumen NETO de TODA
// la cuenta en ese símbolo, no por mágico: una posición manual o de otro EA en el mismo símbolo
// también consume ese cupo).
//   volLimit <= 0   → el bróker no lo publica: sin techo, devuelve rlc tal cual (no hay con qué
//                     avisar; NUNCA tratar 0 como "no se puede abrir nada").
//   otherVolume     → volumen ya abierto en ese símbolo por fuera de esta grilla (otras
//                     posiciones reales; en SIM, la exposición ya simulada de este mismo basket
//                     si se llama a mitad de grilla). 0 si no aplica.
// Devuelve N tal que entrada + REC#1..REC#N caben dentro del límite, pero REC#(N+1) no.
// N puede ser 0 (ni la entrada sola entra) hasta rlc (la grilla completa entra).
int MaxReachableRecoveryLevel(double baseLot, double mul, int et, int rlc,
                               double volMin, double volMax, double volStep, double volLimit,
                               double otherVolume = 0.0)
{
   if(rlc <= 0) return 0;
   if(volLimit <= 0.0) return rlc;   // sin techo publicado por el bróker
   double cum = baseLot + otherVolume;
   if(cum > volLimit) return 0;      // ya se pasa solo con la entrada (+ lo que hay afuera)
   for(int k = 1; k <= rlc; k++)
   {
      double lot = RecoveryLotAt(baseLot, mul, et, k, volMin, volMax, volStep);
      if(cum + lot > volLimit) return k - 1;
      cum += lot;
   }
   return rlc;
}

#endif
