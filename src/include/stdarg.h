/* zcc 自带 <stdarg.h>
 * 注意:zcc 不支持「定义」可变参数函数(如 vprintf 的实现),
 * 此头文件只为解析 ZOS libc 头文件里的原型提供 va_list 类型。
 */

#ifndef __ZCC_STDARG_H
#define __ZCC_STDARG_H

typedef __builtin_va_list va_list;

#endif
