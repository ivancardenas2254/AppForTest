# Transferencias e integridad

Flujos de subida y descarga, reanudacion y verificacion.

## Subida

`upload` realiza el flujo completo:

1. Calcula el SHA-256 del archivo.
2. Envia `TransferBeginRequest` a `/v1/transfers`.
3. Reanuda desde `next_chunk_index` y `next_chunk_offset`.
4. Envia bloques a `/v1/transfers/chunk` y exige que cada respuesta confirme el
   indice y el offset.
5. Envia `TransferCommitRequest` a `/v1/transfers/commit` y exige
   `success = true`.

Si el servidor pide un offset que no coincide con el archivo local, la operacion
falla con un error de validacion. Un commit fallido lanza
``MDTPError/transferCommitFailed``.

### Tamano de bloque

El tamano recomendado es 1 MiB (``MDTPDefaults/recommendedChunkSize``). El
cliente usa el menor valor entre el solicitado y el devuelto por el servidor en
`TransferBeginResponse.max_chunk_size`. Un archivo nunca se envia completo en un
unico mensaje.

### Reanudacion

El estado de reanudacion lo indica el servidor. Si `TransferBeginResponse`
devuelve un offset mayor que cero, `upload` continua desde ese punto. No se
guardan checkpoints locales.

## Descarga

`download` inicia la descarga con `/v1/downloads/begin`, lee los bloques de
`/v1/downloads/chunk` y verifica:

- indices y offsets de cada respuesta;
- longitud solicitada y bloques vacios;
- coherencia de `is_last_chunk`;
- tamano final;
- SHA-256 anunciado, si existe.

Si el archivo de destino ya contiene el prefijo indicado por el servidor, la
descarga se reanuda desde ese offset. Al terminar, el archivo se trunca al tamano
declarado. El estado de reanudacion es el propio archivo parcial.

`download(record:to:)` ademas rechaza registros con `content_available = false` y
compara el hash final con `RecordInfo.sha256` cuando esta presente.

## Errores y reintentos

La libreria no reintenta automaticamente. Usa ``MDTPError/isRetryable`` y una
politica propia. Son seguras de repetir las consultas y los bloques de descarga.
Las operaciones de escritura requieren idempotencia explicita o cuidado
adicional.
