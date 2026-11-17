#include <stdio.h>
#include "soc.h"

int main(void) {
    printf("Hello from meimei (RV64IMFDC_Zicsr, out-of-order)!\n");
    printf("cycle %lu, instret %lu\n", (unsigned long)rdcycle(), (unsigned long)rdinstret());
    return 0;
}
