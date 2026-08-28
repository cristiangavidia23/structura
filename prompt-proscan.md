# Prompts para mejorar ProScan (Structura) en Claude Code

> Contexto detectado: proyecto Swift/iOS gestionado con **XcodeGen** (`project.yml`).
> Módulo ProScan: `Structura/Capture3D/` (ARPointCloudSession, ProScanCaptureView,
> ProScanCoordinator, PointCloudFrame, PointCloudStore, ARCameraPassthroughView,
> PerformanceMonitor), exportadores en `Structura/Export/PointCloud/`
> (PLY, LAS, reader, coordinator, location provider) y visor en
> `Structura/Result/PointCloudSceneView.swift`.

---

## PASO 1 — Prompt de auditoría y plan

**Úsalo en modo plan (Shift+Tab hasta "plan mode"). No dejes que escriba código todavía.**

```text
Actúa como un ingeniero senior de visión 3D / geomática con experiencia real en
ARKit + Metal y en producción de nubes de puntos de grado topográfico.

OBJETIVO
Auditar el módulo ProScan de esta app (escáner LiDAR para iPhone Pro / iPad Pro)
y producir un plan de mejora que lo lleve de "demo funcional" a "herramienta de
campo confiable": precisa, repetible, a prueba de errores de usuario, y con
exportables que un ingeniero civil pueda meter en AutoCAD/Civil3D/CloudCompare
sin retrabajo.

ALCANCE DEL CÓDIGO A LEER (léelo completo antes de opinar)
- Structura/Capture3D/*.swift
- Structura/Export/PointCloud/*.swift
- Structura/Result/PointCloudSceneView.swift y ResultView.swift
- Structura/Models/ScanRecord.swift, ScanStore.swift
- Structura/Info.plist y project.yml

EJES DE LA AUDITORÍA (evalúa cada uno con evidencia del código, citando
archivo:línea, y clasifica cada hallazgo como CRÍTICO / IMPORTANTE / MEJORA)

1. Configuración de ARKit
   - ¿Se usa ARWorldTrackingConfiguration con worldAlignment = .gravity
     (o .gravityAndHeading)? Para uso en ingeniería el eje Z/Y debe estar a plomo:
     verifica que no quede alineado a la cámara.
   - frameSemantics: ¿.sceneDepth y/o .smoothedSceneDepth? ¿Se elige según el caso
     (smoothed = menos ruido temporal, sceneDepth = más fiel a la geometría real)?
   - sceneReconstruction: ¿.meshWithClassification cuando el dispositivo lo soporta?
     ¿Se usa el mesh para raycast/medición y para exportar malla, o se desperdicia?
   - videoFormat: ¿se selecciona el formato de mayor resolución disponible para el
     color de los puntos? ¿autoFocus está en el estado correcto para la escena?
   - Guardas de capacidad: supportsSceneReconstruction, supportsFrameSemantics,
     y degradación elegante en dispositivos sin LiDAR.

2. Calidad del dato por punto (aquí se gana o se pierde la precisión)
   - ¿Se filtra por ARConfidenceLevel del confidenceMap? Mínimo .medium; con
     opción de exigir .high en modo "precisión".
   - ¿Se recorta el rango de profundidad? El LiDAR de Apple es fiable ~0.25–5 m;
     todo lo demás es extrapolación ruidosa y debe descartarse o marcarse.
   - Desproyección: ¿los intrínsecos de la cámara se reescalan correctamente a la
     resolución del depthMap (256x192) antes de desproyectar? Este es el error
     silencioso más común y produce un sesgo de escala/inclinación.
   - ¿Se descartan frames con tracking degradado (camera.trackingState != .normal),
     con velocidad angular/lineal alta (motion blur), o con exposición mala?
   - ¿El color se muestrea del capturedImage (YCbCr biplanar) con la conversión y
     las coordenadas correctas, o se inventa?

3. Acumulación y densidad
   - ¿Hay deduplicación espacial (voxel grid / spatial hashing) con media
     ponderada por confianza por vóxel, o solo se apilan puntos repetidos?
     Sin esto la nube pesa 10x y es menos precisa, no más.
   - ¿Existe un presupuesto de puntos adaptativo según memoria y thermalState?
   - ¿El pipeline corre en GPU (Metal compute) o hace copias CPU por frame?

4. Deriva (drift) y consistencia global
   - ¿Se mide y se le muestra al usuario la calidad de tracking a lo largo de la
     sesión? ¿Se pausa y se pide relocalización al perder tracking?
   - ¿Se puede persistir/reanudar con ARWorldMap?
   - ¿Hay alguna verificación de cierre de bucle o al menos una advertencia cuando
     la sesión es tan larga que la deriva ya es inaceptable?

5. Medición y exactitud verificable
   - ¿Las mediciones usan raycast contra la malla/planos de ARKit con snap a
     plano, arista y esquina, o son puntos flotantes a pulso?
   - ¿Existe alguna herramienta de verificación: medir una distancia patrón
     conocida y reportar el error? Sin esto, "preciso" es una afirmación sin prueba.

6. Exportación
   - PLY/LAS: ¿binario little-endian correcto? ¿Cabeceras válidas?
   - LAS: ¿scale/offset en double para no perder precisión al convertir a int32?
     ¿Versión, point data record format y CRS declarados? ¿Georreferenciación
     opcional con CLLocation + rumbo, con la exactitud reportada en metadatos?
   - ¿Se exporta también malla (OBJ/USDZ) y un reporte de metadatos
     (fecha, dispositivo, nº de puntos, densidad, confianza media, duración,
     calidad de tracking, unidades, sistema de coordenadas)?
   - Unidades: metros siempre en el archivo; la conversión a pies solo en UI.

7. Robustez / "infalible"
   - Permisos, interrupciones (llamada, background), sesión ARKit que falla,
     memoria baja, sobrecalentamiento, batería baja, almacenamiento lleno:
     ¿cada uno tiene una ruta de recuperación que NO pierda el escaneo en curso?
   - ¿Hay autoguardado incremental durante la captura?

8. UX de captura guiada
   - Retroalimentación en tiempo real: cobertura, densidad, "vas muy rápido",
     "acércate", "poca luz", zonas sin datos resaltadas.
   - Háptica y audio como refuerzo (ya existe el módulo Haptics: úsalo).

ENTREGABLE DE ESTE PASO (no escribas código todavía)
1. Tabla de hallazgos: archivo:línea | severidad | qué está mal | impacto real en
   la precisión o en la confiabilidad.
2. Arquitectura objetivo del pipeline ProScan, en capas
   (captura → filtrado → desproyección GPU → acumulación por vóxel → índice
   espacial → medición → export), indicando qué archivos se crean, cuáles se
   modifican y cuáles se eliminan.
3. Plan por fases, ordenado por (impacto en precisión ÷ riesgo). Cada fase debe
   ser compilable y probable por separado.
4. Para cada fase: cómo se verifica que funcionó, incluyendo pruebas numéricas
   con datos sintéticos (p. ej. un depthMap de un plano a 2.000 m debe producir
   un plano ajustado con RMS < X mm).
5. Riesgos y decisiones que requieren mi opinión antes de implementar.

REGLAS
- No inventes APIs. Si no estás seguro de una firma de ARKit/Metal, dilo
  explícitamente y verifícala en el SDK instalado o en la documentación de Apple
  antes de proponerla.
- Prioriza precisión física y correctitud numérica sobre features vistosas.
- Nada de reescrituras totales: propone cambios incrementales sobre el código que
  ya existe.
- Cuando dos enfoques compitan, muestra el trade-off en una línea y recomienda uno.
```

