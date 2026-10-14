# Migrar una instancia antigua de cosmoSys

Este procedimiento lleva una instancia antigua de cosmoSys (Redmine 4.2 con los plugins `cosmosys_*`) a una instancia nueva de cosmoSys (Redmine 7), con su historial: notas, cambios, versiones de wiki, tiempo dedicado, observadores, usuarios con su contraseña, autores y fechas. Está escrito para seguirlo de principio a fin sin ayuda.

## Qué hace y qué no

- **La instancia antigua no se toca.** Solo se lee, dentro de una transacción de solo lectura. No se instala nada, no se migra la base de datos y no se reinicia el contenedor. Lo único que se escribe es un directorio temporal dentro del contenedor, que se borra al terminar.
- **La instancia nueva tiene que estar vacía y cerrada** hasta el final del paso 7. Nadie debe trabajar en ella antes de importar el historial: Redmine usa el orden de las notas en varias funciones, y un historial añadido después quedaría desordenado. El importador se niega si encuentra notas que no sean suyas.
- **Lo que no se migra** lo dice el informe de conversión. Entre otras cosas: lo que el cosmoSys antiguo nunca guardó en el historial (los botones de borrar y zombi, mover y reordenar en el árbol, las importaciones ODS y git), las noticias, los foros y los repositorios. Las etiquetas y la conversión de los modelos PORIS llegan en una fase posterior.
- **Las contraseñas se conservan**: Redmine 4.2 y 7 las guardan igual. **El 2FA se reinicia**: quien lo usaba tiene que volver a activarlo.

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

Para otro reparto, añade `roles=rqReviewer:Reporter,...` a `importar history` (paso 6.3). Un rol sin destino deja sin importar sus membresías, y el paso 6.1 lo avisa.

**Campos de los ítems:**

| Antes | Después |
| --- | --- |
| `rqType` (Complex, Opt, Mech, Hw, Sw) | tipo de requisito (complex, optical, mechanical, hardware, software) |
| `rqLevel`, `rqRationale`, `rqSources` | nivel, justificación y fuentes del requisito |
| `rqComplanceState`, `rqComplianceJustif` | estado y justificación del cumplimiento |
| `rqVerif`, `rqVerifDescr` | métodos y descripción de la verificación |
| `csOldCode`, `csWload` | código externo y carga de trabajo (`csExtCode`, `csWLoad`) |
| `rqVar` y `rqValue` | un dato de proyecto (`csDatum`) con ese nombre y ese valor, bajo un capítulo "Project data" |
| `rqAplDocs`, `rqRefDocs`, `rqComplianceDocs` | referencias del catálogo de documentos; el texto que no es una referencia se conserva como campo personalizado |
| `csID`, `csChapter`, `depGrahInReports` | nada: el CSID y el capítulo son nativos, y la marca de informe no tiene equivalente |
| cualquier otro campo personalizado | el mismo campo, con su definición |

El historial sigue a los campos: un cambio antiguo de `rqLevel` se ve como cambio del nivel de requisito, con los valores nuevos. Hasta que cosmoSys etiquete `csExtCode` y `csWLoad` en el historial (corrección preparada), sus cambios, también los que se hagan en la instancia nueva, se leen "Translation missing"; el paso 7 lo avisa sin darlo por fallo.

**Estructura:**

- Los ítems `AD n`, `RD n` y `CD n` pasan a ser documentos del proyecto, con su posición en el catálogo. Si el título trae código, versión y fecha, se extraen.
- Un requisito o un `csRefDoc` con hijos queda dentro de un capítulo generado, "Group: <título>", porque en el modelo nuevo no pueden tener hijos.
- Los CSID se conservan, también los que tienen el prefijo de otro proyecto porque el ítem se movió. Solo se renumera un ítem sin CSID o con uno repetido en su árbol.
- En los modelos PORIS, una relación "bloquea" va al revés que antes: el modo bloquea lo que incluye (sus submodos y sus valores). La conversión invierte esas relaciones y sus cambios en el historial.

**Personas:** los usuarios se emparejan por login. Si ya existían en la instancia nueva (como `admin`), conservan su contraseña y toman el nombre de origen. Si no, se crean con su contraseña de siempre. El asignado de cada ítem llega con el historial (paso 6.3), porque Redmine solo deja asignar a miembros del proyecto.

## Qué hace falta

- En el servidor antiguo: acceso a `docker` y el nombre del contenedor de la instancia (en este documento, `<contenedor-antiguo>`; en el despliegue antiguo suele ser `csys_rm-<nombre>`).
- En el servidor nuevo: Docker, un checkout de `cosmoSys_deploy` en la rama `feat/optional-plugins` y espacio para una instancia nueva.
- En cualquiera de los dos: este repositorio, `snapshots_gen`, y Docker para el conversor.
- Un sitio seguro para los paquetes. **Llevan los datos de todos los usuarios, con sus correos y sus contraseñas cifradas:** se tratan como una copia de seguridad, no se envían por correo y se borran al terminar (paso 10).

