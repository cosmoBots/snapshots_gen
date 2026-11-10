# Migrar una instancia antigua de cosmoSys

Este procedimiento lleva una instancia antigua de cosmoSys (Redmine 4.2 con los plugins `cosmosys_*`) a una instancia nueva de cosmoSys (Redmine 7, desplegada con `cosmoSys_deploy`), con su historial: notas, cambios, versiones de wiki, tiempo dedicado, observadores, usuarios con su contraseña, autores y fechas, y con sus etiquetas. Está escrito para que lo siga de principio a fin, sin ayuda, alguien que sabe Docker y Linux pero no conoce cosmoSys por dentro.

**Antes de tocar nada, lee [Material sensible](#material-sensible).** Los ficheros que se generan llevan los correos y las contraseñas cifradas de todos los usuarios y todo el contenido de la instancia.

Algunos términos de cosmoSys que salen a menudo:

- Ítem: una petición de Redmine (un requisito, una nota informativa, un capítulo...). Su tipo es el tracker (`rq`, `csInfo`, `csRefDoc`...).
- CSID: el código legible de cada ítem dentro de su proyecto (por ejemplo, `PRJ-0012`). La migración lo conserva y lo usa para identificar los ítems entre la instancia antigua y la nueva.
- Journal: cada entrada del historial de un ítem (una nota, un cambio de campos o las dos cosas).
- Paquete: cada fichero que generan las herramientas de este repositorio. `.cslegacy` es la copia de la instancia antigua; `.csys`, `.cshistory` y `.cstags` son los que se importan en la nueva.

## Qué hace y qué no

- **La instancia antigua no se toca.** Solo se lee, dentro de una transacción de solo lectura. No se instala nada, no se migra la base de datos y no se reinicia el contenedor. Lo único que se escribe es un directorio temporal dentro del contenedor, que se borra al terminar el paso 3.
- **La instancia nueva tiene que estar recién creada y cerrada** hasta el paso 8. Nadie debe trabajar en ella antes de importar el historial: Redmine usa el orden de las notas en varias funciones, y un historial añadido después quedaría desordenado. El importador se niega si encuentra notas que no sean suyas. Una instancia recién creada ya trae dos proyectos de ayuda, `csys_help` y `csys_admin_help`, con unas páginas de wiki; el importador los acepta y no hay que borrarlos.
- **Lo que no se migra** lo dice el informe de conversión. Entre otras cosas: lo que el cosmoSys antiguo nunca guardó en el historial (los botones de borrar y zombi, mover y reordenar en el árbol, las importaciones ODS y git), las noticias, los foros y los repositorios.
- **Las etiquetas se migran tal cual** (paso 6.4): las mismas etiquetas, con el mismo nombre exacto, en los mismos ítems y páginas de wiki, con sus fechas, y los cambios de etiquetas en el historial. Cada rol de la instancia nueva recibe los permisos de etiquetas que tenía su rol antiguo, para que quien las veía las siga viendo (solo se añaden permisos, nunca se quitan). Lo que no se conserva es el orden de las etiquetas de cada ítem (el plugin nuevo siempre las ordena por nombre), y el plugin nuevo borra por su cuenta las etiquetas que no usa ningún ítem en cuanto alguien edita un ítem, igual que hacía el antiguo. La importación deja las etiquetas exactas, pero el plugin nuevo trata algunos nombres de otra forma al editar un ítem: parte por la coma un nombre como `A,B` (queda `A` y `B`), funde dos etiquetas del mismo ítem que solo se distinguen por mayúsculas y no deja guardar un ítem con dos etiquetas del mismo grupo `grupo::`. Si la instancia antigua tiene alguno de esos casos, el inventario del paso 1 los cuenta y la conversión los avisa; se decide antes de migrar (por ejemplo, renombrándolos en la instancia antigua).
- **Los modelos PORIS no se pueden migrar todavía.** Es una limitación conocida: la conversión escribe las relaciones "bloquea" entre los ítems PORIS, y el plugin `cosmosys_poris` actual solo acepta "precede", así que el paso 6.2 falla con `Validation failed: Relation type is invalid` en todo paquete que las tenga, aunque su preflight haya dicho `Preflight passed` (no escribe nada de ese paquete). Si el inventario del paso 1 muestra ítems de los trackers `pr*` (`prSys`, `prParam`, `prMode`, `prValFloat`, `prValText`, `prCmd`), no sigas: pregunta antes en las incidencias de este repositorio, sin adjuntar nada de la instancia.
- **Las contraseñas se conservan**: Redmine 4.2 y 7 las guardan igual. **El 2FA se reinicia**: quien lo usaba tiene que volver a activarlo. Quien entraba por LDAP u otra autenticación externa no tiene contraseña en Redmine y no podrá entrar hasta que un administrador le dé una.
- **No sale ningún correo.** `cosmoSys_deploy` no configura ningún servidor de correo, y la instancia nueva no debe tener uno hasta que se abra (paso 8). Además, mientras importa, el importador no deja que Redmine encole ninguna notificación: cada orden termina diciendo `Jobs queued: none`. Así nadie recibe miles de avisos de ítems "creados" o "cambiados" por la migración.
- **Los paquetes de una conversión van juntos.** Todos los `.csys`, el `.cshistory` y el `.cstags` de una misma conversión se importan juntos, y el paso 6.4 lo comprueba. Convertir otra vez el mismo `.cslegacy` da paquetes distintos (no son idénticos byte a byte), así que, si se repite la conversión, se repite también la importación desde una instancia nueva (paso 5).

## Qué cambia en la conversión

La conversión no reorganiza nada a mano, pero el modelo nuevo nombra algunas cosas de otra forma. Todo lo que cambia queda en el informe de conversión (paso 4).

**Estados:**

| Antes | Después |
| --- | --- |
| `rqDraft`, `rqStable`, `rqApproved`, `rqRejected` | `Draft`, `Stable`, `Approved`, `Rejected` |
| `rqErased` y `rqZombie` | `Erased` |
| `csNone` | el estado por defecto del tracker |
| cualquier otro | el mismo nombre |

**Trackers:** `rq` pasa a `csRq`, salvo los ítems con `rqType` `Info`, que pasan a `csInfo`. `csInfo` y `csRefDoc` se quedan igual. Los valores PORIS `prValFloat` y `prValText` pasan a `prValue`, el único tipo de valor del PORIS nuevo. Los demás trackers conservan su nombre.

**Roles de las membresías:** si la instancia nueva tiene un rol con el mismo nombre, se usa ese. Si no:

| Antes | Después |
| --- | --- |
| `rqMngr` | `Manager` |
| `rqWriter` | `Developer` |
| `rqReviewer` | `Developer` |
| `rqReader` | `Reporter` |

Para otro reparto, añade `roles=rqReviewer:Reporter,...` a `importar history` (paso 6.3) y lo mismo a `importar tags` (paso 6.4), que usa el mismo reparto para los permisos de etiquetas. Un rol sin destino deja sin importar sus membresías, y el paso 6.1 lo avisa.

**Campos de los ítems:**

| Antes | Después |
| --- | --- |
| `rqType` (Complex, Opt, Mech, Hw, Sw) | tipo de requisito (complex, optical, mechanical, hardware, software) |
| `rqLevel`, `rqRationale`, `rqSources` | nivel, justificación y fuentes del requisito |
| `rqComplanceState`, `rqComplianceJustif` | estado y justificación del cumplimiento |
| `rqVerif`, `rqVerifDescr` | métodos y descripción de la verificación |
| `csOldCode`, `csWload` | código externo y carga de trabajo (`csExtCode`, `csWLoad`) |
| `rqVar` y `rqValue` | un dato de proyecto (`csDatum`) con ese nombre y ese valor, bajo un capítulo "Project data", si el nombre es un identificador que cosmoSys acepta (una letra seguida de letras, números o `_`) y no se repite en el árbol del proyecto; si no, o si solo hay `rqValue`, el requisito los conserva como campos personalizados `rqVar` y `rqValue`, con su historial. Un proyecto sin ningún dato no tiene capítulo "Project data" |
| `rqAplDocs`, `rqRefDocs`, `rqComplianceDocs` | referencias del catálogo de documentos; el texto que no es una referencia se conserva como campo personalizado |
| `csID`, `csChapter`, `depGrahInReports` | nada: el CSID y el capítulo son nativos, y la marca de informe no tiene equivalente |
| cualquier otro campo personalizado | el mismo campo, con su definición |

El historial sigue a los campos: un cambio antiguo de `rqLevel` se ve como cambio del nivel de requisito, con los valores nuevos.

**Estructura:**

- Los ítems `AD n`, `RD n` y `CD n` pasan a ser documentos del proyecto, con su posición en el catálogo. Si el título trae código, versión y fecha, se extraen.
- Un requisito o un `csRefDoc` con hijos queda dentro de un capítulo generado, "Group: <título>", porque en el modelo nuevo no pueden tener hijos.
- Cada ítem que solo existe en la instancia nueva (los capítulos "Group: ...", los capítulos "Project data" y sus datos) tiene en el informe de conversión una entrada `item_generated` con su CSID final y el ítem del origen del que sale. Los CSID renumerados (`identity_renumbered`) son solo los de ítems del origen.
- Los CSID se conservan, también los que tienen el prefijo de otro proyecto porque el ítem se movió. Solo se renumera un ítem sin CSID o con uno repetido en su árbol.
- En los modelos PORIS, una relación "bloquea" va al revés que antes: el modo bloquea lo que incluye (sus submodos y sus valores). La conversión invierte esas relaciones y sus cambios en el historial, pero el plugin `cosmosys_poris` actual no las acepta (ver "Qué hace y qué no").

**Historial que nombra registros borrados:** si un cambio antiguo tiene como valor anterior o nuevo un ítem, estado, tracker, prioridad, categoría, versión o proyecto que se borró en la instancia antigua, la conversión conserva el otro lado y deja ese vacío. Redmine 4.2 ya enseñaba vacíos los estados, las versiones y los demás registros borrados. Un padre borrado lo enseñaba con su número, pero en la instancia nueva ese número sería el de otro ítem, así que también se deja vacío: "Tarea padre cambiado de #120 a #135" pasa a "Item padre establecido a #<nuevo número de 135>". Si no queda ningún lado, el cambio se quita; el journal solo se quita si no le queda ni nota ni otro cambio. Todo queda en el informe de conversión (`history_reference_cleared` y `history_reference_dropped`), con el CSID del ítem y el journal.

**Cambios de adjuntos que el ítem ya no tiene:** un cambio antiguo "Fichero añadido" o "Fichero eliminado" guarda el número del adjunto. Si ese adjunto se borró en la instancia antigua, o no llega a la nueva con ese mismo ítem (su fichero faltaba o pertenece a otro contenedor), su número no vale en la instancia nueva: allí sería otro fichero o ninguno. La conversión conserva el cambio con sus nombres de fichero y le pone el número 0, que no tiene ningún adjunto. Redmine 4.2 y Redmine 7 pintan igual un cambio cuyo adjunto ya no está en el ítem: el nombre del fichero, sin enlace. Así que se ve igual que en la instancia antigua y nunca enlaza un fichero equivocado. Cada caso queda en el informe de conversión (`history_attachment_cleared`), con el ítem, su CSID, el journal, el detalle, el número del adjunto en la instancia antigua, el lado que lo nombraba (`old` si se quitó, `new` si se añadió) y el motivo (`deleted from the source` o `not migrated with this item`). El importador escribe exactamente eso; si encuentra un adjunto que el paquete da por migrado y no está, no lo cambia por 0: descarta el cambio y lo lista en su informe, y el paso 7 lo da por fallo.

**Etiquetas:** la conversión las deja en `<nombre>.cstags` tal como están en la instancia antigua, sin tocar ningún nombre: no quita espacios, no cambia mayúsculas ni acentos y no parte en las comas (`A,B` es una sola etiqueta; `A` y `a` son dos). Los ítems se identifican por su proyecto y su CSID final (el renumerado, si lo fue) y las páginas de wiki por su proyecto y su título. El orden de las etiquetas de cada ítem no se conserva: el plugin nuevo siempre las muestra por nombre. El plugin nuevo no tiene contexto ni autor de cada etiquetado, así que solo se pueden importar los etiquetados de contexto `tags` sin autor; cualquier otro caso, igual que un nombre que el plugin nuevo cambiaría (espacios al principio o al final, más de 255 caracteres), una etiqueta repetida, un ítem `AD n`/`RD n`/`CD n` etiquetado o con cambios de etiquetas en su historial (esos ítems pasan a documentos y su historial no se migra, así que el cambio se perdería), deja el `.cstags` como no importable y el informe lo cuenta en `Blocking`. Los cambios de etiquetas del historial se conservan literalmente. El formato está en [cstags-format.md](cstags-format.md).

**Personas:** los usuarios se emparejan por login. Si ya existían en la instancia nueva (como `admin`), conservan su contraseña y toman el nombre de origen. Si no, se crean con su contraseña de siempre. El asignado de cada ítem llega con el historial (paso 6.3), porque Redmine solo deja asignar a miembros del proyecto.

## Material sensible

Los ficheros que genera este procedimiento son una copia de la instancia y se tratan como una copia de seguridad de su base de datos. Llevan los correos de todos los usuarios y sus contraseñas cifradas: no van en claro, sino con el mismo esquema de Redmine 4.2 y 7 (SHA-1 con sal), pero una contraseña débil se puede sacar de su huella por fuerza bruta. Por eso no pueden quedarse en cualquier sitio ni viajar de cualquier forma.

### Qué lleva cada fichero

| Fichero | Se crea en | Qué lleva |
| --- | --- | --- |
| `migracion/inventario/inventory-*.json` | paso 1 | Recuentos, y los nombres de trackers, estados, campos personalizados, roles y plugins. Ni personas, ni correos, ni contenido. Es información interna de la organización: compártelo solo por un canal privado. |
| `migracion/exportado/<nombre>-<fecha>.cslegacy` | paso 3 | Toda la base de la instancia antigua salvo las sesiones y los tokens: usuarios con su contraseña cifrada y su sal, correos, notas (también las privadas), wiki, consultas, preferencias, y los ficheros adjuntos. Los secretos del 2FA y las contraseñas de servicios van borrados. |
| `migracion/historial-origen.jsonl`, `migracion/historial-destino.jsonl` | pasos 3 y 7 | El texto de todo el historial de cada ítem, notas privadas incluidas, con los valores completos. |
| `migracion/etiquetas-origen.jsonl`, `migracion/etiquetas-destino.jsonl` | pasos 3 y 7 | Los nombres de todas las etiquetas, los proyectos y CSID de los ítems y los títulos de las páginas de wiki. |
| `migracion/convertido/<nombre>-<identificador>.csys` | paso 4 | Todo el contenido de un proyecto raíz y de sus subproyectos: ítems, wiki, documentos y adjuntos. |
| `migracion/convertido/<nombre>.cshistory` | paso 4 | Los usuarios con su contraseña cifrada, su sal y su correo, y todo el historial: notas (también las privadas), cambios, versiones de wiki, tiempo dedicado y observadores. |
| `migracion/convertido/<nombre>.cstags` | paso 4 | Los nombres de las etiquetas, a qué ítems y páginas van, los ajustes del plugin y los permisos de etiquetas de cada rol. |
| `migracion/convertido/report.md`, `report.json` | paso 4 | Logins (los que tienen 2FA o autenticación externa), asuntos de ítems, títulos de documentos, nombres de ficheros adjuntos, identificadores de proyecto y valores de campos. |
| `migracion/importado/history-import-*.json`, `tags-import-*.json` | pasos 6.3 y 6.4 | Números y CSID de ítems y journals, nombres de roles, ajustes y recuentos. Se tratan igual que los demás. |
| Lo que imprimen `--details`, `--show` y `--show-names` | paso 7 | Lo mismo que los ficheros que comparan. |
| `/tmp/snapshots_gen-out` en el contenedor antiguo | pasos 1 a 3 | Copias de lo anterior. Se borra al final del paso 3. |
| `/tmp/sg` en el contenedor nuevo | pasos 5 a 7 | Copias de los paquetes, de los informes y de los JSONL de destino. Se borra en el paso 8. |
| El fichero de entorno de la instancia nueva (`COSMOSYS_ENV_FILE`) | paso 5 | La contraseña de su base de datos, su clave secreta y la contraseña inicial del administrador. Se conserva mientras viva la instancia, con modo 600 y fuera de cualquier repositorio. |
| La copia de seguridad del deploy | paso 8.1 | Toda la base de la instancia nueva y sus adjuntos. |

### Dónde se guardan

- Solo en el directorio de trabajo de cada servidor (ver "Preparar el directorio de trabajo"), con `umask 077` en cada terminal: `migracion/` y sus directorios con modo 700 y los ficheros con 600. Nunca dentro de un checkout de git, en una carpeta sincronizada (una nube, Syncthing...) ni en un directorio con copias automáticas que no se vayan a borrar también. Mejor aún en un volumen cifrado.
- Solo entra quien hace la migración. Ninguna copia en equipos personales.
- Algunos ficheros salen de los contenedores legibles por otros usuarios. Después de cada `docker cp` hacia `migracion/` el procedimiento repite esta comprobación, que no tiene que imprimir nada:

```sh
chmod -R go-rwx migracion
find migracion -perm /077
```

### Cómo se llevan de un servidor a otro

- Directamente por SSH (`rsync -e ssh` o `scp`), o pasando por tu equipo con `scp -3`, que no guarda nada en él. Si no hay más remedio que un disco, que esté cifrado y se borre después.
- Nunca por correo, chat, incidencias, enlaces públicos, servicios de intercambio de ficheros ni nubes sin cifrar.
- Comprueba siempre con `sha256sum` que lo que llegó es lo que salió (paso 3.4).

### Lo que no se hace nunca

- Enviar a nadie un paquete, un informe de conversión o de importación, un JSONL de comparación o una copia de seguridad, ni adjuntarlos a una incidencia. `report.md` tampoco: lleva logins y asuntos.
- Para pedir ayuda basta con el mensaje de error, el inventario (por un canal privado) y los títulos de `report.md` con sus recuentos, que no llevan personas ni contenido:

```sh
grep '^###' migracion/convertido/report.md
```

- Dejar copias en `/tmp` del servidor, en un directorio compartido o dentro de un contenedor después del paso que las usa.

### Cuándo se borran

En el paso 10, con una lista cerrada y una comprobación de que no queda nada. `rm` no garantiza que los datos desaparezcan del disco (discos SSD, instantáneas del sistema de ficheros, copias de seguridad del servidor), así que la protección de verdad es trabajar en un volumen cifrado y no dejar que el directorio de trabajo entre en otras copias.

### Si un fichero acaba donde no debe

1. Bórralo de ahí y de todo lo que lo haya copiado (papelera, carpetas sincronizadas, copias de seguridad, correos enviados y recibidos), y apunta qué fichero era, dónde estuvo, cuánto tiempo y quién pudo verlo.
2. Avisa enseguida a quien lleve la protección de datos en tu organización: es una posible brecha de datos personales, que puede haber que notificar en plazo.
3. Si era un `.cslegacy`, un `.cshistory` o una copia de seguridad, las contraseñas cifradas han quedado expuestas. Pide a todos los usuarios que cambien su contraseña en la instancia nueva (y en la antigua, si sigue en uso) y en cualquier otro servicio donde usaran la misma. Un administrador puede forzarlo en cada usuario con "Debe cambiar la contraseña en el próximo inicio de sesión".
4. Si era el fichero de entorno de la instancia nueva, cambia los secretos que lleva: la contraseña del administrador, `REDMINE_SECRET_KEY_BASE` (cierra todas las sesiones) y la contraseña de la base de datos, en PostgreSQL y en el fichero.

## Versiones con las que se ha ensayado

| Pieza | Versión ensayada |
| --- | --- |
| Instancia antigua | Redmine 4.2.10 (Rails 5.2.8.1, Ruby 2.7.8) sobre MySQL 5.7, con `cosmosys_rm`, `cosmosys_req_rm`, `cosmosys_git_rm`, `additionals` 3.0.5.2 y `additional_tags` 1.0.4 (la copia de cosmoBots), en el contenedor del despliegue antiguo de cosmoSys |
| cosmoSys | 0.2.10 (etiqueta `0.2.10`, commit `4d9e1c7e6d3ebf97c76590162fb1b19dd29f1338`) |
| cosmoSys Requirements | commit `9de64877b8f1402cad91b586e33f84e28b09179c` (plugin 0.3.5) |
| Etiquetas en la instancia nueva | `additionals` 4.6.0 (`5f5ff955dcff00e5fef47c7609f9e0d4fb038178`) y `additional_tags` 4.6.0 (`3d503b183ae9254d89bc8f71a517f1f3ec1662c4`), el conjunto `tags` del deploy |
| Instancia nueva | Redmine 7.0.1 sobre PostgreSQL 16, desplegada con `cosmoSys_deploy` (Docker Compose 2.20 o posterior) |

Con otras versiones no está ensayado. El importador usa clases internas de cosmoSys que cambian de una versión a otra, y el de etiquetas se niega si `additional_tags` no es 4.6. Con otra versión de cosmoSys, ensaya antes el procedimiento entero (pasos 1 a 7) con una copia, sobre una instancia desechable.

Hace falta un `cosmoSys_deploy` cuyo pin de cosmoSys sea la 0.2.10. Compruébalo antes del paso 5, en el servidor nuevo y desde el directorio del checkout del deploy:

```sh
git ls-remote https://github.com/cosmoBots/cosmoSys.git 'refs/tags/0.2.10^{}'
grep '^COSMOSYS_REVISION=' .env.example
grep '^COSMOSYS_REQ_REVISION=' .env.example
grep -E '^PLUGIN_(additionals|additional_tags)_REVISION=' plugins.conf
```

La primera y la segunda orden tienen que dar el mismo commit, `4d9e1c7e6d3ebf97c76590162fb1b19dd29f1338`, y las otras dos los de la tabla. Si `COSMOSYS_REVISION` es otro, ese checkout no instala cosmoSys 0.2.10: actualízalo (`git pull` en `main`) hasta una versión del deploy con ese pin antes de crear la instancia. El paso 5 comprueba después la imagen que de verdad corre.

## Antes de empezar

### Dónde se hace cada paso y cuánto tarda

Los tiempos son los de un ensayo con una instancia de 26 proyectos y unos 2000 ítems (un paquete de 34 MB). Sirven para planificar la ventana en la que la instancia antigua queda congelada, del paso 2 al 8.

| Paso | Dónde | Tiempo de referencia |
| --- | --- | --- |
| 1. Inventario | servidor antiguo | unos segundos |
| 2. Congelar la instancia antigua | servidor antiguo | lo que tarde avisar a los usuarios |
| 3. Exportar y tomar las referencias | servidor antiguo | 15 s la exportación y unos 40 s las referencias |
| 3.4. Llevar los ficheros al servidor nuevo | entre los dos | lo que tarde copiar el paquete |
| 4. Convertir | servidor nuevo | unos segundos, más la construcción de la imagen del conversor la primera vez |
| 5. Crear la instancia nueva | servidor nuevo | 75 s hasta que está sana, más la construcción de la imagen de cosmoSys |
| 6.1. Preparar | servidor nuevo | 7 s |
| 6.2. Importar cada `.csys` | servidor nuevo | de 10 a 40 s cada paquete pequeño; entre 16 y 23 minutos uno de unos 2000 ítems |
| 6.3. Importar el historial | servidor nuevo | unos 35 s el ensayo y otros tantos la importación |
| 6.4. Importar las etiquetas | servidor nuevo | unos 8 s el ensayo y otros tantos la importación |
| 7. Comprobar | servidor nuevo | un par de minutos, más la revisión a mano |
| 8. Copia de seguridad, publicar y abrir | servidor nuevo | depende del tamaño y de cómo se publique |

En total, del paso 1 al 7, unos 30 minutos en el ensayo, casi todos en el paquete grande del 6.2. Cada orden del importador tarda además 5 o 6 segundos en arrancar.

### Lista de comprobación

- [ ] Puedes ejecutar `docker` en el servidor antiguo y sabes el nombre del contenedor de Redmine de la instancia (`docker ps --format '{{.Names}}'`; en el despliegue antiguo de cosmoSys suele ser `csys_rm-<nombre>`). Este procedimiento supone ese despliegue: un contenedor con Redmine en `/usr/src/redmine` y un usuario `redmine` dentro. Si tu instancia antigua corre de otra forma, las órdenes de los pasos 1 a 3 hay que adaptarlas.
- [ ] En el servidor nuevo tienes Docker con Compose 2.20 o posterior, un checkout de `cosmoSys_deploy` con el pin de cosmoSys 0.2.10 (ver "Versiones con las que se ha ensayado") y salida a GitHub, Docker Hub y rubygems para construir las imágenes.
- [ ] Hay espacio: en el servidor nuevo, unas cuatro veces lo que ocupan los adjuntos y la base de la instancia antigua (el paquete antiguo, los convertidos, su copia dentro del contenedor y la instancia ya importada); en el antiguo, unas dos veces. El inventario (paso 1) dice cuánto ocupan los adjuntos.
- [ ] Sabes cómo llevarás los ficheros del servidor antiguo al nuevo (paso 3.4), si no son el mismo.
- [ ] La ventana de congelación está acordada y los usuarios lo saben: del paso 2 al 8 nadie trabaja ni en la instancia antigua ni en la nueva.
- [ ] Está decidido cómo se publicará la instancia nueva (paso 8.2): con el proxy del deploy, con un proxy propio o sin proxy.
- [ ] Está decidido cuánto tiempo se conserva la instancia antigua parada como vuelta atrás (paso 9).
- [ ] Has leído "Material sensible" y tu organización acepta cómo se van a guardar, llevar y borrar los ficheros.

### Preparar el directorio de trabajo

En cada servidor, trabaja en un directorio propio, fuera del checkout del deploy y de cualquier carpeta sincronizada o con copias automáticas. En los ejemplos, `snapshots_gen/` es el checkout de este repositorio y `migracion/` el directorio de los ficheros que se generan, los dos dentro de ese directorio de trabajo, y todas las órdenes se ejecutan desde él:

```sh
umask 077
mkdir -m 700 cosmosys-migracion
cd cosmosys-migracion
git clone https://github.com/cosmoBots/snapshots_gen.git
git -C snapshots_gen rev-parse HEAD
mkdir -m 700 migracion
```

Usa la misma revisión de `snapshots_gen` en los dos servidores: la última orden de `git` la imprime. Si el servidor antiguo no llega a GitHub, crea en el nuevo un archivo con el código y llévalo al antiguo (el código no es sensible):

```sh
git -C snapshots_gen archive --format=tar.gz --prefix=snapshots_gen/ -o snapshots_gen.tar.gz HEAD   # en el servidor nuevo
tar xzf snapshots_gen.tar.gz                                                                       # en el servidor antiguo, en su directorio de trabajo
```

Las órdenes usan unas variables de la terminal. En el servidor antiguo:

```sh
ANTIGUO=<contenedor-antiguo>   # el nombre del contenedor de Redmine de la instancia antigua
NOMBRE=<nombre>                # un nombre corto para la instancia, que da nombre a los paquetes
```

`<nombre>` lleva solo letras, números, `-` o `_` (por ejemplo, `antigua`). En el servidor nuevo:

```sh
NOMBRE=<nombre>                                        # el mismo que en el servidor antiguo
DEPLOY=<ruta del checkout de cosmoSys_deploy>
export COSMOSYS_ENV_FILE=<ruta absoluta del fichero de entorno de la instancia nueva>
```

`COSMOSYS_ENV_FILE` es el fichero de configuración de la instancia nueva que crea el paso 5 (por ejemplo, `$HOME/cosmosys/migrada.env`, fuera del directorio de trabajo, porque se conserva mientras viva la instancia); los scripts del deploy lo leen de esa variable. El `umask` y las variables se pierden al cerrar la terminal: si abres otra, vuelve a definirlos (y `NUEVO`, que define el paso 5).

## 1. Inventario

En el servidor antiguo. El inventario cuenta lo que hay sin sacar contenido: versiones, plugins, trackers, estados, campos, notas por tipo de cambio, versiones de wiki con huecos, adjuntos, usuarios con 2FA, etiquetas y los ajustes de formato de texto. Se pasa primero para saber si la instancia tiene algo que el procedimiento no cubre.

Copia en el contenedor el código que usan los pasos 1 a 3 y pasa el inventario:

```sh
docker exec -u 0 "$ANTIGUO" mkdir -p /tmp/snapshots_gen-code
docker cp snapshots_gen/exporter "$ANTIGUO":/tmp/snapshots_gen-code/exporter
docker cp snapshots_gen/test/history_text.rb "$ANTIGUO":/tmp/snapshots_gen-code/history_text.rb
docker cp snapshots_gen/test/tags "$ANTIGUO":/tmp/snapshots_gen-code/tags
docker exec -u 0 "$ANTIGUO" chown -R redmine:redmine /tmp/snapshots_gen-code
docker exec -u redmine -w /usr/src/redmine "$ANTIGUO" \
  bundle exec rails runner -e production /tmp/snapshots_gen-code/exporter/export.rb inventory out=/tmp/snapshots_gen-out/inventario
docker cp "$ANTIGUO":/tmp/snapshots_gen-out/inventario migracion/inventario
chmod -R go-rwx migracion
find migracion -perm /077
```

El `chown` hace falta porque `docker cp` deja los ficheros a nombre de root dentro del contenedor, y con `umask 077` el usuario `redmine` no podría leerlos. La orden imprime un resumen y deja el inventario completo en `migracion/inventario/inventory-*.json`. Comprueba en el resumen:

- La primera línea: la versión de Redmine y de la base de datos. Lo ensayado es Redmine 4.2.10 sobre MySQL 5.7; con otra, ensaya antes con una copia.
- `text_formatting="markdown"`. Si dice `textile`, para: esa conversión no está cubierta.
- `Trackers` y `Statuses`: los de cosmoSys (`rq`, `csInfo`, `csRefDoc`, estados `rq*`, `csNone`) se convierten solos. Si hay ítems de trackers `pr*`, la instancia usa PORIS: para (ver "Qué hace y qué no"). Cualquier otro tracker con ítems (`Bug`, `Task`, `Test Case`...) tiene que existir con el mismo nombre en la instancia nueva antes de importar: apunta sus nombres exactos para el paso 5.
- `Attachments`: cuánto ocupan (para el espacio) y cuántos no tienen fichero. Los que no tienen fichero no se pueden migrar; el informe de conversión los cuenta.
- `Users`: cuántos tienen 2FA (tendrán que volver a activarlo) y cuántos usan autenticación externa (LDAP), que no podrán entrar hasta que se les dé una contraseña.
- `Ambiguous Markdown tables`: tablas Markdown con la cabecera sangrada, que el cosmoSys nuevo enseña como código. No bloquean; el informe de conversión dice dónde están.
- `Tags`: las etiquetas, solo recuentos (nunca nombres). Lo normal es que todo lo que va después del punto y coma valga 0, con un solo contexto y 0 con autor: entonces no hay nada que decidir. Qué significa cada recuento:
  - `tags`, `unused` y `taggings` (por tipo): cuántas etiquetas hay, cuántas no usa ningún ítem ni página, y cuántos etiquetados hay en ítems (`Issue`) y en páginas de wiki (`WikiPage`). Todas se migran, también las sin uso, pero el plugin nuevo borra las sin uso en cuanto alguien edita un ítem. Otro tipo distinto de `Issue` y `WikiPage` no se puede migrar: la conversión lo bloquea.
  - `distinct contexts` y `with tagger`: el plugin nuevo no tiene contexto ni autor de cada etiquetado. Con 1 contexto y 0 con autor todo encaja; si no, la conversión bloquea y hay que decidir qué hacer con esos etiquetados antes de seguir.
  - `names with a comma`: nombres como `A,B`. Se importan como una sola etiqueta, pero la primera edición normal del ítem la parte en `A` y `B`.
  - `groups equal except for case`: grupos de nombres que solo se distinguen por mayúsculas (`Rojo` y `rojo`). Se importan separados, pero el plugin nuevo los trata como uno al editar un ítem que tenga los dos.
  - `scope conflicts on one object`: ítems con dos etiquetas del mismo grupo `grupo::` (`grupo::uno` y `grupo::dos`). El plugin nuevo no deja guardar ese ítem hasta quitar una.
  - `names with edge spaces`: nombres con espacios al principio o al final. El plugin nuevo los recortaría, así que la conversión los bloquea: hay que renombrarlos en la instancia antigua.
  - `tag changes in the history`: cambios de etiquetas en el historial de los ítems. Se migran literalmente.
  - Si la línea dice `Tags: no additional_tags and additional_taggings tables`, la instancia no tiene el plugin de etiquetas y la conversión se bloqueará (`missing_table`): para y pregunta antes de seguir.

Si algo de esto no cuadra, pide ayuda con el `inventory-*.json` por un canal privado antes de seguir. No lleva personas ni contenido, pero sí los nombres de trackers, estados, campos y roles.

## 2. Congelar la instancia antigua

Desde aquí hasta el paso 8 nadie debe cambiar nada en la instancia antigua, o esos cambios no llegarán a la nueva. Avisa a los usuarios y activa el modo mantenimiento si la instancia lo tiene (Administración, Plugins, Redmine Maintenance Mode), o como mínimo deja de usarla.

## 3. Exportar y tomar las referencias

En el servidor antiguo.

### 3.1. Exportar

```sh
docker exec -u redmine -w /usr/src/redmine "$ANTIGUO" \
  bundle exec rails runner -e production /tmp/snapshots_gen-code/exporter/export.rb capture out=/tmp/snapshots_gen-out/exportado label="$NOMBRE"
docker cp "$ANTIGUO":/tmp/snapshots_gen-out/exportado migracion/exportado
```

El exportador lee todo en una sola transacción de solo lectura, copia los adjuntos, comprueba que los recuentos no han cambiado mientras leía y verifica el paquete antes de terminar. Al final dice:

```text
Captured N tables, N rows, N attachment rows.
Gaps: none.
Redactions: N.
Package written to /tmp/snapshots_gen-out/exportado/<nombre>-<fecha>.cslegacy (...), verified.
```

`Gaps` lista lo que no se pudo copiar tal cual, normalmente adjuntos cuyo fichero ya no existe. No impide seguir; el informe de conversión los repite. `Redactions` cuenta los secretos que se han dejado en blanco (claves del 2FA, contraseñas de servicios).

### 3.2. Tomar las referencias para comprobar

El paso 7 compara la instancia nueva con la antigua: el historial de cada ítem y las etiquetas. Como la antigua ya está congelada, sus referencias se toman ahora y viajan con el paquete, y así el paso 7 se hace entero en el servidor nuevo:

```sh
docker exec -u redmine -w /usr/src/redmine "$ANTIGUO" \
  bundle exec rails runner -e production /tmp/snapshots_gen-code/history_text.rb /tmp/snapshots_gen-out/historial-origen.jsonl es
docker exec -u redmine -w /usr/src/redmine "$ANTIGUO" \
  bundle exec rails runner -e production /tmp/snapshots_gen-code/tags/extract_source.rb /tmp/snapshots_gen-out/etiquetas-origen.jsonl
docker cp "$ANTIGUO":/tmp/snapshots_gen-out/historial-origen.jsonl migracion/
docker cp "$ANTIGUO":/tmp/snapshots_gen-out/etiquetas-origen.jsonl migracion/
```

La primera dice `wrote /tmp/snapshots_gen-out/historial-origen.jsonl` y la segunda `tags evidence: objects=N tags=N assignments=N`. El `es` es el idioma en el que se pinta el historial: el paso 7 usa el mismo.

### 3.3. Limpiar el contenedor antiguo

```sh
docker exec -u 0 "$ANTIGUO" rm -rf /tmp/snapshots_gen-code /tmp/snapshots_gen-out
docker exec "$ANTIGUO" sh -c 'ls -d /tmp/snapshots_gen-* 2>/dev/null || echo limpio'
chmod -R go-rwx migracion
find migracion -perm /077
```

La segunda orden tiene que decir `limpio`, y la última no tiene que imprimir nada.

### 3.4. Llevar los ficheros al servidor nuevo

Si los dos servidores son el mismo, salta este apartado. Si no, todo `migracion/` viaja al directorio de trabajo del servidor nuevo, por SSH (ver "Material sensible"). En el servidor antiguo:

```sh
(cd migracion && find . -type f ! -name SHA256SUMS -exec sha256sum {} + > SHA256SUMS)
rsync -a -e ssh migracion/ <usuario>@<servidor-nuevo>:<directorio de trabajo>/migracion/
```

`rsync -a` conserva los permisos 600 y 700. Si los servidores no se ven entre sí, pásalo por tu equipo sin guardarlo en él: `scp -3 -rp <usuario>@<servidor-antiguo>:<directorio de trabajo>/migracion <usuario>@<servidor-nuevo>:<directorio de trabajo>/`. En el servidor nuevo, desde su directorio de trabajo:

```sh
(cd migracion && sha256sum -c SHA256SUMS)
chmod -R go-rwx migracion
find migracion -perm /077
```

Cada fichero tiene que decir `OK`. Cuando sea así, borra `migracion/` del servidor antiguo (`rm -rf migracion`): ya no hace falta allí.

## 4. Convertir

En el servidor nuevo. La conversión corre en un contenedor con un Ruby actual; primero se construye su imagen (necesita salida a Docker Hub y a rubygems):

```sh
docker build -t snapshots_gen-converter snapshots_gen/converter
CSLEGACY=$(ls migracion/exportado/*.cslegacy); echo "$CSLEGACY"
docker run --rm -v "$PWD:/work" snapshots_gen-converter \
  ruby snapshots_gen/bin/verify-legacy-snapshot "$CSLEGACY"
docker run --rm -u "$(id -u):$(id -g)" -v "$PWD:/work" snapshots_gen-converter \
  ruby snapshots_gen/converter/convert.rb "$CSLEGACY" migracion/convertido
```

El `echo` tiene que enseñar un solo fichero, el que exportó el paso 3. La comprobación dice `valid: N tables, N rows, N assets`. La conversión termina con `blocking: false`, `tags_importable: true` y `Report: migracion/convertido/report.md`, y con código 0 (1 si hay algo `Blocking`). `migracion/convertido` no puede existir antes: para repetir la conversión, bórralo, y si ya importaste algo, empieza también de nuevo desde el paso 5 (los paquetes de dos conversiones no se mezclan). El `-u` hace que los ficheros sean tuyos y no de root.

Deja en `migracion/convertido/`:

- un `.csys` por cada proyecto raíz de la instancia antigua (`<nombre>-<identificador>.csys`), con sus subproyectos;
- `<nombre>.cshistory`, el paquete de historial y usuarios;
- `<nombre>.cstags`, el paquete de etiquetas de toda la instancia (también las que no usa ningún ítem), con los permisos de etiquetas que tenía cada rol, ligado a los `.csys` y al `.cshistory` de esta misma conversión;
- `report.md` y `report.json`, el informe de conversión.

**Lee el informe antes de seguir.** `report.md` está ordenado por gravedad:

- `Blocking`: no se puede seguir. La orden termina con código 1. Un `.cstags` no importable también es `Blocking` (`tags_blocking`, con el número de casos por código); el `.cstags` se escribe igualmente, para diagnosticarlo.
- `Warning`: algo se pierde o se adapta y conviene saberlo: adjuntos sin fichero, referencias `#id` a ítems que no existen, cambios del historial que no se pueden traducir o que solo nombraban registros borrados, tablas Markdown ambiguas. En `tags_warning`, lo que hay que revisar de las etiquetas antes de entregar: etiquetas desactivadas en los ajustes, etiquetas sin uso (el plugin nuevo las borra tras cualquier edición), nombres que solo difieren en mayúsculas (`case_variant_names`: la primera edición normal de un ítem que tenga las dos las funde en una), nombres con coma (`comma_in_name`: se importan como una sola etiqueta, pero la primera edición normal del ítem la parte en varias por la coma) o dos etiquetas del mismo grupo `grupo::` en un ítem (`scoped_tag_conflict`: el plugin nuevo no deja guardar ese ítem hasta quitar una). La importación las deja exactas; el problema aparece al usarlas después. Si alguno de estos recuentos no es 0, decide antes de entregar si se renombran en la instancia antigua (y se vuelve a exportar) o se aceptan.
- `Transformation`: lo que la conversión cambia a propósito, por ejemplo los estados `rqDraft` a `Draft`, los campos `rq*` a los campos nativos, los ítems `AD n`/`RD n`/`CD n` a documentos, los CSID renumerados, el lado vacío de un cambio del historial que nombraba un registro borrado o los cambios de adjuntos que el ítem ya no tiene, que se quedan con sus nombres de fichero y sin adjunto.
- `Information`: lo que no se puede recuperar porque nunca se guardó, los usuarios cuyo 2FA se reinicia y los roles de las membresías.

## 5. Crear la instancia nueva

En el servidor nuevo, con `cosmoSys_deploy` (antes, comprueba su pin como dice "Versiones con las que se ha ensayado"). La instancia se crea con su propio fichero de entorno y su propio nombre de proyecto Compose, así que no toca ninguna otra instancia que ya corra en el servidor. Se crea cerrada: solo escucha en `127.0.0.1` del servidor y no se publica hasta el paso 8.

### 5.1. El fichero de entorno

```sh
mkdir -p -m 700 "$(dirname "$COSMOSYS_ENV_FILE")"
install -m 600 "$DEPLOY/.env.example" "$COSMOSYS_ENV_FILE"
openssl rand -hex 32
openssl rand -hex 64
```

Edita `$COSMOSYS_ENV_FILE` y deja estas líneas con estos valores (las que ya están se cambian y las que no, se añaden):

```dotenv
COMPOSE_PROJECT_NAME=<nombre del proyecto Compose, por ejemplo cosmosys_migrada>
POSTGRES_PASSWORD=<la primera cadena de openssl>
REDMINE_SECRET_KEY_BASE=<la segunda cadena de openssl>
COSMOSYS_INITIAL_ADMIN_PASSWORD=<una contraseña fuerte para admin>
COSMOSYS_VARIANT=requirements
COSMOSYS_PLUGINS=tags
COSMOSYS_BIND_ADDRESS=127.0.0.1
COSMOSYS_HTTP_PORT=<un puerto libre del servidor, por ejemplo 3000>
COSMOSYS_SESSION_COOKIE_KEY=<un nombre propio, por ejemplo _cosmosys_migrada_session>
REDMINE_LANG=en
```

- `COMPOSE_PROJECT_NAME` da nombre a los contenedores y a los volúmenes de la instancia (`<proyecto>-redmine-1`, `<proyecto>_database`...): letras minúsculas, números, `_` o `-`, y distinto del de cualquier otra instancia del servidor.
- `COSMOSYS_VARIANT=requirements` añade cosmoSys Requirements, que hace falta si la instancia antigua tenía requisitos (tracker `rq`), que es lo normal.
- `COSMOSYS_PLUGINS=tags` es obligatorio: instala los plugins de etiquetas. Sin él, el paso 6.4 se niega a importarlas (`the tag plugin is not ready in this instance`). Otros conjuntos del deploy se pueden activar después con `scripts/update-instance.sh --plugins` (ver su README); la migración solo se ha ensayado con `tags`.
- `COSMOSYS_BIND_ADDRESS=127.0.0.1` deja la instancia cerrada mientras se migra. El paso 8.2 la cambia según cómo se publique.
- `COSMOSYS_SESSION_COOKIE_KEY` con un nombre propio evita que el navegador mezcle la sesión de esta instancia con la de la antigua o la de otra instancia en el mismo nombre de host.
- `REDMINE_LANG=en`, como viene en `.env.example`, es lo ensayado. Con otro idioma, Redmine crea sus trackers, estados y roles de serie con los nombres traducidos, y el reparto de roles del paso 6 (`rqWriter` a `Developer`...) no los encuentra. Cada usuario elige luego su idioma en "Mi cuenta", y el idioma por defecto se cambia en Administración, Configuración, Visualización.
- `COSMOSYS_INITIAL_ADMIN_PASSWORD` es la contraseña del usuario `admin`. Solo se aplica en el primer arranque, mientras `admin` conserva la contraseña de fábrica. Si en la instancia antigua había un usuario `admin`, el paso 6.1 lo empareja con este, que conserva la contraseña nueva.
- No añadas `COSMOSYS_PROXY_MODE` ni `COSMOSYS_HOSTNAME` todavía (el proxy del deploy publicaría la instancia en cuanto arrancara), ni ninguna configuración de correo.

### 5.2. Construir y arrancar

Desde el directorio de trabajo:

```sh
(cd "$DEPLOY" && ./scripts/compose.sh build)
(cd "$DEPLOY" && ./scripts/compose.sh up -d --wait)
NUEVO=$(cd "$DEPLOY" && ./scripts/compose.sh ps -q redmine); echo "$NUEVO"
```

La construcción descarga y compila cosmoSys y sus plugins (necesita salida a GitHub, Docker Hub y rubygems); la primera vez tarda bastante más que las siguientes. `up --wait` termina cuando la instancia está sana: en el ensayo, 75 s. `NUEVO` es el identificador del contenedor de Redmine de la instancia, y el `echo` tiene que imprimirlo. Comprueba que es la instancia que toca:

```sh
docker inspect --format '{{index .Config.Labels "eu.cosmobots.cosmosys.revision"}}' "$NUEVO"
docker exec "$NUEVO" printenv COSMOSYS_PLUGINS
docker exec "$NUEVO" ls /usr/src/redmine/plugins
docker exec "$NUEVO" sh -c 'grep -s email_delivery /usr/src/redmine/config/configuration.yml || echo "sin correo"'
```

La primera tiene que dar `4d9e1c7e6d3ebf97c76590162fb1b19dd29f1338` (cosmoSys 0.2.10), la segunda `tags`, la tercera tiene que incluir `additionals`, `additional_tags`, `cosmosys` y `cosmosys_req`, y la última `sin correo`.

Para ver la instancia sin publicarla, abre un túnel SSH desde tu equipo y entra con el navegador en `http://localhost:8080` como `admin`, con la contraseña de `COSMOSYS_INITIAL_ADMIN_PASSWORD`:

```sh
ssh -N -L 8080:127.0.0.1:<COSMOSYS_HTTP_PORT> <usuario>@<servidor-nuevo>
```

Tiene que tener solo los dos proyectos de ayuda que trae toda instancia nueva. No dejes entrar a nadie más hasta el paso 8.

### 5.3. Crear los trackers que no son de cosmoSys

Si el inventario del paso 1 mostraba ítems de trackers que no son de cosmoSys, créalos ahora con el mismo nombre exacto, mayúsculas y espacios incluidos. La instancia nueva trae de serie `Bug`, `Feature` y `Support`; los demás (por ejemplo `Test Case` o `Task`) hay que crearlos. En Administration, Trackers, New tracker (Administración, Tipos de petición, Nuevo tipo de petición):

- Name: el nombre exacto de la instancia antigua.
- Default status: `New`.
- Copy workflow from: `Bug`, para que tenga un flujo de trabajo.

Sin estado por defecto o sin flujo de trabajo, Redmine no deja usar el tracker. Si falta alguno, el paso 6.1 lo dice (`Missing trackers (the .csys import will refuse their items): ...`) y el preflight del 6.2 se niega sin escribir nada; se crea entonces y se repite ese paso.

### 5.4. Copiar el importador y los paquetes al contenedor

```sh
docker exec -u 0 "$NUEVO" install -d -m 700 /tmp/sg /tmp/sg/pkg
docker cp snapshots_gen/exporter "$NUEVO":/tmp/sg/exporter
docker cp snapshots_gen/importer "$NUEVO":/tmp/sg/importer
docker cp snapshots_gen/converter "$NUEVO":/tmp/sg/converter
docker cp snapshots_gen/test/history_text.rb "$NUEVO":/tmp/sg/history_text.rb
docker cp snapshots_gen/test/tags "$NUEVO":/tmp/sg/tags
for f in migracion/convertido/*.csys migracion/convertido/*.cshistory migracion/convertido/*.cstags; do docker cp "$f" "$NUEVO":/tmp/sg/pkg/; done
docker exec -u 0 "$NUEVO" chown -R redmine:redmine /tmp/sg
```

`/tmp/sg/pkg` tiene que quedar con todos los `.csys`, el `.cshistory` y el `.cstags` de la misma conversión y con ningún otro: el paso 6.4 comprueba que son exactamente los que se convirtieron juntos. El directorio `converter` hace falta porque en él está el lector del `.cstags`, y `history_text.rb` y `tags` son para el paso 7. El `chown` es por lo mismo que en el paso 1.

Para no repetir la orden larga, define:

```sh
importar() { docker exec -u redmine -w /usr/src/redmine "$NUEVO" bundle exec rails runner /tmp/sg/importer/import.rb "$@"; }
```

## 6. Importar

En el servidor nuevo, desde el directorio de trabajo y con `importar` definido (paso 5.4). Son cuatro pasos, siempre en este orden. El 6.2 puede tardar más de veinte minutos con un paquete grande: lanza las órdenes desde `tmux` o `screen`, para que un corte de la conexión SSH no deje la terminal a medias.

Ninguno avisa a nadie: mientras corren, el importador hace que Redmine no vea eventos que notificar y descarta cualquier correo antes de encolarlo, solo dentro de su propio proceso y sin cambiar ningún ajuste de la instancia. Cada orden termina diciendo `Jobs queued: none`; si dice `WARNING: jobs queued during the import`, nombra los trabajos que se encolaron.

**6.1. Preparar:** crea los usuarios que falten, con su contraseña, los grupos, las definiciones de los campos personalizados que se conservan y las actividades de tiempo. Empareja por login los usuarios que ya existan. Repetirlo no duplica nada.

```sh
importar prepare /tmp/sg/pkg/"$NOMBRE".cshistory
```

Termina con una línea `Prepared: created_users=N, ...`. Revisa lo que dice de los roles (`Role rqWriter -> Developer`...). Si un rol antiguo no tiene destino, sus membresías no se importarán; créalo en la instancia nueva o indica otro con `roles=rqWriter:Developer,...` en el paso 6.3. Si dice `Missing trackers (the .csys import will refuse their items): ...`, crea esos trackers (paso 5.3) y repite esta orden.

**6.2. Importar cada paquete de proyecto:** hay un `.csys` por proyecto raíz de la instancia antigua (`ls migracion/convertido/*.csys`), y da igual en qué orden se importen. Cada uno, primero sin confirmar, que solo enseña el preflight de cosmoSys (el mismo que la interfaz):

```sh
importar csys /tmp/sg/pkg/<nombre>-<identificador>.csys
```

Si termina en `Preflight passed`, impórtalo:

```sh
importar csys /tmp/sg/pkg/<nombre>-<identificador>.csys confirm=yes
```

Mientras importa, escribe una línea al empezar cada fase (`[ 10%] items 0/2000 (1 s)`) otra cada 30 segundos dentro de una fase larga y, si una fase pasa un minuto sin dar señales, una línea `still working`: un paquete grande puede tardar bastante más de un cuarto de hora. Durante la importación, el log de Rails solo recoge avisos y errores, para que se lean las líneas del importador. Al terminar dice `Imported <identificador>: N projects, M items.` y el tiempo total.

Repite con cada `.csys`. Si el preflight dice `BLOCKING`, corrige lo que indique (normalmente un tracker que falta: `BLOCKING: Required trackers are unavailable: ...`) y vuelve a empezar con ese paquete; nada se ha escrito. Cada importación es una sola transacción: si falla o se corta, ese paquete no deja nada en la base y se repite. En el ensayo, un paquete pequeño tardó entre 10 y 40 segundos, y uno de unos 2000 ítems entre 16 y 23 minutos, casi todo en las fases `items`, `hierarchy`, `references` y `committing`.

**6.3. Importar el historial**, primero en ensayo (escribe todo, lo verifica y lo deshace):

```sh
importar history /tmp/sg/pkg/"$NOMBRE".cshistory dry_run=yes
```

Si termina en `Dry run: everything was rolled back.`, impórtalo de verdad:

```sh
importar history /tmp/sg/pkg/"$NOMBRE".cshistory
```

Al terminar de escribir el historial, y si la versión de cosmoSys las tiene, captura las líneas base de presentación de los ítems consolidados (por ejemplo, los requisitos que ya no están en borrador): son el texto aprobado con el que cosmoSys compara después, y sin ellas el ítem se lee "falta evidencia". La instancia antigua no las tenía, así que se toman del contenido migrado ya completo, como hace el script `scripts/capture_approved_presentation_baselines.rb` de cosmoSys con los ítems anteriores a esa función. Por eso el paso 6.2 no las captura, aunque la interfaz sí lo hace al importar un paquete: las referencias y relaciones entre paquetes no están completas hasta este paso.

Todo ocurre en una sola transacción: o queda todo importado y verificado, o no queda nada. Al final dice cuántos journals, versiones de wiki, entradas de tiempo, observadores y membresías ha escrito, y deja un informe en `/tmp/sg/pkg/history-import-<fecha>.json` con lo que no pudo traducir. Lo que la conversión ya quitó está en su informe y no llega al importador, así que cualquier cosa que el importador descarte es algo que el informe de conversión no anunciaba: la última línea lo dice (`Dropped by the importer: none` o un `WARNING: the importer dropped N records that the conversion report does not announce`). En el JSON (formato `snapshots_gen-history-import-v1`), `dropped` lista cada registro con `kind`, `id` (en el origen) y `reason`, y los journals y cambios llevan además `journal` (el journal de origen), `item` y `csid` (el CSID del ítem en la instancia nueva); `dropped_counts` los cuenta por tipo. El informe se copia al final del paso 6.4.

**6.4. Importar las etiquetas**, también primero en ensayo (escribe todo, lo verifica y lo deshace):

```sh
importar tags /tmp/sg/pkg/"$NOMBRE".cstags dry_run=yes
```

Si en el paso 6.3 usaste `roles=...`, añade lo mismo aquí. Si termina en `Dry run: everything was rolled back.`, impórtalas de verdad:

```sh
importar tags /tmp/sg/pkg/"$NOMBRE".cstags
```

Tiene que terminar en `Tags imported.`. Antes de escribir nada comprueba que los plugins de etiquetas están instalados y migrados, que sus tablas son las que conoce, que cada ítem y cada página de wiki del paquete existe una sola vez en la instancia nueva y que no hay ya etiquetas que choquen con las del paquete. Después escribe las etiquetas directamente en las tablas del plugin, sin pasar por los ítems (no crea notas en el historial, no cambia la fecha de ningún ítem y no manda correo), pone los ajustes del plugin como estaban en la instancia antigua (si las etiquetas estaban activadas, las activa), da a cada rol de la instancia nueva los permisos de etiquetas que tenía su rol antiguo (la línea `Roles:` dice cuáles; solo añade, nunca quita) y, antes de confirmar, vuelve a leer la base y comprueba que cada ítem y cada página tiene exactamente las etiquetas del paquete, también los que no tenían ninguna, y que nada más ha cambiado. Todo ocurre en una sola transacción: o queda todo, o no queda nada.

Repetir la orden no cambia nada: la segunda vez dice `Nothing to import` y deja la base como estaba. Lee los avisos del final (`WARNING`):

- `roles ... lack the view_issue_tags permission, also after the import`: los miembros con esos roles no verán las etiquetas ni los cambios de etiquetas del historial, porque sus roles antiguos tampoco las veían. Es lo que había; si se quiere otra cosa, da el permiso a mano (Administración, Roles y permisos).
- `source roles with tag permissions and no destination role`: un rol antiguo tenía permisos de etiquetas y no tiene rol en la instancia nueva (ni con su nombre ni con el reparto de arriba), así que no se ha dado nada por él. Normalmente es un rol sin membresías; si las tenía, el paso 6.3 tampoco las importó. Repite con `roles=<antiguo>:<nuevo>` si debe ir a algún rol.
- `active_issue_tags is off, as in the source`: en la instancia antigua las etiquetas estaban desactivadas en los ajustes del plugin. Están importadas, pero no se ven hasta activarlas (Administración, Tags).

La línea `Roles:` dice qué permisos de etiquetas ha dado a cada rol y de qué rol antiguo vienen (por ejemplo `Developer +view_issue_tags (from rqWriter)`). Los roles antiguos internos (`Non member` y `Anonymous`) pasan a los internos de la instancia nueva. Si varios roles antiguos van al mismo rol nuevo, recibe la unión de sus permisos. La instancia nueva solo da de serie los permisos de etiquetas (`view_issue_tags`, `create_issue_tags`, `edit_issue_tags` y `add_wiki_tags`) al rol `Manager`, y esos no se quitan aunque el rol antiguo no los tuviera.

Copia los informes de la importación (`history-import-<fecha>.json` y `tags-import-<fecha>.json`, los de los ensayos y los de las importaciones de verdad), y solo ellos:

```sh
mkdir -m 700 migracion/importado
for f in $(docker exec "$NUEVO" sh -c 'cd /tmp/sg/pkg && ls *-import-*.json'); do docker cp "$NUEVO":/tmp/sg/pkg/"$f" migracion/importado/; done
chmod -R go-rwx migracion
find migracion -perm /077
```

## 7. Comprobar

En el servidor nuevo, desde el directorio de trabajo. La instancia sigue cerrada.

### 7.1. Lo que el importador ya ha comprobado

Antes de confirmar la transacción del historial, el importador verifica que:

- los journals y los cambios escritos son los esperados;
- ninguna nota sale como "Editada" y sus números siguen el orden de las fechas;
- ningún cambio nombra un estado, tracker, usuario, versión, categoría, proyecto, ítem o adjunto que no exista (un cambio de adjunto con el número 0 es el que anuncia `history_attachment_cleared`), y ningún adjunto es de otro ítem;
- no queda ninguna referencia sin traducir;
- ningún cambio del historial sale como "Translation missing", en inglés y en castellano.

Y el de etiquetas, antes de confirmar la suya, que cada ítem y cada página tiene exactamente las etiquetas del paquete. Además, todas las órdenes del paso 6 tienen que haber dicho `Jobs queued: none`.

### 7.2. Comparar el historial con el de la instancia antigua

Pinta el historial de cada ítem de la instancia nueva, en el mismo idioma que la referencia del paso 3.2, y lo compara con ella:

```sh
docker exec -u redmine -w /usr/src/redmine "$NUEVO" bundle exec rails runner /tmp/sg/history_text.rb /tmp/sg/historial-destino.jsonl es
docker cp "$NUEVO":/tmp/sg/historial-destino.jsonl migracion/
INFORME=$(grep -l '"dry_run": false' migracion/importado/history-import-*.json); echo "$INFORME"
docker run --rm -v "$PWD:/work" snapshots_gen-converter \
  ruby snapshots_gen/test/compare_history.rb migracion/historial-origen.jsonl migracion/historial-destino.jsonl migracion/convertido/report.json \
  --history migracion/convertido/"$NOMBRE".cshistory \
  --import-report "$INFORME"
```

El `echo` tiene que enseñar un solo fichero: el informe de la importación de verdad del paso 6.3, no el del ensayo (el comparador rechaza el del ensayo).

Tiene que terminar en `Failures (0)` y `Unexplained differences (0)`; devuelve 1 si cualquiera es distinto de cero y 2 si no puede leer o validar las entradas. Antes dice `Items: N in the source, N in the target`. `Explained differences` agrupa los cambios por regla del conversor o entrada concreta de `report.json`; añade `--details` para ver su detalle o `--show CSID` para inspeccionar un ítem. Un detalle perdido sin descarte declarado, un descarte del importador, una referencia a otro ítem, una nota editada y cualquier `Translation missing` son fallos. Las diferencias de presentación que no cubra una regla siguen en `Unexplained differences` y requieren investigación, nunca se aceptan automáticamente.

Un cambio de adjunto que en destino tiene el número 0 solo se explica con su entrada `history_attachment_cleared`: el mismo detalle, journal, ítem, número de adjunto, nombres de fichero y lado, un motivo que cuadre con el origen (`deleted from the source` si allí el adjunto tampoco existe, `not migrated with this item` si existe) y el mismo texto pintado.

Redmine (4.2 y 7) pinta cada cambio de un journal en su línea, salvo los de un campo personalizado múltiple: los valores añadidos a un mismo campo van juntos en una línea ("Añadido Riesgo Alto, Bajo") y los quitados en otra. Por eso un journal con varios cambios de un campo múltiple tiene menos líneas que cambios, en el origen, en el destino o en los dos (en el destino `rqVerif` es un campo nativo y ya no se agrupa). El paso 7 lo explica (`R5b`) solo si las líneas del journal son exactamente las de los demás cambios más, por cada campo múltiple, una línea con exactamente los valores añadidos y otra con los quitados, en cualquier orden pero ni uno más ni uno menos. Cada cambio se compara además uno a uno con su pareja.

Los recuentos de explicaciones son por regla aplicada, no por journal: un detalle puede tener una explicación para sus valores y otra para su presentación.

Los dos JSONL deben generarse con la misma versión de `history_text.rb` (formato `history-text-v2`) y el mismo idioma. Conservan los valores completos, incluso los que el Redmine antiguo oculta al pintar campos de texto largo, y son material sensible. La extracción los crea con modo 600; protege también cualquier salida de `--details` o `--show`. Este paso comprueba historial e identidades, no sustituye la comprobación del estado actual ni la de etiquetas.

### 7.3. Comparar las etiquetas con las de la instancia antigua

Lee por SQL todas las etiquetas de la instancia nueva, sin pasar por el plugin, y las compara con la referencia del paso 3.2:

```sh
docker exec -u redmine -w /usr/src/redmine "$NUEVO" bundle exec rails runner /tmp/sg/tags/extract_target.rb /tmp/sg/etiquetas-destino.jsonl
docker cp "$NUEVO":/tmp/sg/etiquetas-destino.jsonl migracion/
chmod -R go-rwx migracion
docker run --rm -v "$PWD:/work" snapshots_gen-converter \
  ruby snapshots_gen/test/tags/compare.rb migracion/etiquetas-origen.jsonl migracion/etiquetas-destino.jsonl migracion/convertido/report.json
```

La extracción dice `tags evidence: objects=N tags=N assignments=N`. La comparación enseña `Tags: N source, N target` y `Assignments: N source, N target` con los mismos números a los dos lados, `order: not-certified` (el orden de las etiquetas no se conserva, como se dijo) y tiene que terminar en `Failures (0)`, con código 0. Compara cada nombre byte a byte, sin recortar espacios ni cambiar mayúsculas, cada etiqueta de cada ítem y de cada página, sus fechas, los ajustes del plugin y los contadores. Devuelve 1 si hay diferencias y 2 si una de las dos capturas no es válida. Por defecto no enseña nombres de etiquetas, solo huellas; `--show-names` los enseña y su salida es material sensible.

No comprueba quién ve las etiquetas: eso es el 7.4.

### 7.4. Revisar a mano

Entra por el túnel SSH del paso 5.2 (`http://localhost:8080`):

- Como `admin`, abre dos o tres ítems con historial, la wiki de un proyecto y un proyecto privado. El historial tiene que leerse como en la instancia antigua, con sus autores y fechas.
- Con una cuenta normal, sin permisos de administrador y con su contraseña de siempre (por ejemplo, la de un compañero que esté contigo), abre un proyecto en el que sea miembro y un ítem con etiquetas: tiene que ver las etiquetas y, en el historial, los cambios de etiquetas. Si no los ve, a su rol le falta el permiso `view_issue_tags`: mira la línea `Roles:` y los avisos del paso 6.4.

Si no hay nadie con cuenta normal a mano, crea un usuario de prueba después de 7.2 y 7.3, hazlo miembro de un proyecto con etiquetas con el rol que tienen la mayoría (`Developer` o `Reporter`), compruébalo y bórralo al terminar (Administración, Usuarios).

## 8. Abrir la instancia nueva

En el servidor nuevo, solo cuando el paso 7 haya salido bien.

### 8.1. Limpiar el contenedor y hacer una copia de seguridad

Borra del contenedor los paquetes y lo demás que se copió en el paso 5.4, y haz una copia de seguridad de la instancia recién migrada con el script del deploy. Es el punto al que se puede volver después de abrir (paso 9). Guárdala fuera del checkout del deploy y del directorio de trabajo (el paso 10 lo borra), con la terminal todavía en `umask 077`, porque el script crea la copia con los permisos que le da el `umask`:

```sh
docker exec -u 0 "$NUEVO" rm -rf /tmp/sg
docker exec "$NUEVO" test ! -e /tmp/sg && echo "/tmp/sg borrado"
mkdir -p -m 700 <ruta absoluta de las copias>
(cd "$DEPLOY" && ./scripts/backup.sh <ruta absoluta de las copias>)
```

El script imprime el directorio de la copia (`<ruta absoluta de las copias>/<fecha>`). Compruébala:

```sh
COPIA=<el directorio que imprimió>
(cd "$COPIA" && sha256sum -c SHA256SUMS)
grep -E '^(cosmosys_revision|plugin_sets)=' "$COPIA/manifest.env"
```

Los tres ficheros tienen que decir `OK`, y el manifiesto `cosmosys_revision=4d9e1c7e6d3ebf97c76590162fb1b19dd29f1338` y `plugin_sets=tags`. La copia lleva toda la base y los adjuntos: es material sensible. Si se saca del servidor, que sea a un almacenamiento cifrado.

### 8.2. Publicar

Hay tres formas, según lo que se decidiera antes de empezar. En las tres se cambia el fichero de entorno, se vuelve a arrancar la instancia y se comprueba desde fuera. Al volver a arrancar, el contenedor cambia, así que vuelve a definir `NUEVO`:

```sh
(cd "$DEPLOY" && ./scripts/compose.sh up -d --wait)
NUEVO=$(cd "$DEPLOY" && ./scripts/compose.sh ps -q redmine); echo "$NUEVO"
```

En los ejemplos, `cosmosys.example.org` es el nombre público de la instancia. Si la instancia antigua va a seguir accesible con el mismo nombre de host, conserva el `COSMOSYS_SESSION_COOKIE_KEY` propio del paso 5.1.

**Con el proxy del deploy.** Hace falta que el proxy de `cosmoSys_deploy` ya corra en este servidor (su README, "Shared reverse proxy"), que el nombre apunte al servidor y, para un certificado de Let's Encrypt, que los puertos 80 y 443 lleguen desde Internet. Añade al fichero de entorno, sin cambiar `COSMOSYS_BIND_ADDRESS`:

```dotenv
COSMOSYS_PROXY_MODE=shared
COSMOSYS_HOSTNAME=cosmosys.example.org
COSMOSYS_PROXY_TLS=<el correo de la cuenta de Let's Encrypt, o internal>
```

Si el proxy usa una red distinta de `caddy_proxy`, añade también `COSMOSYS_PROXY_NETWORK` con la suya. Al arrancar, el deploy pone en Redmine el nombre y el protocolo `https`, salvo que un administrador ya los haya cambiado; compruébalo con `(cd "$DEPLOY" && ./scripts/compose.sh logs bootstrap)`, que tiene que decir `Configured host_name as cosmosys.example.org` y `Configured protocol as https`.

**Con un proxy propio** (Nginx, Apache, Traefik, Caddy...). Si el proxy corre en el mismo servidor, deja `COSMOSYS_BIND_ADDRESS=127.0.0.1` y apúntalo a `http://127.0.0.1:<COSMOSYS_HTTP_PORT>`; si corre en otra máquina, pon en `COSMOSYS_BIND_ADDRESS` la dirección del servidor en la red que los une y cierra ese puerto a todo lo que no sea el proxy. El proxy tiene que pasar las cabeceras `Host` (el nombre público), `X-Forwarded-For` y `X-Forwarded-Proto` (`https`), admitir subidas al menos tan grandes como el tamaño máximo de adjuntos de Redmine (Administración, Configuración, Ficheros) y esperar varios minutos a las respuestas largas, como las exportaciones. Por ejemplo, en Nginx:

```nginx
location / {
    proxy_pass http://127.0.0.1:<COSMOSYS_HTTP_PORT>;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    client_max_body_size 100m;
    proxy_read_timeout 600s;
}
```

Después, en Redmine (Administración, Configuración, General), pon "Nombre y ruta del servidor" a `cosmosys.example.org` y "Protocolo" a HTTPS: con ellos genera Redmine los enlaces de sus exportaciones, sus fuentes Atom y sus correos, si algún día los hay.

**Sin proxy**, solo dentro de una red de confianza o una VPN. Pon en `COSMOSYS_BIND_ADDRESS` la dirección del servidor en esa red (o `0.0.0.0` para todas sus interfaces) y en `COSMOSYS_HTTP_PORT` el puerto, y limita el acceso a ese puerto con el cortafuegos del servidor. Sin TLS, las contraseñas viajan sin cifrar por la red. En Redmine (Administración, Configuración, General), pon "Nombre y ruta del servidor" a `<dirección o nombre>:<puerto>` y "Protocolo" a HTTP.

Comprueba desde otra máquina de la red de los usuarios:

```sh
curl -sI https://cosmosys.example.org/login | head -n 1
```

(o `http://<dirección o nombre>:<puerto>/login` sin proxy). Tiene que responder `200`. Entra después con el navegador por esa dirección, como `admin`, y navega por un par de proyectos sin que te vuelva a pedir la contraseña.

### 8.3. Abrir a los usuarios

- Avisa a los usuarios: la dirección nueva; que entran con su usuario y su contraseña de siempre; que quien tuviera 2FA tiene que volver a activarlo; que quien entraba por LDAP u otra autenticación externa necesita que un administrador le dé una contraseña; y que la instancia nueva no manda correo, si no se configura.
- Si la organización quiere notificaciones por correo, se configura ahora, ya abierta (queda fuera de este procedimiento). La importación no dejó ninguna en cola.
- Deja la instancia antigua parada pero sin borrar, como vuelta atrás, el tiempo que se haya acordado (por ejemplo, con `docker stop` de sus contenedores).

## 9. Volver atrás

**Antes de abrir** (hasta el paso 8.2), la instancia antigua no ha cambiado: desactiva su modo mantenimiento y sigue trabajando en ella. Para repetir la migración desde cero, destruye la instancia nueva con su base de datos y sus adjuntos:

```sh
echo "$COSMOSYS_ENV_FILE"
(cd "$DEPLOY" && ./scripts/compose.sh down -v)
```

`down -v` borra para siempre la base y los adjuntos de la instancia de `COSMOSYS_ENV_FILE`: comprueba con el `echo` que apunta al fichero de la instancia migrada, y no lo uses nunca con una instancia ya abierta. Después vuelve al paso 5.2 (el fichero de entorno sirve tal cual), o al 3 si la antigua ha cambiado entretanto (y entonces también al 4: los paquetes de dos conversiones no se mezclan).

**Después de abrir**, lo que se haga en la instancia nueva no vuelve a la antigua. Quedan dos salidas, y las dos pierden lo que se haya hecho en la nueva desde que se abrió:

- Volver a la antigua: arráncala y desactiva su modo mantenimiento. Lo hecho en la nueva habría que rehacerlo a mano en la antigua.
- Devolver la nueva al estado recién migrado, restaurando la copia del paso 8.1. Sirve cuando el problema es de uso y no de la migración:

```sh
(cd "$DEPLOY" && RESTORE_CONFIRMATION=ERASE_EXISTING_COSMOSYS_DATA ./scripts/restore.sh "$COPIA")
```

Por eso la instancia antigua parada y la copia del paso 8.1 se conservan el tiempo acordado. Pasado ese tiempo, paso 10.

## 10. Borrar los ficheros de la migración

Cuando la instancia nueva esté abierta y comprobada, borra todo lo que lista la tabla de "Material sensible", salvo el fichero de entorno de la instancia nueva (lo necesita mientras viva) y la copia de seguridad del paso 8.1, que se borra cuando pase el tiempo acordado para volver atrás (o pasa al régimen de copias de la instancia, con el mismo cuidado).

En el servidor antiguo, desde el directorio de trabajo:

```sh
rm -rf migracion
test ! -e migracion && echo "migracion borrado"
```

En el servidor nuevo, desde el directorio de trabajo:

```sh
rm -rf migracion
test ! -e migracion && echo "migracion borrado"
docker exec "$NUEVO" test ! -e /tmp/sg && echo "/tmp/sg borrado"
```

Los dos `echo` tienen que salir. El directorio `/tmp/snapshots_gen-*` del contenedor antiguo ya se borró y se comprobó en el paso 3.

Busca después copias olvidadas en cada máquina por la que hayan pasado los ficheros (los dos servidores, el disco del traslado, tu equipo si los tuvo):

```sh
sudo find / \( -path /proc -o -path /sys \) -prune -o \( -name '*.cslegacy' -o -name '*.cshistory' -o -name '*.csys' -o -name '*.cstags' -o -name 'historial-*.jsonl' -o -name 'etiquetas-*.jsonl' -o -name 'history-import-*.json' -o -name 'tags-import-*.json' \) -print 2>/dev/null
```

No tiene que imprimir nada de esta migración. cosmoSys también exporta proyectos en ficheros `.csys`: si aparece alguno que no es de la migración, déjalo. La imagen `snapshots_gen-converter` y el checkout `snapshots_gen/` no llevan datos; se pueden borrar o conservar (`docker image rm snapshots_gen-converter`).

`rm` no garantiza que los datos desaparezcan del disco: en discos SSD, en sistemas de ficheros con instantáneas y en las copias de seguridad del servidor pueden seguir ahí. La protección de verdad es la de "Material sensible": trabajar en un volumen cifrado y no dejar que el directorio de trabajo entre en otras copias.

## Si algo falla

Cuando haya que pedir ayuda, basta con el mensaje, el paso y, si hace falta, los títulos de `report.md` con sus recuentos (`grep '^###' migracion/convertido/report.md`). Nunca los paquetes, los informes enteros ni los JSONL (ver "Material sensible").

| Mensaje | Paso | Qué pasa y qué hacer |
| --- | --- | --- |
| `No such container` | cualquiera | La variable `ANTIGUO` o `NUEVO` está vacía o no es la del contenedor, por ejemplo porque has abierto otra terminal o porque el contenedor se ha recreado. Vuelve a definirla ("Preparar el directorio de trabajo" y paso 5.2). |
| `cannot load such file -- /tmp/...` (`LoadError`) o `... could not be found` | 1, 3, 6, 7 | El usuario `redmine` del contenedor no puede leer el código copiado. Repite el `chown` del paso 1 (contenedor antiguo) o del 5.4 (contenedor nuevo). |
| `Tags: no additional_tags and additional_taggings tables` | 1 | La instancia antigua no tiene el plugin de etiquetas, y la conversión se bloqueará (`missing_table`). Para y pregunta antes de seguir. |
| `the package does not verify` | 3, 4 | El paquete está dañado o incompleto, por ejemplo por una copia cortada. Vuelve a copiarlo (paso 3.4) o a exportar. |
| `row counts changed during the capture` | 3 | Alguien cambió la instancia antigua mientras se exportaba. Congélala (paso 2) y repite el paso 3. |
| `output already exists` | 3.2, 7.3 | La extracción de etiquetas no sobrescribe nunca un fichero. Bórralo dentro del contenedor (o usa otro nombre) y repite. |
| `Unable to find image 'snapshots_gen-converter:latest' locally` o `pull access denied for snapshots_gen-converter` | 4, 7 | La imagen del conversor no está construida en este servidor. Constrúyela con la primera orden del paso 4. |
| `migracion/convertido already exists` | 4 | Ya hubo una conversión. Para repetirla, borra `migracion/convertido`; si ya importaste algo, empieza también de nuevo desde el paso 5. |
| `blocking: true` (y código 1) | 4 | `report.md` tiene algo en `Blocking`, por ejemplo `tags_blocking` si el `.cstags` no es importable. No se puede seguir sin resolverlo; los títulos de `report.md` dicen qué es. |
| `Set POSTGRES_PASSWORD in .env` (o la misma frase con otra variable) | 5 | Al fichero de entorno le falta esa variable, o `COSMOSYS_ENV_FILE` no está exportada en esta terminal. |
| `COSMOSYS_ENV_FILE does not exist` | 5, 8, 9 | La variable apunta a un fichero que no existe. Revisa la ruta (absoluta). |
| `Missing trackers (the .csys import will refuse their items): ...` | 6.1 | Falta en la instancia nueva un tracker con ítems en la antigua. Créalo (paso 5.3) y repite el 6.1. |
| `BLOCKING: Required trackers are unavailable: ...` | 6.2 | Lo mismo, visto por el preflight. No se ha escrito nada: crea el tracker (paso 5.3) y repite ese paquete. |
| `BLOCKING: Destination project identifiers are already used: ...` | 6.2 | La instancia nueva ya tiene un proyecto con ese identificador. Si es porque ese paquete ya se importó, pasa al siguiente: cada paquete se importa una sola vez. Si no, la instancia no estaba recién creada: empieza de nuevo desde el paso 5. |
| `Validation failed: Relation type is invalid` después de `Preflight passed` | 6.2 | El paquete tiene relaciones PORIS, que no se pueden migrar todavía (ver "Qué hace y qué no"). Ese paquete no ha escrito nada. Para y pregunta. |
| `projects not imported yet` | 6.3, 6.4 | Falta importar algún `.csys` (paso 6.2). |
| `journals already exist on the imported items` | 6.3 | Alguien ha trabajado en la instancia nueva antes de importar el historial. Empieza de nuevo desde el paso 5. |
| `active webhooks exist` | 6.3 | Desactiva los webhooks de la instancia nueva durante la importación. |
| `verification failed, nothing was written` | 6.3 | El historial no se ha importado. La lista dice qué no cuadra; pide ayuda con ella y con los títulos de `report.md`. |
| `WARNING: the importer dropped N records that the conversion report does not announce` | 6.3 | El importador ha descartado algo que la conversión no anunciaba: el paso 7.2 lo contará como fallo. Los registros están en `dropped` del informe de importación; pide ayuda con sus recuentos (`dropped_counts`) antes de abrir. |
| `WARNING: jobs queued during the import` | 6 | Algo se encoló durante la importación; la línea dice qué. Comprueba que la instancia no tiene correo configurado (paso 5.2) y pregunta antes de abrir. |
| `the tags package does not verify` | 6.4 | El `.cstags` está dañado, o en `/tmp/sg/pkg` no están exactamente el `.cshistory` y todos los `.csys` de la misma conversión (`not the ones this tags package was converted with`). Vuelve a copiar los paquetes de `migracion/convertido/` (paso 5.4) y quita cualquier otro. |
| `the tags package is not importable` | 6.4 | La conversión encontró etiquetas que el plugin nuevo no puede guardar igual (`tags_blocking` en `report.md`, paso 4). No se puede seguir sin decidir qué hacer con ellas; pide ayuda con los títulos de `report.md`. |
| `the tag plugin is not ready in this instance` | 6.4 | La instancia nueva no tiene el conjunto `tags`, o sus migraciones no se han aplicado. Créala con `COSMOSYS_PLUGINS=tags` (paso 5.1). |
| `the tag tables are not the ones this importer knows` | 6.4 | El plugin de etiquetas de la instancia nueva no es el que este procedimiento conoce (`additional_tags` 4.6). No se ha escrito nada; pide ayuda con el mensaje. |
| `the history is not imported yet` | 6.4 | Las etiquetas van después del historial (paso 6.3). |
| `the history in this instance is not the one of this history package` | 6.4 | Los cambios de etiquetas del historial de la instancia nueva no son los del `.cshistory` que hay junto al `.cstags`: el historial se importó de otra conversión, o alguien ha editado ítems. No se ha escrito nada. Empieza de nuevo desde el paso 5 con los paquetes de una sola conversión. |
| `objects of the package that are not exactly one object here` | 6.4 | Falta importar algún `.csys`, o un ítem o una página del paquete no está en la instancia nueva (o está más de una vez). No se ha escrito nada; pide ayuda con el mensaje. |
| `conflicts with tags that already exist in this instance` | 6.4 | La instancia nueva ya tenía etiquetas que no son las del paquete en los mismos ítems, o con el mismo nombre y otras fechas, o que solo se distinguen por las mayúsculas. Alguien ha trabajado en ella: empieza de nuevo desde el paso 5. |
| `verification failed, nothing was written` (en `tags`) | 6.4 | Lo escrito no coincide con el paquete o ha cambiado algo más. Las etiquetas no se han importado. La lista nombra ítems y etiquetas por número y huella, sin nombres; pide ayuda con ella. |
| `regenerate both extracts with history_text.rb v2` | 7.2 | La referencia del paso 3.2 se tomó con otra revisión de `snapshots_gen`. Usa la misma en los dos servidores y vuelve a tomar la referencia (la instancia antigua sigue congelada). |
| `use a real import report, not a dry run` | 7.2 | `INFORME` apunta al informe del ensayo. Vuelve a definirlo con la orden del paso 7.2. |
| `Failures (N)` o `Unexplained differences (N)` distintos de 0 | 7.2 | No abras la instancia. Mira el detalle en privado con `--details` o `--show CSID` y pide ayuda con los recuentos de cada grupo, sin el texto de los ítems. |
| `Failures (N)` distinto de 0 | 7.3 | No abras la instancia. Cada línea empieza por el tipo de diferencia (por ejemplo, `object_coverage`) y lleva huellas, no nombres: pide ayuda con esas líneas. |
