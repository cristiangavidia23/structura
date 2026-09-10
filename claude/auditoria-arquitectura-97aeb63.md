# Auditoría de arquitectura — Structura LiDAR (commit 97aeb63, 09/09/2026)

Alcance: 77 archivos Swift, 8.458 líneas. Repo: cristiangavidia23/structura.
Versión completa y navegable: artefacto "Auditoría Structura LiDAR".

## Veredicto

El código está por encima del promedio (matemática pura separada de ARKit y testeada sin
dispositivo, comentarios que documentan supuestos reales, trampas clásicas ya resueltas —
reescalado de intrínsecos al depth map, convención de signo imagen/cámara, dedup por vóxel).
No hay que reescribir nada.

Dos problemas de fondo:

1. **Trabajo pesado en el hilo equivocado.** El procesamiento de malla comparte cola serial con
   el delegate de ARSession, y la reconstrucción completa de la nube corre en el main actor cada
   10 s. Cuando esa cola se atrasa, ARKit no entrega frames: se ve como malla congelada, saltos
   e islas desconectadas.
2. **El plano 2D no sale de la nube de puntos.** Sale de RoomPlan, en otra sesión y otro origen
   de coordenadas. Todo el trabajo de precisión de ProScan no llega al entregable.

## Cuellos de botella

| ID | Sev | Hallazgo | Ubicación |
|----|-----|----------|-----------|
| C1 | Crítico | `currentMeshPoints()` reconstruye toda la nube en el main actor cada 10 s (flatMap completo + VoxelAccumulator nuevo, bajo `meshLock`) | ProScanCaptureView.swift:292 → ProScanCoordinator.swift:203 → ARPointCloudSession.swift:91 |
| C2 | Crítico | Un `Dictionary` en heap por vóxel ocupado (`classificationVotes`). Clasificaciones son 0–7: bastan 8 contadores fijos | VoxelAccumulator.swift:62 |
| C3 | Alto | La clasificación recorre TODAS las caras del ancla en cada update, más un `Set` de índices innecesario | ARPointCloudSession.swift:244-251, 331-380 |
| C4 | Alto | `session.delegateQueue = processingQueue`: depth y malla compiten por la cola por la que ARKit entrega frames. **Este es el mecanismo raíz de la inestabilidad** | ARPointCloudSession.swift:11, 126 |
| C5 | Medio | `PointCloudStore.ingest` procesa ~1.900 puntos/frame en el main actor y publica a 6 Hz | PointCloudStore.swift:37-59 |
| C6 | Medio | `.occlusion` de RealityKit activado solo para el wireframe de debug: GPU y calor a cambio de nada; el calor realimenta el thermal throttling | ARCameraPassthroughView.swift:26-27 |
| C7 | Medio | PLY armado entero en memoria, ~10 `append` por punto, repetido cada 10 s | PLYExporter.swift:56-76 |
| C8 | Bajo | `thermalState` leído por update de ancla; `Timer` del HUD en modo `.default` | ARPointCloudSession.swift:243, ProScanCoordinator.swift:130 |

## Inestabilidad y precisión

| ID | Sev | Hallazgo | Ubicación |
|----|-----|----------|-----------|
| E1 | Crítico | El gating por velocidad angular está declarado y testeado pero **ningún archivo lo consume**; hoy `.limited(.excessiveMotion)` sí se acumula | ProScanConfig.swift:92, FrameGate.swift:5-9/38 |
| E2 | Alto | La confianza por punto de la malla es en su mayoría el valor de relleno 0,5: la ConfidenceGrid solo se alimenta del pipeline de depth (6 Hz, stride 5), que no cubre el volumen de la malla | ARPointCloudSession.swift:307 |
| E3 | Alto | Dos reglas de dedup distintas sobre la misma constante (mayor-confianza vs. promedio ponderado); clave de vóxel copiada en 3 archivos | PointCloudStore.swift:44/61, VoxelAccumulator.swift:80/130, ConfidenceGrid.swift:66 |
| E4 | Alto | Sin `ARWorldMap`: la deriva se mitiga limitando el pase a 40 s. Techo duro para obra civil | ProScanCoordinator.swift:57-60 |
| E5 | Medio | Callbacks reenviados con `Task { @MainActor }` sin orden garantizado | ProScanCoordinator.swift:77-98 |
| E6 | Medio | El arranque depende de `asyncAfter(0.3)` para esperar el teardown de RoomPlan | ARPointCloudSession.swift:143 |
| E7 | Medio | El FPS del HUD mide la pantalla (CADisplayLink), no ARKit: puede marcar 60 fps con la captura atascada | PerformanceMonitor.swift:24, 55 |
| E8 | Bajo | Viewport y orientación congelados en `start()`; deuda para iPad/landscape | ARPointCloudSession.swift:20-21, 130 |

## Configuración de ARSession

