# F0/F1/F2/F3/F4 — Progreso de implementación (Structura)

Estado: **F0, F1, F2 completos**; **F3 completo** (E4 y E6 resueltos; continuidad de `ARWorldMap` entre pases de Pro Scan sobre el mismo nombre de escaneo, implementada — ver sección propia); **F4 conectado a la UI detrás de un flag de debug**, todavía sin validar contra un escaneo real; **F5 sin empezar**, ver nota al final. Según el plan de `auditoria-arquitectura-97aeb63.md`.

Rama: `f1/acumulador-incremental`, pusheada a GitHub. Todo lo de abajo — incluida la sesión de Claude Code local que compiló esto por primera vez — ya está en `origin/f1/acumulador-incremental`.

## Sesión de Claude Code local (09/09/2026) — primera compilación real

Todo lo de arriba (commits 1-10) se escribió en un sandbox de Cowork sin Xcode ni dispositivo. Esta fue la primera vez que pasó por un compilador real:

- `5d5b1f1` — 3 bugs reales que nunca se habían compilado: falta `import Foundation` en `ConfidenceGrid.swift`; `DelegateFrameMetrics` medía la ventana de FPS desde el reloj del callback (`now`) en vez del timestamp de ARKit (`frameTimestamp`), lo que desalineaba la ventana cuando ambos no coincidían exactamente — expuesto por su propio test sintético; dos asserts de test sin desenvolver `Float?`. Build de dispositivo y los 195 tests de `StructuraTests` en verde después.
- `2674af2` — Resuelve las dos decisiones de producto que quedaban abiertas (ver secciones F3 y F4 abajo): continuidad de `ARWorldMap` por nombre de escaneo, y F4 conectado a `ResultView` detrás de `#if DEBUG`.

Verificado con `xcodegen generate` + build de dispositivo (Debug y Release, ambos en verde — Release confirma que `#if DEBUG` realmente excluye el código de F4) + los 195 tests. **Sin probar en el iPhone real todavía** — no hubo acceso físico al dispositivo durante esta sesión (estaba con Cristian, no con la Mac). Antes de dar por buena la continuidad de `ARWorldMap` en particular, hace falta un pase real: nombrar dos escaneos igual, confirmar que aparece el diálogo de continuar, y confirmar que el segundo pase efectivamente comparte el marco de referencia del primero.

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

**ARWorldMap — implementado en la sesión de Claude Code local del 09/09/2026, ver más abajo.**

El plan original también pedía "persistir y recargar `ARWorldMap`... compartir world map entre RoomPlan y ProScan". Se implementó solo la primera mitad:

1. Persistir/recargar un `ARWorldMap` **dentro de un mismo pase de Pro Scan** (entre sesiones de la propia `ARPointCloudSession`) es factible con la API documentada de Apple (`ARSession.getCurrentWorldMap`, `ARWorldTrackingConfiguration.initialWorldMap`) — **implementado**.
2. **Compartir ese world map con RoomPlan** — la otra mitad de lo que pedía el plan — sigue sin implementarse: no hay, hasta donde se pudo confirmar, una API pública de `RoomCaptureSession` para extraer o inyectar un `ARWorldMap`. RoomPlan administra su propia `ARSession` internamente. Sigue fuera de alcance.

Lo implementado: `Structura/Capture3D/WorldMapStore.swift` persiste el world map de un pase de Pro Scan al terminar, clave por **nombre del escaneo** (no por proyecto/fase — `ScanRecord` no tiene ese campo hoy; Cristian eligió explícitamente identificar continuidad por nombre en vez de agregar un campo nuevo al modelo de datos o postergar esto). `ARPointCloudSession.start(...)` acepta `initialWorldMap:`; `ProScanCaptureView` detecta un world map guardado con el mismo nombre al abrir y ofrece un diálogo "Continuar ese escaneo" / "Empezar de cero". **Sin validar en dispositivo real** — ver la sección de la sesión local arriba para el pase de prueba pendiente.

## F4 — Plano 2D desde la nube de puntos propia (objetivo #2 del proyecto)

`Structura/Result/PointCloudFloorPlanBuilder.swift` (+ `StructuraTests/PointCloudFloorPlanBuilderTests.swift`). Elegido sobre F3 al retomar el trabajo ("sigamos") porque es el objetivo #2 explícito del proyecto y no depende de F3 para un escaneo continuo único.

Pipeline, Swift/simd puro sin ARKit/RoomPlan (compila en el target de tests sin host):

1. `estimateFloorHeight` — histograma de altura entre puntos de normal casi-vertical (candidatos a piso/techo); elige el clúster más grande en la mitad inferior del rango, no el punto más bajo ni el clúster más grande a secas.
2. `wallCandidatePoints2D` — franja horizontal fina a altura de pared, solo puntos de normal casi-horizontal, proyectados a 2D (X, Z).
3. `detectWallLines` — RANSAC secuencial (múltiples paredes, no un ajuste global), refinado por total-least-squares (evita el fallo de mínimos cuadrados ordinarios con paredes casi verticales). RNG propio determinista (SplitMix64) para pruebas reproducibles.
4. `dominantGridAngle` / `snapToGrid` / `weldCorners` / `closePolygons` — mismo razonamiento que los métodos equivalentes de `FloorPlan.swift`, pero **reimplementado**, no compartido: `FloorPlan.swift` es código de producción en uso, sin pruebas propias, y no hay compilador en este entorno para verificar un refactor con seguridad. Duplicar es el riesgo menor; unificar queda para F5 una vez que este camino tenga validación propia.

