#!/usr/bin/env bash
# Часть 1 (Кирилл Виденкин)
set -euo pipefail


# СПРАВКА ПО КОДАМ ВОЗВРАТА:
#   0  - успех
#   1  - непредвиденная ошибка bash
#   2  - неверное количество аргументов
#   3  - некорректный порог
#   4  - некорректный лимит в МиБ
#   5  - каталог логов не найден
#   6  - нет прав на каталог логов
#   7  - не удалось создать каталог backup
#   8  - каталог backup находится внутри каталога логов
#   9  - не удалось определить размер каталога логов
#  10  - не удалось определить вместимость
#  11  - нет файлов для архивации
#  12  - ошибка при создании архива
#  13  - не удалось удалить оригиналы после архивации
#  14  - архивация выполнена, но уложиться в лимит всё равно не удалось
#  15  - не существует директории

readonly E_ARGS=2
readonly E_THRESHOLD=3
readonly E_LIMIT=4
readonly E_LOGDIR_MISSING=5
readonly E_LOGDIR_PERM=6
readonly E_BACKUP_CREATE=7
readonly E_BACKUP_INSIDE_LOGS=8
readonly E_SIZE_UNKNOWN=9
readonly E_CAPACITY_UNKNOWN=10
readonly E_NO_FILES=11
readonly E_ARCHIVE_FAILED=12
readonly E_DELETE_FAILED=13
readonly E_LIMIT_UNREACHABLE=14
readonly E_DOESNTEXIST=15

error() {
  local code=$1
  shift
  printf 'Ошибка: %s\n' "$*" >&2
  exit "$code"
}

