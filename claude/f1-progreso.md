# F0/F1/F2/F3(parcial)/F4 — Progreso de implementación (Structura)

Estado: **F0, F1 y F2 completos**; **F4 tiene su núcleo algorítmico implementado y cubierto con pruebas sintéticas, pendiente de validación en dispositivo real antes de conectarse a la UI**; **F3 parcialmente implementado** (E4 y E6 resueltos; la parte de `ARWorldMap` queda deliberadamente sin tocar — ver sección propia). Según el plan de `auditoria-arquitectura-97aeb63.md`.

Rama: `f1/acumulador-incremental`. Todo commiteado localmente; el push a GitHub está pendiente de correrse desde una máquina con acceso real al repo (ver `HANDOFF.md`).

## Commits

1. `5525cf5` — Acumulador de vóxeles incremental (`VoxelAccumulator`), sin heap por celda. Resuelve C1/C2.
2. `fcf9a41` — Autosave y export fuera del main actor; `PLYExporter` streaming por `FileHandle`. Resuelve C7.
3. `220253f` — Split del delegate queue de ARSession (`delegateQueue`/`meshProcessingQueue`); `ConfidenceGrid` gana lock propio. Resuelve C4.
4. `893f5a7` — `PointCloudStore.ingest` fuera del main actor, throttle a 2 Hz. Resuelve C5.
5. `1095e22` — F0: `os_signpost`, `DelegateFrameMetrics` (ARKit fps/latencia real), `thermalState`/`peakMemoryUsedMB` en `PerformanceMonitor`.
6. `64c5762` — F2 parte 1: `AngularVelocityGate` (E1), clave de vóxel unificada en `ProScanConfig.voxelKey(for:)` (E3, parte segura), `thermalState` por batch + `Timer` en modo `.common` (C8).
7. `b31d253` — F2 parte 2: confianza honesta en el LAS (E2) — `isConfidenceObserved` en `VoxelAccumulator.Sample`/`PointCloudExportPoint`, `LASExporter` escribe el sentinel `0` en vez de un 0,5 fabricado, `ScanMetadataReport.meanConfidence` promedia solo puntos observados + nuevo campo `unobservedConfidencePointFraction`.
8. `a45726b` — F4: `PointCloudFloorPlanBuilder`, plano 2D derivado directamente de la nube de puntos de Pro Scan (ver sección propia abajo).
9. `c64b5ff` — F3 (parcial): `ARSessionStartupPolicy` (E6) + `ScanDriftBudget` (E4) — ver sección propia abajo.
10. `97aef82` — dev: `PurchaseManager.isPaywallDisabledForTesting = true`, para probar la app sin el paywall en el teléfono de Cristian. **Volver a `false` antes de cualquier build que instale alguien más.**

**F2 queda cerrado**: los 5 hallazgos (E1, E2, E3, C6, C8) tienen resolución — 4 implementados, C6 resuelto como decisión explícita de no tocar nada (ver abajo).

## Decisiones de Cristian (F2)

- **E2 (confianza):** "marcar como desconocida" — implementado. Un punto sin observación real de `ConfidenceGrid` ya no escribe un 0,5 que se puede confundir con una lectura real en el LAS.
- **C6 (`.occlusion` de RealityKit):** "mantener el wireframe, aceptar el costo" — sin cambios. El feedback visual de cobertura en vivo durante la captura vale el costo de GPU/calor.

## Hallazgos descubiertos en el camino (no en la auditoría original)

- **C5 (F1):** el framing original ("SwiftUI redibuja el HUD 6 veces por segundo") sobreestimaba el efecto visible — nada observa `pointCloudStore.pointCount`/`lastUpdate`. El costo real (dedup en el main actor) sí era real y F1 lo eliminó.
- **E3 (F2):** la mitad de este hallazgo (dos reglas de fusión distintas) resultó ser un no-problema — `PointCloudStore.accumulatedSnapshot()` no tiene ningún consumidor hoy. Toda su acumulación por vóxel es trabajo real sin beneficio (una búsqueda en diccionario y hasta tres escrituras de array por punto, en cada frame de profundidad). **No se tocó** — es una decisión pendiente: ¿simplificar `PointCloudStore` a solo lo que se usa, o conectar `accumulatedSnapshot()` a algo real?