**Importante — sin validar contra dispositivo real todavía.** Cada función tiene pruebas con datos sintéticos (habitación rectangular limpia, ruido inyectado, techo/mueble como confusor, múltiples habitaciones), lo cual no es lo mismo que "validado". La altura de la franja de pared (1 m sobre el piso), el grosor de la franja (15 cm) y el umbral de inlier de RANSAC (3 cm) son placeholders de ingeniería, no valores calibrados contra un escaneo LiDAR real de una habitación amueblada e imperfecta — mismo espíritu de advertencia que ya tenía el comentario de `PlaneSnapping`. Tampoco hay compilador disponible en este entorno de trabajo: las pruebas nuevas están revisadas a mano y con chequeo de balance de llaves/paréntesis, pero el caso extremo a extremo (`testBuildRecoversARectangularRoomEndToEnd`) depende de que RANSAC encuentre las 4 líneas con la semilla fija por defecto — es la prueba de más riesgo de fallar al compilar/correr por primera vez en Xcode; vale la pena confirmarla ahí antes de confiar en el resto.

**Decisión de producto — resuelta en la sesión de Claude Code local del 09/09/2026:** detrás de un flag de debug. `Structura/Result/PointCloudFloorPlanDebugView.swift` conecta el builder a una pestaña "Plano (exp.)" en `ResultView`, compilada solo en `#if DEBUG` (verificado que un build Release la excluye). No reemplaza `FloorPlanView` ni se muestra lado a lado — Cristian eligió la opción de menor riesgo dado que el algoritmo solo tiene cobertura sintética. Sigue pendiente el mismo paso de validación contra un escaneo real antes de considerar cualquiera de las otras dos opciones.

## Deliberadamente no tocado (fuera de alcance, no arreglado)

- La carrera de reuso de instancia de `ARPointCloudSession` entre escaneos (preexistente).
- `HapticEngineManager`/`HapticFeedbackAdapter` sin sincronización propia — hoy seguro porque todo se llama desde main actor.
- `PointCloudStore`: acumulación por vóxel sin consumidor (ver arriba) — decisión pendiente.
- `videoFormat`/`planeDetection`/`isAutoFocusEnabled` de `ARSession`: sin tocar.
- `FloorPlan.swift` (RoomPlan): sin tocar, sin refactor compartido con `PointCloudFloorPlanBuilder` (ver F4 arriba).
- `ARWorldMap` compartido con RoomPlan (ver F3 arriba) — sin API pública disponible, no es una decisión de producto pendiente sino una limitación de plataforma.

## F0: qué falta para tener línea base real

Instrumentación commiteada, medición pendiente: Instruments (Time Profiler + `os_signpost`, subsystem `com.structura.capture3d`), ~60 s de escaneo real en dispositivo con LiDAR. Como F1 ya se implementó antes que F0, lo que se mida es el estado **post-F1/F2**, no la línea base original.

## Siguiente paso lógico

Con F0, F1, F2 y F3 cerrados, y F4 conectado a la UI tras un flag de debug, lo único genuinamente pendiente de las fases F0-F4 es **validar en un iPhone real**: el pase completo de world map continuity (nombrar dos escaneos igual, confirmar el diálogo, confirmar que comparten marco de referencia) y el plano experimental de F4 contra un ambiente real amueblado. Ninguno de los dos se puede cerrar sin acceso físico al dispositivo.

Mientras tanto, lo que sigue sin acceso a un iPhone es **F5** (estructura enterprise del código, ver nota abajo).

## F5 — Estructura enterprise: evaluado, no iniciado (09/09/2026)

El plan pide partir `ARPointCloudSession` (1129 líneas tras las fases anteriores, ~7 responsabilidades: lifecycle, procesamiento de malla, procesamiento de depth/frame, y el `ARSessionDelegate` completo) en archivos separados, además de convertir el núcleo puro de Capture3D en un Swift Package local, un protocolo `ScanSource` con implementación falsa, y concurrency checking estricto por fases.

Se evaluó empezar por el paso más chico y seguro (separar `ARPointCloudSession` en extensiones por responsabilidad, en archivos distintos) pero se decidió **no hacerlo en esta sesión**: dividir en archivos distintos obliga a subir varias propiedades de `private` a `internal` para que las extensiones se vean entre sí, y esta clase es exactamente el código que corre en la cola del delegate de ARKit — el mecanismo raíz de la inestabilidad original (C4). Ya hubo un bug real esta misma sesión (`DelegateFrameMetrics`) que solo salió a la luz al compilar por primera vez; tocar esta clase en particular sin poder correr un escaneo real después para confirmar que sigue estable es un riesgo que no vale la pena tomar a ciegas. F5 sigue completamente sin empezar — el análisis de por dónde partirla queda hecho, no el código.
