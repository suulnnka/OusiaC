/* OusiaC 控制流测试:循环/switch/goto/标签 */
#include <stdio.h>

int fib(int n) {
    if (n < 2)
        return n;
    return fib(n - 1) + fib(n - 2);
}

int main(void) {
    /* while */
    int s = 0, i = 1;
    while (i <= 10) {
        s += i;
        i++;
    }
    printf("1: %d\n", s); /* 55 */

    /* do-while */
    int j = 10;
    do {
        j--;
    } while (j > 7);
    printf("2: %d\n", j); /* 7 */

    /* for + continue + break */
    int t = 0;
    for (int k = 0; k < 100; k++) {
        if (k % 2 == 0)
            continue;
        if (k > 20)
            break;
        t += k;
    }
    printf("3: %d\n", t); /* 1+3+...+19 = 100 */

    /* switch + fallthrough + default */
    for (int k = 0; k < 6; k++) {
        switch (k) {
        case 0:
            printf("4: zero\n");
            break;
        case 1:
        case 2:
            printf("4: small %d\n", k);
            break;
        case 5:
            printf("4: five\n");
            break;
        default:
            printf("4: other %d\n", k);
            break;
        }
    }

    /* goto 跳出嵌套循环 */
    int a[4][4];
    int found = -1;
    for (int y = 0; y < 4; y++) {
        for (int x = 0; x < 4; x++) {
            a[y][x] = y * 10 + x;
            if (a[y][x] == 23)
                goto found_it;
        }
    }
found_it:
    found = 23;
    printf("5: %d\n", found);

    /* 递归 */
    printf("6:");
    for (int k = 0; k < 12; k++)
        printf(" %d", fib(k));
    printf("\n");

    /* switch 字符 case */
    char *msg = "az";
    for (int k = 0; msg[k]; k++) {
        switch (msg[k]) {
        case 'a':
            putchar('A');
            break;
        case 'z':
            putchar('Z');
            break;
        }
    }
    printf("\n");
    return 0;
}
