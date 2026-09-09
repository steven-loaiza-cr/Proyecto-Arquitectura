; =============================================================
; stats_vector.asm
; Version VECTORIZADA (AVX2, 8 floats por iteracion) de los
; kernels de computo. Misma ABI que la version escalar.
;
; Antes de compilar/ejecutar en su maquina, confirme soporte AVX2:
;   lscpu | grep avx2
;   cat /proc/cpuinfo | grep avx2
; =============================================================

    global sum_array
    global compute_stats
    global normalize_array

    section .text

; ---------------------------------------------------------------
; float sum_array(const float *arr, int n)
;   rdi = arr, esi = n -> retorna la suma en xmm0
;
; IMPLEMENTADA COMO EJEMPLO. Fijense especialmente en:
;   (1) como se calcula cuantos elementos entran en bucles de 8
;       ("and ecx, ~7" redondea n hacia abajo al multiplo de 8),
;   (2) la REDUCCION HORIZONTAL para pasar de 8 sumas parciales
;       (un YMM) a un unico escalar,
;   (3) el BUCLE ESCALAR DE CIERRE para el remanente (n % 8 != 0).
; Reutilicen este mismo patron en compute_stats y normalize_array.
; ---------------------------------------------------------------
sum_array:
    xor     eax, eax               ; eax = i = 0
    vxorps  ymm0, ymm0, ymm0       ; ymm0 = acumulador vectorial (8 carriles) = 0

    mov     ecx, esi
    and     ecx, ~7                ; ecx = n redondeado hacia abajo, multiplo de 8
    test    ecx, ecx               ; ecx <= n (prueba casos de ecx menor a 0 o 8)   
    jle     .sum_reduce

.sum_vec_loop:
    cmp     eax, ecx
    jge     .sum_reduce
    vmovups ymm1, [rdi + rax*4]    ; carga 8 floats (unaligned: siempre valido)
    vaddps  ymm0, ymm0, ymm1       ; acumula por carril
    add     eax, 8
    jmp     .sum_vec_loop

.sum_reduce:
    ; --- reduccion horizontal: 8 carriles de ymm0 -> un escalar ---
    vextractf128 xmm2, ymm0, 1     ; xmm2 = mitad alta (carriles 4-7)
    vaddps  xmm0, xmm0, xmm2       ; xmm0 = 4 sumas parciales (carriles 0-3 + 4-7)
    vhaddps xmm0, xmm0, xmm0       ; suma horizontal dentro de 128 bits
    vhaddps xmm0, xmm0, xmm0       ; xmm0[0] = suma total de los 8 carriles originales

.sum_scalar_tail:
    ; --- elementos sobrantes (n % 8), uno a la vez ---
    cmp     eax, esi
    jge     .sum_done
    vmovss  xmm1, [rdi + rax*4]
    vaddss  xmm0, xmm0, xmm1
    inc     eax
    jmp     .sum_scalar_tail

.sum_done:
    vzeroupper                     ; evita penalizacion de transicion AVX/SSE
    ret

; ---------------------------------------------------------------
; void compute_stats(const float *arr, int n,
;                     float *mean, float *var, float *min, float *max)
;   rdi = arr, esi = n, rdx = mean*, rcx = var*, r8 = min*, r9 = max*
;
; TODO (estudiante):
;   1) mean = suma(arr) / n (puede llamar a sum_array; recuerde
;      guardar arr/n/mean*/var*/min*/max* en registros callee-saved
;      antes, porque la llamada destruye registros caller-saved).
;   2) Segunda pasada VECTORIZADA para acumular sum((x-mean)^2):
;        - "broadcast" de mean a los 8 carriles con vbroadcastss.
;        - vsubps + vmulps (o vfmadd231ps si quieren ir mas alla)
;          para acumular los cuadrados de las diferencias,
;        - misma reduccion horizontal que en sum_array,
;        - bucle escalar para el remanente (subss/mulss/addss).
;   3) Min/max VECTORIZADOS con vminps/vmaxps a lo largo del bucle
;      principal, reduccion final con vextractf128 + vminps/vmaxps
;      (y shuffles si quieren reducir los 4 restantes a 1), mas
;      bucle escalar de cierre con minss/maxss o comiss.
;   4) Guarde los resultados en [rdx]=mean, [rcx]=var, [r8]=min,
;      [r9]=max. Si n == 0, escriba 0.0 en los cuatro.
;   5) 'vzeroupper' antes de cualquier 'ret' en una funcion que usa
;      registros YMM.
; ---------------------------------------------------------------
compute_stats:
    push    rbp
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15

    ; rsp%16 == 8 aqui (6 pushes = 48 bytes, no cambia la paridad de entrada)
    ; F: Hay que alinear la pila a un múltiplo de 16 bytes antes de llamar a sum_array, porque sum_array hace
    ; push de rbx y luego hace vmovups (que requiere rsp%16==0). Esto para evitar errores de segmentación.


    ; --- placeholder temporal: elimine estas lineas al implementar ---
    ;vxorps  xmm0, xmm0, xmm0
    ;vmovss  [rdx], xmm0
    ;vmovss  [rcx], xmm0
    ;vmovss  [r8], xmm0
    ;vmovss  [r9], xmm0
    ; --- fin placeholder ---

    mov     r12, rdi            ; arr
    mov     r13d, esi           ; n
    mov     rbx, rdx            ; mean*
    mov     rbp, rcx            ; var*
    mov     r14, r8             ; min*
    mov     r15, r9             ; max*

    test    r13d, r13d
    jle     .cs_empty

    ; --- mean = sum_array(arr, n) / n ---
    mov     rdi, r12
    mov     esi, r13d
    sub     rsp, 8              ; alinea a 16 antes del call
    call    sum_array
    add     rsp, 8              ; deshace el ajuste

    cvtsi2ss xmm1, r13d
    divss   xmm0, xmm1          ; xmm0 = mean
    movss   [rbx], xmm0         ; guarda mean

    vbroadcastss ymm2, xmm0     ; mean en 8 carriles
    vbroadcastss ymm4, dword [r12]   ; semilla min = arr[0]
    vbroadcastss ymm5, dword [r12]   ; semilla max = arr[0]
    vxorps  ymm3, ymm3, ymm3    ; acumulador sumsq = 0

    xor     eax, eax
    mov     ecx, r13d
    and     ecx, ~7
    test    ecx, ecx
    jle     .cs_tail

