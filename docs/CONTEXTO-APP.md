# Structura — contexto de la app

> Documento de contexto para pasar a un asistente externo (Gemini u otro) antes
> de pedirle ayuda sobre este proyecto. Resume qué es la app, cómo está armada y
> qué convenciones hay que respetar. Estado: rama `claude/app-summary-gemini-by375a`.

---

## 1. Qué es

**Structura** es una app iOS de escaneo LiDAR para **ingeniería civil y
construcción**. El usuario escanea un ambiente (o varios) con un iPhone/iPad Pro
y obtiene:

- un **modelo 3D** (USDZ) tipo "casa de muñecas",
- un **plano 2D acotado** con medidas de paredes, puertas y ventanas,
- una **nube de puntos** de grado topográfico (PLY + LAS 1.4) exportable a
  AutoCAD / Civil3D / CloudCompare.

La premisa del producto es que **la precisión medible importa más que las
features**: la app declara explícitamente lo que midió y lo que infirió, y nunca
afirma una exactitud que no verificó.

Toda la UI y los comentarios de dominio están **en español**.

---

## 2. Stack y configuración

| Aspecto | Valor |
|---|---|
| Lenguaje / UI | Swift 5, SwiftUI (+ SceneKit, RealityKit, Metal) |
| Frameworks Apple | RoomPlan, ARKit, CoreLocation, CoreHaptics, QuickLookThumbnailing, PDFKit/UIGraphics |
| Target mínimo | iOS 17.0 |
| Dispositivos | iPhone/iPad **con LiDAR obligatorio** (`UIRequiredDeviceCapabilities: arkit, lidar`), solo vertical, full screen |
| Bundle ID | `com.cristiangavidia.structura` |
| Proyecto | **XcodeGen** — `project.yml` es la fuente de verdad; tras agregar archivos hay que correr `xcodegen generate`. **No editar el `.xcodeproj` a mano.** |
| Dependencia externa | **RevenueCat** (`purchases-ios` ≥ 5.0.0) — única dependencia de terceros |
| Tamaño | ~8.5k líneas Swift, ~70 archivos fuente |

Build de verificación:
`xcodebuild -scheme Structura -destination 'generic/platform=iOS' build`

---

## 3. Arquitectura de carpetas

```
Structura/
├── StructuraApp.swift        @main — decide Onboarding vs Home, inyecta PurchaseManager
├── Onboarding/               3 slides de bienvenida (AppStorage: hasCompletedOnboarding)
├── Home/                     HomeView: grilla de escaneos, botón +, paywall gate
├── Capture/                  Pase 1 — RoomPlan (RoomCaptureSession) + HUD
│   └── HUD/                  MetricsHUD, RadialToolMenu, HUDStyle
├── Capture3D/                Pase 2 — "Pro Scan": ARKit crudo + nube de puntos
├── Result/                   Visualización: dollhouse 3D, plano 2D, nube de puntos, medición
├── Export/                   PDF, CSV, y Export/PointCloud/ (PLY, LAS, metadatos, CRS)
├── Models/                   ScanRecord, ScanStore (persistencia), FloorPlan (geometría 2D)
├── Purchases/                PurchaseManager (RevenueCat) + PaywallView
├── Haptics/                  Motor CoreHaptics + patrones de feedback de captura
├── Settings/                 Unidades, estado de suscripción, restaurar, legal
└── Support/                  Theme, GraphPaperBackground, CornerBrackets, UnitSystem
StructuraTests/               Bundle de pruebas lógicas SIN host de app (ver §8)
```

---

## 4. Los dos pases de captura

ARKit permite **una sola sesión activa por proceso**, así que los dos pases
nunca corren a la vez.

### Pase 1 — RoomPlan (obligatorio)
`Capture/CaptureView.swift` + `RoomCaptureRepresentable`.

- Usa `RoomCaptureSession` con coaching en pantalla y háptica.
- **Multi-ambiente**: al terminar un cuarto se ofrece "agregar otro ambiente" o
  "finalizar"; todo termina pasando por `StructureBuilder(options: [.beautifyObjects])`
  para producir un `CapturedStructure` único (un cuarto o una casa entera usan el
  mismo camino de código).
