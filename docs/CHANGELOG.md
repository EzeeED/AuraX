# CHANGELOG — AuraX

## 1.00 — 2026-11-13 (primera versión)
- EA nueva `AuraX.mq5`: scanner + trading en una sola EA, licencia "AURX".
- Detección del último impulso solo con velas (sin EMAs) y Fibo de zonas áureas
  (Av1 -0.38, Av2 -0.68, Av3 -1, Última zona -1.618, Engaño -2, No Fasha -2.236).
- Semiautomática: la 1ª entrada la hace el trader (INICIAR desde Av1); la EA abre los
  recoveries proporcionales (LOT, MULT, ET, RLC editables en el panel, igual que EmaRiskPro).
- TP: Av1/Av2 → cierre de la 3ª vela de retroceso en ganancia; Av3 en adelante → % fijo por
  zona (14 / 21 / 30 / 35 %). La línea TP se arrastra a mano.
- Stop (FRACCIÓN): cierre de vela con cuerpo más allá de No Fasha (+FRAC% opcional).
- Regla 5: en M15 o más, después de pagar en Av1/Av2 se marca el siguiente Fibo una sola vez.
- Pain = solo ventas, Gain = solo compras.
- Panel en azul y negro; sin campo TP%; SL% pasa a llamarse FRAC%.
- Logo de AuraX como ícono de la EA (`Images/AuraX/aurax.ico`) y en la barra de título de los
  dos paneles (`Images/AuraX/aurax_logo22.bmp`); los dos se embeben al compilar.
- Scanner de Observación del Mercado (M5 a D1) con avisos (tarjeta, sonido, push).