---

## PASO 2 — Prompt de implementación (uno por fase)

**Después de aprobar el plan. Repítelo cambiando el número de fase.**

```text
Implementa la FASE N del plan aprobado. Solo esa fase.

CONDICIONES DE ENTREGA
- Código Swift idiomático, concurrencia con async/await + actors donde aplique,
  sin retain cycles en los delegados de ARSession.
- Todo el trabajo pesado por frame en Metal o en una cola dedicada; el hilo
  principal nunca debe hacer procesamiento de nube de puntos.
- Cada constante física (rango válido de profundidad, umbral de confianza,
  tamaño de vóxel, umbral de velocidad angular) va en un único archivo de
  configuración con nombre y comentario que explique de dónde sale el valor.
- Añade pruebas unitarias para toda la matemática: desproyección, reescalado de
  intrínsecos, vóxel hashing, ajuste de plano, escritura de cabeceras PLY/LAS.
- Documenta en comentarios las suposiciones sobre sistemas de coordenadas
  (ARKit es Y-arriba, diestro; el exportador destino puede ser Z-arriba).

VERIFICACIÓN ANTES DE DARME LA FASE POR TERMINADA
1. xcodegen generate
2. xcodebuild -scheme Structura -destination 'generic/platform=iOS' build
3. Corre las pruebas unitarias y pégame la salida.
4. Dame un resumen de 5 líneas: qué cambió, qué mejora concreta en precisión o
   robustez produce, y qué debo probar yo en campo con el dispositivo.

Si algo del plan ya no tiene sentido al ver el código de cerca, detente y
dímelo antes de improvisar.
```