En los ejemplos, `snapshots_gen/` es el checkout de este repositorio y `migracion/` el directorio de trabajo, con permisos solo para su dueño:

```sh
mkdir -m 700 migracion
```

## 1. Inventario

El inventario cuenta lo que hay sin sacar contenido: versiones, plugins, trackers, estados, campos, notas por tipo de cambio, versiones de wiki con huecos, usuarios con 2FA y los ajustes de formato de texto. Se pasa primero para saber si la instancia tiene algo que el procedimiento no cubre.

```sh
docker cp snapshots_gen/exporter <contenedor-antiguo>:/tmp/snapshots_gen-exporter
docker exec -u redmine -w /usr/src/redmine <contenedor-antiguo> \
  bundle exec rails runner -e production /tmp/snapshots_gen-exporter/export.rb inventory out=/tmp/snapshots_gen-out
docker cp <contenedor-antiguo>:/tmp/snapshots_gen-out migracion/inventario
```

La orden imprime un resumen y deja el inventario completo en `migracion/inventario/inventory-*.json`. Comprueba en el resumen:

- `text_formatting="markdown"`. Si dice `textile`, para: esa conversión no está cubierta.
- `Trackers` y `Statuses`: los de cosmoSys (`rq`, `csInfo`, `csRefDoc`, estados `rq*`, `csNone`) se convierten solos. Cualquier otro tracker con ítems (`Bug`, `Task`, `prSys`...) tiene que existir con el mismo nombre en la instancia nueva (paso 5).
- `Users`: cuántos tienen 2FA y si alguno usa autenticación externa (LDAP). Los de autenticación externa no tienen contraseña en Redmine y no podrán entrar hasta que se les dé una.
- `Ambiguous Markdown tables`: tablas Markdown con la cabecera sangrada, que el cosmoSys nuevo enseña como código. No bloquean; el informe de conversión dice dónde están.

Si algo de esto no cuadra, manda el `inventory-*.json` antes de seguir. No lleva contenido de la instancia.

## 2. Congelar la instancia antigua

Desde aquí hasta el final nadie debe cambiar nada en la instancia antigua, o esos cambios no llegarán a la nueva. Avisa a los usuarios y activa el modo mantenimiento (Administración, Plugins, Redmine Maintenance Mode), o como mínimo deja de usarla.

## 3. Exportar

```sh
docker exec -u redmine -w /usr/src/redmine <contenedor-antiguo> \
  bundle exec rails runner -e production /tmp/snapshots_gen-exporter/export.rb capture out=/tmp/snapshots_gen-out label=<nombre>
docker cp <contenedor-antiguo>:/tmp/snapshots_gen-out migracion/exportado
docker exec -u 0 <contenedor-antiguo> rm -rf /tmp/snapshots_gen-exporter /tmp/snapshots_gen-out
```

`<nombre>` es una etiqueta corta para la instancia, con letras, números, `-` o `_` (por ejemplo, `est`). El exportador lee todo en una sola transacción de solo lectura, copia los adjuntos, comprueba que los recuentos no han cambiado mientras leía y verifica el paquete antes de terminar. Al final dice:

```text
Captured N tables, N rows, N attachment rows.
Gaps: none.
Package written to /tmp/snapshots_gen-out/<nombre>-<fecha>.cslegacy (...), verified.
```

`Gaps` lista lo que no se pudo copiar tal cual, normalmente adjuntos cuyo fichero ya no existe. No impide seguir; el informe de conversión los repite.

Para comprobar el paquete en otro sitio (por ejemplo, después de copiarlo):

```sh
docker build -t snapshots_gen-converter snapshots_gen/converter
docker run --rm -v "$PWD:/work" snapshots_gen-converter \
  ruby snapshots_gen/bin/verify-legacy-snapshot migracion/exportado/<nombre>-<fecha>.cslegacy
```

## 4. Convertir

```sh
docker run --rm -u "$(id -u):$(id -g)" -v "$PWD:/work" snapshots_gen-converter \
  ruby snapshots_gen/converter/convert.rb migracion/exportado/<nombre>-<fecha>.cslegacy migracion/convertido
```

Deja en `migracion/convertido/`:

- un `.csys` por cada proyecto raíz de la instancia antigua (`<nombre>-<identificador>.csys`), con sus subproyectos;
- `<nombre>.cshistory`, el paquete de historial y usuarios;
- `report.md` y `report.json`, el informe de conversión.

