#!/bin/bash

# Asegurar que las herramientas de Postgres (con soporte zstd) estén en el PATH si existen
find_zstd_pg_restore() {
    local candidate
    # 1. Revisar el pg_restore actual en PATH
    if command -v pg_restore >/dev/null 2>&1; then
        candidate="$(command -v pg_restore)"
        if otool -L "$candidate" 2>/dev/null | grep -q "zstd" || ldd "$candidate" 2>/dev/null | grep -q "zstd"; then
            echo "$candidate"
            return 0
        fi
    fi
    # 2. Buscar en Postgres.app y Homebrew (macOS / Linux)
    for candidate in \
        /Applications/Postgres.app/Contents/Versions/latest/bin/pg_restore \
        /Applications/Postgres.app/Contents/Versions/18/bin/pg_restore \
        /Applications/Postgres.app/Contents/Versions/17/bin/pg_restore \
        /Applications/Postgres.app/Contents/Versions/16/bin/pg_restore \
        /opt/homebrew/opt/postgresql@18/bin/pg_restore \
        /opt/homebrew/opt/postgresql@17/bin/pg_restore \
        /opt/homebrew/opt/postgresql@16/bin/pg_restore \
        /opt/homebrew/Cellar/postgresql@*/*/bin/pg_restore \
        /usr/lib/postgresql/*/bin/pg_restore; do
        if [ -x "$candidate" ]; then
            if otool -L "$candidate" 2>/dev/null | grep -q "zstd" || ldd "$candidate" 2>/dev/null | grep -q "zstd"; then
                echo "$candidate"
                return 0
            fi
        fi
    done
    return 1
}

ZSTD_PG_RESTORE="$(find_zstd_pg_restore || true)"
if [ -n "$ZSTD_PG_RESTORE" ]; then
    export PATH="$(dirname "$ZSTD_PG_RESTORE"):$PATH"
fi

# Función para restaurar un archivo custom (.pgc / .dump) validando soporte zstd o usando Docker como fallback
run_pg_restore_safe() {
    local target_port="$1"
    local target_db="$2"
    local dump_file="$3"
    local restore_err

    restore_err="$(mktemp)"
    if pg_restore -j 4 -p "$target_port" -d "$target_db" --no-owner --no-privileges "$dump_file" 2>"$restore_err"; then
        rm -f "$restore_err"
        return 0
    fi

    # Si falló porque el pg_restore local no soporta compresión zstd
    if grep -qi "does not support compression with zstd" "$restore_err"; then
        echo "⚠️  El pg_restore actual ($(command -v pg_restore)) no tiene soporte para compresión zstd."
        if [ -n "$ZSTD_PG_RESTORE" ] && [ "$ZSTD_PG_RESTORE" != "$(command -v pg_restore)" ]; then
            echo "🔄 Reintentando con binario que sí soporta zstd: $ZSTD_PG_RESTORE"
            if "$ZSTD_PG_RESTORE" -j 4 -p "$target_port" -d "$target_db" --no-owner --no-privileges "$dump_file"; then
                rm -f "$restore_err"
                return 0
            fi
        elif command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
            echo "🐳 Usando contenedor temporal postgres:16-alpine (con zstd) para restaurar hacia el Postgres local..."
            if docker run --rm \
                -v "$(cd "$(dirname "$dump_file")" && pwd)/$(basename "$dump_file"):/tmp/dump.pgc:ro" \
                postgres:16-alpine \
                pg_restore -h host.docker.internal -p "$target_port" -U "$(whoami)" -d "$target_db" --no-owner --no-privileges -j 4 /tmp/dump.pgc; then
                rm -f "$restore_err"
                return 0
            fi
        else
            cat "$restore_err"
            rm -f "$restore_err"
            echo "❌ Error: El dump está comprimido con zstd y ningún pg_restore local tiene soporte zstd (ni Docker está activo)."
            echo "💡 Instala postgresql@16+ con Homebrew (brew install postgresql@17) o inicia Docker."
            return 1
        fi
    fi

    # En pg_restore algunos warnings no fatales devuelven código != 0; verificar si se crearon tablas
    local table_count
    table_count=$(psql -p "$target_port" -d "$target_db" -t -A -c "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public';" 2>/dev/null | tr -d '[:space:]')
    rm -f "$restore_err"
    if [ -n "$table_count" ] && [ "$table_count" -gt 0 ]; then
        return 0
    fi
    return 1
}

# Función para manejar la interrupción con Control+C
cleanup() {
    echo ""
    echo "⚠️  Proceso interrumpido por el usuario (Ctrl+C)"
    echo "🧹 Limpiando procesos y archivos temporales..."
    
    # Limpiar archivos descomprimidos si existen
    if [ -n "$DOWNLOAD_DIR" ] && [ -n "$DB_NAME" ] && [ -d "$HOME/$DOWNLOAD_DIR/$DB_NAME" ]; then
        echo "🗑️  Eliminando archivos temporales: $HOME/$DOWNLOAD_DIR/$DB_NAME"
        rm -rf "$HOME/$DOWNLOAD_DIR/$DB_NAME"
    fi

    # Limpiar dump temporal descargado desde instalador .sh si existe
    if [ -n "$TMP_SH_DUMP" ] && [ -f "$TMP_SH_DUMP" ]; then
        echo "🗑️  Eliminando dump temporal: $TMP_SH_DUMP"
        rm -f "$TMP_SH_DUMP"
    fi
    
    # Limpiar filestore parcial si existe
    if [ -n "$FILESTORE_PATH" ] && [ -n "$DB_NAME" ] && [ -d "$FILESTORE_PATH/$DB_NAME" ]; then
        echo "🗑️  Eliminando filestore parcial: $FILESTORE_PATH/$DB_NAME"
        rm -rf "$FILESTORE_PATH/$DB_NAME"
    fi
    
    echo "❌ Script cancelado completamente"
    exit 130
}

# Configurar trap para capturar Control+C (SIGINT) y SIGTERM
trap cleanup SIGINT SIGTERM

