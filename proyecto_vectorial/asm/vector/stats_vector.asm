; =============================================================
; stats_vector.asm
; Version VECTORIZADA (AVX2, 8 floats por iteracion) de los
; kernels de computo. Misma ABI que la version escalar.
; Estudiantes: Steven Loaiza y Felipe Sánchez
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
    xor     eax, eax               ; eax = i = 0. Xor consigo mismo para inicializar a 0
    vxorps  ymm0, ymm0, ymm0       ; ymm0 = acumulador vectorial (8 carriles) = 0. Nuevamente, xor consigo mismo para inicializar en 0
                                   ;                                               se usa xorps porque es mas rapido que vmovaps para inicializar a 0
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
;      guardar arr/n/mean*/var*/min*/max* en registros caller-saved
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
;----------------------------------------------------------------
; Se guardan registros callee-saved que se van a usar en la funcion dado que se llama sum_array (la llamada destruye registros caller_saved)
; Esto se hace para que el driver no lea los registros equivocados y que no se pierda información.

    push    rbp
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
	
; En esta sección, se guardan los argumentos de la función en los registros callee-saved para poder
; llamar a sum_array sin perder los valores de los argumentos. Además de copiar el contenido
; de los registros para evitar que se pierdan datos en caso de que otras funciones llamen a sum_array o compute_stats.
; Se asignan los registros de la siguiente manera:
; r12 <- arr
; r13 <- n
; rbx <- mean* (puntero a mean)
; rbp <- var* (puntero a var)
; r14 <- min* (puntero a min)
; r15 <- max* (puntero a max)
;-----------------------------------------------------------------
    mov     r12, rdi            ; arr
    mov     r13d, esi           ; n
    mov     rbx, rdx            ; mean*
    mov     rbp, rcx            ; var*
    mov     r14, r8             ; min*
    mov     r15, r9             ; max*

;------- Verificación del caso borde (n = 0)----------------------
    test    r13d, r13d                     ; La instrucción test verifica si n es igual a 0 por medio de una AND y levanta la bandera de salto interna. 
    jle     .cs_vaciar_registros           ; jle verifica esta bandera. Si n <= 0, salta a la sección de vaciado de registros para evitar una división por cero.
                                           ; Luego de vaciar los registros, se salta a la sección de cierre de la función para poner los registros de salida en 0.0 y ejecutar 
                                           ; protocolo de cierre de la función.
                                           ; Si n>0, se continúa con la ejecución normal de la función.
										   
; ------- Cálculo de mean = sum_array(arr, n) / n -----------------
    mov     rdi, r12            ; Se copia el contenido de los registros callee-saved 
    mov     esi, r13d           ; a sus respectivos registros
    sub     rsp, 8              ; En la entrada rsp es exactamente igual a 8 mod 16, y cada push
    call    sum_array           ; resta 8. Con los 6 pushes rsp no está alineado a 16 bytes, sino desplazado
    add     rsp, 8              ; por 8 bytes, por lo que se resta 8 a rsp antes de la llamada de sum array 
	                            ; para que rsp esté alineado. Luego de esta llamada se le suma 8 para dejar rsp
								; como estaba antes de la llamada de sum_array.

    cvtsi2ss xmm1, r13d         ; Con la instrucción cvtsi2ss convierto el contenido de r13d (n) a un valor 
	                            ; escalar de punto flotante con presición simple. Por lo tanto: xmm1 = n (flotante)
    divss   xmm0, xmm1          ; Calculo la media después de la llamada de sum array xmm0 = xmm0/n = mean
    movss   [rbx], xmm0         ; Guarda mean en el puntero a rbx*

    vbroadcastss ymm2, xmm0          ; Con la instrucción vbroadcastss replico el contenido de xmm0 (mean) a un registro YMM de 8 carriles
    vbroadcastss ymm4, dword [r12]   ; Escribe el contenido de la dirección de memoria de 12 (arr). En este caso semilla min = arr[0]
    vbroadcastss ymm5, dword [r12]   ; semilla max = arr[0]
    vxorps  ymm3, ymm3, ymm3         ; Xor en ymm3 para utilizarlo como acumulador más adelante (sumsq = 0).
	
