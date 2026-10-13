; Среднее арифметическое разностей элементов двух массивов.
; NASM, Linux x86-64, только системные вызовы (без libc).

bits 64
default rel

global _start

; Номера системных вызовов Linux x86-64.
%define SYS_READ   0
%define SYS_WRITE  1
%define SYS_OPEN   2
%define SYS_CLOSE  3
%define SYS_EXIT  60

; Максимальный допустимый размер входного файла — 64 КиБ.
; Буфер на один байт больше: этот дополнительный байт позволяет обнаружить,
; что файл не помещается в установленное ограничение.
%define BUFFER_SIZE 65536


section .data
    ; Разделитель между именем обработанного файла и результатом.
    separator       db ": "
    separator_len   equ $ - separator

    ; Сообщение об ошибке в UTF-8: ": файл испорчен\n".
    ; Русская часть задана байтами, чтобы результат не зависел от кодировки,
    ; в которой ассемблер читает исходный файл.
    broken_message  db ": ", 0xd1, 0x84, 0xd0, 0xb0, 0xd0, 0xb9, 0xd0, 0xbb
                    db 0x20, 0xd0, 0xb8, 0xd1, 0x81, 0xd0, 0xbf, 0xd0, 0xbe
                    db 0xd1, 0x80, 0xd1, 0x87, 0xd0, 0xb5, 0xd0, 0xbd, 0x0a
    broken_len      equ $ - broken_message

    ; Сообщение выводится в stderr, если имя файла не передано.
    usage_message   db "Использование: ./average <файл>", 10
    usage_len       equ $ - usage_message


section .bss
    ; Рабочие буферы.
    input_buffer    resb BUFFER_SIZE + 1
    number_buffer   resb 32

    ; Данные, которые должны сохраняться между отдельными этапами программы.
    filename_ptr    resq 1
    filename_len    resq 1
    file_descriptor resq 1
    input_length    resq 1
    first_sum       resq 1
    first_count     resq 1


section .text

; =============================================================================
; Точка входа и проверка аргументов командной строки
; =============================================================================
_start:
    ; При запуске процесса стек имеет вид:
    ; [rsp] = argc, [rsp + 8] = argv[0], [rsp + 16] = argv[1].
    ; Программа принимает ровно один пользовательский аргумент — имя файла.
    mov rax, [rsp]
    cmp rax, 2
    jne .usage

    ; Запоминаем адрес argv[1], потому что он потребуется и для открытия файла,
    ; и для вывода имени файла перед результатом или сообщением об ошибке.
    mov rax, [rsp + 16]
    mov [filename_ptr], rax

    ; Системный вызов write принимает явную длину строки. argv[1] завершается
    ; нулевым байтом, поэтому определяем длину вручную, как это делает strlen.
    mov rdi, rax
    xor rcx, rcx

.filename_length_loop:
    cmp byte [rdi + rcx], 0
    je .filename_length_ready
    inc rcx
    jmp .filename_length_loop

.filename_length_ready:
    mov [filename_len], rcx


; =============================================================================
; Открытие и чтение входного файла
; =============================================================================

    ; open(filename, O_RDONLY, 0):
    ; RDI — адрес имени файла, RSI = 0 — только чтение, RDX = 0 — режим не нужен.
    ; При успехе RAX содержит файловый дескриптор, при ошибке — отрицательный код.
    mov rax, SYS_OPEN
    mov rdi, [filename_ptr]
    xor rsi, rsi
    xor rdx, rdx
    syscall

    test rax, rax
    js .broken
    mov [file_descriptor], rax

    ; R8 хранит суммарное количество прочитанных байтов. Один read может вернуть
    ; меньше запрошенного объёма, поэтому чтение выполняется в цикле до EOF или
    ; до заполнения input_buffer всеми BUFFER_SIZE + 1 байтами.
    xor r8, r8

.read_loop:
    cmp r8, BUFFER_SIZE + 1
    je .read_ready

    ; read(file_descriptor, input_buffer + r8, оставшееся_место).
    mov rax, SYS_READ
    mov rdi, [file_descriptor]
    lea rsi, [input_buffer + r8]
    mov rdx, BUFFER_SIZE + 1
    sub rdx, r8
    syscall

    ; -EINTR означает, что системный вызов прерван сигналом: его можно повторить.
    cmp rax, -4                 ; EINTR
    je .read_loop

    ; Отрицательное значение — ошибка; ноль — достигнут конец файла.
    test rax, rax
    js .close_and_broken
    jz .read_ready

    ; Положительное значение RAX равно числу прочитанных байтов.
    add r8, rax
    jmp .read_loop

