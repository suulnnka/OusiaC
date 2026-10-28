/* OusiaC 堆分配/字符串函数/errno/文件 IO 测试 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>

int main(void) {
    /* malloc/realloc/free */
    int *v = malloc(5 * sizeof(int));
    if (v == 0) {
        perror("malloc");
        return 1;
    }
    for (int i = 0; i < 5; i++)
        v[i] = i + 1;
    v = realloc(v, 8 * sizeof(int));
    for (int i = 5; i < 8; i++)
        v[i] = (i + 1) * 10;
    int sum = 0;
    for (int i = 0; i < 8; i++)
        sum += v[i];
    printf("1: %d\n", sum); /* 15 + 60+70+80 = 225 */
    free(v);

    /* calloc */
    char *z = calloc(16, 1);
    printf("2: %d %d\n", z[0], z[15]);
    free(z);

    /* string.h */
    char buf[64];
    strcpy(buf, "OusiaC");
    strcat(buf, "-");
    strcat(buf, "works");
    printf("3: %s %d\n", buf, (int)strlen(buf));
    printf("4: %d %d %d\n", strcmp("abc", "abd") < 0, strcmp("abc", "abc") == 0, strncmp("xyz", "xyw", 2) == 0);
    char *dup = strdup(buf);
    printf("5: %s\n", dup);
    free(dup);
    memset(buf, 'A', 4);
    buf[4] = 0;
    printf("6: %s\n", buf);

    /* atoi / abs */
    printf("7: %d %d %ld\n", atoi("-123"), abs(-45), atol("100000"));

    /* errno */
    FILE *f = fopen("/no/such/file", "r");
    if (f == 0) {
        printf("8: errno=%d(%s)\n", errno, strerror(errno));
    }

    /* 真实文件读取 + fprintf/fgets */
    FILE *motd = fopen("/etc/motd", "r");
    if (motd) {
        char line[128];
        int lc = 0;
        while (fgets(line, sizeof(line), motd) != 0) {
            lc++;
            printf("9: %s", line);
        }
        printf("10: %d line(s)\n", lc);
        fclose(motd);
    }

    /* snprintf/sprintf 回读 */
    char sb[32];
    int w = snprintf(sb, sizeof(sb), "x=%d y=%s", 7, "z");
    printf("11: %s (%d)\n", sb, w);
    return 0;
}
