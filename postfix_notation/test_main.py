import runpy
import subprocess
import sys
from pathlib import Path

import pytest

from main import apply_op, eval_expr, parse_args


MAIN_FILE = Path(__file__).with_name("main.py")


@pytest.mark.parametrize(
    ("arguments", "expected"),
    [
        (["2 3 +"], "2 3 +"),
        (["2", "3", "+"], "2 3 +"),
        (["0 1 2 ~"], "0 1 2 ~"),
        (["0", "1", "2", "~"], "0 1 2 ~"),
        (
            ["3", "0", "4", str(Path.home()), "2", str(Path.home())],
            "3 0 4 ~ 2 ~",
        ),
        ([str(Path.home() / "value")], str(Path.home() / "value")),
    ],
    ids=[
        "single_argument",
        "separate_arguments",
        "tilde_in_single_argument",
        "literal_tilde",
        "home_paths_are_replaced",
        "home_subdirectory_is_not_replaced",
    ],
)
def test_parse_arguments(arguments, expected):
    # Подготовка
    raw_arguments = arguments.copy()

    # Действие
    result = parse_args(raw_arguments)

    # Проверка
    assert result == expected


@pytest.mark.parametrize(
    ("expression", "expected"),
    [
        ("2 3 +", 5.0),
        ("8 3 -", 5.0),
        ("4 5 *", 20.0),
        ("8 2 /", 4.0),
    ],
    ids=["addition", "subtraction", "multiplication", "division"],
)
def test_arithmetic_operations(expression, expected):
    # Подготовка
    raw_expression = expression

    # Действие
    result = eval_expr(raw_expression)

    # Проверка
    assert result == expected


@pytest.mark.parametrize(
    ("expression", "expected"),
    [
        ("8 2 -", 6.0),
        ("8 2 /", 4.0),
    ],
    ids=["subtraction", "division"],
)
def test_operand_order(expression, expected):
    # Подготовка
    raw_expression = expression

    # Действие
    result = eval_expr(raw_expression)

    # Проверка
    assert result == expected


def test_division_with_fractional_result():
    # Подготовка
    expression = "5 2 /"

    # Действие
    result = eval_expr(expression)

    # Проверка
    assert result == 2.5


@pytest.mark.parametrize(
    ("expression", "expected"),
    [
        ("-4 2 +", -2.0),
        ("1.5 2.5 +", 4.0),
    ],
    ids=["negative_number", "fractional_numbers"],
)
def test_negative_and_fractional_numbers(expression, expected):
    # Подготовка
    raw_expression = expression

    # Действие
    result = eval_expr(raw_expression)

    # Проверка
    assert result == expected


def test_several_operations_in_one_expression():
    # Подготовка
    expression = "2 3 + 4 * 5 -"

    # Действие
    result = eval_expr(expression)

    # Проверка
    assert result == 15.0


def test_expression_with_one_number():
    # Подготовка
    expression = "42"

    # Действие
    result = eval_expr(expression)

    # Проверка
    assert result == 42.0


def test_commas_are_treated_as_separators():
    # Подготовка
    expression = "2,3,+"

    # Действие
    result = eval_expr(expression)

    # Проверка
    assert result == 5.0


def test_tilde_with_nonzero_operands():
    # Подготовка
    expression = "8 2 ~"

    # Действие
    result = eval_expr(expression)

    # Проверка
    assert result == 6.0


def test_tilde_with_equal_operands():
    # Подготовка
    expression = "5 5 ~"

    # Действие
    result = eval_expr(expression)

    # Проверка
    assert result == 0.0


@pytest.mark.parametrize(
    ("expression", "expected"),
    [
        ("0 3 ~", 9.0),
        ("3 0 ~", 9.0),
        ("0 0 ~", 0.0),
    ],
    ids=["x_is_zero", "y_is_zero", "both_are_zero"],
)
def test_tilde_with_zero_operands(expression, expected):
    # Подготовка
    raw_expression = expression

    # Действие
    result = eval_expr(raw_expression)

    # Проверка
    assert result == expected


def test_tilde_with_zero_operand_sums_the_whole_stack():
    # Подготовка
    expression = "2 3 0 ~"

    # Действие
    result = eval_expr(expression)

    # Проверка
    assert result == 25.0


def test_tilde_with_nonzero_operands_keeps_other_stack_values():
    # Подготовка
    stack = [10.0, 8.0, 2.0]

    # Действие
    apply_op(stack, "~")

    # Проверка
    assert stack == [10.0, 6.0]