;----- Inicialización antes de los bucles (vectorial o cola escalar) --------------------
    xor     eax, eax                        ; Inicializo el contador en 0 utilizando xor con sí mismo (eax = i = 0)
    mov     ecx, r13d                       ; Cargo el valor de n a ecx (ecx = 0)
    and     ecx, ~7                         ; Redondeo el valor de ecx hacia abajo y que sea múltipo de 8 (ecx = n&~7)
    test    ecx, ecx                        ; Utilizando la instrucción test, verifico si ecx es igual a 0 utilizando una AND interna (similar al pasado).
    jle     .cs_reduccion_cola_escalar      ; jle verifica la bandera de salto interna y salta a la reducción de cola escalar si ecx <= n. Esto prueba los 
	                                        ; casos en que ecx es menor a 0 o 8. Si ecx >  n entonces entra al bucle vectorial y continua el flujo normal.

; ---- Bucle vectorial ------------------------------------------------------------------
.cs_bucle_vectorial: 
    cmp     eax, ecx                          ; Se compara eax (i) con ecx (n&~7). Si eax >= ecx entonces salta a la reducción horizontal de los registros
    jge     .cs_reduccion_horizontal          ; vectoriales. Si no, entonces continua con el calculo de la media, minimo y máximo vectorial. 
    vmovups ymm7, [r12 + rax*4]               ; Con vmovups se cargan 8 flotantes (unaligned) del contenido de memoria de r12 (arr). Este será nuestro x. (ymm7 = x)
    vsubps  ymm6, ymm7, ymm2                  ; La instrucción vsubps realiza la operación x - mean y almacena en el registro ymm6 (ymm6 = ymm7 - ymm2)
    vfmadd231ps ymm3, ymm6, ymm6              ; La instrucción vfmadd231ps realiza una operación combinada de multiplicación y suma en un solo paso.
	                                          ; Por lo tanto, en ymm3 (sumsq) se guarda el resultado de esta sumatoria y multiplicación (sumsq += (x-mean)^2).
    vminps  ymm4, ymm4, ymm7                  ; Las instrucciones vminps y vmaxps comparan valores de punto flotante de presición simple empaquetados de dos fuentes
    vmaxps  ymm5, ymm5, ymm7                  ; y devuelven el mínimo y el máximo de cada par respectivamente, por lo tanto estas líneas devolverían el mínimo y máximo
	                                          ; entre ymm4/ymm5(min y max) y ymm7(x). (min = min(min,x),max = max(max,x))
    add     eax, 8                            ; i = i+8
    jmp     .cs_bucle_vectorial               ; Salta de nuevo al incio del bucle vectorial
	
