# Conformidad con MDTP v1

Correspondencia entre el contrato y la API publica.

## Operaciones

| Endpoint | API |
| --- | --- |
| `GET /health` | `health()` |
| `POST /v1/devices/register` | `registerDevice(clientInstanceID:deviceName:)` |
| `POST /v1/transfers` | `transferBegin(deviceID:transferID:fileName:fileSize:fileHash:...)` |
| `POST /v1/transfers/chunk` | `transferChunk(deviceID:transferID:chunkIndex:chunkOffset:chunkData:)` |
| `POST /v1/transfers/status` | `transferStatus(deviceID:transferID:)` |
| `POST /v1/transfers/commit` | `transferCommit(deviceID:transferID:)` |
| `POST /v1/devices/list` | `listDevices(pageSize:pageToken:)` |
| `POST /v1/records/search` | `searchRecords(_:)` |
| `POST /v1/records/get` | `getRecord(recordID:)` |
| `POST /v1/downloads/begin` | `downloadBegin(recordID:)` |
| `POST /v1/downloads/chunk` | `downloadChunk(downloadID:chunkIndex:chunkOffset:requestedLength:)` |

Las operaciones compuestas `upload` y `download` usan varias de las anteriores.

## Invariantes del transporte

- Salvo `/health`, cada solicitud es un mensaje Protobuf enviado con
  `Content-Type: application/x-protobuf`.
- `/health` usa `GET`, no envia cuerpo y responde JSON (`{"status":"ok"}`).
- El endpoint determina el tipo de mensaje; no hay `Envelope`, `request_id` ni
  `protocol_version`.
- La version se identifica con `/v1/` en la URL.
- Un estado HTTP fuera de 2xx se convierte en ``MDTPError/httpStatus(_:)``.
- Cualquier respuesta que no se pueda decodificar como el mensaje o JSON
  esperado se rechaza con ``MDTPError/invalidResponse(_:)``.

## Validacion local

- SHA-256 de subida: exactamente 32 bytes.
- SHA-256 de descarga y metadatos: 0 o 32 bytes.
- Offsets, indices, longitudes y `is_last_chunk`.
- `record_id` no vacio y coincidencia en `getRecord`.
- `content_available` antes de descargar por metadatos.

## Fuente de verdad

`proto/protocol_v1_completo.proto` es el contrato normativo. Los modelos Swift se
generan con `protoc` y `protoc-gen-swift`; el script
`scripts/generate-proto.ps1 -Check` verifica que esten actualizados.

El endpoint `/health` no forma parte del contrato Protobuf; su respuesta es el
JSON `{"status":"ok"}`.