# Función para sugerir la opción correcta cuando el archivo no coincide o no es compatible con la opción elegida
suggest_compatible_option() {
    local base_dir="${HOME}/${DOWNLOAD_DIR:-Downloads}"
    local target_name="$1"
    local chosen_mode="$2"
    local clean_name="${target_name%.zip}"
    clean_name="${clean_name%.sql}"
    clean_name="${clean_name%.dump}"
    clean_name="${clean_name%.pgc}"
    clean_name="${clean_name%.sh}"

    echo ""
    echo "🔎 Buscando archivos alternativos o compatibles en $base_dir..."
    local found_any=false

    if [ "$chosen_mode" != "zip" ] && [ -f "$base_dir/$clean_name.zip" ]; then
        echo "💡 Se encontró un archivo ZIP ($clean_name.zip). Ejecuta:"
        echo "   $0 $clean_name"
        found_any=true
    fi
    if [ "$chosen_mode" != "sql" ] && [ -f "$base_dir/$clean_name.sql" ]; then
        echo "💡 Se encontró un archivo SQL ($clean_name.sql). Usa la opción -sql:"
        echo "   $0 $clean_name -sql"
        found_any=true
    fi
    if [ "$chosen_mode" != "dump" ] && [ -f "$base_dir/$clean_name.dump" ]; then
        echo "💡 Se encontró un archivo DUMP ($clean_name.dump). Usa la opción -dump:"
        echo "   $0 $clean_name -dump"
        found_any=true
    fi
    if [ "$chosen_mode" != "dump" ] && [ -f "$base_dir/$clean_name.pgc" ]; then
        echo "💡 Se encontró un archivo PGC ($clean_name.pgc). Renómbralo a .dump y usa -dump:"
        echo "   mv \"$base_dir/$clean_name.pgc\" \"$base_dir/$clean_name.dump\" && $0 $clean_name -dump"
        found_any=true
    fi

    local matching_sh
    matching_sh=$(ls "$base_dir"/install-*"$clean_name"*.sh "$base_dir"/"$clean_name"*.sh 2>/dev/null | head -n 1 || true)
    if [ "$chosen_mode" != "file" ] && [ -n "$matching_sh" ]; then
        echo "💡 Se encontró un script instalador ($(basename "$matching_sh")). Usa la opción -file:"
        echo "   $0 $clean_name -file $(basename "$matching_sh")"
        found_any=true
    fi

    if [ "$found_any" = false ]; then
        echo "📂 Archivos relacionados disponibles actualmente en $base_dir:"
        ls -1 "$base_dir" 2>/dev/null | grep -iE "\.(zip|sql|dump|pgc|sh)$" | head -n 10 | sed 's/^/   • /' || echo "   (Ninguno encontrado)"
    fi
    echo ""
}

# Función para validar el contenido real (magic bytes / formato) de un archivo frente a la opción elegida
validate_file_compatibility() {
    local file_path="$1"
    local expected_mode="$2"
    local magic_header file_desc

    [ -f "$file_path" ] || return 0
    magic_header="$(head -c 5 "$file_path" 2>/dev/null || true)"
    file_desc="$(file -b "$file_path" 2>/dev/null || true)"

    case "$expected_mode" in
        sql)
            if [ "$magic_header" = "PGDMP" ]; then
                echo "❌ Error de compatibilidad: '$file_path' NO es un texto SQL plano, es un DUMP binario de PostgreSQL (PGDMP)."
                echo "💡 Sugerencia: Usa la opción '-dump' en lugar de '-sql':"
                echo "   mv \"$file_path\" \"${file_path%.sql}.dump\" && $0 $DB_NAME -dump"
                exit 1
            elif echo "$file_desc" | grep -qi "Zip archive"; then
                echo "❌ Error de compatibilidad: '$file_path' es un archivo comprimido ZIP, no un SQL plano."
                echo "💡 Sugerencia: Ejecútalo sin '-sql' (modo ZIP por defecto)."
                exit 1
            elif head -n 1 "$file_path" 2>/dev/null | grep -q "^#!/bin/.*sh"; then
                echo "❌ Error de compatibilidad: '$file_path' es un script instalador (.sh), no un archivo SQL."
                echo "💡 Sugerencia: Usa la opción '-file':"
                echo "   $0 $DB_NAME -file $(basename "$file_path")"
                exit 1
            fi
            ;;
        zip)
            if [ "$magic_header" = "PGDMP" ]; then
                echo "❌ Error de compatibilidad: '$file_path' es un DUMP binario de PostgreSQL (PGDMP), no un archivo ZIP."
                echo "💡 Sugerencia: Usa la opción '-dump':"
                echo "   mv \"$file_path\" \"${file_path%.zip}.dump\" && $0 $DB_NAME -dump"
                exit 1
            elif head -n 1 "$file_path" 2>/dev/null | grep -q "^#!/bin/.*sh"; then
                echo "❌ Error de compatibilidad: '$file_path' es un script instalador (.sh), no un archivo ZIP."
                echo "💡 Sugerencia: Usa la opción '-file':"
                echo "   $0 $DB_NAME -file $(basename "$file_path")"
                exit 1
            elif ! echo "$file_desc" | grep -qi "Zip archive"; then
                echo "❌ Error de compatibilidad: '$file_path' no es un archivo ZIP válido (detectado: $file_desc)."
                suggest_compatible_option "$DB_NAME" "zip"
                exit 1
            fi
            ;;
        dump)
            if echo "$file_desc" | grep -qi "Zip archive"; then
                echo "❌ Error de compatibilidad: '$file_path' es un archivo ZIP, no un archivo DUMP."
                echo "💡 Sugerencia: Ejecútalo sin '-dump' (modo ZIP):"
                echo "   mv \"$file_path\" \"${file_path%.dump}.zip\" && $0 $DB_NAME"
                exit 1
            elif head -n 1 "$file_path" 2>/dev/null | grep -q "^#!/bin/.*sh"; then
                echo "❌ Error de compatibilidad: '$file_path' es un script instalador (.sh), no un archivo DUMP."
                echo "💡 Sugerencia: Usa la opción '-file':"
                echo "   $0 $DB_NAME -file $(basename "$file_path")"
                exit 1
            fi
            ;;
        file)
            if [ "$magic_header" = "PGDMP" ]; then
                echo "❌ Error de compatibilidad: '$file_path' es un archivo DUMP binario de PostgreSQL, no un script instalador .sh."
                echo "💡 Sugerencia: Usa la opción '-dump' en lugar de '-file':"
                echo "   $0 ${DB_NAME:-nombre_bd} -dump"
                exit 1
            elif echo "$file_desc" | grep -qi "Zip archive"; then
                echo "❌ Error de compatibilidad: '$file_path' es un archivo ZIP, no un script instalador .sh."
                echo "💡 Sugerencia: Ejecútalo en modo ZIP (sin '-file'):"
                echo "   $0 $(basename "$file_path" .zip)"
                exit 1
            elif echo "$file_path" | grep -qiE "\.sql$" || head -n 5 "$file_path" 2>/dev/null | grep -qiE "^-- PostgreSQL database dump|^SET statement_timeout"; then
                echo "❌ Error de compatibilidad: '$file_path' es un volcado SQL directo, no un script instalador .sh."
                echo "💡 Sugerencia: Usa la opción '-sql' en lugar de '-file':"
                echo "   $0 $(basename "$file_path" .sql) -sql"
                exit 1
            fi
            ;;
    esac
}

# Verificar que no se ejecute como root
if [ "$EUID" -eq 0 ]; then
    echo "Error: Este script no debe ejecutarse como root por seguridad."
    echo "Por favor, ejecuta el script con un usuario normal."
    exit 1
fi

