# Comprobación independiente de etiquetas (G3)

`extract_source.rb` lee por SQL las tablas y todos los ítems y páginas wiki del origen (Redmine 4.2, fork 1.0.4). `extract_target.rb` hace otra lectura del destino (Redmine 7, additional_tags 4.6.0). Comparten `extract.rb`, pero no cargan el conversor, el importador ni modelos/API de etiquetas. Las dos capturas usan una transacción consistente de solo lectura y terminan con rollback. Solo admiten MySQL y PostgreSQL; un error no publica un fichero parcial ni sobreescribe una captura anterior.

Cada JSONL contiene `meta`, todos los `object` (también sin etiquetas), todo el catálogo `tag` (también sin uso), una fila `assignment` por asignación física y `end` con recuentos y SHA-256 del prefijo. Conserva IDs técnicos, nombres exactos, contexto y tagger en origen y fechas UTC con microsegundos. Los bytes que no son UTF-8 se representan mediante `{"$base64":"..."}`; el comparador los rechaza, sin repararlos. Las capturas incluyen columnas físicas, ajustes efectivos y su procedencia, versiones de plugins, `taggings_count` y `actual_taggings_count` obtenido mediante SQL. No se copian nombres de usuarios ni textos de ítems.

`compare.rb` exige ambos JSONL y `report.json`. Compara multiconjuntos de catálogo con fechas, asignaciones, fechas de asignación y objetos en ambas direcciones. La igualdad de nombres se hace por bytes, sin strip, split, normalización Unicode ni cambios de mayúsculas. Exige contexto `tags`, tagger nulo y ausencia de proyecciones duplicadas. También comprueba ajustes y activación cuando hay etiquetas y que todos los contadores destino coincidan con las filas físicas. Un contador fuente erróneo se informa, porque el destino debe recalcularlo. Las columnas imprevistas bloquean la comprobación. Solo devuelve 0 con `Failures (0)`; devuelve 1 ante diferencias y 2 ante evidencia incompleta/inválida. Por defecto muestra SHA-256 corto de la etiqueta, huellas e IDs técnicos. `--show-names` incluye los valores y debe usarse solo en privado.

El único mapa externo es el informe de conversión v1: `identity_renumbered` y `identity_prefix_normalized` con `subject=item:<id>` (solo ítems del origen) y `detail.from/to`. Se comprueba `from` contra el CSID extraído. La identidad incluye siempre proyecto y tipo; wiki usa título exacto. Un `document_item_absorbed` permite omitir de la cobertura destino ese ítem únicamente si no tiene etiquetas y su proyecto coincide con el informe. Los ítems que genera la migración (capítulos "Group: ...", capítulos "Project data" y sus datos) se reconocen por su entrada `item_generated` (`subject=item:group-<id>`, `item:data-<proyecto>` o `item:datum-<id>`; `detail.kind`, `project`, `csid` final y `from`, el ítem del origen del que salen, o nada para un capítulo de datos), y cada una tiene que cuadrar con el anuncio del paso que la crea: `synthetic_chapter` con `detail.around=item:<id>`, `data_section_created` con el mismo CSID y proyecto, `datum_created` con `variable` igual al CSID y el mismo `requirement`. Un anuncio sin `item_generated`, o al revés, invalida la evidencia; un ítem generado en otro proyecto que el de su origen es fallo (`report_generated_project_mismatch`). Se añaden a la cobertura esperada y no pueden tener etiquetas (`generated_item_has_tags`). Toda asignación a un absorbido o a un ítem generado sigue siendo diferencia. No hay excepciones basadas en recuentos o prefijos de CSID.

El resultado dice siempre `order: not-certified`. La extracción SQL deja `source_order=null`: ni ID ni fecha prueban un orden API. Si se aportan observaciones explícitas en `source_order` (IDs de etiquetas), se comparan por nombre como información y nunca afectan a la salida. El acceso de un usuario normal, el comportamiento de la UI/edición, la limpieza posterior de etiquetas sin uso, permisos/módulos, correo/jobs/webhooks e historial se verifican aparte en el ensayo. Este comparador certifica el estado de los datos en las dos capturas, no su conservación tras una edición futura ni la correspondencia criptográfica entre la base y los paquetes.