Correcto: `sceneReconstruction = .meshWithClassification`, `worldAlignment = .gravity` explícito,
ambas semánticas de depth con preferencia por la suavizada, reescalado de intrínsecos.

Ausente o sin fijar:
- `videoFormat` — ARKit elige alta resolución que el pipeline no aprovecha (ancho de banda, energía, calor).
- `planeDetection` — no se activa. `ARPlaneAnchor` es la primitiva natural para muros/pisos y es lo que
  más directamente sirve al objetivo de planos 2D.
- `isAutoFocusEnabled` — queda en `true`; el autofoco altera los intrínsecos entre frames.
- `initialWorldMap` — sin continuidad entre pases.
- Degradación a `.mesh` cuando `.meshWithClassification` no está soportado.

Conclusión: correcta para lo que hace hoy (nube densa en pase corto). **No** está configurada para
procesar planos en tiempo real ni para presupuesto energético.

## El bloqueo estructural

`FloorPlan.init(structure:)` consume solo un `CapturedStructure` de RoomPlan. ProScan corre después,
en otra ARSession con `.resetTracking`. El propio código lo reconoce (PointCloudSceneView.swift:11).
Consecuencias:

- El plano nunca puede validarse ni refinarse contra la nube.
- RoomPlan es interiores/habitaciones: no cubre fachadas, excavaciones ni estructuras — no cubre obra civil.
- La precisión de ProScan (confianza real, LAS 1.4, CRS local, puntos de control) no llega al plano acotado.

Para nivel comercial en obra civil, el plano debe derivarse de la nube propia, con RoomPlan como
fuente auxiliar de interiores.

## Plan de acción

**F0 — Instrumentar antes de tocar nada (~1 semana).** `os_signpost` en `processMeshAnchor`,
`processFrame` y `currentMeshPoints`; perfilar 60 s en dispositivo real; añadir frames-de-ARKit/s y
latencia del delegate al PerformanceMonitor; registrar thermalState y memoria. Sin línea base todo
lo demás es opinión.

**F1 — Desbloquear el hilo (~2 semanas). C1·C2·C4·C5·C7.** Sacar la malla del delegate queue (copiar
buffers y encolar; colas separadas para depth y malla); 8 contadores fijos en `Cell`; VoxelAccumulator
incremental con generación por ancla; autosave sobre snapshot inmutable con `FileHandle`; `ingest`
fuera del main actor y métricas a 2 Hz. Punto de control: si la latencia del delegate no bajó, el
resto espera.

**F2 — Estabilidad y honestidad del dato (~2 semanas). E1·E2·E3·C6·C8 + configuración.** Implementar el
gating angular; fijar `videoFormat` y quitar `.occlusion`; decidir qué hace la confianza (subir
cobertura o marcar desconocido — nunca 0,5 inventado en un LAS); unificar clave de vóxel y regla de
dedup; cachear thermalState; Timer a `.common`; A/B de autofoco contra objeto de dimensiones conocidas.

**F3 — Continuidad del marco de coordenadas (~3 semanas). E4·E6, habilita F4.** Persistir y recargar
`ARWorldMap` (reutilizando `RelocalizationConfirmation`); reemplazar el `asyncAfter(0.3)` por una
máquina de estados; compartir world map entre RoomPlan y ProScan; sustituir el límite de 40 s por un
presupuesto de deriva medible.

**F4 — Plano 2D desde la nube propia (~4-6 semanas). Objetivo #2, desbloquea #3.** Activar
`planeDetection`; RANSAC sobre posiciones y normales (las normales ya se calculan y exportan); corte
horizontal → proyección → detección de líneas → esquinas → polígono (reutilizando `PlaneSnapping`,
`dominantGridAngle`, `weldCorners`); publicar con `isExtrapolated`/`confidence`/`isReliable`.

**F5 — Estructura enterprise (continuo).** Partir `ARPointCloudSession` (690 líneas, ~7
responsabilidades); convertir el núcleo puro de Capture3D en Swift Package local (hoy el target de
tests lista 17 archivos a mano en project.yml:59-75); protocolo `ScanSource` con implementación falsa
para probar el pipeline sin dispositivo; strict concurrency checking por fases.

## Lo que no hay que tocar

- La separación entre matemática pura y ARKit (ProScanConfig, CameraUnprojection, ConfidenceGrid,
  VoxelAccumulator, FaceClassificationVoting no importan ARKit y por eso se prueban sin dispositivo).
- La disciplina de comentarios: cada constante dice si viene de Apple, de una medición o de una
  estimación pendiente de calibrar.
- El manejo de convenciones de coordenadas (eje Y imagen/cámara; +Z arriba diferido al export).
- La renuencia a fabricar precisión: no superponer nube sobre muros de RoomPlan, marcar bordes
  inferidos, degradar a punto crudo cuando el ajuste de plano no es confiable.