@pytest.mark.parametrize(
    ("expression", "expected"),
    [
        ("3 0 4 ~ 2 ~", 47.0),
        ("2 2 + 4 - 4 ~ 2 3 * +", 22.0),
    ],
    ids=["first_task_expression", "second_task_expression"],
)
def test_expressions_from_task(expression, expected):
    # Подготовка
    raw_expression = expression

    # Действие
    result = eval_expr(raw_expression)

    # Проверка
    assert result == expected


@pytest.mark.parametrize(
    ("expression", "message"),
    [
        ("2 unknown", "Неизвестный оператор: поддерживаемые операторы '+ - / * ~'"),
        ("+", "Некорректный ввод: количество операндов должно быть не менее 2"),
        ("2 +", "Некорректный ввод: количество операндов должно быть не менее 2"),
        ("2 0 /", "Ошибка деления: деление на нуль запрещено"),
        ("", "Ошибка стека: стек пуст, вычислять нечего"),
        ("   ", "Ошибка стека: стек пуст, вычислять нечего"),
        ("2 3", "Отсутствие операторов: нет операций для объединения"),
    ],
    ids=[
        "unknown_token",
        "operator_with_empty_stack",
        "operator_with_one_number",
        "division_by_zero",
        "empty_expression",
        "whitespace_expression",
        "several_values_left",
    ],
)
def test_invalid_expression_exits_with_message(expression, message, capsys):
    # Подготовка
    raw_expression = expression

    # Действие
    with pytest.raises(SystemExit) as error:
        eval_expr(raw_expression)

    # Проверка
    assert error.value.code == 1
    assert message in capsys.readouterr().out


def test_stack_is_printed_after_adding_number(capsys):
    # Подготовка
    expression = "2"

    # Действие
    eval_expr(expression)

    # Проверка
    assert capsys.readouterr().out.splitlines() == ["[2.0]"]


def test_stack_is_printed_after_operation(capsys):
    # Подготовка
    expression = "2 3 +"

    # Действие
    eval_expr(expression)

    # Проверка
    assert capsys.readouterr().out.splitlines()[-1] == "[5.0]"


def test_all_stack_states_are_printed_in_order(capsys):
    # Подготовка
    expression = "2 3 +"

    # Действие
    eval_expr(expression)

    # Проверка
    assert capsys.readouterr().out.splitlines() == [
        "[2.0]",
        "[2.0, 3.0]",
        "[5.0]",
    ]


@pytest.mark.parametrize(
    ("arguments", "message"),
    [
        ([], "Ошибка: выражение не передано, передайте выражение через пробел или строкой"),
        (["2 3 +", "4 5 +"], "Отсутствие операторов: нет операций для объединения"),
    ],
    ids=["no_expression", "several_values_left"],
)
def test_cli_rejects_invalid_input(arguments, message):
    # Подготовка
    command = [sys.executable, str(MAIN_FILE), *arguments]

    # Действие
    completed = subprocess.run(command, capture_output=True, text=True, check=False)

    # Проверка
    assert completed.returncode == 1
    assert message in completed.stdout


@pytest.mark.parametrize(
    ("arguments", "expected"),
    [
        (["2 3 +"], "2 3 + = 5.0"),
        (["2", "3", "+"], "2 3 + = 5.0"),
        (["3 0 4 ~ 2 ~"], "3 0 4 ~ 2 ~ = 47.0"),
        (
            ["3", "0", "4", str(Path.home()), "2", str(Path.home())],
            "3 0 4 ~ 2 ~ = 47.0",
        ),
    ],
    ids=["single_argument", "separate_arguments", "literal_tilde", "expanded_tilde"],
)
def test_cli_prints_expression_and_result(arguments, expected):
    # Подготовка
    command = [sys.executable, str(MAIN_FILE), *arguments]

    # Действие
    completed = subprocess.run(command, capture_output=True, text=True, check=False)

    # Проверка
    assert completed.returncode == 0
    assert completed.stdout.splitlines()[-1] == expected
    assert completed.stderr == ""


def test_main_block_rejects_missing_expression(monkeypatch, capsys):
    # Подготовка
    monkeypatch.setattr(sys, "argv", [str(MAIN_FILE)])

    # Действие
    with pytest.raises(SystemExit) as error:
        runpy.run_path(str(MAIN_FILE), run_name="__main__")

    # Проверка
    assert error.value.code == 1
    assert (
        capsys.readouterr().out.strip()
        == "Ошибка: выражение не передано, передайте выражение через пробел или строкой"
    )


def test_main_block_prints_expression_and_result(monkeypatch, capsys):
    # Подготовка
    expression = "2 3 +"
    monkeypatch.setattr(sys, "argv", [str(MAIN_FILE), expression])

    # Действие
    runpy.run_path(str(MAIN_FILE), run_name="__main__")

    # Проверка
    assert capsys.readouterr().out.splitlines()[-1] == "2 3 + = 5.0"
