import sys

if len(sys.argv) != 2:
    print("Ошибка аргумента: неверно переданный аргумент, программа ожидает выражение")
    sys.exit(1)

def doAct(stack, act):
    y = float(stack.pop())
    x = float(stack.pop())
    s = 0

    if act != "~":
        if act == "+":
            stack.append(x + y)
        elif act == "-":
            stack.append(x - y)
        elif act == "*":
            stack.append(x * y)
        elif act == "/":
            if y == 0:
                print("Ошибка деления: деление на нуль запрещено")
                sys.exit(1)
            stack.append(x / y)
    else:
        if x != 0 and y != 0:
            stack.append(abs(x - y))
        else:
            s = x + y
            while len(stack) != 0:
                s+= stack.pop()
            stack.append(s*s)

        

stack = []
op = ["+", "-", "/", "*", "~"]
expression = sys.argv[1].replace(",", " ").split()

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

        doAct(stack, i)
    else:
        stack.append(number)
    print(stack)

print("\n")

stack_len = len(stack)
if stack_len == 1:
    print(f"{" ".join(expression)} = {stack[0]}")
elif stack_len >= 2:
    print("Отсутствие операторов: нет операций для объединения")
    sys.exit(1)
else:
    print("Ошибка стека: стек пуст, вычислять нечего")
    sys.exit(1)



