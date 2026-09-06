; =============================================================
; stats_scalar.asm
; Version ESCALAR (referencia) de los kernels de computo.
;
; Convencion de llamada: System V AMD64 ABI
;   enteros/punteros: rdi, rsi, rdx, rcx, r8, r9
;   flotantes:        xmm0, xmm1, xmm2, ...
;   retorno float:    xmm0
;   callee-saved:     rbx, rbp, r12-r15 (si los usa, debe preservarlos)
; =============================================================

    global sum_array
    global compute_stats
    global normalize_array

    section .text

; ---------------------------------------------------------------
; float sum_array(const float *arr, int n)
;   rdi = arr, esi = n
;   retorna la suma en xmm0
;
; IMPLEMENTADA COMO EJEMPLO: estudien este patron (recorrido,
; acumulador, condicion de salida) antes de escribir compute_stats
; y normalize_array.
; ---------------------------------------------------------------
sum_array:
    xor     eax, eax           ; eax = i = 0
    xorps   xmm0, xmm0         ; xmm0 = acumulador = 0.0

.sum_loop:
    cmp     eax, esi
    jge     .sum_done
    movss   xmm1, [rdi + rax*4]
    addss   xmm0, xmm1
    inc     eax
    jmp     .sum_loop

.sum_done:
    ret

; ---------------------------------------------------------------
; void compute_stats(const float *arr, int n,
;                     float *mean, float *var, float *min, float *max)
;   rdi = arr, esi = n, rdx = mean*, rcx = var*, r8 = min*, r9 = max*
;
;   var = varianza POBLACIONAL = sum((x - mean)^2) / n
;   Caso borde: si n == 0, escriba 0.0 en mean/var/min/max.
;
; TODO (estudiante):
;   1) Calcular mean = suma(arr) / n. Puede reutilizar sum_array con
;      'call sum_array', pero recuerde que eso destruye los
;      registros caller-saved (rax, rcx, rdx, rsi, rdi, r8-r11):
;      guarde arr/n/mean*/var*/min*/max* en registros callee-saved
;      (rbx, r12-r15) ANTES de llamar.
;   2) Recorrer el arreglo una segunda vez para acumular
;      sum((x - mean)^2) y obtener var = esa suma / n.
;   3) Recorrer el arreglo (puede combinarlo con el paso 1) llevando
;      min y max con comiss + saltos condicionales (ja/jb, etc.)
;      o con las instrucciones minss/maxss.
;   4) Guardar los resultados en las direcciones recibidas por
;      puntero: [rdx]=mean, [rcx]=var, [r8]=min, [r9]=max.
;   5) No olvide restaurar los registros callee-saved en el epilogo.
; ---------------------------------------------------------------
compute_stats:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15

	;Guardar los 4 punteros de salid
	mov r12, rdx ; mean_ptr
	mov r13, rcx ; var_ptr
	mov r14, r8  ; min_ptr
	mov r14, r9  ; max_ptr

	test esi, esi
	jle .cs_empty

	xorps xmm0, xmm0  ;sum = 0
	movss xmm1, [rdi] ;min = arr[0]
	movss xmm2, [rdi] ;max = arr[0]
	xor eax, eax

.cs_pass1:
	cmp eax, esi
	jge .cs_pass1_done
	movss xmm3, [rdi + rax*4]
	addss xmm0, xmm3
	comiss xmm3, xmm1
	jae .cs_chkmax
	movss xmm1, xmm3

.cs_chkmax:
	comiss xmm3, xmm2
	jbe .cs_next1
	movss xmm2, xmm3

.cs_next1:
	inc eax
	jmp .cs_pass1

.cs_pass1_done:
	cvtsi2ss xmm4, esi
	divss xmm0, xmm4


	;Pasado 2: sum((x-mean)^2)
	xorps xmm5, xmm5
	xor eax, eax

.cs_pass2:
	cmp eax, esi
	jge .cs_pass2_done
	movss xmm3, [rdi + rax*4]
	subss xmm3, xmm0 ;x - mean
	mulss xmm3, xmm3 ;(x- mean)^2
	addss xmm5, xmm3
	inc eax
	jmp .cs_pass2

.cs_pass2_done:
	divss xmm5, xmm4  ; var = sum ((x - mean)^2) / n
	movss [r12], xmm0 ;*mean
	movss [r13], xmm5 ;*var
	movss [r14], xmm1 ;*min
	movss [r15], xmm2 ;*max
	jmp .cs_ret
    ; TODO: implementar el algoritmo descrito arriba.

.cs_empty:
	xorps xmm0, xmm0
	movss [r12], xmm0
	movss [r13], xmm0
	movss [r14], xmm0
	movss [r15], xmm0


    ; --- placeholder temporal: elimine estas lineas al implementar ---
   ; xorps   xmm0, xmm0
   ; movss   [rdx], xmm0
   ; movss   [rcx], xmm0
   ; movss   [r8], xmm0
   ; movss   [r9], xmm0
    ; --- fin placeholder ---

.cs_ret:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ---------------------------------------------------------------
; void normalize_array(const float *in, float *out, int n,
;                       float mean, float stddev)
;   rdi = in, rsi = out, edx = n, xmm0 = mean, xmm1 = stddev
;
;   out[i] = (in[i] - mean) / stddev
;   Caso borde: si stddev == 0.0, copie in[i] en out[i] tal cual
;   (evite division por cero).
;
; TODO (estudiante): implementar el bucle escalar.
; Sugerencia: guarde mean (xmm0) y stddev (xmm1) en registros que no
; se sobrescriban dentro del bucle (por ejemplo xmm8/xmm9, que en
; System V no se usan para pasar argumentos), o vuelva a cargarlos
; en cada iteracion desde una copia guardada en la pila.
; ---------------------------------------------------------------
normalize_array:
    ; TODO: implementar

	xorps xmm2, xmm2	; xmm2 = 0.0
	comiss xmm1, xmm2
	je .na_copy			; stddev == 0
	xor eax, eax

.na_loop:
	cmp eax, edx
	jge .na_done
	movss xmm3, [rdi + rax*4]
	subss xmm3, xmm0
	divss xmm3, xmm1
	movss [rsi + rax*4], xmm3
	inc eax
	jmp .na_loop

.na_copy:
	xor eax, eax

.na_copy_loop:
	cmp eax, edx
	jge .na_done
	movss xmm3, [rdi + rax*4]
	movss [rsi + rax*4], xmm3
	inc eax
	jmp .na_copy_loop

.na_done:
    ret
