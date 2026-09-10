# Notas para el equipo de revisión de App Store — Structura

Este documento está pensado para copiarse (total o parcialmente) en el campo
**"App Review Information" → "Notes"** de App Store Connect al enviar una
build a revisión. También sirve como referencia interna antes de cada envío.

## 1. Requisito de hardware: LiDAR real, no es opcional

Structura **requiere** un sensor LiDAR. Sin él, la app no puede escanear —
no es una función degradada, es la función central de la app.

- `Info.plist` declara `arkit` y `lidar` en `UIRequiredDeviceCapabilities`,
  así que la App Store no debería ofrecer instalar la app en un dispositivo
  sin LiDAR.
- Si de todas formas se evalúa en un dispositivo o Simulator sin LiDAR, la
  app muestra una pantalla explicativa ("Dispositivo no compatible") en vez
  de fallar o quedar en blanco — no es un bug, es el comportamiento
  esperado en ese caso (`ScanRequirements`/`RequirementsBlockedView`).

**Por favor probar en un dispositivo físico con LiDAR**: iPhone 12 Pro/Pro
Max o más reciente (línea Pro), o iPad Pro 2020 o más reciente. El
Simulator de Xcode no expone LiDAR ni ARKit real, así que no sirve para
probar el flujo de captura.

## 2. Cómo probar el flujo principal, sin necesidad de comprar nada

La app permite un escaneo completo gratis, de punta a punta, sin pedir
suscripción:

1. Abrir la app → pantalla de bienvenida (3 diapositivas) → "Comenzar" →
   se solicita el permiso de cámara (necesario para escanear).
2. Desde la pantalla principal, tocar el botón "+" para iniciar un
   escaneo. Este primer pase usa **RoomPlan** (framework de Apple): apuntar
   la cámara a las paredes de un ambiente real y moverse despacio; RoomPlan
   reconoce muros, puertas y ventanas automáticamente.
3. Al finalizar, el escaneo se guarda y se puede ver en dos formas sin
   pagar nada: modelo 3D ("dollhouse") y plano 2D acotado, con sus medidas.

**Esto no requiere ninguna compra.** El primer escaneo es gratuito por
diseño (`HomeView.freeScanCount = 1`).

## 3. Qué está detrás de la suscripción (dónde va a aparecer el paywall)

A partir de ahí, cualquiera de estas acciones muestra la pantalla de
suscripción (`PaywallView`):

- Iniciar un **segundo** escaneo (o cualquiera posterior).
- Iniciar **Pro Scan** (el segundo pase, de captura LiDAR densa —
  el botón "Mejorar con Pro Scan" dentro del escaneo ya guardado).
- **Exportar** en cualquier formato (PDF del plano, modelo 3D USDZ, nube de
  puntos PLY o LAS 1.4) — incluso sobre el escaneo gratuito.

Es decir: el nivel gratuito permite escanear una vez y ver el resultado en
la app; capturar de nuevo, usar Pro Scan, o sacar cualquier archivo fuera
de la app requiere suscripción.

## 4. Cómo probar la compra (sandbox)

Structura usa **RevenueCat** sobre StoreKit/In-App Purchase de Apple —no
hay procesamiento de pagos propio ni de terceros fuera del sistema de
Apple. Hay dos planes (semanal y anual), ambos gestionados como
suscripciones auto-renovables estándar de App Store.

**Para el equipo de revisión:** recomendamos iniciar sesión en el
dispositivo de prueba con un **Sandbox Tester** de App Store Connect antes
de tocar "Suscribirme" en el paywall — así la compra se completa contra el
entorno sandbox de Apple sin cargo real, y el flujo completo (compra,
restaurar compras, cancelar desde Ajustes) se puede probar de punta a
punta.

> ⚠️ **Pendiente de completar antes de enviar a revisión:** este documento
> debe incluir acá un usuario Sandbox Tester real (correo + contraseña)
> creado en App Store Connect → Users and Access → Sandbox → Testers,
> específicamente para esta revisión. No se incluye uno de ejemplo en el
> repositorio a propósito — nunca debe haber una credencial, ni siquiera
> de sandbox, commiteada en el control de versiones.

Si la compra en sandbox no se completa por cualquier motivo, el botón
"Restaurar compras" del paywall usa `Purchases.shared.restorePurchases()`
(RevenueCat) tal como lo haría cualquier usuario real que reinstale la app.

## 5. Permisos que la app solicita, y por qué

| Permiso | Cuándo se pide | Por qué |
|---|---|---|
| Cámara (`NSCameraUsageDescription`) | Último paso del onboarding, antes de cualquier intento de escanear | Es cómo Structura ve el ambiente para escanearlo junto con el sensor LiDAR — sin este permiso la app no puede funcionar en absoluto. |
| Ubicación mientras se usa (`NSLocationWhenInUseUsageDescription`) | Al finalizar un escaneo Pro Scan, antes de exportar | **Opcional.** Se usa solo para anotar la ubicación aproximada en los metadatos del archivo exportado (útil para levantamientos topográficos con referencia geográfica). Negar este permiso no bloquea nada: el escaneo y la exportación funcionan igual, simplemente sin esa coordenada en el archivo. |

Si el usuario niega la cámara, la app no queda en un estado roto ni
confuso: muestra una pantalla explicando qué pasó y un botón directo a
Ajustes para revertirlo (`RequirementsBlockedView`).

## 6. Procesamiento y datos

- Todo el procesamiento de la captura (RoomPlan y Pro Scan/LiDAR) ocurre
  **en el dispositivo**. Los escaneos no se suben a ningún servidor de
  Structura — no existe tal servidor; la app no tiene backend propio.
- RevenueCat recibe únicamente lo necesario para validar el estado de
  suscripción (recibos de StoreKit), no el contenido de los escaneos.
- La coordenada de ubicación (§5) queda embebida solo en el archivo que el
  usuario decide exportar y compartir explícitamente; no se envía a
  ningún servicio por su cuenta.

## 7. Contacto

Ante cualquier duda durante la revisión, Cristian Gavidia está disponible
en la dirección de correo asociada a la cuenta de Apple Developer de esta
app.
