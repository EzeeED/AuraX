# AuraX — Zonas Áureas (Delorrio Capital)

<img src="docs/img/aurax-logo.png" width="160" alt="Logo AuraX">

EA para MetaTrader 5 que combina scanner + trading con la estrategia de **zonas áureas**.

- Código: carpeta `MQL5/` (se copia tal cual dentro de la carpeta `MQL5\` de MetaTrader).
- Compilar: solo `MQL5/Experts/AuraX/AuraX.mq5` (F7 en MetaEditor). No embebe indicadores.
- Licencia: producto **AURX** en delorrio.com (la web tiene que reconocer ese código).
- Reglas de la estrategia: [`docs/estrategia_zonas_aureas.md`](docs/estrategia_zonas_aureas.md)
- Historial: [`docs/CHANGELOG.md`](docs/CHANGELOG.md)

Base reutilizada de EmaRiskPro 9.00 (copiada a `Include/AuraX/`, sin tocar EmaRiskPro):
panel de trading, basket con recoveries, líneas del basket, toast y validador de licencia.

Diseño de los paneles (maqueta): [`docs/img/aurax-paneles.png`](docs/img/aurax-paneles.png)
