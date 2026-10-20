#!/usr/bin/env bash
# Часть 1 (Кирилл Виденкин)
set -euo pipefail

error() {
  printf 'Ошибка: %s\n' "$*" >&2
  exit 1
}

if (( $# < 1 || $# > 4 )); then
  error 'Ожидается от 1 до 4 аргументов: LOG_DIR [ПОРОГ_%] [BACKUP_DIR] [ЛИМИТ_МИБ]'
fi

input_log_dir=$1
threshold=${2:-70}
input_backup_dir=${3:-"$(dirname -- "$input_log_dir")/backup"}
limit_mib=${4:-}

[[ "$threshold" =~ ^(0|[1-9][0-9]?|100)$ ]] || error 'Порог должен быть целым числом от 0 до 100.'
if [[ -n "$limit_mib" ]]; then
  [[ "$limit_mib" =~ ^[1-9][0-9]*$ ]] || error 'Лимит в МиБ должен быть положительным целым числом.'
fi

[[ -d "$input_log_dir" ]] || error "Каталог логов не найден: $input_log_dir"
[[ -r "$input_log_dir" && -w "$input_log_dir" && -x "$input_log_dir" ]] \
  || error 'Нет прав для работы с каталогом логов.'

log_dir=$(cd -- "$input_log_dir" && pwd -P)
mkdir -p -- "$input_backup_dir" || error 'Не удалось создать каталог для архивов.'
backup_dir=$(cd -- "$input_backup_dir" && pwd -P)

case "$backup_dir/" in
  "$log_dir/"*) error 'Каталог backup должен находиться вне каталога логов.' ;;
esac

used_kib=$(du -sk "$log_dir" | awk '{print $1}')
[[ "$used_kib" =~ ^[0-9]+$ ]] || error 'Не удалось определить размер каталога логов.'

if [[ -n "$limit_mib" ]]; then
  limit_kib=$((limit_mib * 1024))
  limit_description="заданный лимит: ${limit_mib} МиБ"
else
  limit_kib=$(df -Pk "$log_dir" | awk 'NR==2 {print $2}')
  limit_description='вся файловая система'
fi
[[ "$limit_kib" =~ ^[1-9][0-9]*$ ]] || error 'Не удалось определить вместимость.'

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
DIR_SIZE=$(du -sb "$log_dir" | awk '{print $1}')
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

# Цикл для выбора M файлов
while [[ "$CURRENT_DIR_SIZE" -gt "$CRITICAL_SIZE" ]]; do

    FILE_INFO=$(find "$log_dir" "${EXCLUDE_ARGS[@]}" -type f -printf "%T@ %s %p\n" | sort -n | awk 'NR==1 {print}')

    if [[ -z "$FILE_INFO" ]]; then
        echo '[Ошибка] Нет файлов для архивации. Нельзя уложиться в лимит памяти!'
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
    echo "[Ошибка] Нет файлов для архивации!"
else
    echo "Файлы для архивации найдены. Запускаю архивацию..."

    RELATIVE_FILES=()
    for FILE_PATH in "${FILES[@]}"; do
        RELATIVE_FILES+=("./${FILE_PATH#"$log_dir"/}")
    done
    if tar -czf "$ARCHIVE_PATH" -C "$log_dir" -- "${RELATIVE_FILES[@]}"; then
          echo "Успешно! Файлы заархивировались и были успешно размещены в папке: $ARCHIVE_PATH"

          rm -- "${FILES[@]}"
          echo "[Success] Оригиналы файлов были удалены. Выполнение скрипта успешно завершено"
    else
        rm -f -- "$ARCHIVE_PATH"
        echo "[Ошибка] Ошибка в процессе архивации!" >&2
        exit 1
    fi
fi
