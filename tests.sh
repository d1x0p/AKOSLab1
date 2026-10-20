#!/bin/bash
SCRIPT_PATH="/home/vboxuser/archive_new.sh"
TEST_LOGS_DIR="/tmp/archive_test_logs_$$"
TEST_BACKUPS_DIR="/tmp/archive_test_backups_$$"

passed=0
failed=0

assert() {
        local test_name="$1"
        local expected="$2"
        local actual="$3"
        if [[ "$expected" == "$actual" ]]; then
            echo "+ PASSED: $test_name"
            ((passed++))
        else
            echo "- FAILED: $test_name (ожидается: '$expected', получено: '$actual')"
            ((failed++))
        fi
}

cleanup() {
        rm -rf "$TEST_LOGS_DIR" "$TEST_BACKUPS_DIR"
}
trap cleanup EXIT

mkdir -p "$TEST_LOGS_DIR" "$TEST_BACKUPS_DIR"

# Тест 1: Пустой путь
"$SCRIPT_PATH" "" 80 1> /dev/null 2>&1
assert "Пустой путь" "1" "$?"

# Тест 2: Неверный формат
touch "$TEST_LOGS_DIR/wrong_format"
"$SCRIPT_PATH" "$TEST_LOGS_DIR/wrong_format" 80 > /dev/null 2>&1
assert "Неверный формат (файл вместо папки)" "1" "$?"

# Тест 3: Неверные аргументы
"$SCRIPT_PATH" "$TEST_LOGS_DIR/non_existent_log" 125 > /dev/null 2>&1
assert "Неверные аргументы" "1" "$?"

# Тест 4: Правильная архивация
test_log="$TEST_LOGS_DIR/success_log"
backup_4="$TEST_BACKUPS_DIR/backup_4"
mkdir -p "$test_log"
dd if=/dev/zero of="$test_log/file1.log" bs=1M count=1 2>/dev/null
dd if=/dev/zero of="$test_log/file2.log" bs=1M count=1 2>/dev/null
touch -t 202501010000 "$test_log/file1.log"
touch -t 202502010000 "$test_log/file2.log"

"$SCRIPT_PATH" "$test_log" 0 "$backup_4" > /dev/null 2>&1

count=$(find "$backup_4" -name "*.tar.gz" 2>/dev/null | wc -l)
existing_archive=$([[ $count -gt 0 ]] && echo "yes" || echo "no")
assert "Правильная архивация" "yes" "$existing_archive"

# Тест 5: Архивация не нужна (порог 99%, файл крошечный)
test2_log="$TEST_LOGS_DIR/skip_log"
backup_5="$TEST_BACKUPS_DIR/backup_5"
mkdir -p "$test2_log"
touch "$test2_log/new_file.log"

"$SCRIPT_PATH" "$test2_log" 99 "$backup_5" > /dev/null 2>&1

count_skip=$(find "$backup_5" -name "*.tar.gz" 2>/dev/null | wc -l)
non_existing_archive=$([[ $count_skip -eq 0 ]] && echo "yes" || echo "no")
assert "Архивация не нужна, архивов нет" "yes" "$non_existing_archive"

# Тест 6: Архивация большого объема (более 3% от диска)
test_big_log="$TEST_LOGS_DIR/big_log"
backup_6="$TEST_BACKUPS_DIR/backup_6"
mkdir -p "$test_big_log"

disk_total_b=$(df -B1 "$test_big_log" | awk 'NR==2 {print $2}')
file_size_mb=$(( disk_total_b * 5 / 100 / 1024 / 1024 ))
[[ $file_size_mb -lt 1 ]] && file_size_mb=1

echo "Размер диска - $(( disk_total_b / 1024 / 1024 / 1024 )) ГБ"
echo "Создаем файл размером ~5% от диска: $file_size_mb MB"
dd if=/dev/zero of="$test_big_log/big_data_1.log" bs=1M count=$file_size_mb 2>/dev/null

touch -t 202504010000 "$test_big_log/small_old1.log"
touch -t 202503010000 "$test_big_log/small_old2.log"

"$SCRIPT_PATH" "$test_big_log" 3 "$backup_6" > /dev/null 2>&1

count_big=$(find "$backup_6" -name "*.tar.gz" 2>/dev/null | wc -l)
existing_archive_big=$([[ $count_big -gt 0 ]] && echo "yes" || echo "no")
assert "Архивация логов более чем на 3% системы" "yes" "$existing_archive_big"


#Тест 7: логи и бэкапы в одной папке
test_7_log="$TEST_LOGS_DIR/log"
mkdir -p "$test_7_log"
"$SCRIPT_PATH" "$test_7_log" 3 "$test_7_log" > /dev/null 2>&1
assert "Бэкапы и логи в одной папке" "1" "$?"

echo "ИТОГ ТЕСТОВ:"
echo "Пройдено: $passed"
echo "Провалено: $failed"