## Ejecución en un ensayo

Mantén ambas instancias congeladas y usa un destino reservado para la migración completa. Se incluyen todos los objetos y todo el catálogo global: una etiqueta ajena en destino produce diferencias. Los objetos de destino de un proyecto que no está en el origen (toda instancia nueva de cosmoSys trae los wikis de ayuda `csys_help` y `csys_admin_help`) no forman parte de la migración: si no tienen ninguna etiqueta solo se cuentan como información (`foreign_unlabelled_objects`, con el número por tipo y de proyectos); si tienen alguna, es fallo (`foreign_object_has_tags`). Un objeto de más en un proyecto que sí está en el origen sigue siendo diferencia (`object_coverage`). Desde el directorio que contiene `snapshots_gen/`, sustituye los nombres entre `<...>`:

```sh
umask 077
mkdir -p migracion/g3
chmod 700 migracion/g3
docker cp snapshots_gen/test/tags <contenedor-antiguo>:/tmp/sg-tags-code
docker exec -u 0 <contenedor-antiguo> install -d -o redmine -g redmine -m 700 /tmp/sg-g3
docker exec -u redmine -w /usr/src/redmine <contenedor-antiguo> bundle exec rails runner -e production /tmp/sg-tags-code/extract_source.rb /tmp/sg-g3/source.jsonl
docker cp <contenedor-antiguo>:/tmp/sg-g3/source.jsonl migracion/g3/source.jsonl
docker cp snapshots_gen/test/tags <contenedor-nuevo>:/tmp/sg-tags-code
docker exec -u 0 <contenedor-nuevo> install -d -o redmine -g redmine -m 700 /tmp/sg-g3
docker exec -u redmine -w /usr/src/redmine <contenedor-nuevo> bundle exec rails runner -e production /tmp/sg-tags-code/extract_target.rb /tmp/sg-g3/target.jsonl
docker cp <contenedor-nuevo>:/tmp/sg-g3/target.jsonl migracion/g3/target.jsonl
chmod 600 migracion/g3/*.jsonl
docker run --rm -v "$PWD:/work" -w /work snapshots_gen-converter ruby snapshots_gen/test/tags/compare.rb migracion/g3/source.jsonl migracion/g3/target.jsonl migracion/convertido/report.json
```

En local, Ruby 2.7 o superior basta (también ejecutado con Ruby 2.6.10):

```sh
ruby test/tags/compare_test.rb
ruby test/tags/extract_test.rb
ruby test/tags/compare.rb test/tags/fixtures/source.jsonl test/tags/fixtures/target.jsonl test/tags/fixtures/report.json
```

Los fixtures versionados son inventados. Las pruebas regeneran ficheros JSONL completos con su footer antes de alterar semántica; también prueban truncamiento y corrupción de huella. Los dobles SQL de `extract_test.rb` comprueban la transacción, rollback, escritura atómica, permisos y bytes, pero no sustituyen ejecutar los dos runners contra los adaptadores reales.

## Sintético de origen

En una base desechable recién rellenada por `test/legacy_env/synthesize.rb`, ejecuta el script hermano. Comprueba los tres identificadores inventados de proyecto y una marca de ejecución; se niega a repetir. Su única misión es escribir datos inventados en esa copia. Emplea modelos Redmine para journals y wiki, y SQL directo para el catálogo y las asignaciones, evitando que el parser o la API filtren precisamente los casos que queremos medir.

```sh
docker cp snapshots_gen/test/legacy_env/synthesize_tags.rb <contenedor-sintetico>:/tmp/synthesize_tags.rb
docker exec -u redmine -w /usr/src/redmine <contenedor-sintetico> bundle exec rails runner -e production /tmp/synthesize_tags.rb valid
```

