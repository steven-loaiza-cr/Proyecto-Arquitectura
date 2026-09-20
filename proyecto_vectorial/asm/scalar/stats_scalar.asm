; =============================================================
; stats_scalar.asm
; Version ESCALAR (referencia) de los kernels de computo.
; Estudiantes: Steven Loaiza y Felipe Sanchez
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
    xor     eax, eax           ; eax = i = 0, El metodo de xor de un registro consigo mismo, es la forma mas directa para ponerele un valor de 0
    xorps   xmm0, xmm0         ; xmm0 = acumulador = 0.0, el registro xmm0 va hacer el acumulador para la suma
    						   ; Asimismo la instruccion xorps limpia los 128 bits del registro XMM

.sum_loop:
    cmp     eax, esi              ;Compara el indice i (eax) contra n (que esta en el registro esi)
    jge     .sum_done			  ;Verifica el salto, si i >= n ya se recorrio todo el arreglo y se sale del bucle

	;En el registro xxm1 se guarda la direccion del arreglo en cuestion para ir sumandolo
    movss   xmm1, [rdi + rax*4]	  ;El registro rdi funciona como un puntero que almacena el inicio del arreglo
    							  ;EL registro rax es un registro de 64 bits y eax es su mitad baja (0-31 bits), ya se sabe que eax es el contador i
    							  ;La direccion se obtiene a partir de rdi (puntero al inicio del arreglo) + rax*4, es decir la base del arreglo
    							  ;mas i posiciones, cada posicion es de 4 bytes, por esta razon se debe hacer el rax*4, porque cada float ocupa 4 bytes

	;En este punto se efectua la suma
    addss   xmm0, xmm1		;Se suma el acumulador (registro xmm0) con lo que se esta analizando en un posicion del arreglo (registro xmm1 = arreglo[i])
    inc     eax				;Se suma +1 al contador -> eax=i++
    jmp     .sum_loop		;Se vuelve a repetir el loop de la suma

;Funcion para salirse de la sumatoria
.sum_done:
    ret		;El resultado ya esta en el registro xmm0, se retorna ese valor de float al sistema

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

;En este punto se guardan  los callee-saved que son los registros rbx/r12-r15;
;ya que la ABI System V (es la conveccion que utiliza esta programacion para definir
;la comunicacion entre el codigo en C (driver.c) y el codigo de emsamblador (stats_scalar.asm),
;obliga a que si la funcion los usa, debe devolverlos intactos al driver.c. En pocas palabras para
;que driver.c no lea los registros equivocados y el resultado no sea basura)

;En resumen: se guardan 5 registros por que la funcion los va a usar estos registros mas adelante (r12-r15
;estos con la finalidad de ser punteros de salida) y en mi caso no utilizo rbx pero de igual manera debo devolverlo

    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15

;-----------------------------------------------------------------------------------------------------------------------------
;En esta seccion se guarda y copian los valores de los registros rdx, rcx, r8 y r9 (ya que estos son caller-saved), ya que si
;en algun momento otra funcion llamara a estos registros (por ejemplo: sum_array o normalize_array) su contenido podria variar
;y destruirse. Por esta razon se efectuan copias a los registros callee-saved (r12-r15).

;Importante rdx, rcx, r8 y r9 son el 3, 4, 5 y 6 argumento respectivamente de la funcion segun el ABI
;rdx -> mean
;rcx -> varianza
;r8 -> minimo
;r9 -> maximo

	;Guardar los 4 punteros de salid
	mov r12, rdx ; mean_ptr
	mov r13, rcx ; var_ptr
	mov r14, r8  ; min_ptr
	mov r15, r9  ; max_ptr

	;------------ Verificacion del primer caso borde - ARREGLO VACIO n<=0 ------------------------------------------------------
	;esi es el registro que contiene a n (tamano del arreglo)

	test esi, esi			;La instruccion test ejecuta una AND interna sin guardar el resultado, solamente actualiza las banderas
	jle .cs_arreglo_vacio	;La instruccion jle verifica las banderas, entonces si n <= 0, no ejecuta ninguna operacion y salta a la
							;seccion del arreglo vacio (.cs_arreglo_vacio)


	;----------- Inicializacion antes de efectuar el primer bucle o while ------------------------------------------------------
	xorps xmm0, xmm0  ;sum = 0			;La instruccion xorps pone en cero los 128 bits de xmm0, puesto que el registro xmm0 sera el acumulador
	movss xmm1, [rdi] ;min = arr[0]		;Copia el primer elemento del arreglo que se obtiene con [rdi] (es como arreglo[0]), ya que el registro
										;rdi es la direccion base del arreglo. Entonces copia en el registro xmm1 la primer direccion del arreglo rdi
	movss xmm2, [rdi] ;max = arr[0]     ;Hace lo mismo que la anterior linea, pero en este caso el registro xmm2 va a contener el maximo al final de
										;la ejecucion pero se debe inicializar en el primer arreglo por eso xmm2 = [rdi] (es lo mismo que arreglo[0])
	xor eax, eax						;Pone los bits de eax en cero (0), para que funcione como el indice i=0 -> eax=0