# Función para mostrar ayuda
show_help() {
    echo "======================================================================"
    echo "🗄️  SCRIPT DE RESTAURACIÓN DE BASE DE DATOS ODOO (bd2.sh)"
    echo "======================================================================"
    echo ""
    echo "📋 DESCRIPCIÓN:"
    echo "   Este script automatiza la restauración de bases de datos Odoo desde"
    echo "   archivos ZIP, SQL, DUMP o scripts instaladores (.sh de Deploy Manager),"
    echo "   incluyendo configuraciones de seguridad, limpieza de datos sensibles"
    echo "   y opcionalmente procesamiento de filestore."
    echo ""
    echo "⚙️  USO:"
    echo "   $0 [nombre_base_datos] [-f|--files|-sql|--sql|-dump|--dump|-config|-file|--file <archivo.sh>] [-p|--port <puerto>]"
    echo "   $0 [-doc|--doc|-web|--web]   (Abre la documentación interactiva en el navegador)"
    echo ""
    echo "📌 ARGUMENTOS:"
    echo "   nombre_base_datos         [OPCIONAL con -file] Nombre de la base de datos a crear/restaurar."
    echo "                             Si se usa -file y no se indica nombre, se toma del instalador .sh."
    echo "   -file, --file <archivo>   [OPCIONAL] Ruta o nombre del archivo instalador .sh en Downloads/Descargas."
    echo "                             Extrae RESTORE_TOKEN y RESTORE_URL, descarga solo la BD en local"
    echo "                             (sin filestore, sin clonar código y sin Docker) y la neutraliza."
    echo "   -f, --files               [OPCIONAL] Procesar archivos filestore del ZIP"
    echo "   -sql, --sql               [OPCIONAL] Cargar directamente desde archivo .sql"
    echo "   -dump, --dump             [OPCIONAL] Cargar directamente desde archivo .dump"
    echo "   -config                   [OPCIONAL] Solo ejecutar comandos de configuración SQL"
    echo "   -p, --port <puerto>       [OPCIONAL] Puerto de PostgreSQL (por defecto: 5432)"
    echo "   -doc, --doc, -web, --web  [OPCIONAL] Abrir la guía interactiva en el navegador"
    echo "   -h, --help                Mostrar esta ayuda"
    echo ""
    echo "💡 EJEMPLOS DE USO CON -file:"
    echo "   • Con nombre automático tomado del instalador .sh:"
    echo "     $0 -file install-mi_instancia_2026-11-12_16-39-36.sh"
    echo ""
    echo "   • Especificando el nombre de la BD local + el instalador .sh:"
    echo "     $0 mi_bd_local -file install-mi_instancia_2026-11-12_16-39-36.sh"
    echo ""
    echo "   • Usando ruta completa al archivo .sh y puerto personalizado:"
    echo "     $0 mi_bd_local --file ~/Downloads/install-mi_instancia_2026-11-12_16-39-36.sh -p 5432"
    echo "======================================================================"
    exit 0
}

DOC_URL="https://jtapia3611.github.io/charge_bd_odoo/"

open_interactive_docs() {
    echo "🌐 Abriendo documentación interactiva: $DOC_URL"
    if command -v open >/dev/null 2>&1; then
        open "$DOC_URL"
    elif command -v xdg-open >/dev/null 2>&1; then
        xdg-open "$DOC_URL"
    else
        echo "🔗 Visita: $DOC_URL"
    fi
    exit 0
}

# Parsear argumentos
PROCESS_FILESTORE=false
PROCESS_SQL_ONLY=false
PROCESS_DUMP_ONLY=false
PROCESS_CONFIG_ONLY=false
PROCESS_SH_FILE=false
SH_FILE_ARG=""
SH_FILE_PATH=""
TMP_SH_DUMP=""
DB_NAME=""
port=""
MODE_COUNT=0

# Revisar argumentos
if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    show_help
elif [ "${1:-}" = "-doc" ] || [ "${1:-}" = "--doc" ] || [ "${1:-}" = "-web" ] || [ "${1:-}" = "--web" ]; then
    open_interactive_docs
elif [ -n "${1:-}" ] && [[ "$1" != -* ]]; then
    DB_NAME="$1"
    shift
fi

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)
            show_help
            ;;
        -doc|--doc|-web|--web)
            open_interactive_docs
            ;;
        -f|--files)
            PROCESS_FILESTORE=true
            MODE_COUNT=$((MODE_COUNT + 1))
            shift
            ;;
        -sql|--sql)
            PROCESS_SQL_ONLY=true
            MODE_COUNT=$((MODE_COUNT + 1))
            shift
            ;;
        -dump|--dump)
            PROCESS_DUMP_ONLY=true
            MODE_COUNT=$((MODE_COUNT + 1))
            shift
            ;;
        -config|--config)
            PROCESS_CONFIG_ONLY=true
            MODE_COUNT=$((MODE_COUNT + 1))
            shift
            ;;
        -file|--file)
            if [ -z "${2:-}" ] || [[ "$2" =~ ^- ]]; then
                echo "❌ Error: la opción '$1' requiere especificar el nombre o ruta del archivo .sh"
                echo "📖 Uso: $0 [nombre_base_datos] -file <archivo.sh> [-p|--port <puerto>]"
                exit 1
            fi
            PROCESS_SH_FILE=true
            SH_FILE_ARG="$2"
            MODE_COUNT=$((MODE_COUNT + 1))
            shift 2
            ;;
        -file=*|--file=*)
            PROCESS_SH_FILE=true
            SH_FILE_ARG="${1#*=}"
            MODE_COUNT=$((MODE_COUNT + 1))
            shift
            ;;
        -p|--port)
            if [ -z "${2:-}" ] || [[ "$2" =~ ^- ]]; then
                echo "❌ Error: la opción '$1' requiere especificar un número de puerto"
                exit 1
            fi
            port="$2"
            shift 2
            ;;
        -p=*|--port=*)
            port="${1#*=}"
            shift
            ;;
        *)
            if [ -z "$DB_NAME" ] && [[ "$1" != -* ]]; then
                DB_NAME="$1"
                shift
            else
                echo "❌ Error: argumento no reconocido '$1'"
                echo "📖 Uso: $0 [nombre_base_datos] [-f|--files|-sql|--sql|-dump|--dump|-config|-file <archivo.sh>] [-p|--port <puerto>]"
                exit 1
            fi
            ;;
    esac
done

if [ "$MODE_COUNT" -gt 1 ]; then
    echo "❌ Error: no puedes combinar más de un modo (-f, --sql, --dump, -config, -file)"
    exit 1
fi

# Detectar carpeta de descargas según idioma del sistema
if [ -d "$HOME/Descargas" ]; then
    DOWNLOAD_DIR="Descargas"
elif [ -d "$HOME/Downloads" ]; then
    DOWNLOAD_DIR="Downloads"
else
    DOWNLOAD_DIR=""
fi