if (( $# < 1 || $# > 4 )); then
  error "$E_ARGS" 'Ожидается от 1 до 4 аргументов: LOG_DIR [ПОРОГ_%] [BACKUP_DIR] [ЛИМИТ_МИБ]'
fi

input_log_dir=$1

[[ -n "$input_log_dir" ]] || error "$E_DOESNTEXIST" 'Пустой путь'

threshold=${2:-70}
input_backup_dir=${3:-"$(dirname -- "$input_log_dir")/backup"}
limit_mib=${4:-}

[[ "$threshold" =~ ^(0|[1-9][0-9]?|100)$ ]] \
  || error "$E_THRESHOLD" 'Порог должен быть целым числом от 0 до 100.'
if [[ -n "$limit_mib" ]]; then
  [[ "$limit_mib" =~ ^[1-9][0-9]*$ ]] \
    || error "$E_LIMIT" 'Лимит в МиБ должен быть положительным целым числом.'
fi

[[ -d "$input_log_dir" ]] || error "$E_LOGDIR_MISSING" "Каталог логов не найден: $input_log_dir"
[[ -r "$input_log_dir" && -w "$input_log_dir" && -x "$input_log_dir" ]] \
  || error "$E_LOGDIR_PERM" 'Нет прав для работы с каталогом логов.'

log_dir=$(cd -- "$input_log_dir" && pwd -P)
mkdir -p -- "$input_backup_dir" || error "$E_BACKUP_CREATE" 'Не удалось создать каталог для архивов.'
backup_dir=$(cd -- "$input_backup_dir" && pwd -P) \
  || error "$E_BACKUP_CREATE" 'Не удалось открыть каталог для архивов.'

case "$backup_dir/" in
  "$log_dir/"*) error "$E_BACKUP_INSIDE_LOGS" 'Каталог backup должен находиться вне каталога логов.' ;;
esac

used_kib=$(du -sk "$log_dir" | awk '{print $1}') \
  || error "$E_SIZE_UNKNOWN" 'Не удалось определить размер каталога логов.'
[[ "$used_kib" =~ ^[0-9]+$ ]] || error "$E_SIZE_UNKNOWN" 'Не удалось определить размер каталога логов.'

if [[ -n "$limit_mib" ]]; then
  limit_kib=$((limit_mib * 1024))
  limit_description="заданный лимит: ${limit_mib} МиБ"
else
  limit_kib=$(df -Pk "$log_dir" | awk 'NR==2 {print $2}') \
    || error "$E_CAPACITY_UNKNOWN" 'Не удалось определить вместимость.'
  limit_description='вся файловая система'
fi
[[ "$limit_kib" =~ ^[1-9][0-9]*$ ]] || error "$E_CAPACITY_UNKNOWN" 'Не удалось определить вместимость.'

percent_x100=$((used_kib * 10000 / limit_kib))
printf 'Каталог: %s\n' "$log_dir"
printf 'Занято: %s КиБ; вместимость: %s КиБ (%s)\n' "$used_kib" "$limit_kib" "$limit_description"
printf 'Заполненность: %d.%02d%%; порог: %s%%\n' \
  "$((percent_x100 / 100))" "$((percent_x100 % 100))" "$threshold"

if (( used_kib * 100 <= limit_kib * threshold )); then
  printf 'Порог не превышен. Архивация не требуется.\n'
  exit 0
fi



# Часть 2 (Гусев Артём)
# Размеры
DIR_SIZE=$(du -sb "$log_dir" | awk '{print $1}') \
  || error "$E_SIZE_UNKNOWN" 'Не удалось определить размер каталога логов в байтах.'
CRITICAL_SIZE=$(( limit_kib * 1024 * threshold / 100 ))

echo "Лимит превышен! Ваша папка занимает больше чем $threshold% вашего лимита!"
echo "Начинаю архивацию файлов..."


# Здесь мы жестко облажались, т.к не стандартизировали названия переменных заранее. На производительность в целом оно не появлияет :)
BACKUP_DIR="$backup_dir"

# Путь архивации
ARCHIVE_NAME="archived_logs_$(date +%m%d_%H%M%S)_$$.tar.gz"
ARCHIVE_PATH="$BACKUP_DIR/$ARCHIVE_NAME"

# Для сортировки файлов
CURRENT_DIR_SIZE=$DIR_SIZE
FILES=()
EXCLUDE_ARGS=()
LIMIT_UNREACHABLE=0

# Цикл для выбора M файлов
while [[ "$CURRENT_DIR_SIZE" -gt "$CRITICAL_SIZE" ]]; do

    FILE_INFO=$(find "$log_dir" "${EXCLUDE_ARGS[@]}" -type f -printf "%T@ %s %p\n" | sort -n | awk 'NR==1 {print}')

    if [[ -z "$FILE_INFO" ]]; then
        echo '[Ошибка] Нет файлов для архивации. Нельзя уложиться в лимит памяти!' >&2
        LIMIT_UNREACHABLE=1
        break
    fi

    FILE_SIZE=$(echo "$FILE_INFO" | awk '{print $2}')
    FILE_PATH=$(echo "$FILE_INFO" | awk '{$1=""; $2=""; print $0}' | sed 's/^ *//')

    FILES+=("$FILE_PATH")
    EXCLUDE_ARGS+=( -not -path "$FILE_PATH" )
    CURRENT_DIR_SIZE=$(( CURRENT_DIR_SIZE - FILE_SIZE ))
done

# Проверка на разные случаи ошибок
if [[ ${#FILES[@]} -eq 0 ]]; then
    error "$E_NO_FILES" 'Нет файлов для архивации!'
else
    echo "Файлы для архивации найдены. Запускаю архивацию..."

    RELATIVE_FILES=()
    for FILE_PATH in "${FILES[@]}"; do
        RELATIVE_FILES+=("./${FILE_PATH#"$log_dir"/}")
    done
    if tar -czf "$ARCHIVE_PATH" -C "$log_dir" -- "${RELATIVE_FILES[@]}"; then
          echo "Успешно! Файлы заархивировались и были успешно размещены в папке: $ARCHIVE_PATH"

          if rm -- "${FILES[@]}"; then
              echo "[Success] Оригиналы файлов были удалены."
          else
              error "$E_DELETE_FAILED" "Не удалось удалить оригиналы файлов (архив сохранён: $ARCHIVE_PATH)."
          fi
    else
        rm -f -- "$ARCHIVE_PATH"
        error "$E_ARCHIVE_FAILED" 'Ошибка в процессе архивации!'
    fi
fi

if (( LIMIT_UNREACHABLE )); then
    error "$E_LIMIT_UNREACHABLE" 'Все файлы заархивированы, но размер всё ещё превышает порог.'
fi

echo "Выполнение скрипта успешно завершено"