La variante `valid` incluye mayúsculas distintas en el mismo ítem, acentos, NFC/NFD, espacios interiores, emoji, comillas, coma literal, nombres de 191 caracteres ASCII y emoji, etiqueta global sin uso, contador fuente incorrecto, nombre compartido entre ítems/proyectos/wiki, un ítem cerrado, dos wikis con el mismo título en proyectos distintos, grupos y una secuencia literal de placeholder. Deja otros objetos sin etiquetas. Crea journals solo de etiquetas, privados, mezclados con una nota y de borrado total. Llama explícitamente a `tags_to_journal`, como el hook del controlador antiguo, y exige tres detalles `attr/tag_list`, con texto que contenga comas. Solo durante la generación dirige el job de limpieza al adaptador de pruebas en memoria para que no borre la etiqueta sin uso al commit; no cambia ajustes persistentes de la cola. Debe pasar G3 después de migrar. La UI y una edición posterior deben probarse separadamente (caso de comas, mayúsculas, grupos y eliminación automática de la etiqueta sin uso).

Un origen real que tenga solo etiquetas sencillas no acredita los casos límite. Ejecuta también el sintético válido y los de rechazo. Los detalles históricos `attr/tag_list` son texto literal: no los dividas por comas ni interpretes como catálogo. La comparación G3 de estado no verifica esos detalles; el ensayo debe cotejar su número y sus valores `old_value/value` exactos, además de la comparación de historial renderizado. Una diferencia de detalles que el comparador de historial muestre solo como revisión sigue necesitando esa comprobación literal.

Para probar rechazo, parte de otra base sintética fresca por caso y cambia `valid` por `reject CASE`. Casos: `context`, `null-context`, `empty-context`, `tagger`, `empty-tagger`, `duplicate`, `orphan-issue`, `orphan-wiki`, `unknown-type`, `empty-type`, `null-type`, `null-name`, `empty-name`, `outer-spaces`, `spaces`, `nul`, `absorbed`. Todos deben bloquear la migración y/o G3 con su evidencia conservada. Contextos, propietarios, duplicados con claves nulas, huérfanos y nombres inválidos se insertan mediante SQL directo. No se desactivan claves foráneas ni se modifica el esquema. Si el DDL real impide alguno, registra el error y conserva el rechazo como caso de fichero, sin relajar el DDL.

UTF-8 inválido, nombres de 255/256 caracteres y corrupción/truncamiento se prueban mediante JSONL: MySQL con `varchar(191)` no permite crearlos fielmente en ese esquema. Las colisiones/renumeraciones y los ítems generados se prueban con `report.json` en `compare_test.rb`. Una FK de etiqueta rota se prueba por JSONL para no desactivar restricciones. Una tabla ausente, ambas vacías, columnas nuevas y falta de plugin también tienen pruebas de fichero. La ejecución de los sintéticos en Rails y la idempotencia, dry-run y rollback de los importadores pertenecen al ensayo integrado.

## Material sensible y borrado

Los JSONL reales contienen nombres de etiquetas, identificadores y títulos de wiki; son sensibles. El informe de conversión también puede contener textos privados. Usa directorios 700, ficheros 600 y transporte protegido; no los adjuntes a incidencias ni los confirmes en Git. La extracción crea sus ficheros con 600 y no sobreescribe: para repetir usa rutas nuevas. Si guardas salida con `--show-names`, protégela y bórrala igual que las capturas.

Después de recoger la evidencia autorizada:

```sh
docker exec -u 0 <contenedor-antiguo> rm -rf /tmp/sg-tags-code /tmp/sg-g3
docker exec -u 0 <contenedor-nuevo> rm -rf /tmp/sg-tags-code /tmp/sg-g3
docker exec -u 0 <contenedor-sintetico> rm -f /tmp/synthesize_tags.rb
rm -rf migracion/g3
```

Incluye las copias y salidas privadas de esta comprobación en el borrado de material de migración. Solo las estadísticas y códigos sin nombres son apropiados para informes compartidos.