---

## PASO 3 — Archivo `CLAUDE.md` en la raíz del proyecto

Pégalo en `/Users/cristiangavidia/Documents/Structura/CLAUDE.md` para que aplique en
todas las sesiones sin repetirlo:

```markdown
# Structura — reglas de trabajo

- App iOS de escaneo LiDAR. Público objetivo: ingeniería civil y construcción.
  La precisión medible importa más que las features.
- Proyecto generado con XcodeGen: tras tocar archivos nuevos, correr
  `xcodegen generate`. No editar el .xcodeproj a mano.
- Build de verificación:
  `xcodebuild -scheme Structura -destination 'generic/platform=iOS' build`
- Unidades internas: SIEMPRE metros. La conversión a pies vive solo en la UI.
- ARKit: worldAlignment .gravity como mínimo. Nunca acumular puntos con
  trackingState != .normal ni con confianza < .medium.
- No inventar APIs de ARKit/Metal. Verificar contra el SDK antes de proponer.
- Todo cambio en el pipeline de puntos requiere una prueba unitaria numérica.
- Responder en español.
```

---

## Modelo y esfuerzo recomendados

| Etapa | Modelo | Esfuerzo | Por qué |
|---|---|---|---|
| Paso 1 — auditoría y plan | **Opus** (el más capaz de tu selector `/model`) | **Alto / máximo** | Es razonamiento geométrico, numérico y de arquitectura. Aquí es donde se decide si la app es precisa; un error de criterio aquí se paga en todas las fases. |
| Paso 2 — fases con matemática (desproyección, vóxel, ajuste de planos, LAS) | **Opus** | **Medio-alto** | Correctitud numérica; un signo invertido no falla el build, falla en campo. |
| Paso 2 — fases mecánicas (UI del HUD, refactors, mover constantes) | **Sonnet** | **Bajo-medio** | Trabajo mecánico; Opus ahí solo gasta cuota. |
| Errores de compilación, ajustes menores | **Sonnet** | **Bajo** | Ciclo rápido de iteración. |
| Revisión final antes de publicar | **Opus** + subagente de revisión | **Alto** | Segunda mirada independiente sobre el pipeline completo. |

**Tres reglas de operación que valen más que el modelo:**

1. Corre el Paso 1 en **modo plan** (Shift+Tab). No dejes que empiece a editar hasta que apruebes el plan.
2. **Una fase por sesión**, y `/clear` entre fases. El contexto sucio es la causa número uno de que un agente rompa código que ya funcionaba.
3. Haz commit al terminar cada fase verde. Así cualquier fase mala se revierte con un comando.