**Lee `report.md` antes de seguir.** Está ordenado por gravedad:

- `Blocking`: no se puede seguir. La orden termina con código 1.
- `Warning`: algo se pierde o se adapta y conviene saberlo: adjuntos sin fichero, referencias `#id` a ítems que no existen, cambios del historial que no se pueden traducir, tablas Markdown ambiguas.
- `Transformation`: lo que la conversión cambia a propósito, por ejemplo los estados `rqDraft` a `Draft`, los campos `rq*` a los campos nativos, los ítems `AD n`/`RD n`/`CD n` a documentos o los CSID renumerados.
- `Information`: lo que no se puede recuperar porque nunca se guardó, los usuarios cuyo 2FA se reinicia y los roles de las membresías.

## 5. Crear la instancia nueva

Crea una instancia nueva y vacía con `cosmoSys_deploy`, rama `feat/optional-plugins`, siguiendo su README:

- variante `requirements` si la instancia antigua tenía requisitos (tracker `rq`);
- el conjunto opcional `poris` si el inventario muestra ítems de los trackers `pr*`: trae `prSys`, `prParam`, `prMode`, `prValue` y `prCmd`, y la conversión lleva `prValFloat` y `prValText` a `prValue`;
- un administrador propio (`COSMOSYS_INITIAL_ADMIN_PASSWORD`). Si en la instancia antigua había un usuario `admin`, se empareja con este y se queda con la contraseña nueva.

No la publiques todavía y no dejes entrar a nadie. En el resto del documento, `<contenedor-nuevo>` es su contenedor de Redmine (`<proyecto>-redmine-1`).

Si la instancia antigua tenía trackers fuera de cosmoSys con ítems (paso 1), créalos ahora con el mismo nombre (Administración, Tipos de petición), o la importación del paso 6 se negará a importar sus ítems.

Copia en el contenedor el importador y los paquetes:

```sh
docker exec -u 0 <contenedor-nuevo> mkdir -p /tmp/sg/pkg
docker cp snapshots_gen/exporter <contenedor-nuevo>:/tmp/sg/exporter
docker cp snapshots_gen/importer <contenedor-nuevo>:/tmp/sg/importer
for f in migracion/convertido/*.csys migracion/convertido/*.cshistory; do docker cp "$f" <contenedor-nuevo>:/tmp/sg/pkg/; done
docker exec -u 0 <contenedor-nuevo> chown -R redmine:redmine /tmp/sg
```

Para no repetir la orden larga, define:

```sh
importar() { docker exec -u redmine -w /usr/src/redmine <contenedor-nuevo> bundle exec rails runner /tmp/sg/importer/import.rb "$@"; }
```

## 6. Importar

Son tres pasos, siempre en este orden.

**6.1. Preparar:** crea los usuarios que falten, con su contraseña, los grupos, las definiciones de los campos personalizados que se conservan y las actividades de tiempo. Empareja por login los usuarios que ya existan. Repetirlo no duplica nada.

```sh
importar prepare /tmp/sg/pkg/<nombre>.cshistory
```

Revisa lo que dice de los roles (`Role rqWriter -> Developer`...). Si un rol antiguo no tiene destino, sus membresías no se importarán; créalo en la instancia nueva o indica otro con `roles=rqWriter:Developer,...` en el paso 6.3.

**6.2. Importar cada `.csys`:** primero sin confirmar, que solo enseña el preflight de cosmoSys (el mismo que la interfaz):

```sh
importar csys /tmp/sg/pkg/<nombre>-<identificador>.csys
```

Si termina en `Preflight passed`, impórtalo:

```sh
importar csys /tmp/sg/pkg/<nombre>-<identificador>.csys confirm=yes
```

Repite con cada `.csys`. Si el preflight dice `BLOCKING`, corrige lo que indique (normalmente un tracker o un campo que falta) y vuelve a empezar este paso; nada se ha escrito.

**6.3. Importar el historial**, primero en ensayo (escribe todo, lo verifica y lo deshace):

```sh
importar history /tmp/sg/pkg/<nombre>.cshistory dry_run=yes
```

Si termina en `Dry run: everything was rolled back.`, impórtalo de verdad:

```sh
importar history /tmp/sg/pkg/<nombre>.cshistory
```

Todo ocurre en una sola transacción: o queda todo importado y verificado, o no queda nada. Al final dice cuántos journals, versiones de wiki, entradas de tiempo, observadores y membresías ha escrito, y deja un informe en `/tmp/sg/pkg/history-import-<fecha>.json` con lo que no pudo traducir. Cópialo:

```sh
docker cp <contenedor-nuevo>:/tmp/sg/pkg/. migracion/importado
```