;-------------------- Bucle #1 - Suma + Minimo + Maximo ---------------------------------------------------------------------------------------------
;Nota: yo se que esta funcion ya estaba implementada, pero en este momento se me habia fue y por eso la programe

.cs_bucle_suma_min_max:			;label para llamar el bucle
	cmp eax, esi				;La instruccion cmp resta internamente eax-esi (no guarda el resultado) pero si actualiza las flags.
	jge .cs_fin_suma_min_max	;EL salto jge verifica la flag (i >= n) ya se recorrio el arreglo y se sale del bucle
	movss xmm3, [rdi + rax*4]	;Obtiene y carga el dato de la posicion i (indice) -> [rdi + rax*4] en el registro xmm3
	addss xmm0, xmm3			;Va sumando el dato que contiene el registro xmm3 con lo que hay en el acumulador xmm1 y lo sobreescribe en xmm1 (acumulador)
	comiss xmm3, xmm1			;La instruccion comiss compara el valor actual del arreglo xmm3 contra el minimo que esta en el registro xmm1. Hace
								;internamente xmm3 - xmm1 y actualiza las flags
	jae .cs_verificar_max		;El salto jae, verifica las flags (arreglo[i]-xmm3 >= min_actual-xmm1)- se salta a verificar_max porque el dato en la
								;posicion arreglo[i]-xmm3 puede ser un nuevo maximo
	movss xmm1, xmm3			;Si el salto no se efectua significa que (arreglo[i]-xmm3 < min_actual-xmm1, entonce se debe actualizar el minimo que
								;se encuentra en xmm1 por eso xmm1 = xmm3

; ---------------------------- Verificar el posible nuevo maximo --------------------------------------------------------------------------------------

.cs_verificar_max:				;label
	comiss xmm3, xmm2			;Compara los datos de los registros xmm3 y xmm2 y actualiza las flags
	jbe .cs_siguiente_elemento	;El salto jbe evalua las flags (se efectua si xmm3 <= xmm2). Aqui  detecta si tengo un nuevo maximo o no
	movss xmm2, xmm3			;Si tengo un nuevo maximo (xmm3 > xmm2), actualiza el maximo en el registro xmm2 -> xmm2 = xmm3

;----------------------------- Verificar el proximo elemento del array --------------------------------------------------------------------------------
.cs_siguiente_elemento:			;label
	inc eax						;incrementa el indice -> eax = eax + 1 -> i+
	jmp .cs_bucle_suma_min_max	;Vuelve al label bucle_suma_min_max para volver a realizar el siguiente elemento

;----------------------------- Calculo de la media ---------------------------------------------------------------------------------------------------
;En este punto se sabe que xmm0 (acumulador) tiene la suma total de todos los elementos y que el registro xmm1 tiene el elemento minimo y el registro
;xmm2 tiene el elemento maximo

.cs_fin_suma_min_max:			;label
	cvtsi2ss xmm4, esi			;cvtsi2ss (convert scalar integer to scalar single), lo que hace es que convierte el entero n (tamano de arreglo guardado
								;en el registro esi) a una representacion flotante y lo almacena en el registro xmm4 -> xmm4 = esi(n)

	;Media = Acumulador / total de elementos del arreglo
	divss xmm0, xmm4			;Lo que hace es lo siguiente xmm0 = xmm0 (acumulador - suma total) / xmm4 (tamano del arreglo), al final sobreescribe en xmm0

;----------------------------- Calculo de la varianza -------------------------------------------------------------------------------------------------
;Despues de obtener la media, se continua con el calculo de la varianza

	;Preparacion previa para iniciar el bluque o while #2
	xorps xmm5, xmm5			;Pone en cero (0) los bits del nuevo acumulador xmm5 para la suma de los cuadrados de las diferencias (x-mean)^2
	xor eax, eax				;Reinicia el indice -> i=0

;---------------------------- Bucle #2 - Variana -------------------------------------------------------------------------------------------------------
.cs_bucle_varianza:					;label
	cmp eax, esi					;resta internamente eax - esi, pero no guarda el dato, pero si actualiza las flags
	jge .cs_fin_varianza			;El salto jge verifica las flags (realiza el salto si eax >= esi -> i >= n), osea si ya se completo todo el arreglo
	movss xmm3, [rdi + rax*4]		;Carga arreglo[i] en el registro xmm3  -> xmm3 = arreglo[i] ([rdi+rax*4])
	subss xmm3, xmm0 ;x - mean		;xmm3 = arreglo[i] (xmm3) - media (xmm0) - Operacion intermedia para la suma de los cuadrados
	mulss xmm3, xmm3 ;(x- mean)^2   ;xmm3 = xmm3 x xmm3 -> (arreglo[i] - media)^2
	addss xmm5, xmm3				;Se actualiza el acumulador xmm5 = xmm5 + xmm3 -> xmm5 = xmm5 + (arreglo[i] - media)^2
	inc eax							;Se incrementa el indice -> i=++  -> eax = eax + 1
	jmp .cs_bucle_varianza			;Vuelve a ejecutar el bucle "bucle_varianza'

;--------------------------- FInalizacion del bucle #2 -------------------------------------------------------------------------------------------------
.cs_fin_varianza:
	;Varianza = suma de la operacion (arreglo[i] - media)^2 / tamano del arreglo (n)
	divss xmm5, xmm4  ;Se calcula la varianza sabiendo que xmm5 = (arreglo[i] - media)^2 y que xmm4 (tamano del arreglo), por eso se tiene que xmm5 = xmm5/xmm4
	movss [r12], xmm0 ;*mean -> Se actualiza el puntero r12 por el dato de la media (xmm0)
	movss [r13], xmm5 ;*var -> Se actualiza el puntero r13 por el dato de la varianza (xmm5)
	movss [r14], xmm1 ;*min -> Se actualiza el puntero r14 por el dato del minimo dato del arreglo (xmm1)
	movss [r15], xmm2 ;*max -> Se actualiza el puntero r15 por el dato del maximo dato del arreglo (xmm2)
	jmp .cs_retorno   ;Se salta directamen al final del algoritmo porque ya estan listos los punteros
    ; TODO: implementar el algoritmo descrito arriba.

;----------------------- Caso Borde: ARREGLO VACIO n <= 0 -------------------------------------------------------------------------------------------------
.cs_arreglo_vacio:		;label
	xorps xmm0, xmm0	;Coloca el acumulador en cero (0) bits -> xmm0 = 0
	;Coloca los puntero r12, r13, r14 y r15 con el dato igual a cero (caso borde)
	movss [r12], xmm0
	movss [r13], xmm0
	movss [r14], xmm0
	movss [r15], xmm0

; ------------------- Retorno ---------------------------------------------------------------------------------------------------------------------------
.cs_retorno:		;label
	;Se restauran los registros callee-saved en orden inverso al de los push del principio (r15, r14, r13, r12 y rbx), como exigen el ABI al
	;desenrollar la pila en cuestion
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret				;finaliza el algortimo sacando de la pula la direccion de retorno

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

;Objetivo: tomar un arreglo de datos (arreglo_in) y produce un segundo arreglo (arreglo_out)
;La finalidad es que cada valor quede normalizado estadisticamente, es decir que el arreglo_out tenga una media de 0 y una desviacion estadar de 1
;Formula -> arreglo_out[i] = (arreglo_in[i] - media) / desviacion estandar

;Nota: la media (se calculo previamente en el compute_stats) y la desviacion estandar (la genero el driver.c)
; -------------------------- Verificacion del caso borde (stddev == 0) -------------------------------------------------------------
;IMPORTANTE: stddev es la abreviacion de standard deviation por eso es la desviacion estandar y ya la entrega el driver.c
;desviacion estandar (stddev) = (varianza)^(1/2)

	xorps xmm2, xmm2				;Pone los bits de xmm2 en cero (0) ->	xmm2 = 0.0
	comiss xmm1, xmm2				;Compara los primeros 32 bits de xmm1 y xmm2 y actualiza las flags
	je .na_copiar_directo			;EL salto je verifica la flag y solamente salta si stddev == 0, en otras palabras cuando
									;xmm1 (desviacion estandar que se calcula  desde el driver.c) == xmm2 (xmm2 en este punto es cero)
									; -> xmm1-xmm2 = 0 (stddev debe ser cero, puesto que sino la formula queda una division por cero,
									;una indeterminacion -> (arreglo[i] - media)/ desviacion estandar (stddev)
	xor eax, eax					;Pone los bits del registro eax en cero (0) bits (eax -> indice, por eso i = 0)

;--------------------------- Blucle Principal de la Normalizacion -------------------------------------------------------------------
.na_bucle_normalizacion:			;label
	cmp eax, edx					;edx son los primeros 32 bits del registro rdx y este registro (rdx) contiene el tamano del arreglo (n)
									;cmp resta internamente eax - edx (indice [i] - tamano del arreglo [n]) y actualiza las flags
	jge .na_fin						;El salto jge verifica las flags y realiza el salto si i >= n (eax >= edx). Esto se hace cuando ya se evaluo todo el
									;arreglo. Se sale del while
	movss xmm3, [rdi + rax*4]		;El registro rdi contiene el puntero al inicio del arreglo de datos, despues rax es el registro completo de eax que
									;contiene el indice (i) y el mismo se debe multiplicar por 4 porque cada dato float ocupa los 4 bytes en memoria,
									;para ir desplazandose por los diferentes datos del arreglo de datos.
									;Finalmente se guarda el dato que esta en  indice i en el arreglo,  en el registro xmm3 -> xmm3 = [rdi + rax x 4]
	subss xmm3, xmm0				;Se efectua la operacion xmm3 = arreglo[i](xmm3) - media(xmm0) -> xmm3 = xmm3 - xmm0
	divss xmm3, xmm1				;Se efectua la operacion xmm3 = (arreglo[i] - media)(xmm3) / desviacion estandar (xmm1)
	movss [rsi + rax*4], xmm3		;El registro rsi contiene el puntero al arreglo de salida
									;[rsi + rax x 4] -> calcula la direccion de memoria del arreglo de salida (out[i]) usando el mismo indice
									;Ya se calcula el resultado normaliza out[i] = (arreglo[i] - media)/desviacion estandar
	inc eax							;Incremente el indice -> eax = eax + 1 (indice)
	jmp .na_bucle_normalizacion		;Se vuelve a ejecutar el bucle o while de normalizacion (Siempre salta)

;-------------------------- Caso Especial - STDDEV == 0 -------------------------------------------------------------------------------------
.na_copiar_directo:		;label
	xor eax, eax		;Pone al indice en cero (0) bits -> i = 0 (reinicia el indice)

.na_bucle_copia:				;label
	cmp eax, edx				;Compara el indice (eax) contra el tamano del arreglo (n) y actualiza las flags
	jge .na_fin					;El salto jge solo se hace cuando i(eax) >= n(edx), En este punto termino de evaluar todo el arreglo
	movss xmm3, [rdi + rax*4]	;En este linea sea hace lo mismo que se hizo en el bucle de normalizacion
								;xmm3 = arreglo_in[i] ([rdi + rax x 4])
	movss [rsi + rax*4], xmm3	;Escribe en el arreglo de out lo mismo que el arreglo de in
								;arreglo_out[i] = arreglo_in[i] -> INDICACION DEL ENUNCIADOO para el caso bor stddev == 0
	inc eax						;Incremente el indice (i) -> eax = eax + 1
	jmp .na_bucle_copia			;Vuelve a ejecutar el while

.na_fin:	;label
    ret		;instruccion de retorno al driver.c
