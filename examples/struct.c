/* OusiaC 结构体/联合/枚举/初始化器测试 */
#include <stdio.h>
#include <stddef.h>

enum color { RED, GREEN = 10, BLUE };
typedef struct point {
    int x;
    int y;
} Point;
typedef struct rect {
    Point tl;
    Point br;
    const char *name;
} Rect;
union blob {
    unsigned long as_word;
    unsigned char as_bytes[8];
};

int area(Rect *r) {
    return (r->br.x - r->tl.x) * (r->br.y - r->tl.y);
}

/* OusiaC 不支持结构体按值传参/返回,用出参指针代替 */
void mid(const Point *a, const Point *b, Point *out) {
    out->x = (a->x + b->x) / 2;
    out->y = (a->y + b->y) / 2;
}

int main(void) {
    /* 枚举 */
    printf("1: %d %d %d\n", RED, GREEN, BLUE);
    enum color c = BLUE;
    switch (c) {
    case BLUE:
        printf("2: blue\n");
        break;
    default:
        printf("2: ?\n");
    }

    /* 结构体成员与嵌套 */
    Point p1 = { 3, 4 };
    Point p2;
    p2.x = 10;
    p2.y = 20;
    printf("3: %d %d %d %d\n", p1.x, p1.y, p2.x, p2.y);

    Rect r = { { 1, 2 }, { 11, 22 }, "box" };
    printf("4: %d %d %s %d\n", r.tl.x, r.br.y, r.name, area(&r));
    r.tl = p2; /* 结构体赋值 */
    printf("5: %d %d\n", r.tl.x, r.tl.y);

    /* 结构体数组与指定初始化 */
    Point pts[3] = { { 1, 1 }, { 2, 4 }, { 3, 9 } };
    printf("6:");
    for (int i = 0; i < 3; i++)
        printf(" (%d,%d)", pts[i].x, pts[i].y);
    printf("\n");
    Point p3 = { .y = 7, .x = 6 };
    printf("7: %d %d\n", p3.x, p3.y);

    /* 联合的字节序视图 */
    union blob b;
    b.as_word = 0x1122334455667788UL;
    printf("8: %d %d\n", b.as_bytes[0], b.as_bytes[7]);

    /* offsetof 与 sizeof */
    printf("9: %d %d %d\n", (int)offsetof(Rect, br), (int)offsetof(Rect, name), (int)sizeof(Rect));
    printf("10: %d\n", (int)sizeof(Point[4]));

    /* 出参风格的"返回结构体" */
    Point mm;
    mid(&p1, &p2, &mm);
    printf("11: %d %d\n", mm.x, mm.y);

    /* 指向结构体数组的指针算术 */
    Point *pp = pts;
    printf("12: %d %d\n", (pp + 2)->y, pp[1].x);
    return 0;
}
