; Среднее арифметическое разностей элементов двух массивов.
; NASM, Linux x86-64, только системные вызовы (без libc).

bits 64
default rel

global _start

%define SYS_READ   0
%define SYS_WRITE  1
%define SYS_OPEN   2
%define SYS_CLOSE  3
%define SYS_EXIT  60

%define BUFFER_SIZE 65536

section .data
    separator       db ": "
    separator_len   equ $ - separator

    broken_message  db ": ", 0xd1, 0x84, 0xd0, 0xb0, 0xd0, 0xb9, 0xd0, 0xbb
                    db 0x20, 0xd0, 0xb8, 0xd1, 0x81, 0xd0, 0xbf, 0xd0, 0xbe
                    db 0xd1, 0x80, 0xd1, 0x87, 0xd0, 0xb5, 0xd0, 0xbd, 0x0a
    broken_len      equ $ - broken_message

    usage_message   db "Использование: ./average <файл>", 10
    usage_len       equ $ - usage_message

section .bss
    input_buffer    resb BUFFER_SIZE + 1
    number_buffer   resb 32
    filename_ptr    resq 1
    filename_len    resq 1
    file_descriptor resq 1
    input_length    resq 1
    first_sum       resq 1
    first_count     resq 1

section .text

_start:
    mov rax, [rsp]
    cmp rax, 2
    jne .usage

    mov rax, [rsp + 16]
    mov [filename_ptr], rax

    ; Длина имени нужна для вывода результата.
    mov rdi, rax
    xor rcx, rcx
.filename_length_loop:
    cmp byte [rdi + rcx], 0
    je .filename_length_ready
    inc rcx
    jmp .filename_length_loop
.filename_length_ready:
    mov [filename_len], rcx

    ; open(filename, O_RDONLY)
    mov rax, SYS_OPEN
    mov rdi, [filename_ptr]
    xor rsi, rsi
    xor rdx, rdx
    syscall
    test rax, rax
    js .broken
    mov [file_descriptor], rax

    ; Читаем не более BUFFER_SIZE + 1 байта. Лишний байт означает,
    ; что файл слишком велик для рабочего буфера.
    xor r8, r8
.read_loop:
    cmp r8, BUFFER_SIZE + 1
    je .read_ready
    mov rax, SYS_READ
    mov rdi, [file_descriptor]
    lea rsi, [input_buffer + r8]
    mov rdx, BUFFER_SIZE + 1
    sub rdx, r8
    syscall
    cmp rax, -4                 ; EINTR
    je .read_loop
    test rax, rax
    js .close_and_broken
    jz .read_ready
    add r8, rax
    jmp .read_loop

.read_ready:
    mov [input_length], r8
    mov rax, SYS_CLOSE
    mov rdi, [file_descriptor]
    syscall

    cmp qword [input_length], BUFFER_SIZE
    ja .broken

    ; Ищем конец первой строки.
    lea r8, [input_buffer]
    mov r9, r8
    add r9, [input_length]
    mov r10, r8
.find_first_newline:
    cmp r10, r9
    je .broken                  ; обязательно нужны две строки
    cmp byte [r10], 10
    je .first_newline_found
    inc r10
    jmp .find_first_newline

.first_newline_found:
    mov r15, r9                 ; parse_line использует r8-r14
    mov rbx, r10
    mov rdx, r10
    cmp rdx, r8
    je .first_line_ready
    cmp byte [rdx - 1], 13
    jne .first_line_ready
    dec rdx                     ; CRLF
.first_line_ready:
    mov rsi, r8
    call parse_line
    jc .broken
    mov [first_sum], rax
    mov [first_count], rcx

    ; Вторая строка заканчивается EOF либо единственным завершающим LF.
    mov r9, r15
    inc rbx
    mov r8, rbx                 ; начало второй строки
    mov r11, r8
.find_second_newline:
    cmp r11, r9
    je .second_line_without_lf
    cmp byte [r11], 10
    je .second_newline_found
    inc r11
    jmp .find_second_newline