.read_ready:
    mov [input_length], r8

    ; Дальнейшая работа идёт только с буфером, поэтому файл можно закрыть сразу.
    mov rax, SYS_CLOSE
    mov rdi, [file_descriptor]
    syscall

    ; Если прочитан дополнительный байт, фактический размер файла больше 64 КиБ.
    cmp qword [input_length], BUFFER_SIZE
    ja .broken


; =============================================================================
; Поиск границ первой строки и её разбор
; =============================================================================

    ; R8 указывает на начало буфера, R9 — на позицию сразу после последнего
    ; прочитанного байта, R10 перемещается по буферу в поиске первого LF.
    lea r8, [input_buffer]
    mov r9, r8
    add r9, [input_length]
    mov r10, r8

.find_first_newline:
    cmp r10, r9
    je .broken                  ; без LF невозможно отделить первую строку
    cmp byte [r10], 10
    je .first_newline_found
    inc r10
    jmp .find_first_newline

.first_newline_found:
    ; parse_line использует R8–R14 как рабочие регистры, поэтому важные адреса
    ; сохраняем отдельно: R15 — конец файла, RBX — позиция первого LF.
    mov r15, r9
    mov rbx, r10

    ; Первая строка занимает диапазон [R8, RDX). Если перед LF находится CR,
    ; исключаем его из диапазона, чтобы поддерживать окончания строк CRLF.
    mov rdx, r10
    cmp rdx, r8
    je .first_line_ready
    cmp byte [rdx - 1], 13
    jne .first_line_ready
    dec rdx

.first_line_ready:
    mov rsi, r8
    call parse_line
    jc .broken

    ; Сохраняем сумму и количество чисел первой строки: после разбора второй
    ; строки эти значения потребуются для проверки и вычисления результата.
    mov [first_sum], rax
    mov [first_count], rcx


; =============================================================================
; Поиск границ второй строки и её разбор
; =============================================================================

    ; Вторая строка начинается сразу после первого LF. Она может завершаться
    ; концом файла либо одним LF в самом конце файла.
    mov r9, r15
    inc rbx
    mov r8, rbx                 ; R8 — начало второй строки
    mov r11, r8

.find_second_newline:
    cmp r11, r9
    je .second_line_without_lf
    cmp byte [r11], 10
    je .second_newline_found
    inc r11
    jmp .find_second_newline

.second_newline_found:
    ; После завершающего LF не должно оставаться байтов: иначе во входном файле
    ; присутствует третья строка или посторонние данные.
    lea rax, [r11 + 1]
    cmp rax, r9
    jne .broken

    ; Исключаем CR перед завершающим LF при формате CRLF.
    mov rdx, r11
    cmp rdx, r8
    je .second_line_ready
    cmp byte [rdx - 1], 13
    jne .second_line_ready
    dec rdx
    jmp .second_line_ready

.second_line_without_lf:
    ; Если LF отсутствует, конец строки совпадает с концом прочитанных данных.
    mov rdx, r9

.second_line_ready:
    mov rsi, r8
    call parse_line
    jc .broken

    ; Среднее разностей определено только для массивов одинаковой длины.
    cmp rcx, [first_count]
    jne .broken


; =============================================================================
; Вычисление среднего арифметического разностей
; =============================================================================

    ; Для массивов x и y одинаковой длины:
    ; average(x[i] - y[i]) = (sum(x) - sum(y)) / count.
    ; После второго parse_line: RAX = sum(y), RCX = count.
    mov rdx, [first_sum]
    sub rdx, rax
    jo .broken                  ; разность не должна выйти за границы int64

    ; CQO расширяет знаковое делимое RAX до пары RDX:RAX. IDIV выполняет
    ; знаковое целочисленное деление и округляет результат к нулю.
    mov rax, rdx
    cqo
    idiv rcx
    mov rbx, rax                ; сохраняем результат: write_all изменяет RAX


