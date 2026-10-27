/* zcc 冒烟测试:printf 与字符串 */
#include <stdio.h>

int main(void) {
    printf("hello, zcc!\n");
    printf("dec=%d hex=%x char=%c pct=%%\n", 42, 255, 'Z');
    puts("puts works too");
    return 0;
}
