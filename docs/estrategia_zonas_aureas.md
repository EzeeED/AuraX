# Estrategia de Zonas Áureas — AuraX

> Reglas tal como las definió el dueño (chat 2026-11-13). Lo que es decisión de
> implementación de Claude (no dicho por el dueño) está marcado aparte, al final.

## Reglas del dueño

1. **Sistema de balas** (recomendado): la bala es el stop, en el panel se llama **FRACCIÓN**, igual que en EmaRiskPro.
2. Si el último impulso es **bajista**, el Fibo se marca de abajo hacia arriba y se buscan **ventas**.
3. Si el último impulso es **alcista**, se marca al revés y se buscan **compras**. (Funciona más en ventas.)
   - En ambos casos el **0** queda donde **arrancó** el impulso y el **1** donde terminó.
4. **Mínimo 3 velas de retroceso y 3 velas de impulso.** No tienen que estar pegadas ni ser continuas (se cuentan por color de cierre). El Fibo se marca de **mecha a mecha**. El impulso tiene que superar la zona (el extremo previo al retroceso) **con más cuerpo que mecha**.
5. Si llega a Av1 y hace mínimo 3 velas de retroceso, se marca el **siguiente Fibo** (de M15 en adelante). Pasa **una sola vez**: el Fibo viejo se descarta y se opera el nuevo.
6. Cuando llega a Av2 o Av3 empiezan los recoveries (Av2 depende del capital). Los recoveries son **proporcionales, con la misma lógica de EmaRiskPro**.
7. Si llega a Av1 o Av2, paga con **3 velas de retroceso** (cierra al cierre de la 3.ª vela).
8. Si llega a Av3, el TP es la zona Av2 (o Av1 si lo dejás correr), sin buscar el pip exacto.
9. Si llega a la Última zona, a Engaño o toca No Fasha, el TP es **cerca de Av3**, sin buscar el pip exacto.
10. Si una vela **cierra con cuerpo** más allá de No Fasha → se cierra todo (se espera el cierre de la vela).
11. Multiplicador (1.2 o 1.5) y Every Trades (1 o 2) **editables en el panel**.
- La estrategia es **de M5 en adelante**.
- **Herramienta semiautomática:** la primera entrada siempre la hace el trader; las demás, la EA.
- **Pain:** solo ventas. **Gain:** solo compras (a favor del spike).

## Niveles

| Zona | Nivel Fibo |
|---|---|
| 1 (fin del impulso) | 1 |
| 0 (inicio del impulso) | 0 |
| Av1 | -0.38 |
| Av2 | -0.68 |
| Av3 | -1 |
| Última zona | -1.618 |
| Engaño | -2 |
| No Fasha | -2.236 |

## TP por zona (fijo, no editable; solo se mueve arrastrando la línea TP)

Medido en un Fibo desde el **fin del impulso (1)** hasta el **extremo alcanzado**:

| Hasta dónde llegó | TP apunta a | % exacto | % usado ("no al pip") |
|---|---|---|---|
| Av3 | Av2 | 16 % | **14 %** |
| Última zona | Av3 | 23,6 % | **21 %** |
| Engaño | Av3 | 33,3 % | **30 %** |
| No Fasha (con mecha) | Av3 | 38,2 % | **35 %** |

## Decisiones de implementación de Claude (no dichas por el dueño — a validar)

- **Cómo se detecta el inicio del retroceso:** se toma el mínimo (en venta) más cercano antes del pico, desde el cual hay al menos 3 velas verdes hasta el pico, sin cruzar un máximo más alto que el pico.
- **"Más cuerpo que mecha":** la parte del cuerpo que quedó más allá de la zona tiene que ser mayor que la mecha de ese mismo lado.
- **Cuándo se confirma un impulso:** en la vela en que se cumplen las dos cosas (ruptura con cuerpo y 3 velas del impulso).
- **Prioridad:** un Fibo que ya llegó a Av1 y no pagó no se reemplaza por un impulso nuevo. Si hay setups de compra y de venta a la vez, manda el que está en zona; si no, el más reciente.
- **INICIAR antes de Av1 se bloquea** con un mensaje ("desde Av1 ya se puede entrar").
- **Pago por 3 velas:** se cuentan desde la vela del extremo (incluida) y solo se cierra si el basket está en ganancia. En SIM solo avisa, no cierra (igual que EmaRiskPro).
- **El TP por zona solo se manda si cierra el basket en ganancia** (tiene que quedar del lado bueno del precio promedio del basket). Si no, la línea queda gris (desarmada).
- **FRAC %:** margen extra más allá de No Fasha, en % del impulso. Default 0 = justo en No Fasha.
- **RLC por defecto = 5:** con la entrada en Av1 y el stop en No Fasha, 5 recoveries parejos caen casi justo en Av2, Av3, la Última zona y Engaño.
- **Re-marcado (regla 5):** el Fibo nuevo va con el 0 en el extremo alcanzado y el 1 en el piso del retroceso de 3 velas.