;---- Reduccion horizontal ---------------------------------------------------------------
.cs_reduccion_horizontal:
    ; Se convierte el acumulador sumsq de vectorial de 8 carriles a
    ; un escalar implementando la reducción horizontal descrita en la
    ; función sum_array. También se hace lo mismo con los acumuladores de min y max
    ; para obtener el mínimo y máximo de los 8 carriles de cada uno.
    ; La instrucción vextractf128 extrae la mitad alta de un registro YMM y la alamacena en un registro XMM. 
    ; Se hace uso de esta instrucción en recurridas ocasiones para reducir los 8 carriles de un registro YMM a 4 carriles en un registro XMM.
    ; La instrucción vhaddps realiza una suma horizontal de los valores de punto flotante empaquetados de presición simple en un registro XMM,
    ; Por lo tanto, esta es la encargada de reducir los 4 carriles de un registro XMM a 2 carriles y luego a 1 carril.
    ; vminps y vmaxps devuelven el mínimo y máxmino de cada par respectivamente, por lo tanto estas líneas devolverían el mínimo y máximo
    ; entre los 4 carriles bajos de ymm4/ymm5(min y max) y los 4 carriles altos de xmm8.
    ; Por último, se hace uso de la instrucciones vmovhlps y vmovshdup para mover los carriles 
    ; altos o bajos de un registro XMM a los carriles bajos o altos de otro registro XMM. Esto se hace para poder
    ; comparar los 2 carriles bajos de un registro XMM con los 2 carriles altos de otro registro XMM.
    
    ; sumsq: 8 carriles -> escalar
    vextractf128 xmm8, ymm3, 1  ; Se extrae la mitad alta del acumulador ymm3 (sumsq) y se almacena en el registro xmm8 (xmm8 = mitad alta de ymm3 (carriles 4-7))
    vaddps  xmm3, xmm3, xmm8    ; xmm3 = 4 sumas parciales (carriles 0-3 + 4-7)
    vhaddps xmm3, xmm3, xmm3    ; xmm3 = suma horizontal dentro de 128 bits
    vhaddps xmm3, xmm3, xmm3    ; xmm3[0] = suma total de los 8 carriles originales

    ; min: 8 carriles -> escalar
    vextractf128 xmm8, ymm4, 1  ; xmm8 = mitad alta (carriles 4-7)
    vminps  xmm4, xmm4, xmm8    ; xmm4 = mínimo entre xmm4 (carriles 0-3) y xmm8 (carriles 4-7)
    vmovhlps xmm8, xmm4, xmm4   ; xmm8 = mueve 2 carriles altos de xmm4 a los 2 carriles bajos de xmm8
    vminps  xmm4, xmm4, xmm8    ; xmm4 = mínimo entre xmm4 (carriles 0-1) y xmm8 (carriles 2-3)
    vmovshdup xmm8, xmm4        ; xmm8 = duplica los 2 carriles bajos de xmm4 a los 2 carriles altos de xmm8
    vminps  xmm4, xmm4, xmm8    ; xmm4 = mínimo entre xmm4 (carriles 0-1) y xmm8 (carriles 2-3)

    ; max: 8 carriles -> escalar
    vextractf128 xmm8, ymm5, 1  ; xmm8 = mitad alta (carriles 4-7)
    vmaxps  xmm5, xmm5, xmm8    ; xmm5 = máximo de ymm5 (carriles 0-3) y xmm8 (carriles 4-7)
    vmovhlps xmm8, xmm5, xmm5   ; xmm8 = mueve 2 carriles altos de xmm5 a los 2 carriles bajos de xmm8
    vmaxps  xmm5, xmm5, xmm8    ; xmm5 = máximo entre xmm5 (carriles 0-1) y xmm8 (carriles 2-3)
    vmovshdup xmm8, xmm5        ; xmm8 = duplica los 2 carriles bajos xmm5 a los 2 carriles altos de xmm8
    vmaxps  xmm5, xmm5, xmm8    ; xmm5 = máximo entre xmm5 (carriles 0-1) y xmm8 (carriles 2-3)

; --- Reducción de cola escalar ------------------------------------------------------
.cs_reduccion_cola_escalar:
;  En esta sección se hace la reducción de cola escalar para los elementos sobrantes (n % 8), uno a la vez.
;  Además de esto, se hace uso de las instrucciones vsubss, vmulss, vaddss, vminss y vmaxss para realizar 
;  las operaciones de resta, multiplicación, suma, mínimo y máximo respectivamente.
;  PD(Nota de Felipe): No explico mucho porque ya es un poco redundante y similar al proceso anterior, solo que con escalares. 
    cmp     eax, r13d
    jge     .cs_almacenar_resultados          ; si i >= n, salta a almacenar resultados, si no continua con la reducción de cola
    vmovss  xmm9, [r12 + rax*4]               ; xmm9 = arr[i]
    vsubss  xmm10, xmm9, xmm0                 ; xmm10 = x - mean
    vmulss  xmm10, xmm10, xmm10               ; xmm10 = (x-mean)^2
    vaddss  xmm3, xmm3, xmm10                 ; xmm3 = sumsq += (x-mean)^2
    vminss  xmm4, xmm4, xmm9                  ; xmm4 = min(min, x)
    vmaxss  xmm5, xmm5, xmm9                  ; xmm5 = max(max, x)
    inc     eax                               ; i = i+1
    jmp     .cs_reduccion_cola_escalar        ; salta al inicio de reducción de cola

; --- Almacenamiento de resultados ------------------------------------------------------
.cs_almacenar_resultados:
; Aquí se almacenan los resultados de interés (mean, var, min, max) en sus respectivos punteros de salida.
    divss   xmm3, xmm1          ; var = sumsq / n
    movss   [rbp], xmm3         ; guardo var
    movss   [r14], xmm4         ; guardo min
    movss   [r15], xmm5         ; guardo max
    jmp     .cs_cierre          ; salta a protocolo de cierre

; -- Caso borde (n = 0) ------------------------------------------------------
.cs_vaciar_registros:
; Aquí se vacían los registros de salida (mean, var, min, max) a 0.0 en caso de que n = 0
; para evitar división por cero y errores de cálculo.
    xorps   xmm0, xmm0          ; xmm0 = 0.0
    movss   [rbx], xmm0         ; pongo todos en 0 (caso n = 0)
    movss   [rbp], xmm0         ; guardo var = 0
    movss   [r14], xmm0         ; guardo min = 0
    movss   [r15], xmm0         ; guardo max = 0