## F3 (parcial) — Arranque reactivo + presupuesto de deriva

`Structura/Capture3D/ARSessionStartupPolicy.swift` y `Structura/Capture3D/ScanDriftBudget.swift` (+ sus tests). Resuelve E6 y E4 del plan original:

- **E6:** el arranque de Pro Scan ya no espera un `asyncAfter(0.3)` fijo — intenta `session.run()` de inmediato y, si ARKit reporta `didFailWithError` muy poco después (< 1 s, el conflicto típico de "RoomPlan todavía no soltó la cámara"), reintenta con backoff exponencial (100/200/400/800 ms, hasta 5 intentos) en vez de adivinar un tiempo fijo. **Supuesto sin confirmar en dispositivo real:** que ARKit efectivamente falla rápido en ese conflicto, en vez de arrancar en silencio sin frames — revisar esto con un iPhone real antes de confiar del todo.
- **E4:** el aviso de "escaneo largo" ya no depende de un tope fijo de 40 s — se calcula con un presupuesto de distancia recorrida + rotación acumulada (reutiliza la matemática de `AngularVelocityGate`), que se parece mucho más a la deriva real de ARKit (sin loop closure) que el tiempo transcurrido. Umbrales (15 m / ~4 vueltas) son placeholders de ingeniería explícitos, sin calibrar contra una medición real de deriva.

**Lo que NO se implementó de F3, a propósito — necesita una decisión de Cristian:**

El plan original también pedía "persistir y recargar `ARWorldMap`... compartir world map entre RoomPlan y ProScan". Esto se dejó sin tocar porque:

1. Persistir/recargar un `ARWorldMap` **dentro de un mismo pase de Pro Scan** (entre sesiones de la propia `ARPointCloudSession`) es factible con la API documentada de Apple (`ARSession.getCurrentWorldMap`, `ARWorldTrackingConfiguration.initialWorldMap`).
2. Pero **compartir ese world map con RoomPlan** — la otra mitad de lo que pedía el plan — no tiene, hasta donde se pudo confirmar sin acceso a la documentación de Apple ni a un dispositivo real, una API pública de `RoomCaptureSession` para extraer o inyectar un `ARWorldMap`. RoomPlan administra su propia `ARSession` internamente. Escribir código contra una API que podría no existir, sin poder compilarlo ni probarlo en este entorno, es peor que no escribir nada.

