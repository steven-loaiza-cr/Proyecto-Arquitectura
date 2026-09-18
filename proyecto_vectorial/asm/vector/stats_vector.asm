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
    jle     .cs_empty           ; r13d <= n, salta a caso borde n=0

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

    xor     eax, eax            ; i = 0
    mov     ecx, r13d           ; ecx = n
    and     ecx, ~7             ; ecx = n redondeado hacia abajo, multiplo de 8
    test    ecx, ecx            ; ecx <= n (prueba casos de ecx menor a 0 o 8)
    jle     .cs_tail            ; si ecx <= 0, salta al bucle escalar de cierre, si no sigue con el bucle vectorial

.cs_vec_loop: ; Bucle vectorial
    cmp     eax, ecx            ; compara i con n redondeado hacia abajo
    jge     .cs_reduce          ; si i >= n redondeado hacia abajo, salta a la reducción horizontal
    vmovups ymm7, [r12 + rax*4] ; ymm7 = arr[i:i+7] (carga 8 floats)
    vsubps  ymm6, ymm7, ymm2    ; x - mean
    vfmadd231ps ymm3, ymm6, ymm6   ; sumsq += (x-mean)^2
    vminps  ymm4, ymm4, ymm7      ; min = min(min, x)
    vmaxps  ymm5, ymm5, ymm7      ; max = max(max, x)
    add     eax, 8                ; i = i+8
    jmp     .cs_vec_loop          ; salta de nuevo al incio del bucle vectorial

.cs_reduce: ; Reducción Horizontal de los acumuladores vectoriales a escalares
    ; sumsq: 8 carriles -> escalar (igual que sum_array)
    vextractf128 xmm8, ymm3, 1  ; xmm8 = mitad alta (carriles 4-7)
    vaddps  xmm3, xmm3, xmm8    ; xmm3 = 4 sumas parciales (carriles 0-3 + 4-7)
    vhaddps xmm3, xmm3, xmm3    ; xmm3 = suma horizontal dentro de 128 bits
    vhaddps xmm3, xmm3, xmm3    ; xmm3[0] = suma total de los 8 carriles originales

    ; min: 8 carriles -> escalar
    vextractf128 xmm8, ymm4, 1  ; xmm8 = mitad alta (carriles 4-7)
    vminps  xmm4, xmm4, xmm8    ; xmm4 = mínimo entre los 4 carriles bajos de ymm4 y los 4 carriles altos de xmm8
    vmovhlps xmm8, xmm4, xmm4   ; xmm8 = mueve 2 carriles altos de xmm4 a los 2 carriles bajos de xmm8
    vminps  xmm4, xmm4, xmm8    ; xmm4 = mínimo entre los 2 carriles bajos de xmm4 y los 2 carriles bajos de xmm8
    vmovshdup xmm8, xmm4        ; xmm8 = duplica los 2 carriles bajos de xmm4 a los 2 carriles altos de xmm8
    vminps  xmm4, xmm4, xmm8    ; xmm4 = mínimo entre los 2 carriles bajos de xmm4 y los 2 carriles bajos de xmm8

    ; max: 8 carriles -> escalar
    vextractf128 xmm8, ymm5, 1  ; xmm8 = mitad alta (carriles 4-7)
    vmaxps  xmm5, xmm5, xmm8    ; xmm5 = máximo entre los 4 carriles bajos de ymm5 y los 4 carriles altos de xmm8
    vmovhlps xmm8, xmm5, xmm5   ; xmm8 = mueve 2 carriles altos de xmm5 a los 2 carriles bajos de xmm8
    vmaxps  xmm5, xmm5, xmm8    ; xmm5 = máximo entre los 2 carriles bajos de xmm5 y los 2 carriles bajos de xmm8
    vmovshdup xmm8, xmm5        ; xmm8 = duplica los 2 carriles bajos de xmm5 a los 2 carriles altos de xmm8 y guarda el resultado en xmm8
    vmaxps  xmm5, xmm5, xmm8    ; xmm5 = máximo entre los 2 carriles bajos de xmm5 y los 2 carriles bajos de xmm8

.cs_tail: ; Reducción de cola escalar para el remanente (n % 8)
    cmp     eax, r13d          
    jge     .cs_store          ; si i >= n, salta a almacenar resultados, si no continua con la reducción de cola
    vmovss  xmm9, [r12 + rax*4]  ; xmm9 = arr[i]
    vsubss  xmm10, xmm9, xmm0      ; x - mean
    vmulss  xmm10, xmm10, xmm10    ; (x-mean)^2
    vaddss  xmm3, xmm3, xmm10      ; sumsq += (x-mean)^2
    vminss  xmm4, xmm4, xmm9       ; min = min(min, x)
    vmaxss  xmm5, xmm5, xmm9       ; max = max(max, x)
    inc     eax                    ; i = i+1
    jmp     .cs_tail               ; salta a la reducción de cola

