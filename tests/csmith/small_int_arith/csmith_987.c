// Options:   --no-arrays --no-pointers --no-structs --no-unions --argc --no-bitfields --checksum --comma-operators --compound-assignment --concise --consts --divs --embedded-assigns --pre-incr-operator --pre-decr-operator --post-incr-operator --post-decr-operator --unary-plus-operator --jumps --longlong --int8 --uint8 --no-float --main --math64 --muls --safe-math --no-packed-struct --no-paranoid --no-volatiles --no-volatile-pointers --const-pointers --no-builtins --max-array-dim 1 --max-array-len-per-dim 4 --max-block-depth 1 --max-block-size 10 --max-expr-complexity 4 --max-funcs 2 --max-pointer-depth 2 --max-struct-fields 2 --max-union-fields 2 -o csmith_987.c
#include "csmith.h"


static long __undefined;



static int32_t g_2 = 7L;
static int16_t g_6 = 0x8E6EL;
static uint64_t g_12 = 5UL;
static int64_t g_13 = (-9L);



static int64_t  func_1(void);




static int64_t  func_1(void)
{ 
    int8_t l_14 = 0x38L;
    int32_t l_15 = (-1L);
    for (g_2 = 0; (g_2 <= (-9)); g_2 = safe_sub_func_int64_t_s_s(g_2, 1))
    { 
        int32_t l_5 = (-1L);
        int32_t l_7 = 0x8BC588E1L;
        g_6 |= l_5;
        l_7 = (l_5 && l_5);
        g_13 = ((safe_mod_func_uint32_t_u_u(((safe_mul_func_int8_t_s_s((l_7 = ((g_12 = g_6) | l_7)), 0L)) & 0x880EL), g_6)) , g_2);
        if (g_2)
            continue;
    }
    l_15 = (l_14 ^= g_13);
    for (l_15 = 0; (l_15 > (-30)); l_15 = safe_sub_func_int32_t_s_s(l_15, 1))
    { 
        uint16_t l_18 = 0UL;
        ++l_18;
    }
    return g_13;
}





int main (int argc, char* argv[])
{
    int print_hash_value = 0;
    if (argc == 2 && strcmp(argv[1], "1") == 0) print_hash_value = 1;
    platform_main_begin();
    crc32_gentab();
    func_1();
    transparent_crc(g_2, "g_2", print_hash_value);
    transparent_crc(g_6, "g_6", print_hash_value);
    transparent_crc(g_12, "g_12", print_hash_value);
    transparent_crc(g_13, "g_13", print_hash_value);
    platform_main_end(crc32_context ^ 0xFFFFFFFFUL, print_hash_value);
    return 0;
}