.second_newline_found:
    lea rax, [r11 + 1]
    cmp rax, r9
    jne .broken                 ; третья строка или данные после LF
    mov rdx, r11
    cmp rdx, r8
    je .second_line_ready
    cmp byte [rdx - 1], 13
    jne .second_line_ready
    dec rdx                     ; CRLF
    jmp .second_line_ready

.second_line_without_lf:
    mov rdx, r9

.second_line_ready:
    mov rsi, r8
    call parse_line
    jc .broken
    cmp rcx, [first_count]
    jne .broken

    ; (sum(x) - sum(y)) / count. IDIV округляет к нулю.
    mov rdx, [first_sum]
    sub rdx, rax
    jo .broken
    mov rax, rdx
    cqo
    idiv rcx
    mov rbx, rax                ; write_all изменяет RAX

    ; Сначала имя файла и разделитель.
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

    ; Преобразование результата в десятичную строку справа налево.
    mov rax, rbx
    lea rsi, [number_buffer + 31]
    mov byte [rsi], 10
    mov rcx, 1
    xor r8d, r8d
    test rax, rax
    jns .absolute_value_ready
    mov r8b, 1
    neg rax                     ; для INT64_MIN остаётся корректный unsigned модуль
.absolute_value_ready:
    mov r9, 10
.number_loop:
    xor rdx, rdx
    div r9
    add dl, '0'
    dec rsi
    mov [rsi], dl
    inc rcx
    test rax, rax
    jnz .number_loop
    test r8b, r8b
    jz .number_ready
    dec rsi
    mov byte [rsi], '-'
    inc rcx
.number_ready:
    mov rdi, 1
    mov rdx, rcx
    call write_all
    jc .exit_error

    xor rdi, rdi
    jmp .exit

.close_and_broken:
    mov rax, SYS_CLOSE
    mov rdi, [file_descriptor]
    syscall

.broken:
    mov rdi, 1
    mov rsi, [filename_ptr]
    mov rdx, [filename_len]
    call write_all

    mov rdi, 1
    lea rsi, [broken_message]
    mov rdx, broken_len
    call write_all

.exit_error:
    mov rdi, 1
    jmp .exit

.usage:
    mov rdi, 2
    lea rsi, [usage_message]
    mov rdx, usage_len
    call write_all
    mov rdi, 1

.exit:
    mov rax, SYS_EXIT
    syscall

; parse_line
; Вход:  RSI = начало, RDX = конец (не включительно).
; Выход: RAX = сумма, RCX = количество, CF = 1 при ошибке.
; Формат: пробелы, [+-]цифры, пробелы, затем запятая или конец.
parse_line:
    mov r8, rsi                 ; текущая позиция
    mov r9, rdx                 ; конец
    xor r10, r10                ; сумма
    xor r11, r11                ; количество

.next_element:
    ; Пробелы перед числом.
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
    xor r12d, r12d              ; 0 = плюс, 1 = минус
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
    cmp r8, r9
    je .parse_error
    mov al, [r8]
    cmp al, '0'
    jb .parse_error
    cmp al, '9'
    ja .parse_error
    xor r13, r13                ; unsigned модуль числа

.digit_loop:
    cmp r8, r9
    je .digits_ready
    movzx rax, byte [r8]
    cmp al, '0'
    jb .digits_ready
    cmp al, '9'
    ja .digits_ready
    sub eax, '0'

    ; Проверка границы int64 до умножения на 10.
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
    mov rax, r13
    test r12b, r12b
    jz .value_ready
    neg rax
.value_ready:
    add r10, rax
    jo .parse_error
    inc r11

    ; После числа допустимы пробелы и табуляции.
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
    cmp al, ','
    jne .parse_error
    inc r8
    jmp .next_element

.parse_success:
    mov rax, r10
    mov rcx, r11
    clc
    ret

.parse_error:
    stc
    ret

; write_all
; Вход: RDI = fd, RSI = адрес, RDX = длина. CF = 1 при ошибке.
write_all:
    test rdx, rdx
    jz .write_success
.write_loop:
    mov rax, SYS_WRITE
    syscall
    cmp rax, -4                 ; EINTR
    je .write_loop
    test rax, rax
    jle .write_error
    add rsi, rax
    sub rdx, rax
    jnz .write_loop
.write_success:
    clc
    ret
.write_error:
    stc
    ret