# Si es modo -file, localizar el script .sh y extraer sus variables
if [ "$PROCESS_SH_FILE" = true ]; then
    if [ -f "$SH_FILE_ARG" ]; then
        SH_FILE_PATH="$SH_FILE_ARG"
    elif [ -n "$DOWNLOAD_DIR" ] && [ -f "$HOME/$DOWNLOAD_DIR/$SH_FILE_ARG" ]; then
        SH_FILE_PATH="$HOME/$DOWNLOAD_DIR/$SH_FILE_ARG"
    elif [ -n "$DOWNLOAD_DIR" ] && [ -f "$HOME/$DOWNLOAD_DIR/${SH_FILE_ARG}.sh" ]; then
        SH_FILE_PATH="$HOME/$DOWNLOAD_DIR/${SH_FILE_ARG}.sh"
    else
        echo "❌ ERROR CRÍTICO: No se encontró el archivo instalador '$SH_FILE_ARG'"
        [ -n "$DOWNLOAD_DIR" ] && echo "📂 Buscado también en: $HOME/$DOWNLOAD_DIR/$SH_FILE_ARG"
        suggest_compatible_option "$SH_FILE_ARG" "file"
        exit 1
    fi

    echo "📄 Archivo instalador detectado: $SH_FILE_PATH"
    validate_file_compatibility "$SH_FILE_PATH" "file"

    SH_RESTORE_TOKEN=$(sed -n "s/^RESTORE_TOKEN='\([^']*\)'.*/\1/p" "$SH_FILE_PATH" | head -1)
    SH_RESTORE_URL=$(sed -n "s/^RESTORE_URL='\([^']*\)'.*/\1/p" "$SH_FILE_PATH" | head -1)
    SH_RESTORE_KIND=$(sed -n "s/^RESTORE_KIND='\([^']*\)'.*/\1/p" "$SH_FILE_PATH" | head -1)
    SH_DOMAIN_DEFAULT=$(sed -n "s/^INSTANCE_DOMAIN_DEFAULT='\([^']*\)'.*/\1/p" "$SH_FILE_PATH" | head -1)
    SH_DB_NAME=$(sed -n "s/^DB_NAME='\([^']*\)'.*/\1/p" "$SH_FILE_PATH" | head -1)
    SH_SESSION_MODULE=$(sed -n "s/^SESSION_STORE_MODULE='\([^']*\)'.*/\1/p" "$SH_FILE_PATH" | head -1)

    if [ -z "$SH_RESTORE_TOKEN" ] || [ -z "$SH_RESTORE_URL" ]; then
        echo "❌ Error: El archivo '$SH_FILE_PATH' no es un script instalador de Deploy Manager válido (no contiene RESTORE_TOKEN ni RESTORE_URL)."
        suggest_compatible_option "${DB_NAME:-$SH_FILE_ARG}" "file"
        exit 1
    fi

    # Si no se pasó DB_NAME por parámetro, deducirlo del nombre del archivo install-<nombre>_YYYY... o del dominio
    if [ -z "$DB_NAME" ]; then
        BASENAME_SH="$(basename "$SH_FILE_PATH" .sh)"
        if [[ "$BASENAME_SH" =~ ^install-([^_]+)_ ]]; then
            DB_NAME="${BASH_REMATCH[1]}"
        elif [ -n "$SH_DOMAIN_DEFAULT" ]; then
            DB_NAME="${SH_DOMAIN_DEFAULT%%.*}"
        elif [ -n "$SH_DB_NAME" ]; then
            DB_NAME="$SH_DB_NAME"
        else
            DB_NAME="$BASENAME_SH"
        fi
    fi
fi

# Verificar que se proporcionó el nombre de la base de datos
if [ -z "$DB_NAME" ]; then
    echo "❌ Error: El nombre de la base de datos es obligatorio"
    echo ""
    echo "📖 Uso: $0 [nombre_base_datos] [-f|--files|-sql|--sql|-dump|--dump|-config|-file <archivo.sh>] [-p|--port <puerto>]"
    exit 1
fi

echo "📊 Base de datos: $DB_NAME"
if [ "$PROCESS_SH_FILE" = true ]; then
    echo "🌐 Se descargará y restaurará únicamente la BD desde el instalador ($SH_FILE_PATH)"
elif [ "$PROCESS_FILESTORE" = true ]; then
    echo "📁 Se procesarán los archivos filestore"
elif [ "$PROCESS_SQL_ONLY" = true ]; then
    echo "📋 Se cargará solo el archivo SQL directo ($DB_NAME.sql)"
elif [ "$PROCESS_DUMP_ONLY" = true ]; then
    echo "📋 Se cargará solo el archivo DUMP directo ($DB_NAME.dump)"
elif [ "$PROCESS_CONFIG_ONLY" = true ]; then
    echo "⚙️  Modo configuración: solo se ejecutarán comandos SQL sobre la BD existente"
fi

# Verificar conexión a PostgreSQL antes de continuar
echo "🔍 Verificando conexión a PostgreSQL..."

if [ -n "$port" ]; then
    echo "🔌 Usando puerto especificado por parámetro: $port"
else
    port=5432
    echo "ℹ️  No se especificó puerto: tomando puerto por defecto $port para PostgreSQL."
fi

# Probar conexión a PostgreSQL
echo "🔍 Probando conexión a PostgreSQL en puerto $port..."
TEST_RESULT=$(psql -p "$port" -c "SELECT 1;" 2>&1)

if echo "$TEST_RESULT" | grep -q "role.*does not exist"; then
    MISSING_ROLE=$(echo "$TEST_RESULT" | grep -o 'role "[^"]*"' | sed 's/role "\(.*\)"/\1/')
    if [ -z "$MISSING_ROLE" ]; then
        MISSING_ROLE=$(whoami)
    fi
    
    echo "❌ El rol/usuario PostgreSQL '$MISSING_ROLE' no existe"
    echo ""
    read -p "¿Deseas crear el rol '$MISSING_ROLE' en PostgreSQL? (y/yes para crear, n/no para cancelar): " CREATE_ROLE
    
    case "$CREATE_ROLE" in
        y|Y|yes|YES|Yes)
            echo "👤 Creando rol PostgreSQL '$MISSING_ROLE'..."
            CREATE_ROLE_RESULT=$(sudo -u postgres createuser -p "$port" -s "$MISSING_ROLE" 2>&1)
            if [ $? -eq 0 ]; then
                echo "✅ Rol '$MISSING_ROLE' creado exitosamente como superusuario"
                TEST_RESULT=$(psql -p "$port" -c "SELECT 1;" 2>&1)
            else
                echo "⚠️  No se pudo crear con sudo, intentando con usuario actual..."
                CREATE_ROLE_RESULT2=$(createuser -p "$port" -s "$MISSING_ROLE" 2>&1)
                if [ $? -eq 0 ]; then
                    echo "✅ Rol '$MISSING_ROLE' creado exitosamente"
                    TEST_RESULT=$(psql -p "$port" -c "SELECT 1;" 2>&1)
                else
                    echo "❌ Error al crear el rol '$MISSING_ROLE'"
                    echo "$CREATE_ROLE_RESULT"
                    echo "$CREATE_ROLE_RESULT2"
                    exit 1
                fi
            fi
            ;;
        *)
            echo "❌ Cancelado por el usuario"
            exit 1
            ;;
    esac
elif echo "$TEST_RESULT" | grep -q "database.*does not exist"; then
    echo "⚠️  La base de datos del usuario '$(whoami)' no existe en PostgreSQL"
    echo ""
    read -p "¿Deseas crear la base de datos del usuario '$(whoami)'? (y/yes para crear, n/no para cancelar): " CREATE_USER_DB
    case "$CREATE_USER_DB" in
        y|Y|yes|YES|Yes)
            createdb -p "$port" "$(whoami)" || exit 1
            ;;
        *)
            echo "❌ Cancelado por el usuario"
            exit 1
            ;;
    esac
elif echo "$TEST_RESULT" | grep -q "connection to server.*failed"; then
    echo "❌ Error: No se pudo conectar a PostgreSQL en el puerto $port"
    exit 1
