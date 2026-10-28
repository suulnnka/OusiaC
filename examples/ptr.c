/* OusiaC 指针/数组/字符串/函数指针测试 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int cmp_int(const void *a, const void *b) {
    return *(const int *)a - *(const int *)b;
}

int apply(int (*f)(int), int x) {
    return f(x);
}

int double_it(int x) {
    return x * 2;
}

int main(void) {
    /* 指针运算与数组 */
    int a[8];
    for (int i = 0; i < 8; i++)
        a[i] = i * i;
    int *p = a;
    printf("1: %d %d %d\n", *p, *(p + 3), p[7]);       /* 0 9 49 */
    printf("2: %d\n", (int)(&a[5] - &a[2]));           /* 3 */
    int *q = &a[8];
    printf("3: %d\n", (int)(q - p));                   /* 8 */

    /* 字符串遍历 */
    char s[] = "OusiaC";
    int n = 0;
    for (char *c = s; *c; c++)
        n++;
    printf("4: %d %d\n", n, (int)strlen(s));           /* 3 3 */

    /* 多维数组 */
    int m[3][4];
    for (int y = 0; y < 3; y++)
        for (int x = 0; x < 4; x++)
            m[y][x] = y + x;
    printf("5: %d %d %d\n", m[0][0], m[1][2], m[2][3]);
    int *row = m[1];
    printf("6: %d\n", row[3]);

    /* 函数指针 */
    int (*fp)(int) = double_it;
    printf("7: %d %d\n", fp(21), apply(double_it, 50));

    /* qsort(libc 回调) */
    int v[10];
    for (int i = 0; i < 10; i++)
        v[i] = (i * 7919) % 100;
    qsort(v, 10, sizeof(int), cmp_int);
    printf("8:");
    for (int i = 0; i < 10; i++)
        printf(" %d", v[i]);
    printf("\n");

    /* 指针数组与字符串字面量 */
    char *names[3];
    names[0] = "ada";
    names[1] = "bob";
    names[2] = "eve";
    for (int i = 0; i < 3; i++)
        printf("9: %c %s\n", names[i][0] - 32, names[i]);

    /* void* 与强转 */
    void *vp = a;
    int *ip = vp;
    printf("10: %d\n", ip[3]);
    return 0;
}
