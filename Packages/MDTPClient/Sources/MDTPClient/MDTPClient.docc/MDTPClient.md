# ``MDTPClient``

Cliente Swift para el protocolo MDTP v1 sobre HTTP y Protobuf.

## Overview

`MDTPClient` implementa los endpoints definidos en
`protocol_v1_completo.proto`: registro de dispositivos, transferencias por
bloques, consultas, metadatos y descargas con verificacion de integridad.

Cada operacion se envia como un mensaje Protobuf a una ruta `/v1/...` concreta.
El endpoint determina el tipo de solicitud y de respuesta; no hay un mensaje
generico que contenga todas las operaciones. La excepcion es `GET /health`, que
responde JSON y se consulta con ``MDTPClient/health()``.

El cliente es `Sendable` y se puede compartir entre tareas.

## Topics

### Primeros pasos

- <doc:GettingStarted>
- <doc:Transfers>
- <doc:Conformance>

### Cliente y configuracion

- ``MDTPClient``
- ``MDTPConfiguration``
- ``MDTPDefaults``
- ``MDTPDataCategory``
- ``MDTPHealthResponse``

### Transferencias y descargas

- ``MDTPTransferProgress``
- ``MDTPUploadResult``
- ``MDTPDownloadResult``
- ``MDTPSHA256``

### Mensajes del protocolo

- ``RegisterDeviceRequest``
- ``RegisterDeviceResponse``
- ``TransferBeginRequest``
- ``TransferBeginResponse``
- ``TransferChunkRequest``
- ``TransferChunkResponse``
- ``TransferStatusRequest``
- ``TransferStatusResponse``
- ``TransferCommitRequest``
- ``TransferCommitResponse``
- ``ListDevicesRequest``
- ``ListDevicesResponse``
- ``DeviceInfo``
- ``SearchRecordsRequest``
- ``SearchRecordsResponse``
- ``RecordInfo``
- ``GetRecordRequest``
- ``GetRecordResponse``
- ``DownloadBeginRequest``
- ``DownloadBeginResponse``
- ``DownloadChunkRequest``
- ``DownloadChunkResponse``

### Errores

- ``MDTPError``