- El resultado se guarda como USDZ + JSON de la estructura + miniatura PNG.

### Pase 2 — "Pro Scan" (opcional, sobre un escaneo ya guardado)
`Capture3D/` — se lanza desde `ResultView` ("Mejorar con Pro Scan").

Pipeline: **captura → gating → desproyección → acumulación por vóxel → export**.

- `ARPointCloudSession` (~690 líneas, el archivo más denso del proyecto):
  - `worldAlignment = .gravity` (vertical a plomo; **no** `.gravityAndHeading`, o
    sea **no hay referencia de norte**),
  - `sceneReconstruction = .meshWithClassification` cuando el dispositivo lo soporta,
  - `frameSemantics`: `.smoothedSceneDepth` con fallback a `.sceneDepth`.
  - **Dos pipelines paralelos y distintos**:
    1. *Depth crudo por frame* (~6 Hz) → solo alimenta el HUD de confianza/cobertura
       y la háptica de muestreo. **No se exporta.**
    2. *Malla fusionada de ARKit* (`ARMeshAnchor`) → **esto es lo que se exporta y
       se visualiza**, porque ARKit ya integró muchos frames en un volumen de vóxeles
       y es mucho más estable que cualquier depth map individual.
  - Almacenamiento **por anchor** (`meshPointsByAnchor`): ARKit reemplaza/elimina
    anchors al re-triangular, así que cada evento debe reemplazar exactamente la
    contribución previa de ese anchor. `currentMeshPoints()` re-funde todo por un
    `VoxelAccumulator` fresco en cada llamada (fusiona vértices duplicados de
    anchors vecinos en vez de concatenarlos).
  - Contador incremental `meshPointCountTotal` en lockstep, para que el HUD no
    copie toda la nube cada segundo.
- `ProScanCoordinator`: orquesta sesión + store + métricas + háptica; sondea 1 Hz.
- `RelocalizationConfirmation`: tras una interrupción, el frame de coordenadas se
  marca **roto** y no se acumula nada hasta tener 60 frames `.normal` consecutivos
  (~1 s). La UI muestra "reubicando…" en vez de fingir que todo está bien.
- **Guardas de recursos** (1 Hz): se detiene solo si hay < 200 MB de disco,
  batería < 10 % desconectado, o `thermalState == .critical` — siempre exportando
  lo ya capturado, nunca perdiéndolo.
- **Autoguardado** cada 10 s: snapshot PLY en disco adjunto al `ScanRecord`, para
  sobrevivir a un kill de la app.
- **Aviso de deriva**: Pro Scan no tiene loop closure ni `ARWorldMap`, así que a
  los 40 s avisa (háptica + banner) de que la deriva ya puede ser notable.

---

## 5. `ProScanConfig` — el archivo que hay que leer primero

`Capture3D/ProScanConfig.swift` es la **única fuente de verdad** de toda constante
física/numérica del pipeline. Cada valor documenta de dónde sale y si es un dato
de hardware, un valor ya en producción, o un *placeholder de ingeniería pendiente
de calibración en campo* (varios lo son y lo dicen explícitamente).

Valores clave:

| Constante | Valor | Razón |
|---|---|---|
| `validDepthRangeMeters` | 0.25 – 5.0 m | rango práctico del LiDAR de Apple |
| `minimumNormalizedConfidence` | 0.5 (= `.medium`) | `ARConfidenceLevel` Low=0/Medium=1/High=2 |
| `voxelSizeMeters` | 0.02 m | deduplicación espacial |
| `maximumAngularVelocityRadiansPerSecond` | 1.0 | descartar motion blur (placeholder) |
| `depthSampleHz` | 6 Hz | el depth crudo solo alimenta el HUD |
| `meshVertexStride` | 3 (×2 en `.serious`, ×4 en `.critical`) | presupuesto adaptativo por `thermalState` |
| `maximumMeshPointBudget` | 4 000 000 | techo fijo provisional |
| `lasScaleFactorMeters` | 0.001 | LAS 1.4 §2.4, 1 mm |
| `recommendedMaxDurationSeconds` | 40 | umbral de riesgo de deriva |
| `autosaveIntervalSeconds` | 10 | supervivencia ante kill |
| `planeFitNeighborhoodRadiusMeters` | 0.05 | snap a plano en medición |
| `coverageVoxelSizeMeters` | 0.10 | estimación de cobertura/huecos (más grueso a propósito) |

