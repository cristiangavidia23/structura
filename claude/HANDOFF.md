# Handoff a Claude Code local — leer esto primero

Este repo trae trabajo hecho en una sesión de Cowork (sandbox en la nube, sin acceso a `git push`
ni a Xcode real) que necesita terminar de aterrizar en la máquina de Cristian. Si estás leyendo
esto desde una sesión nueva de Claude Code, arrancá por acá.

## Contexto del proyecto

- `claude/auditoria-arquitectura-97aeb63.md` — auditoría de arquitectura completa (hallazgos C1-C8,
  E1-E8, plan de acción F0-F5).
- `claude/f1-progreso.md` — qué se implementó de ese plan, qué decisiones tomó Cristian, qué queda
  pendiente y por qué. Léelo completo antes de tocar código de Capture3D/ProScan.

## Lo urgente ahora mismo

1. **Aplicar los cambios pendientes y pushear.** La rama `f1/acumulador-incremental` tiene 10
   commits locales que nunca llegaron a GitHub (el sandbox de Cowork no tiene permiso de push a
   este repo). Si esta carpeta ya tiene esos commits (revisá con `git log --oneline -10`), solo
   falta `git push -u origin f1/acumulador-incremental`. Si no los tiene, hay un
   `incoming-cambios.bundle` en la raíz del repo — aplicalo así:
   ```
   git fetch incoming-cambios.bundle f1/acumulador-incremental
   git checkout -B f1/acumulador-incremental FETCH_HEAD
   git push -u origin f1/acumulador-incremental
   ```
2. **Regenerar el proyecto de Xcode.** `project.yml` es la fuente de verdad (usa `xcodegen`);
   varios archivos nuevos se agregaron ahí y `Structura.xcodeproj` puede estar desactualizado:
   ```
   xcodegen generate
   ```
3. **Compilar e instalar en el iPhone de Cristian.** Abrir `Structura.xcodeproj`, elegir el
   iPhone como destino, Run. Firma automática con el team `WREX368LLS` ya está configurada en
   `project.yml`.
4. **El paywall está desactivado a propósito para pruebas** —
   `Structura/Purchases/PurchaseManager.swift`, `isPaywallDisabledForTesting = true`. Es un
   bypass de desarrollo, no una decisión de producto: **volver a `false` antes de cualquier build
   que instale alguien que no sea Cristian probando en su propio teléfono.**

## Decisión pendiente que Cristian todavía no tomó

**Continuidad de `ARWorldMap` entre pases de Pro Scan, por fase/proyecto de obra.** El plan
original de F3 pedía "persistir y recargar ARWorldMap... compartir world map entre RoomPlan y
ProScan". La parte de compartir con RoomPlan no se implementó — no hay evidencia de una API
pública de `RoomCaptureSession` para eso, y escribir contra una API incierta sin poder compilar ni
probar en dispositivo es peor que no escribir nada. La alternativa que sí es factible con API
documentada de Apple (`ARSession.getCurrentWorldMap` / `ARWorldTrackingConfiguration
.initialWorldMap`) es: persistir el world map de un pase de Pro Scan asociado a la fase/proyecto
del `ScanRecord`, y ofrecer recargarlo en un pase posterior sobre esa misma fase — sirve
directamente al objetivo #3 del proyecto (seguimiento de obra por fases). Antes de implementar esto
hace falta que Cristian decida: ¿dónde vive ese world map por proyecto/fase en el modelo de datos
actual? ¿cómo elige el usuario "continuar la fase anterior" en la UI? Ver el detalle completo en
`claude/f1-progreso.md`, sección "F3 (parcial)".

## Cómo seguir trabajando en este repo con Claude Code

Las instrucciones de la auditoría y del progreso ya están en `claude/`. Decile a Claude Code algo
como: "leé claude/HANDOFF.md y claude/f1-progreso.md, hacé lo urgente primero, y después seguimos
con F5 o con la decisión de ARWorldMap" — no hace falta reexplicar todo el contexto desde cero.