; -- Protocolo de cierre ------------------------------------------------------
.cs_cierre:
; Aquí se hace el protocolo de cierre de la función, donde se restauran los registros callee-saved
; que se habían guardado al inicio de la función para evitar perder información,
; ocasionar segfaults y evitar penalizaciones de transición AVX/SSE.
    vzeroupper                ; evita penalizacion de transicion AVX/SSE
    pop     r15               ; pop de los registros callee-saved en orden inverso a como
    pop     r14               ; se introdujeron a la pila para evitar segfaults. 
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret                       ; Fin de la función

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
    je      .na_camino_copia          ; si stddev == 0.0, salta a copiar sin dividir

    ; --- camino normal: (x - mean) / stddev ---
    vbroadcastss ymm2, xmm0        ; mean en 8 carriles
    vbroadcastss ymm3, xmm1        ; stddev en 8 carriles

    xor     eax, eax               ; eax = i = 0
    mov     ecx, edx               ; ecx = n
    and     ecx, ~7                ; ecx = n redondeado hacia abajo, multiplo de 8
    test    ecx, ecx
    jle     .na_bucle_escalar_cierre               ; si ecx <= n (prueba casos de ecx menor a 0 o 8) salta al bucle escalar de cierre

.na_bucle_vectorial: ; bucle vectorial de 8 en 8
    cmp     eax, ecx
    jge     .na_bucle_escalar_cierre               ; si i >= n redondeado hacia abajo (ecx = n & ~7) salto al bucle escalar de cierre
    vmovaps ymm5, [rdi + rax*4]    ; ymm5 = in[i:i+7] (carga 8 floats)
    vsubps  ymm5, ymm5, ymm2       ; ymm5 = in[i:i+7] - mean
    vdivps  ymm5, ymm5, ymm3       ; ymm5 = (in[i:i+7] - mean) / stddev
    vmovaps [rsi + rax*4], ymm5    ; out[i:i+7] = (in[i:i+7] - mean) / stddev
    add     eax, 8                 ; i = i + 8
    jmp     .na_bucle_vectorial

.na_bucle_escalar_cierre: ; bucle escalar de cierre para el remanente (n % 8)
    cmp     eax, edx
    jge     .na_cierre               ; si i>=n, salto al protocolo de cierre
    vmovss  xmm6, [rdi + rax*4]    ; xmm6 = in[i]
    subss   xmm6, xmm0             ; xmm6 = in[i] - mean
    divss   xmm6, xmm1             ; xmm6 = (in[i] - mean) / stddev
    vmovss  [rsi + rax*4], xmm6    ; out[i] = (in[i] - mean) / stddev
    inc     eax                    ; i++
    jmp     .na_bucle_escalar_cierre

.na_cierre:
    vzeroupper
    ret

.na_camino_copia: ; camino para stddev == 0
    ; --- stddev == 0: copiar sin dividir ---
    xor     eax, eax           ; eax = i = 0
    mov     ecx, edx           ; ecx = n
    and     ecx, ~7            ; ecx = n redondeado hacia abajo, multiplo de 8
    test    ecx, ecx
    jle     .na_copiar_cola      ;  ecx <= n (prueba casos de ecx menor a 0 o 8)

.na_copiar_vectorial: ; bucle vectorial de 8 en 8 para copiar
    cmp     eax, ecx
    jge     .na_copiar_cola      ; si i >= n redondeado hacia abajo (ecx = n & ~7) salta a la copia escalar de cierre 
    vmovaps ymm5, [rdi + rax*4] ; ymm5 = in[i:i+7] (carga 8 floats)
    vmovaps [rsi + rax*4], ymm5 ; out[i:i+7] = in[i:i+7] (guarda 8 floats)
    add     eax, 8              ; i = i + 8
    jmp     .na_copiar_vectorial

.na_copiar_cola: ; bucle escalar de cierre para el remanente (n % 8)
    cmp     eax, edx           ; i >= n?
    jge     .na_cierre           ; salto protocolo de cierre
    vmovss  xmm6, [rdi + rax*4] ; xmm6 = in[i]
    vmovss  [rsi + rax*4], xmm6 ; out[i] = in[i]
    inc     eax                 ; i++
    jmp     .na_copiar_cola