La alternativa más segura y con valor real (directamente conectada al objetivo #3 del proyecto — seguimiento de obra por fases) es: persistir el `ARWorldMap` de Pro Scan al terminar un pase, asociado al proyecto/fase del `ScanRecord`, y ofrecer recargarlo en un pase posterior **de Pro Scan sobre la misma fase** — sin tocar RoomPlan en absoluto. Esto todavía no se implementó porque implica decisiones de producto (¿dónde se guarda el world map por proyecto/fase? ¿cómo elige el usuario "continuar la fase anterior"?) que conviene confirmar con Cristian antes de escribir código a ciegas.

## F4 — Plano 2D desde la nube de puntos propia (objetivo #2 del proyecto)

`Structura/Result/PointCloudFloorPlanBuilder.swift` (+ `StructuraTests/PointCloudFloorPlanBuilderTests.swift`). Elegido sobre F3 al retomar el trabajo ("sigamos") porque es el objetivo #2 explícito del proyecto y no depende de F3 para un escaneo continuo único.

Pipeline, Swift/simd puro sin ARKit/RoomPlan (compila en el target de tests sin host):

1. `estimateFloorHeight` — histograma de altura entre puntos de normal casi-vertical (candidatos a piso/techo); elige el clúster más grande en la mitad inferior del rango, no el punto más bajo ni el clúster más grande a secas.
2. `wallCandidatePoints2D` — franja horizontal fina a altura de pared, solo puntos de normal casi-horizontal, proyectados a 2D (X, Z).
3. `detectWallLines` — RANSAC secuencial (múltiples paredes, no un ajuste global), refinado por total-least-squares (evita el fallo de mínimos cuadrados ordinarios con paredes casi verticales). RNG propio determinista (SplitMix64) para pruebas reproducibles.
4. `dominantGridAngle` / `snapToGrid` / `weldCorners` / `closePolygons` — mismo razonamiento que los métodos equivalentes de `FloorPlan.swift`, pero **reimplementado**, no compartido: `FloorPlan.swift` es código de producción en uso, sin pruebas propias, y no hay compilador en este entorno para verificar un refactor con seguridad. Duplicar es el riesgo menor; unificar queda para F5 una vez que este camino tenga validación propia.

**Importante — sin validar contra dispositivo real todavía.** Cada función tiene pruebas con datos sintéticos (habitación rectangular limpia, ruido inyectado, techo/mueble como confusor, múltiples habitaciones), lo cual no es lo mismo que "validado". La altura de la franja de pared (1 m sobre el piso), el grosor de la franja (15 cm) y el umbral de inlier de RANSAC (3 cm) son placeholders de ingeniería, no valores calibrados contra un escaneo LiDAR real de una habitación amueblada e imperfecta — mismo espíritu de advertencia que ya tenía el comentario de `PlaneSnapping`. Tampoco hay compilador disponible en este entorno de trabajo: las pruebas nuevas están revisadas a mano y con chequeo de balance de llaves/paréntesis, pero el caso extremo a extremo (`testBuildRecoversARectangularRoomEndToEnd`) depende de que RANSAC encuentre las 4 líneas con la semilla fija por defecto — es la prueba de más riesgo de fallar al compilar/correr por primera vez en Xcode; vale la pena confirmarla ahí antes de confiar en el resto.

**Decisión de producto pendiente, no resuelta acá a propósito:** cómo mostrar esta salida — ¿reemplaza el plano de `FloorPlanView` (hoy basado en RoomPlan), se muestra lado a lado para comparar, o queda detrás de un flag de depuración hasta validarse en dispositivo? Cristian eligió explícitamente "todavía no decidir, seguir con F3" cuando se le preguntó — sigue abierta.

## Deliberadamente no tocado (fuera de alcance, no arreglado)

- La carrera de reuso de instancia de `ARPointCloudSession` entre escaneos (preexistente).
- `HapticEngineManager`/`HapticFeedbackAdapter` sin sincronización propia — hoy seguro porque todo se llama desde main actor.
- `PointCloudStore`: acumulación por vóxel sin consumidor (ver arriba) — decisión pendiente.
- `videoFormat`/`planeDetection`/`isAutoFocusEnabled` de `ARSession`: sin tocar.
- `FloorPlan.swift` (RoomPlan): sin tocar, sin refactor compartido con `PointCloudFloorPlanBuilder` (ver F4 arriba).
- `ARWorldMap` persistido/compartido con RoomPlan (ver F3 arriba) — necesita decisión de producto primero.

## F0: qué falta para tener línea base real

Instrumentación commiteada, medición pendiente: Instruments (Time Profiler + `os_signpost`, subsystem `com.structura.capture3d`), ~60 s de escaneo real en dispositivo con LiDAR. Como F1 ya se implementó antes que F0, lo que se mida es el estado **post-F1/F2**, no la línea base original.

## Siguiente paso lógico

Con F0, F1, F2 cerrados, F3 con E4/E6 resueltos (ARWorldMap pendiente de decisión de producto), y F4 con su núcleo algorítmico listo (pendiente de validación real y de la decisión de UI de arriba), lo que sigue es: (a) decidir el alcance real de la continuidad `ARWorldMap` por fase/proyecto, (b) empezar a validar F4 contra grabaciones reales, o (c) **F5** (estructura enterprise del código).
