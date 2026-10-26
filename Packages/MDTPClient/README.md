# MDTPClient

Libreria Swift del protocolo MDTP v1 sobre HTTP y Protocol Buffers. La version
del protocolo se identifica con `/v1/` en la URL: cada endpoint determina el
mensaje de solicitud y el de respuesta.

## Requisitos

- Swift 6.2 o superior.
- SwiftProtobuf 1.39.0, resuelto por SwiftPM desde
  `https://github.com/apple/swift-protobuf.git`.
- PowerShell 5.1 o superior solo para los scripts de Windows.
- `protoc` y `protoc-gen-swift` unicamente si se van a regenerar los modelos.

La compilacion normal no necesita `protoc`: usa
`Sources/MDTPClient/protocol_v1_completo.pb.swift`, ya generado.

## Estructura

```text
proto/
  protocol_v1_completo.proto          Contrato de los mensajes
scripts/
  setup-tools.ps1                     Instala protoc y compila protoc-gen-swift
  generate-proto.ps1                  Regenera o verifica los modelos Swift
Sources/MDTPClient/
  protocol_v1_completo.pb.swift       Modelos generados (no editar a mano)
  ProtocolTypes.swift                 Alias, defaults y categorias
  MDTPConfiguration.swift             URL base, tiempos y encabezados
  HTTPTransport.swift                 Transporte HTTP y errores de red
  MDTPClient.swift                    Cliente y despacho por endpoint
  MDTPClient+Transfers.swift          Registro y transferencias
  MDTPClient+Queries.swift            Dispositivos, registros y descargas
  MDTPClient+Health.swift             Consulta GET /health en JSON
  MDTPClient+FileTransfer.swift       Subida y descarga por bloques
  MDTPSHA256.swift                    SHA-256 local
  MDTPError.swift                     Errores tipados
  MDTPClient.docc/                    Documentacion DocC
Tests/MDTPClientTests/
  ConformanceTests.swift              Un test por endpoint y mensaje
  HTTPTransportTests.swift            Transporte y errores HTTP
  MDTPClientTests.swift               Cliente, SHA-256 y transferencias
  QueriesTests.swift                  Consultas y descargas por metadatos
```

## Endpoints

Salvo `/health`, todas las solicitudes usan `POST` y
`Content-Type: application/x-protobuf`.

| Endpoint | Solicitud | Respuesta |
| --- | --- | --- |
| `GET /health` | Ninguna | JSON `{"status":"ok"}` |
| `/v1/devices/register` | `RegisterDeviceRequest` | `RegisterDeviceResponse` |
| `/v1/transfers` | `TransferBeginRequest` | `TransferBeginResponse` |
| `/v1/transfers/chunk` | `TransferChunkRequest` | `TransferChunkResponse` |
| `/v1/transfers/status` | `TransferStatusRequest` | `TransferStatusResponse` |
| `/v1/transfers/commit` | `TransferCommitRequest` | `TransferCommitResponse` |
| `/v1/devices/list` | `ListDevicesRequest` | `ListDevicesResponse` |
| `/v1/records/search` | `SearchRecordsRequest` | `SearchRecordsResponse` |
| `/v1/records/get` | `GetRecordRequest` | `GetRecordResponse` |
| `/v1/downloads/begin` | `DownloadBeginRequest` | `DownloadBeginResponse` |
| `/v1/downloads/chunk` | `DownloadChunkRequest` | `DownloadChunkResponse` |

Las respuestas exitosas usan `Content-Type: application/x-protobuf`, excepto
`/health`, que responde `application/json`. Los errores se informan con el estado
HTTP (`400`, `404`, `409`, `500`, etc.); no hay un contenedor generico de
operaciones.

## Health

`client.health()` hace `GET /health`, sin cuerpo, y espera
`Content-Type: application/json`:

```json
{"status":"ok"}
```

Devuelve `MDTPHealthResponse`: `status` contiene el valor reportado por el
servidor e `isHealthy` es `true` cuando el estado es `ok`.

## Generar los modelos Swift

```powershell
.\scripts\setup-tools.ps1
.\scripts\generate-proto.ps1
```

Para verificar sin escribir:

```powershell
.\scripts\generate-proto.ps1 -Check
```

El comando devuelve exit code 1 si el archivo generado esta desactualizado. No
editar `protocol_v1_completo.pb.swift` a mano: modificar el `.proto`, regenerar y
volver a compilar.

## Compilar y probar

```sh
swift build
swift test
```

## Uso

```swift
import MDTPClient

let configuration = MDTPConfiguration(
    baseURL: URL(string: "https://servidor.example")!
)
let client = MDTPClient(configuration: configuration)

let health = try await client.health()
print(health.isHealthy)

let registration = try await client.registerDevice(deviceName: "iPhone")
let deviceID = registration.deviceID

var search = SearchRecordsRequest()
search.dataCategory = MDTPDataCategory.photo
search.pageSize = 100
let records = try await client.searchRecords(search)

let result = try await client.download(
    record: records.records[0],
    to: URL(fileURLWithPath: "salida/foto.jpg")
)
print(result.sha256)
```

Todas las rutas se agregan a `baseURL`: si `baseURL` termina en `/api`, la
solicitud de registro va a `/api/v1/devices/register`.

## Transferencias

La subida completa se hace con `upload`:

1. Calcula el SHA-256 y el tamano del archivo.
2. Envia `TransferBeginRequest` a `/v1/transfers`.
3. Reanuda desde `next_chunk_index` y `next_chunk_offset`.
4. Envia bloques a `/v1/transfers/chunk` y exige que el servidor confirme el
   indice y el offset esperados.
5. Envia `TransferCommitRequest` y exige `success = true`.

La descarga sigue el flujo inverso: `downloadBegin`, bloques con
`downloadChunk` y verificacion del tamano y del SHA-256 anunciado por el
servidor. Si el archivo de destino ya contiene un prefijo, la descarga reanuda
desde el offset devuelto por el servidor.

El tamano de bloque recomendado es 1 MiB (`MDTPDefaults.recommendedChunkSize`).
El cliente usa el menor valor entre ese limite y el que devuelva el servidor. No
se envia un archivo completo en un unico mensaje.

## Errores

- `httpStatus`: respuesta HTTP no exitosa.
- `timeout`: vencio el tiempo de espera.
- `transport`: error de red u otro error de `URLSession`.
- `CancellationError`: la tarea fue cancelada.
- `invalidResponse`: el cuerpo no es el mensaje Protobuf o el JSON esperado.
- `invalidHashLength`: un SHA-256 no mide 32 bytes.
- `hashMismatch`: el SHA-256 descargado no coincide con el anunciado.
- `transferCommitFailed`: el servidor no confirmo la transferencia.
- `contentUnavailable`: el registro no tiene contenido binario disponible.

Los errores HTTP `5xx`, los timeouts y los fallos de transporte se consideran
reintentables (`isRetryable`). La libreria no reintenta automaticamente.

## Decisiones

- Los mensajes de bloque se envian como un unico cuerpo Protobuf, igual que el
  resto de las operaciones. El limite de respuesta y el tamano de bloque son
  configurables.
- No hay negociacion de version ni capacidades: la version es `/v1/`.
- No se mantiene estado de sesion ni checkpoints locales; la reanudacion la
  indica el servidor mediante indices y offsets.
- No se conservan las operaciones que no tienen endpoint en el contrato actual
  (catalogo de aplicaciones y cancelacion de transferencias).
- `/health` es la unica operacion que usa `GET` y JSON; no forma parte del
  contrato Protobuf de `/v1/`.