elif echo "$TEST_RESULT" | grep -q "FATAL"; then
    echo "❌ Error de autenticación o permisos en PostgreSQL"
    exit 1
else
    echo "✅ Conexión a PostgreSQL exitosa"
fi

echo "stoping all instances"
pkill -9 python 2>/dev/null || true

# Inicializar variable de filestore
FILESTORE_PATH=""

if [ "$PROCESS_CONFIG_ONLY" = true ]; then
    echo "ℹ️  Modo -config detectado: se omite restauración de BD y manejo de filestore"

    DB_EXISTS=$(psql -p "$port" -t -A -d postgres -c "SELECT 1 FROM pg_database WHERE datname = '$DB_NAME' LIMIT 1;" | tr -d '[:space:]')
    if [ "$DB_EXISTS" != "1" ]; then
        echo "❌ Error: la base de datos '$DB_NAME' no existe en el puerto $port"
        exit 1
    fi

    echo "✅ Base de datos '$DB_NAME' encontrada. Se aplicarán solo comandos SQL de configuración"
elif [ "$PROCESS_SH_FILE" = true ]; then
    echo "🌐 Solicitando URL de descarga al Deploy Manager..."
    RESTORE_RESPONSE="$(curl -sS --retry 5 --retry-delay 3 -X POST \
        --data-urlencode "token=${SH_RESTORE_TOKEN}" -w '\n%{http_code}' "${SH_RESTORE_URL}")"
    RESTORE_STATUS="${RESTORE_RESPONSE##*$'\n'}"
    RESTORE_BODY="${RESTORE_RESPONSE%$'\n'*}"

    if [ "$RESTORE_STATUS" != "200" ]; then
        echo "❌ Error: El Deploy Manager no entregó el backup (HTTP $RESTORE_STATUS): $RESTORE_BODY"
        echo "💡 El instalador vale un día; regénéralo desde Odoo si ya venció."
        exit 1
    fi

    DUMP_URL="$(printf '%s\n' "$RESTORE_BODY" | head -n 1)"
    if [ -z "$DUMP_URL" ]; then
        echo "❌ Error: No se recibió una URL de dump válida."
        exit 1
    fi

    TMP_DIR="${HOME}/${DOWNLOAD_DIR:-Downloads}"
    mkdir -p "$TMP_DIR"

    if [ "$SH_RESTORE_KIND" = "standard" ]; then
        TMP_SH_DUMP="${TMP_DIR}/.tmp_${DB_NAME}_backup.zip"
        echo "⬇️  Descargando backup.zip temporalmente..."
        if ! curl -fSL --retry 5 --retry-delay 3 "$DUMP_URL" -o "$TMP_SH_DUMP"; then
            echo "❌ Error al descargar el archivo del backup."
            rm -f "$TMP_SH_DUMP"
            exit 1
        fi
    else
        TMP_SH_DUMP="${TMP_DIR}/.tmp_${DB_NAME}_dump.pgc"
        echo "⬇️  Descargando dump.pgc temporalmente (sin filestore ni repositorios)..."
        if ! curl -fSL --retry 5 --retry-delay 3 "$DUMP_URL" -o "$TMP_SH_DUMP"; then
            echo "❌ Error al descargar el dump."
            rm -f "$TMP_SH_DUMP"
            exit 1
        fi
    fi

    echo "🗄️  Creando base de datos '$DB_NAME'..."
    psql -p "$port" -d postgres -c "DROP DATABASE IF EXISTS \"$DB_NAME\" WITH (FORCE);"
    psql -p "$port" -d postgres -c "CREATE DATABASE \"$DB_NAME\";"

    if [ "$SH_RESTORE_KIND" = "standard" ]; then
        echo "📋 Extrayendo y cargando dump.sql desde el ZIP..."
        if ! unzip -p "$TMP_SH_DUMP" dump.sql | psql -p "$port" -d "$DB_NAME" -q; then
            echo "❌ Error al restaurar dump.sql desde el ZIP"
            rm -f "$TMP_SH_DUMP"
            exit 1
        fi
    else
        echo "📋 Restaurando dump en '$DB_NAME' con pg_restore..."
        if ! run_pg_restore_safe "$port" "$DB_NAME" "$TMP_SH_DUMP"; then
            echo "❌ Error al restaurar el dump en '$DB_NAME'"
            rm -f "$TMP_SH_DUMP"
            exit 1
        fi
    fi

    echo "🧹 Eliminando dump temporal descargado..."
    rm -f "$TMP_SH_DUMP"
    TMP_SH_DUMP=""