; =============================================================================
; Вывод имени файла и результата
; =============================================================================

    ; Сначала в stdout выводятся имя файла и разделитель ": ".
    mov rdi, 1
    mov rsi, [filename_ptr]
    mov rdx, [filename_len]
    call write_all
    jc .exit_error

    mov rdi, 1
    lea rsi, [separator]
    mov rdx, separator_len
    call write_all
    jc .exit_error

    ; Десятичные цифры формируются справа налево в number_buffer. Последний байт
    ; заранее занят LF, а RCX хранит текущую длину готовой строки.
    mov rax, rbx
    lea rsi, [number_buffer + 31]
    mov byte [rsi], 10
    mov rcx, 1

    ; R8B — признак отрицательного числа. Для отрицательного результата NEG
    ; формирует unsigned-модуль. Даже INT64_MIN после NEG имеет корректное
    ; беззнаковое представление 2^63, которое можно обрабатывать инструкцией DIV.
    xor r8d, r8d
    test rax, rax
    jns .absolute_value_ready
    mov r8b, 1
    neg rax

.absolute_value_ready:
    mov r9, 10

.number_loop:
    ; Остаток от деления на 10 — очередная цифра, частное — ещё не обработанная
    ; старшая часть числа. Цикл выполняется хотя бы раз, поэтому ноль выводится.
    xor rdx, rdx
    div r9
    add dl, '0'
    dec rsi
    mov [rsi], dl
    inc rcx
    test rax, rax
    jnz .number_loop

    ; Для исходного отрицательного числа добавляем знак перед первой цифрой.
    test r8b, r8b
    jz .number_ready
    dec rsi
    mov byte [rsi], '-'
    inc rcx

.number_ready:
    ; RSI уже указывает на первый символ, RCX содержит длину вместе с LF.
    mov rdi, 1
    mov rdx, rcx
    call write_all
    jc .exit_error

    ; Код возврата 0 означает успешное завершение.
    xor rdi, rdi
    jmp .exit


; =============================================================================
; Обработка ошибок и завершение программы
; =============================================================================

.close_and_broken:
    ; При ошибке чтения закрываем уже открытый дескриптор перед выводом сообщения.
    mov rax, SYS_CLOSE
    mov rdi, [file_descriptor]
    syscall

.broken:
    ; Ошибки открытия, чтения, формата данных и переполнения имеют единый вид:
    ; "<имя файла>: файл испорчен". Сообщение отправляется в stdout по условию
    ; исходной программы; возможную ошибку самого вывода здесь уже не обрабатываем.
    mov rdi, 1
    mov rsi, [filename_ptr]
    mov rdx, [filename_len]
    call write_all

    mov rdi, 1
    lea rsi, [broken_message]
    mov rdx, broken_len
    call write_all

.exit_error:
    ; Любая ошибка завершается кодом 1.
    mov rdi, 1
    jmp .exit

.usage:
    ; Некорректное число аргументов: подсказка выводится в stderr (fd = 2).
    mov rdi, 2
    lea rsi, [usage_message]
    mov rdx, usage_len
    call write_all
    mov rdi, 1

.exit:
    ; exit(RDI), где RDI — заранее подготовленный код возврата.
    mov rax, SYS_EXIT
    syscall


; =============================================================================
; parse_line — разбор одной строки с целыми числами
; =============================================================================
;
; Вход:
;   RSI — адрес первого символа строки;
;   RDX — адрес конца строки, не включённого в диапазон.
;
; Выход при успехе:
;   RAX — сумма всех чисел;
;   RCX — количество чисел;
;   CF = 0.
;
; Выход при ошибке:
;   CF = 1; значения остальных регистров не определены.
;
; Допустимый формат элемента: пробелы/табуляции, необязательный знак + или -,
; одна или несколько цифр, пробелы/табуляции. Элементы разделяются запятыми.
; Пустые элементы, лишняя запятая, другие символы и переполнение int64 считаются
; ошибкой. Процедура использует R8–R14 как внутренние рабочие регистры.
parse_line:
    ; Инициализация состояния разбора.
    mov r8, rsi                 ; текущая позиция в строке
    mov r9, rdx                 ; конец строки, не включительно
    xor r10, r10                ; накопленная сумма
    xor r11, r11                ; количество разобранных чисел

.next_element:
    ; Перед каждым числом пропускаем пробелы и горизонтальные табуляции.
    ; Если после них достигнут конец, элемент отсутствует: это также обнаруживает
    ; пустую строку и запятую без числа после неё.
.skip_leading_spaces:
    cmp r8, r9
    je .parse_error

    mov al, [r8]
    cmp al, ' '
    je .leading_space
    cmp al, 9
    jne .read_sign