.cs_vec_loop:
    cmp     eax, ecx
    jge     .cs_reduce
    vmovups ymm7, [r12 + rax*4]
    vsubps  ymm6, ymm7, ymm2
    vfmadd231ps ymm3, ymm6, ymm6   ; sumsq += (x-mean)^2
    vminps  ymm4, ymm4, ymm7
    vmaxps  ymm5, ymm5, ymm7
    add     eax, 8
    jmp     .cs_vec_loop

.cs_reduce:
    ; sumsq: 8 carriles -> escalar (igual que sum_array)
    vextractf128 xmm8, ymm3, 1
    vaddps  xmm3, xmm3, xmm8
    vhaddps xmm3, xmm3, xmm3
    vhaddps xmm3, xmm3, xmm3

    ; min: 8 carriles -> escalar
    vextractf128 xmm8, ymm4, 1
    vminps  xmm4, xmm4, xmm8
    vmovhlps xmm8, xmm4, xmm4
    vminps  xmm4, xmm4, xmm8
    vmovshdup xmm8, xmm4
    vminps  xmm4, xmm4, xmm8

    ; max: 8 carriles -> escalar
    vextractf128 xmm8, ymm5, 1
    vmaxps  xmm5, xmm5, xmm8
    vmovhlps xmm8, xmm5, xmm5
    vmaxps  xmm5, xmm5, xmm8
    vmovshdup xmm8, xmm5
    vmaxps  xmm5, xmm5, xmm8

.cs_tail:
    cmp     eax, r13d
    jge     .cs_store
    vmovss  xmm9, [r12 + rax*4]
    vsubss  xmm10, xmm9, xmm0      ; x - mean
    vmulss  xmm10, xmm10, xmm10
    vaddss  xmm3, xmm3, xmm10
    vminss  xmm4, xmm4, xmm9
    vmaxss  xmm5, xmm5, xmm9
    inc     eax
    jmp     .cs_tail

.cs_store:
    cvtsi2ss xmm1, r13d
    divss   xmm3, xmm1          ; var = sumsq / n
    movss   [rbp], xmm3
    movss   [r14], xmm4
    movss   [r15], xmm5
    jmp     .cs_ret

.cs_empty:
    xorps   xmm0, xmm0
    movss   [rbx], xmm0
    movss   [rbp], xmm0
    movss   [r14], xmm0
    movss   [r15], xmm0

.cs_ret:
    vzeroupper
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    vzeroupper
    ret

; ---------------------------------------------------------------
; void normalize_array(const float *in, float *out, int n,
;                       float mean, float stddev)
;   rdi = in, rsi = out, edx = n, xmm0 = mean, xmm1 = stddev
;
;   out[i] = (in[i] - mean) / stddev
;   Caso borde: si stddev == 0.0, copie in[i] en out[i] tal cual.
;
; TODO (estudiante):
;   - "Broadcast" mean y stddev a registros YMM con vbroadcastss
;     (guarde antes xmm0/xmm1 en otros registros o en la pila, ya
;     que planea usar xmm0/xmm1 tambien como temporales del bucle).
;   - Bucle vectorial de 8 en 8: vmovups/vmovaps carga, vsubps,
;     vdivps (o vmulps por el reciproco de stddev si quieren
;     optimizar), vmovups/vmovaps guarda.
;   - Bucle escalar de cierre para el remanente (n % 8), igual que
;     en sum_array.
;   - 'vzeroupper' antes del 'ret'.
; ---------------------------------------------------------------
normalize_array:
    ; TODO: implementar
    ret