.cs_store:
    cvtsi2ss xmm1, r13d         ; convierte n a float, almacena en xmm1
    divss   xmm3, xmm1          ; var = sumsq / n
    movss   [rbp], xmm3         ; guardo var
    movss   [r14], xmm4         ; guardo min
    movss   [r15], xmm5         ; guardo max
    jmp     .cs_ret             ; salta a protocolo de cierre

.cs_empty:
    xorps   xmm0, xmm0          ; xmm0 = 0.0
    movss   [rbx], xmm0         ; pongo todos en 0 (caso n = 0)
    movss   [rbp], xmm0         ; guardo var = 0
    movss   [r14], xmm0         ; guardo min = 0
    movss   [r15], xmm0         ; guardo max = 0

.cs_ret:
    vzeroupper                ; evita penalizacion de transicion AVX/SSE
    pop     rbp               ; pop de los registros callee-saved
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret                      ; Fin de la función 

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
    xorps   xmm4, xmm4             ; xmm4 = 0.0
    comiss  xmm1, xmm4             ; compara stddev con 0.0
    je      .na_copy_path          ; si stddev == 0.0, salta a copiar sin dividir

    ; --- camino normal: (x - mean) / stddev ---
    vbroadcastss ymm2, xmm0        ; mean en 8 carriles
    vbroadcastss ymm3, xmm1        ; stddev en 8 carriles

    xor     eax, eax               ; eax = i = 0
    mov     ecx, edx               ; ecx = n
    and     ecx, ~7                ; ecx = n redondeado hacia abajo, multiplo de 8
    test    ecx, ecx 
    jle     .na_tail               ; si ecx <= n (prueba casos de ecx menor a 0 o 8) salta al bucle escalar de cierre

.na_vec_loop: ; bucle vectorial de 8 en 8 
    cmp     eax, ecx               
    jge     .na_tail               ; si i >= n redondeado hacia abajo (ecx = n & ~7) salto al bucle escalar de cierre
    vmovaps ymm5, [rdi + rax*4]    ; ymm5 = in[i:i+7] (carga 8 floats)
    vsubps  ymm5, ymm5, ymm2       ; ymm5 = in[i:i+7] - mean
    vdivps  ymm5, ymm5, ymm3       ; ymm5 = (in[i:i+7] - mean) / stddev
    vmovaps [rsi + rax*4], ymm5    ; out[i:i+7] = (in[i:i+7] - mean) / stddev
    add     eax, 8                 ; i = i + 8
    jmp     .na_vec_loop

.na_tail: ; bucle escalar de cierre para el remanente (n % 8)
    cmp     eax, edx               
    jge     .na_done               ; si i>=n, salto al protocolo de cierre
    vmovss  xmm6, [rdi + rax*4]    ; xmm6 = in[i]
    subss   xmm6, xmm0             ; xmm6 = in[i] - mean
    divss   xmm6, xmm1             ; xmm6 = (in[i] - mean) / stddev
    vmovss  [rsi + rax*4], xmm6    ; out[i] = (in[i] - mean) / stddev
    inc     eax                    ; i++
    jmp     .na_tail

.na_done:
    vzeroupper
    ret

.na_copy_path: ; camino para stddev == 0
    ; --- stddev == 0: copiar sin dividir ---
    xor     eax, eax           ; eax = i = 0
    mov     ecx, edx           ; ecx = n
    and     ecx, ~7            ; ecx = n redondeado hacia abajo, multiplo de 8
    test    ecx, ecx           
    jle     .na_copy_tail      ;  ecx <= n (prueba casos de ecx menor a 0 o 8)

.na_copy_vec_loop: ; bucle vectorial de 8 en 8 para copiar
    cmp     eax, ecx           
    jge     .na_copy_tail      ; si i >= n redondeado hacia abajo (ecx = n & ~7) salta a la copia escalar de cierre 
    vmovaps ymm5, [rdi + rax*4] ; ymm5 = in[i:i+7] (carga 8 floats)
    vmovaps [rsi + rax*4], ymm5 ; out[i:i+7] = in[i:i+7] (guarda 8 floats)
    add     eax, 8              ; i = i + 8
    jmp     .na_copy_vec_loop

.na_copy_tail: ; bucle escalar de cierre para el remanente (n % 8)
    cmp     eax, edx           ; i >= n?
    jge     .na_done           ; salto protocolo de cierre
    vmovss  xmm6, [rdi + rax*4] ; xmm6 = in[i]
    vmovss  [rsi + rax*4], xmm6 ; out[i] = in[i]
    inc     eax                 ; i++
    jmp     .na_copy_tail