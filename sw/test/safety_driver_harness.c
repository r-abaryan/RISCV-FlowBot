/* Host harness: compiles the REAL safety_driver.h and filters stdin vectors.
 * Input lines: last_v last_w raw_v raw_w dist_cm ; output: safe_v safe_w */
#include <stdio.h>
#include "safety_driver.h"
int main(void){
    int lv,lw,rv,rw,d;
    while(scanf("%d %d %d %d %d",&lv,&lw,&rv,&rw,&d)==5){
        safety_state_t s={(int8_t)lv,(int8_t)lw,0}; int8_t sv,sw;
        safety_filter_command(&s,(int8_t)rv,(int8_t)rw,(int16_t)d,&sv,&sw);
        printf("%d %d\n",sv,sw);
    }
    return 0;
}