else
    if [ -z "$DOWNLOAD_DIR" ]; then
        echo "Error: No se encontró carpeta de descargas (Downloads/Descargas)"
        exit 1
    fi

    # Verificar existencia y compatibilidad de archivos ANTES de crear la base de datos
    echo "🔍 Verificando existencia y compatibilidad de archivos requeridos..."

    # Si el usuario pasó extensión en DB_NAME (ej. mi_bd.sql, mi_bd.sh, mi_bd.dump) sin la bandera correspondiente
    case "$DB_NAME" in
        *.sh)
            echo "❌ Error: Pasaste un archivo '.sh' ($DB_NAME) sin la opción '-file'."
            echo "💡 Sugerencia: Ejecuta:"
            echo "   $0 -file $DB_NAME"
            exit 1
            ;;
        *.sql)
            if [ "$PROCESS_SQL_ONLY" != true ]; then
                echo "❌ Error: Pasaste un archivo '.sql' ($DB_NAME) sin la opción '-sql'."
                echo "💡 Sugerencia: Ejecuta:"
                echo "   $0 ${DB_NAME%.sql} -sql"
                exit 1
            fi
            DB_NAME="${DB_NAME%.sql}"
            ;;
        *.dump|*.pgc)
            if [ "$PROCESS_DUMP_ONLY" != true ]; then
                echo "❌ Error: Pasaste un archivo '${DB_NAME}' sin la opción '-dump'."
                echo "💡 Sugerencia: Ejecuta:"
                echo "   $0 ${DB_NAME%.*} -dump"
                exit 1
            fi
            DB_NAME="${DB_NAME%.*}"
            ;;
        *.zip)
            DB_NAME="${DB_NAME%.zip}"
            ;;
    esac

    if [ "$PROCESS_SQL_ONLY" = true ]; then
        if [ ! -f "$HOME/$DOWNLOAD_DIR/$DB_NAME.sql" ]; then
            echo "❌ ERROR CRÍTICO: No se encontró el archivo $DB_NAME.sql"
            echo "📂 Ubicación esperada: $HOME/$DOWNLOAD_DIR/$DB_NAME.sql"
            suggest_compatible_option "$DB_NAME" "sql"
            exit 1
        else
            validate_file_compatibility "$HOME/$DOWNLOAD_DIR/$DB_NAME.sql" "sql"
            echo "✅ Archivo SQL válido encontrado: $DB_NAME.sql"
        fi
    elif [ "$PROCESS_DUMP_ONLY" = true ]; then
        if [ ! -f "$HOME/$DOWNLOAD_DIR/$DB_NAME.dump" ]; then
            echo "❌ ERROR CRÍTICO: No se encontró el archivo $DB_NAME.dump"
            echo "📂 Ubicación esperada: $HOME/$DOWNLOAD_DIR/$DB_NAME.dump"
            suggest_compatible_option "$DB_NAME" "dump"
            exit 1
        else
            validate_file_compatibility "$HOME/$DOWNLOAD_DIR/$DB_NAME.dump" "dump"
            echo "✅ Archivo DUMP válido encontrado: $DB_NAME.dump"
        fi
    else
        if [ ! -f "$HOME/$DOWNLOAD_DIR/$DB_NAME.zip" ]; then
            echo "❌ ERROR CRÍTICO: No se encontró el archivo $DB_NAME.zip"
            echo "📂 Ubicación esperada: $HOME/$DOWNLOAD_DIR/$DB_NAME.zip"
            suggest_compatible_option "$DB_NAME" "zip"
            exit 1
        else
            validate_file_compatibility "$HOME/$DOWNLOAD_DIR/$DB_NAME.zip" "zip"
            echo "✅ Archivo ZIP válido encontrado: $DB_NAME.zip"
        fi
    fi

    # Ahora que confirmamos que el archivo existe, proceder con la BD
    echo "🗄️  Creando base de datos..."
    psql -p "$port" -c "DROP DATABASE \"$DB_NAME\" WITH (FORCE);"
    echo "drop database"
    psql -p "$port" -c "create DATABASE \"$DB_NAME\";"
    echo "created"

    # Solo buscar carpeta de filestore si se va a procesar filestore
    if [ "$PROCESS_FILESTORE" = true ]; then
        echo "🔍 Buscando carpeta de filestore de Odoo..."

        FILESTORE_LOCATIONS=(
            "$HOME/.local/share/Odoo/filestore"
            "$HOME/odoo-dev/filestore"
            "$HOME/odoo/filestore"
            "/opt/odoo/filestore"
            "/var/lib/odoo/filestore"
            "$HOME/.odoo/filestore"
            "/usr/local/var/odoo/filestore"
        )

        for location in "${FILESTORE_LOCATIONS[@]}"; do
            if [ -d "$location" ]; then
                FILESTORE_PATH="$location"
                echo "✅ Filestore encontrado en: $FILESTORE_PATH"
                break
            fi
        done

        if [ -z "$FILESTORE_PATH" ]; then
            echo "⚠️  No se encontró carpeta de filestore en ubicaciones comunes"
            FOUND_FILESTORE=$(find / -name "filestore" -type d 2>/dev/null | grep -E "(odoo|Odoo)" | head -1)
            if [ -n "$FOUND_FILESTORE" ]; then
                FILESTORE_PATH="$FOUND_FILESTORE"
                echo "✅ Filestore encontrado en: $FILESTORE_PATH"
            fi
        fi
    else
        echo "ℹ️  Saltando búsqueda de filestore (no se especificó -f o --files)"
    fi

    cd "$HOME/$DOWNLOAD_DIR"

    if [ "$PROCESS_SQL_ONLY" = true ]; then
        echo "📋 Cargando base de datos directamente desde archivo SQL..."
        psql -p "$port" "$DB_NAME" < "$HOME/$DOWNLOAD_DIR/$DB_NAME.sql"
        if [ $? -eq 0 ]; then
            echo "✅ Base de datos cargada exitosamente desde $DB_NAME.sql"
        else
            echo "❌ Error al cargar la base de datos desde el archivo SQL"
            exit 1
        fi
    elif [ "$PROCESS_DUMP_ONLY" = true ]; then
        echo "📋 Cargando base de datos directamente desde archivo DUMP..."
        if [ "$(head -c 5 "$HOME/$DOWNLOAD_DIR/$DB_NAME.dump" 2>/dev/null)" = "PGDMP" ]; then
            run_pg_restore_safe "$port" "$DB_NAME" "$HOME/$DOWNLOAD_DIR/$DB_NAME.dump"
        else
            psql -p "$port" "$DB_NAME" < "$HOME/$DOWNLOAD_DIR/$DB_NAME.dump"
        fi

        if [ $? -eq 0 ]; then
            echo "✅ Base de datos cargada exitosamente desde $DB_NAME.dump"
        else
            echo "❌ Error al cargar la base de datos desde el archivo DUMP"
            exit 1
        fi
    else
            echo "📦 Descomprimiendo archivo ZIP..."
        if unzip -l "$HOME/$DOWNLOAD_DIR/$DB_NAME.zip" 2>/dev/null | grep -qE "(^|/)[[:space:]]*dump\.sql$"; then
            unzip "$HOME/$DOWNLOAD_DIR/$DB_NAME.zip" -d "$DB_NAME" | awk 'BEGIN {ORS=" "} {print "."}'
            cd "$HOME/$DOWNLOAD_DIR/$DB_NAME"
            SQL_IN_ZIP="dump.sql"
        else
            FIRST_SQL_IN_ZIP=$(unzip -Z1 "$HOME/$DOWNLOAD_DIR/$DB_NAME.zip" 2>/dev/null | grep -iE "\.sql$" | head -n 1 || true)
            if [ -n "$FIRST_SQL_IN_ZIP" ]; then
                echo "ℹ️  El ZIP no contiene 'dump.sql', pero se detectó '$FIRST_SQL_IN_ZIP'; se usará ese archivo."
                unzip "$HOME/$DOWNLOAD_DIR/$DB_NAME.zip" -d "$DB_NAME" | awk 'BEGIN {ORS=" "} {print "."}'
                cd "$HOME/$DOWNLOAD_DIR/$DB_NAME"
                SQL_IN_ZIP="$FIRST_SQL_IN_ZIP"
            else
                echo "❌ Error de compatibilidad: El archivo '$DB_NAME.zip' no contiene ningún archivo .sql adentro."
                suggest_compatible_option "$DB_NAME" "zip"
                exit 1
            fi
        fi

        if [ "$PROCESS_FILESTORE" = true ]; then
            echo "🔍 Revisando si el archivo contiene filestore..."
            if [ -d "filestore" ] && [ -n "$FILESTORE_PATH" ]; then
                TARGET_FILESTORE="$FILESTORE_PATH/$DB_NAME"
                mkdir -p "$TARGET_FILESTORE"
                rm -rf "$TARGET_FILESTORE"/*
                cp -r filestore/* "$TARGET_FILESTORE/"
                echo "✅ Filestore copiado exitosamente a: $TARGET_FILESTORE"
            fi
        fi

        echo "📋 Cargando base de datos desde $SQL_IN_ZIP..."
        psql -p "$port" "$DB_NAME" -q < "$SQL_IN_ZIP"
        if [ $? -eq 0 ]; then
            echo "✅ Base de datos cargada exitosamente desde dump.sql"
        else
            echo "❌ Error al cargar la base de datos desde dump.sql"
            exit 1
        fi
    fi
fi

# Comandos de limpieza y configuración (aplica para todos los modos)
echo "🔧 Aplicando configuraciones de seguridad y limpieza..."
echo "change user to admin"
psql -p "$port" -d "$DB_NAME" -c "update res_users set login='admin' where id = 2;"
echo "change partner emails"
psql -p "$port" -d "$DB_NAME" -c "update res_partner set email ='test@example.com';"
echo "change partner mobile"
psql -p "$port" -d "$DB_NAME" -c "update res_partner set mobile ='0000000000';"
echo "disable captcha"
psql -p "$port" -d "$DB_NAME" -c "DO \$\$ BEGIN IF to_regclass('website') IS NOT NULL THEN UPDATE website SET is_captcha_enabled=False,recaptcha_key_site='',recaptcha_key_secret=''; END IF; END \$\$;"
echo "change paswords and activate"
psql -p "$port" -d "$DB_NAME" -c "update res_users set password='1'"
echo "delete mails"
psql -p "$port" -d "$DB_NAME" -c "DO \$\$ BEGIN IF to_regclass('ir_mail_server') IS NOT NULL THEN DELETE FROM ir_mail_server; END IF; END \$\$;"
echo "disable fetchmail and clear outgoing mail queue"
psql -p "$port" -d "$DB_NAME" -c "DO \$\$ BEGIN IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'fetchmail_server') THEN UPDATE fetchmail_server SET active = false; END IF; IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'mail_mail') THEN DELETE FROM mail_mail WHERE state IN ('outgoing', 'exception'); END IF; END \$\$;"
echo "disabled crons"
psql -p "$port" -d "$DB_NAME" -c "update ir_cron set active=False"
echo "delete tawks"
psql -p "$port" -d "$DB_NAME" -c "delete from ir_config_parameter where key like 'tawk%';"
echo "update expiration"
psql -p "$port" -d "$DB_NAME" -c "update ir_config_parameter set value = '2999-08-06 00:00:00' where key = 'database.expiration_date';"

echo "🛡️  Replicando neutralización de Odoo en SQL directo (UUID, secretos, IAP, OAuth, pagos, webhooks)..."
psql -v ON_ERROR_STOP=1 -p "$port" -d "$DB_NAME" <<'SQL'
DO $$
BEGIN
    -- 1. Regenerar database.uuid y database.secret para desvincular la copia de producción
    UPDATE ir_config_parameter
       SET value = gen_random_uuid()::text
     WHERE key = 'database.uuid';

    UPDATE ir_config_parameter
       SET value = gen_random_uuid()::text
     WHERE key = 'database.secret';

    -- 2. Eliminar código de suscripción enterprise y llaves push/SFU
    DELETE FROM ir_config_parameter
     WHERE key IN (
         'database.enterprise_code',
         'mail.web_push_vapid_private_key',
         'mail.web_push_vapid_public_key',
         'mail.sfu_server_key'
     );

    -- 3. Desactivar proveedores OAuth externos
    IF to_regclass('auth_oauth_provider') IS NOT NULL THEN
        UPDATE auth_oauth_provider SET enabled = false;
    END IF;

    -- 4. Deshabilitar tokens IAP
    IF to_regclass('iap_account') IS NOT NULL THEN
        UPDATE iap_account
           SET account_token = REGEXP_REPLACE(account_token, '(\+.*)?$', '+disabled')
         WHERE account_token IS NOT NULL
           AND account_token NOT LIKE '%+disabled';
    END IF;

    -- 5. Desactivar pasarelas de pago productivas (Odoo 16+: payment_provider, Odoo <=15: payment_acquirer)
    IF to_regclass('payment_provider') IS NOT NULL THEN
        UPDATE payment_provider
           SET state = 'disabled'
         WHERE state NOT IN ('test', 'disabled');
    END IF;
    IF to_regclass('payment_acquirer') IS NOT NULL THEN
        UPDATE payment_acquirer
           SET state = 'disabled'
         WHERE state NOT IN ('test', 'disabled');
    END IF;

    -- 6. Desactivar webhooks en acciones de servidor y limpiar mail_server_id en plantillas
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
         WHERE table_schema = 'public' AND table_name = 'ir_act_server' AND column_name = 'webhook_url'
    ) THEN
        UPDATE ir_act_server
           SET webhook_url = 'neutralization - disable webhook'
         WHERE state = 'webhook';
    END IF;

    IF to_regclass('mail_template') IS NOT NULL THEN
        UPDATE mail_template SET mail_server_id = NULL;
    END IF;

    -- 7. Limpiar dominios de producción en website para evitar redirecciones
    IF to_regclass('website') IS NOT NULL THEN
        UPDATE website SET domain = NULL;
        IF EXISTS (
            SELECT 1 FROM information_schema.columns
             WHERE table_schema = 'public' AND table_name = 'website' AND column_name = 'cdn_activated'
        ) THEN
            UPDATE website SET cdn_activated = false;
        END IF;
    END IF;

    -- 8. Desbloquear campos versionados bloqueados (solt_field_version)
    IF to_regclass('model_field_version') IS NOT NULL THEN
        UPDATE model_field_version
           SET is_locked = false,
               lock_type = NULL,
               locked_by = NULL,
               locked_date = NULL,
               lock_reason = NULL,
               unlock_after_days = NULL,
               auto_unlock_date = NULL,
               unlock_by = NULL,
               unlock_via_request = NULL,
               unlock_date_actual = now(),
               unlock_reason = 'Unlocked by database neutralization'
         WHERE is_locked = true;
    END IF;
    IF to_regclass('field_lock_unlock_request') IS NOT NULL THEN
        UPDATE field_lock_unlock_request
           SET state = 'expired'
         WHERE state IN ('draft', 'pending');
    END IF;
END $$;
SQL

if [ -n "${SH_SESSION_MODULE:-}" ]; then
    echo "Desactivando módulo de sesión (${SH_SESSION_MODULE})..."
    psql -p "$port" -d "$DB_NAME" -c "update ir_module_module set state = 'uninstalled' where name = '${SH_SESSION_MODULE}' and state != 'uninstalled';"
fi

echo "🧹 Eliminando assets personalizados y compilados..."
psql -v ON_ERROR_STOP=1 -p "$port" -d "$DB_NAME" <<'SQL'
BEGIN;
DELETE FROM ir_asset
WHERE path LIKE '/_custom/%';
DELETE FROM ir_attachment
WHERE url LIKE '/_custom/%'
   OR url LIKE '/web/assets/%';
COMMIT;
SQL
if [ "$?" -ne 0 ]; then
    echo "❌ Error al limpiar los assets de Odoo"
    exit 1
fi
echo "✅ Assets eliminados; Odoo los regenerará al iniciar"

PAC_USERNAME="testing@solucionfactible.com"
PAC_PASSWORD="timbrado.SF.16672"
ODOO_VERSION=$(psql -v ON_ERROR_STOP=1 -p "$port" -d "$DB_NAME" -t -A -c "
    SELECT latest_version
    FROM ir_module_module
    WHERE name = 'base'
    LIMIT 1;
" | tr -d '[:space:]')
ODOO_MAJOR_VERSION="${ODOO_VERSION%%.*}"

if [ -z "$ODOO_VERSION" ]; then
    echo "❌ No se pudo detectar la versión de Odoo en la base de datos"
    exit 1
fi

case "$ODOO_MAJOR_VERSION" in
    15|16|17|18|19|20)
        echo "🔍 Versión de Odoo detectada: $ODOO_VERSION"
        ;;
    *)
        echo "❌ Versión de Odoo no soportada para configurar el PAC: $ODOO_VERSION"
        exit 1
        ;;
esac

PAC_LAYOUT=$(psql -v ON_ERROR_STOP=1 -p "$port" -d "$DB_NAME" -t -A -c "
    WITH pac_tables AS (
        SELECT
            'edi' AS layout,
            table_schema,
            table_name,
            0 AS priority
        FROM information_schema.columns
        WHERE table_schema NOT IN ('pg_catalog', 'information_schema')
          AND column_name IN (
              'l10n_mx_edi_pac',
              'l10n_mx_edi_pac_password',
              'l10n_mx_edi_pac_username',
              'l10n_mx_edi_pac_test_env'
          )
        GROUP BY table_schema, table_name
        HAVING count(DISTINCT column_name) = 4

        UNION ALL

        SELECT
            'cfdi' AS layout,
            table_schema,
            table_name,
            1 AS priority
        FROM information_schema.columns
        WHERE table_schema NOT IN ('pg_catalog', 'information_schema')
          AND column_name IN (
              'l10n_mx_cfdi_pac',
              'l10n_mx_cfdi_pac_password',
              'l10n_mx_cfdi_pac_username',
              'l10n_mx_cfdi_pac_test_env'
          )
        GROUP BY table_schema, table_name
        HAVING count(DISTINCT column_name) = 4
    )
    SELECT layout || '|' || format('%I.%I', table_schema, table_name)
    FROM pac_tables
    ORDER BY
        CASE WHEN table_schema = 'public' AND table_name = 'res_company' THEN 0 ELSE 1 END,
        priority,
        table_schema,
        table_name
    LIMIT 1;
" | tr -d '[:space:]')

if [ -z "$PAC_LAYOUT" ]; then
    echo "⚠️  No se encontró una tabla con campos PAC edi o cfdi (se omite configuración PAC)"
else
    PAC_FIELD_LAYOUT="${PAC_LAYOUT%%|*}"
    PAC_TABLE="${PAC_LAYOUT#*|}"

    if [[ ! "$PAC_TABLE" =~ ^[a-zA-Z_][a-zA-Z0-9_]*\.[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
        echo "❌ La tabla PAC detectada tiene un nombre no válido"
        exit 1
    fi

    echo "🔍 Tabla PAC detectada: $PAC_TABLE (campos $PAC_FIELD_LAYOUT)"
    case "$PAC_FIELD_LAYOUT" in
        edi)
            psql -v ON_ERROR_STOP=1 \
                -v pac_table="$PAC_TABLE" \
                -v pac_username="$PAC_USERNAME" \
                -v pac_password="$PAC_PASSWORD" \
                -p "$port" \
                -d "$DB_NAME" <<'SQL'
BEGIN;
UPDATE :pac_table
SET l10n_mx_edi_pac = 'solfact',
    l10n_mx_edi_pac_username = :'pac_username',
    l10n_mx_edi_pac_password = :'pac_password',
    l10n_mx_edi_pac_test_env = true;
COMMIT;
SQL
            ;;
        cfdi)
            psql -v ON_ERROR_STOP=1 \
                -v pac_table="$PAC_TABLE" \
                -v pac_username="$PAC_USERNAME" \
                -v pac_password="$PAC_PASSWORD" \
                -p "$port" \
                -d "$DB_NAME" <<'SQL'
BEGIN;
UPDATE :pac_table
SET l10n_mx_cfdi_pac = 'solfact',
    l10n_mx_cfdi_pac_username = :'pac_username',
    l10n_mx_cfdi_pac_password = :'pac_password',
    l10n_mx_cfdi_pac_test_env = true;
COMMIT;
SQL
            ;;
        *)
            echo "❌ Esquema de campos PAC no soportado: $PAC_FIELD_LAYOUT"
            exit 1
            ;;
    esac

    # Verificar que las credenciales PAC fueron aplicadas correctamente
    case "$PAC_FIELD_LAYOUT" in
        edi)
            PAC_CHECK_RESULT=$(psql -v ON_ERROR_STOP=1 \
                -v pac_table="$PAC_TABLE" \
                -v pac_username="$PAC_USERNAME" \
                -v pac_password="$PAC_PASSWORD" \
                -p "$port" \
                -d "$DB_NAME" \
                -t -A <<'SQL'
SELECT count(*)
FROM :pac_table
WHERE l10n_mx_edi_pac = 'solfact'
  AND l10n_mx_edi_pac_password = :'pac_password'
  AND l10n_mx_edi_pac_username = :'pac_username'
  AND l10n_mx_edi_pac_test_env = true;
SQL
)
            ;;
        cfdi)
            PAC_CHECK_RESULT=$(psql -v ON_ERROR_STOP=1 \
                -v pac_table="$PAC_TABLE" \
                -v pac_username="$PAC_USERNAME" \
                -v pac_password="$PAC_PASSWORD" \
                -p "$port" \
                -d "$DB_NAME" \
                -t -A <<'SQL'
SELECT count(*)
FROM :pac_table
WHERE l10n_mx_cfdi_pac = 'solfact'
  AND l10n_mx_cfdi_pac_password = :'pac_password'
  AND l10n_mx_cfdi_pac_username = :'pac_username'
  AND l10n_mx_cfdi_pac_test_env = true;
SQL
)
            ;;
    esac
    PAC_CHECK_RESULT=$(printf "%s" "$PAC_CHECK_RESULT" | tr -d '[:space:]')

    if [ -n "$PAC_CHECK_RESULT" ] && [ "$PAC_CHECK_RESULT" -ge 1 ]; then
        echo "✅ Verificación PAC exitosa: credenciales de prueba aplicadas correctamente"
    else
        echo "❌ Error: la verificación de credenciales PAC falló"
    fi
fi

# Limpiar filestore solo si no se va a procesar filestore y no es modo -config
if [ "$PROCESS_CONFIG_ONLY" = false ]; then
    if [ "$PROCESS_FILESTORE" = false ] && [ -n "$FILESTORE_PATH" ] && [ -d "$FILESTORE_PATH/$DB_NAME" ]; then
        echo "🧹 Limpiando filestore anterior para la base de datos: $DB_NAME"
        rm -rf "$FILESTORE_PATH/$DB_NAME"
        echo "✅ Filestore limpiado: $FILESTORE_PATH/$DB_NAME"
    fi
fi

# Limpieza condicional de archivos temporales y filestore
if [ "$PROCESS_CONFIG_ONLY" = true ]; then
    echo "ℹ️  Modo -config completado: sin limpieza de ZIP/SQL/DUMP ni filestore"
elif [ "$PROCESS_SH_FILE" = true ]; then
    echo "ℹ️  Proceso desde instalador .sh completado - sin archivos temporales residuales"
elif [ "$PROCESS_SQL_ONLY" = true ] || [ "$PROCESS_DUMP_ONLY" = true ]; then
    echo "ℹ️  Proceso directo completado - sin archivos temporales que limpiar"
else
    cd ..
    rm -rf "$DB_NAME/"
    echo "🧹 Archivos temporales del ZIP eliminados"
fi

echo "******************************** database $DB_NAME charged in port $port ********************************"
