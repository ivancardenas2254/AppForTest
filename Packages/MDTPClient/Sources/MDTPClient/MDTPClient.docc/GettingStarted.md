# Primeros pasos

Crea un cliente y ejecuta la primera operacion.

## Requisitos

- Swift 6.2 o posterior.
- Un servidor que implemente los endpoints `/v1/` de MDTP.
- El paquete `MDTPClient` como dependencia de SwiftPM.

## Crear el cliente

```swift
import MDTPClient

let configuration = MDTPConfiguration(
    baseURL: URL(string: "https://servidor.example")!
)
let client = MDTPClient(configuration: configuration)
```

El inicializador usa una `URLSession` efimera con validacion TLS normal. Para
TLS pinning, proxies o pruebas de integracion se puede inyectar una sesion:

```swift
let session = URLSession(configuration: customConfiguration)
let client = MDTPClient(configuration: configuration, session: session)
```

## Comprobar el servidor

```swift
let health = try await client.health()
print(health.isHealthy)
```

`health()` hace `GET /health` y decodifica `{"status":"ok"}`.

## Registrar un dispositivo

```swift
let registration = try await client.registerDevice(deviceName: "iPhone")
let deviceID = registration.deviceID
```

La solicitud se envia a `/v1/devices/register` como `RegisterDeviceRequest`.

## Consultar

```swift
var search = SearchRecordsRequest()
search.dataCategory = MDTPDataCategory.photo
search.pageSize = 100
let records = try await client.searchRecords(search)

let devices = try await client.listDevices(pageSize: 50)
```

`searchRecords` envia `SearchRecordsRequest` a `/v1/records/search`;
`listDevices` envia `ListDevicesRequest` a `/v1/devices/list`.

## Descargar

```swift
guard let record = records.records.first else {
    throw CancellationError()
}

let result = try await client.download(
    record: record,
    to: URL(fileURLWithPath: "salida/foto.jpg")
)
print(result.sha256)
```

`download(record:to:)` valida los metadatos y verifica el SHA-256. Si el
servidor no anuncia un hash, el resultado contiene el hash calculado localmente.

## Subir

```swift
let result = try await client.upload(
    fileURL: URL(fileURLWithPath: "foto.jpg"),
    deviceID: deviceID,
    dataCategory: MDTPDataCategory.photo
)
print(result.transferID)
```

La subida calcula el SHA-256, se reanuda desde el bloque indicado por el
servidor y confirma la transferencia al terminar.

## Siguientes pasos

- <doc:Transfers>
- <doc:Conformance>