**Regla:** ninguna de estas constantes se re-declara inline en ningún otro lugar
de `Capture3D/` ni `Export/PointCloud/`.

---

## 6. Sistemas de coordenadas y unidades (crítico)

- **Unidades internas: SIEMPRE metros.** La conversión a pies vive únicamente en
  la UI (`Support/UnitSystem.swift`).
- **ARKit**: diestro, **+Y arriba**, cámara mirando a −Z al iniciar la sesión.
- **`TopographicAxisConvention`**: rota a diestro **+Z arriba** (CAD/topografía)
  con `(x, y, z) → (x, −z, y)` — determinante +1, es rotación, no espejo.
- **Solo `LASExporter` aplica esa rotación.** `PLYExporter` se queda a propósito
  en el frame nativo de ARKit (para el visor SceneKit interno y para CloudCompare/
  MeshLab, agnósticos al eje).
- **No hay norte.** Como la captura es `.gravity` y no `.gravityAndHeading`, el
  eje horizontal apunta a donde miraba la cámara al arrancar. `LocalEngineeringCRS`
  declara un WKT1 `LOCAL_CS` honesto que **omite deliberadamente las etiquetas
  `AXIS NORTH/EAST`** en vez de afirmar una orientación que nunca se midió.
- `ControlPointTransform` permite anclar el **origen** a un punto de control real
  del proyecto — es **solo traslación**, no verifica orientación, y el WKT lo dice.

---

## 7. Exportación

| Formato | Archivo | Notas |
|---|---|---|
| PDF | `Export/PDFExporter.swift` | plano acotado, US Letter a 72 pt/in |
| CSV | `Export/CSVExporter.swift` | tabla de medidas |
| USDZ | generado por RoomPlan en `ScanStore.save` | modelo 3D |
| PLY | `Export/PointCloud/PLYExporter.swift` | binario, frame ARKit nativo, con `confidence` por punto |
| LAS | `Export/PointCloud/LASExporter.swift` | **LAS 1.4, PDRF 7**; header público de 375 B, registro de 36 B, VLR OGC WKT obligatorio — verificado byte a byte contra "LAS Specification 1.4 - R15" de ASPRS. Sin dependencias, sin LAZ. |
| JSON | `ScanMetadataReport` | sidecar: dispositivo, versión iOS, fecha, duración, calidad de tracking, nº de puntos, densidad/m², confianza media, unidades y CRS declarado |

`PointCloudExportCoordinator` es un `actor`: toda la serialización pesada corre
fuera del main thread.

Caveat conocido y documentado: el GPS time del LAS es "Adjusted Standard GPS Time"
sin corrección de leap seconds (~18 s) — sirve como registro de procedencia, no
como sincronización topográfica real.

---

## 8. Visualización, medición y QA (`Result/`)

`ResultView` tiene tres pestañas: **3D** (dollhouse SceneKit), **Plano** (2D
acotado) y **Color real** (nube de puntos, solo si existe un Pro Scan).

- `FloorPlan` proyecta el `CapturedStructure` a 2D con un **pase de escuadrado**
  que corrige ruido de escaneo **sin ocultar** geometría genuinamente fuera de
  escuadra. Distingue explícitamente:
  - `isExtrapolated` → RoomPlan nunca vio ambos extremos ⇒ medida inferida, se
    dibuja con "~" y línea punteada;
  - `isOutOfSquare` → desviación real más allá de la tolerancia.
  - La confianza cruda de RoomPlan se muestra como dato aparte, **no** se mezcla
    en `isReliable` (RoomPlan casi nunca reporta `.high`, gatear ahí marcaba todo
    como no fiable).
