import sys
import operator
from pathlib import Path

def parse_args(args):
    home_dir = str(Path.home())
    for i,e in enumerate(args):
        if home_dir == e:
            args[i] = "~"

    expression = " ".join(args)
    return expression

def eval_expr(raw_expression):
    stack = []
    op = ["+", "-", "/", "*", "~","!"]
    expression = raw_expression.replace(",", " ").split()

    for i in expression:
        try:
            number = float(i)
        except ValueError:
            if i not in op:
                print(f"Неизвестный оператор: поддерживаемые операторы \'{" ".join(op)}\'")
                sys.exit(1)
            if len(stack) < 2:
                print("Некорректный ввод: количество операндов должно быть не менее 2")
                sys.exit(1)

            apply_op(stack, i)
        else:
            stack.append(number)
        print(stack)

    stack_len = len(stack)
    if stack_len == 1:
        return stack[0]
    elif stack_len >= 2:
        print("Отсутствие операторов: нет операций для объединения")
        sys.exit(1)
    else:
        print("Ошибка стека: стек пуст, вычислять нечего")
        sys.exit(1)

def apply_op(stack, act):
    y = stack.pop()
    x = stack.pop()

    if act != "~":
        if act == "/" and y == 0:
            print("Ошибка деления: деление на нуль запрещено")
            sys.exit(1)
        if act == "!":
            stack.append(x ** y)
        else:
            stack.append(operations[act](x, y))
    else:
        if x != 0 and y != 0:
            stack.append(abs(x - y))
        else:
            s = x + y
            while len(stack) != 0:
                s+= stack.pop()
            stack.append(s*s)

operations = {
    "+": operator.add,
    "-": operator.sub,
    "*": operator.mul,
    "/": operator.truediv,
}


if __name__ == "__main__":
    args = sys.argv[1:]
    if not args:
        print("Ошибка: выражение не передано, передайте выражение через пробел или строкой")
        sys.exit(1)
    args = parse_args(args)

    # if len(args) != 2:
    #     print("Ошибка аргумента: неверно переданный аргумент, программа ожидает выражение")
    #     sys.exit(1)

    result = eval_expr(args)
    print(f"{args} = {result}")