.leading_space:
    inc r8
    jmp .skip_leading_spaces

.read_sign:
    ; R12B хранит знак текущего числа: 0 — неотрицательное, 1 — отрицательное.
    xor r12d, r12d
    cmp al, '-'
    jne .check_plus

    mov r12b, 1
    inc r8
    jmp .digits_start

.check_plus:
    cmp al, '+'
    jne .digits_start
    inc r8

.digits_start:
    ; Сразу после необязательного знака должна находиться хотя бы одна цифра.
    cmp r8, r9
    je .parse_error

    mov al, [r8]
    cmp al, '0'
    jb .parse_error
    cmp al, '9'
    ja .parse_error

    ; Модуль числа накапливается как беззнаковое значение. Это необходимо для
    ; корректного представления -9223372036854775808, модуль которого равен 2^63.
    xor r13, r13

.digit_loop:
    ; Конец диапазона или первый нецифровой символ завершает чтение числа.
    cmp r8, r9
    je .digits_ready

    movzx rax, byte [r8]
    cmp al, '0'
    jb .digits_ready
    cmp al, '9'
    ja .digits_ready
    sub eax, '0'

    ; До операции value = value * 10 + digit проверяем границы int64.
    ; Первые 18 цифр сравниваются с INT64_MAX / 10. Если частичное значение
    ; совпало с этой границей, последняя цифра может быть не больше 7 для плюса
    ; и не больше 8 для минуса.
    mov r14, 922337203685477580
    cmp r13, r14
    ja .parse_error
    jb .append_digit

    test r12b, r12b
    jz .positive_last_digit
    cmp eax, 8
    ja .parse_error
    jmp .append_digit

.positive_last_digit:
    cmp eax, 7
    ja .parse_error

.append_digit:
    imul r13, r13, 10
    add r13, rax
    inc r8
    jmp .digit_loop

.digits_ready:
    ; Применяем сохранённый знак к готовому модулю.
    mov rax, r13
    test r12b, r12b
    jz .value_ready
    neg rax

.value_ready:
    ; Добавляем число к общей сумме. Даже если каждое число помещается в int64,
    ; их сумма может переполниться, поэтому проверяется флаг OF.
    add r10, rax
    jo .parse_error
    inc r11

    ; После числа также разрешены пробелы и горизонтальные табуляции.
.skip_trailing_spaces:
    cmp r8, r9
    je .parse_success

    mov al, [r8]
    cmp al, ' '
    je .trailing_space
    cmp al, 9
    jne .expect_comma

.trailing_space:
    inc r8
    jmp .skip_trailing_spaces

.expect_comma:
    ; Первый непробельный символ после числа обязан быть запятой. После неё
    ; управление возвращается к разбору следующего обязательного элемента.
    cmp al, ','
    jne .parse_error
    inc r8
    jmp .next_element

.parse_success:
    ; Возвращаем накопленные значения и сбрасываем флаг переноса.
    mov rax, r10
    mov rcx, r11
    clc
    ret

.parse_error:
    ; Установленный CF сообщает вызывающему коду о некорректной строке.
    stc
    ret


; =============================================================================
; write_all — гарантированная запись всего переданного диапазона
; =============================================================================
;
; Вход:
;   RDI — файловый дескриптор;
;   RSI — адрес первого выводимого байта;
;   RDX — количество байтов.
;
; Выход:
;   CF = 0, если записан весь диапазон;
;   CF = 1 при ошибке записи.
;
; Системный вызов write может записать только часть данных, поэтому процедура
; повторяет его, сдвигая адрес и уменьшая остаток, пока не запишет всё.
write_all:
    ; Пустой диапазон уже считается успешно записанным.
    test rdx, rdx
    jz .write_success

.write_loop:
    mov rax, SYS_WRITE
    syscall

    ; Прерванный сигналом write безопасно повторяется с теми же аргументами.
    cmp rax, -4                 ; EINTR
    je .write_loop

    ; Отрицательное значение — ошибка. Ноль при ненулевой длине не продвигает
    ; запись и привёл бы к бесконечному циклу, поэтому тоже считается ошибкой.
    test rax, rax
    jle .write_error

    ; RAX байтов уже записаны: переходим к ещё не выведенной части диапазона.
    add rsi, rax
    sub rdx, rax
    jnz .write_loop

.write_success:
    clc
    ret

.write_error:
    stc
    ret