- **Medición tap-to-measure** sobre la nube (`PointCloudRaycast` + `PlaneSnapping`):
  se ajusta un plano local a 5 cm; si la dispersión angular de normales supera
  ~15° o hay menos de 6 vecinos, **no inventa plano** y usa el punto crudo.
  El HUD marca con ✓ verde solo cuando ambos puntos hicieron snap.
- **Calibración verificable** (`MeasurementCalibration`): el usuario mide algo de
  medida conocida y la app reporta el error absoluto y porcentual. Es la prueba
  de que "preciso" no es solo una afirmación.
- **Panel QA**: puntos, confianza media, calidad de tracking, duración, cobertura
  estimada (`ScanCoverageEstimator`, vóxeles de 10 cm) y aviso de deriva si el
  escaneo superó los 40 s.

---

## 9. Monetización

- RevenueCat, envuelto en `PurchaseManager` (singleton `@MainActor`) que expone
  esencialmente una sola cosa al resto de la app: `isPremium`.
- **No hay un entitlement unificado**: cada plan tiene el suyo ("Structura
  Semanal", "Structura Anual"); cualquiera activo cuenta como premium.
- Modelo v1: **el primer escaneo es gratis; escanear más requiere premium, y
  TODA exportación (PDF/CSV/USDZ/PLY/LAS) está detrás del paywall.**
- Si la API key no está configurada, el SDK nunca se configura y todos son
  tratados como no-premium de forma segura (el paywall se muestra igual).

---

## 10. Pruebas

`StructuraTests` es un bundle de **pruebas lógicas sin host de app**: el target
`Structura` exige capacidades `arkit`/`lidar`, así que no puede instalarse en el
simulador ni servir de host. La solución es que el bundle de tests **compila
directamente como fuentes propias** los archivos Swift puros bajo prueba (los
lista `project.yml`) — sin módulo de app, sin dispositivo, sin host.

~103 tests cubriendo la matemática: desproyección de cámara y reescalado de
intrínsecos, grid de confianza, hashing/fusión por vóxel, cabeceras y round-trip
PLY/LAS, convención de ejes topográficos, transform de punto de control,
raycast, ajuste de plano, calibración de medición, cobertura y
confirmación de relocalización.

**Regla del proyecto: todo cambio en el pipeline de puntos requiere una prueba
unitaria numérica.**

---

## 11. Reglas de trabajo del repo

1. XcodeGen: tras tocar archivos nuevos, `xcodegen generate`. Nunca editar el
   `.xcodeproj` a mano.
2. Unidades internas siempre en metros; pies solo en la UI.
3. ARKit: `worldAlignment` `.gravity` como mínimo. Nunca acumular puntos con
   `trackingState != .normal` ni con confianza < `.medium`.
4. No inventar APIs de ARKit/Metal — verificar contra el SDK instalado.
5. Nada de procesamiento de nube de puntos en el hilo principal.
6. Cada constante física va en `ProScanConfig`, con comentario que explique su
   origen y si es un placeholder.
7. Documentar en comentarios toda suposición sobre sistemas de coordenadas.
8. **Preferir la honestidad sobre la apariencia**: si un dato es inferido,
   aproximado o no verificado, la UI y los metadatos deben decirlo.
9. Responder en español.

---

## 12. Limitaciones conocidas (no son bugs, son alcance declarado)

- Sin loop closure, sin `ARWorldMap`, sin persistir/reanudar sesión ⇒ la deriva
  crece con la duración; la mitigación es mantener los pases cortos (≤ 40 s).
- Sin referencia de norte (ver §6).
- Varias constantes de `ProScanConfig` son placeholders de ingeniería pendientes
  de calibración en campo, y así están marcados en el código.
- El presupuesto de puntos es un techo fijo, no una medición real de presión de
  memoria.
- Los exportadores construyen el archivo completo en memoria.
- El pipeline actual corre en CPU sobre colas dedicadas; no hay compute Metal
  para la desproyección.
