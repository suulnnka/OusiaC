/* OusiaC 算术/位运算/类型测试 */
#include <stdio.h>

int main(void) {
    /* 优先级与结合性 */
    printf("1: %d\n", 2 + 3 * 4 - 10 / 2 % 3);       /* 11 */
    printf("2: %d\n", (2 + 3) * (4 - 6));             /* -10 */
    printf("3: %d\n", 1 << 3 | 1 & 3 ^ 2);            /* 8|(1&3)^2 = 8|3 = 11 */

    /* int 溢出回绕 */
    int big = 2147483647;
    printf("4: %d\n", big + 1);                       /* -2147483648 */

    /* unsigned */
    unsigned u = 0;
    printf("5: %u\n", u - 1);                         /* 4294967295 */
    unsigned long ul = 18446744073709551615UL;
    printf("6: %lu\n", ul / 3);                       /* 6148914691236517205 */

    /* 移位(有符号算术右移) */
    int neg = -64;
    printf("7: %d\n", neg >> 3);                      /* -8 */
    printf("8: %d\n", -8 / 3);                        /* -2 (截断) */
    printf("9: %d\n", -8 % 3);                        /* -2 */

    /* 递增/递减与复合赋值 */
    int i = 5;
    printf("10: %d %d %d\n", i++, ++i, i--);          /* 5 7 7 */
    i = 10;
    i *= 3; i -= 4; i <<= 1; i ^= 0xff;
    printf("11: %d\n", i);

    /* sizeof 与转换 */
    printf("12: %d %d %d\n", (int)sizeof(char), (int)sizeof(int), (int)sizeof(long));
    char c = 200;                                      /* 回绕为 -56 */
    printf("13: %d\n", c);
    long l = 1234567890123L;
    printf("14: %ld %d\n", l, (int)l);

    /* 三目与逻辑短路 */
    int side = 0;
    int r = (1 || (side = 1)) ? 100 : 200;
    printf("15: %d %d\n", r, side);                   /* 100 0 */

    /* long long 级别字面量与十六进制/八进制 */
    printf("16: %ld %d %d\n", 4611686018427387904LL, 0x1F, 010);
    return 0;
}