## 7. Comprobar

El importador ya verifica, antes de confirmar la transacción, que:

- los journals y los cambios escritos son los esperados;
- ninguna nota sale como "Editada" y sus números siguen el orden de las fechas;
- ningún cambio nombra un estado, tracker, usuario, versión, categoría, proyecto, ítem o adjunto que no exista;
- no queda ninguna referencia sin traducir;
- ningún cambio del historial sale como "Translation missing", en inglés y en castellano.

Además, compara el historial de cada ítem con el de la instancia antigua. Esta comprobación solo lee en las dos:

```sh
docker cp snapshots_gen/test/history_text.rb <contenedor-antiguo>:/tmp/history_text.rb
docker exec -u redmine -w /usr/src/redmine <contenedor-antiguo> bundle exec rails runner -e production /tmp/history_text.rb /tmp/origen.jsonl es
docker cp <contenedor-antiguo>:/tmp/origen.jsonl migracion/
docker exec -u 0 <contenedor-antiguo> rm -f /tmp/history_text.rb /tmp/origen.jsonl
docker cp snapshots_gen/test/history_text.rb <contenedor-nuevo>:/tmp/sg/history_text.rb
docker exec -u redmine -w /usr/src/redmine <contenedor-nuevo> bundle exec rails runner /tmp/sg/history_text.rb /tmp/sg/destino.jsonl es
docker cp <contenedor-nuevo>:/tmp/sg/destino.jsonl migracion/
docker run --rm -v "$PWD:/work" snapshots_gen-converter \
  ruby snapshots_gen/test/compare_history.rb migracion/origen.jsonl migracion/destino.jsonl migracion/convertido/report.json
```

Tiene que terminar en `Failures (0)`. Antes enseña las diferencias que la conversión hace a propósito (estados y campos renombrados, números de ítem nuevos, relaciones PORIS invertidas), para revisarlas. Un fallo nombra el ítem por su CSID y lo que no coincide. La línea "Labels cosmoSys lacks for its own native fields" no es un fallo de la migración: es la etiqueta de `csExtCode` y `csWLoad` que le falta a cosmoSys (ver "Qué cambia en la conversión").

Por último, entra como administrador y abre dos o tres ítems con historial, la wiki y un proyecto privado con un usuario normal (con su contraseña de siempre).

## 8. Abrir la instancia nueva

- Publica la instancia y avisa a los usuarios: entran con su usuario y su contraseña de siempre, y quien tuviera 2FA tiene que volver a activarlo.
- Borra el directorio temporal del contenedor: `docker exec -u 0 <contenedor-nuevo> rm -rf /tmp/sg`.
- Deja la instancia antigua parada pero sin borrar, como vuelta atrás, el tiempo que se haya acordado.

## 9. Volver atrás

Hasta el paso 8, volver atrás es simplemente no usar la instancia nueva: la antigua no ha cambiado. Desactiva su modo mantenimiento y sigue trabajando en ella. Para repetir la migración desde cero, destruye la instancia nueva con su base de datos (`docker compose down -v` con las opciones de tu despliegue) y vuelve al paso 5, o al paso 3 si la antigua ha cambiado entretanto.

Después del paso 8, lo que se haya hecho en la instancia nueva no vuelve a la antigua.

## 10. Borrar los paquetes

Cuando la instancia nueva esté abierta y comprobada, borra `migracion/` y cualquier copia de los paquetes `.cslegacy` y `.cshistory`: tienen las contraseñas cifradas y los correos de todos los usuarios.

## Si algo falla

| Mensaje | Qué pasa y qué hacer |
| --- | --- |
| `the package does not verify` | El paquete está dañado o incompleto, por ejemplo por una copia cortada. Vuelve a copiarlo o a exportar. |
| `row counts changed during the capture` | Alguien cambió la instancia antigua mientras se exportaba. Congélala (paso 2) y repite el paso 3. |
| `BLOCKING: ... trackers missing` | Falta en la instancia nueva un tracker con ítems en la antigua. Créalo con el mismo nombre y repite el paso 6.2. |
| `BLOCKING: ... identifiers taken` | La instancia nueva ya tiene un proyecto con ese identificador. Tiene que estar vacía (paso 5). |
| `projects not imported yet` | Falta importar algún `.csys` (paso 6.2). |
| `journals already exist on the imported items` | Alguien ha trabajado en la instancia nueva antes de importar el historial. Empieza de nuevo desde el paso 5. |
| `verification failed, nothing was written` | El historial no se ha importado. La lista dice qué no cuadra; manda el mensaje y el informe de conversión. |
| `active webhooks exist` | Desactiva los webhooks de la instancia nueva durante la importación. |
