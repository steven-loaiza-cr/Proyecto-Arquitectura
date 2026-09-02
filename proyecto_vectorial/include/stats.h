#ifndef STATS_H
#define STATS_H

#ifdef __cplusplus
extern "C" {
#endif

/*
 *Objetivo: como viene en lo que adjuntó el profesor en los comentarios es un archivo de cabecera de C, el cual declara las firmas de las tres
 *funciones que se van a escribir en ensamblador
 *
 *float sum_array (const float *arr, int n);
 *void compute_stats (const float *arr, int n, float *mean, float *var, float *min, float *max);
 *void normalize_array (const float *in, float *out, int n, float mean, float stddev);
 *
 *En otras palabras stats.h une la programacion en C (driver.c) y los de emsambladores (.asm). Asimismo el compilador de C lee este .h (stats.h) para
 *saber como llamar a funciones las cuales no estan programadas en C

 Por otra parte,la definicion exacta de que debe hacer cada funcion (puesto que indica que registro reibe cada argumento, como se calcula la varianza,
 que se debe hacer si n == 0 o stddev == 0). NOTA: TENER CUIDADO PORQUE SI EL ENSAMBLADOR NO CUMPLE EXACTAMENTE LO QUE DICE AQUI, EL DRIVER.C VA A LLAMAR
 MAL A LAS FUNCIONES GENERADAS .ASM Y SE PUEDE INTERPRETAR MAL EL RESULTADO
 */

/*
 * Firmas de los kernels de computo. Estas MISMAS firmas deben estar
 * implementadas tanto en asm/scalar/stats_scalar.asm como en
 * asm/vector/stats_vector.asm, respetando la convencion de llamada
 * System V AMD64 ABI:
 *
 *   Enteros/punteros (en orden): rdi, rsi, rdx, rcx, r8, r9
 *   Flotantes (en orden, aparte): xmm0, xmm1, xmm2, ...
 *   Valor de retorno float: xmm0
 *
 *  F: En general, asigna registros por tipo de argumento, no por posición absoluta.
 *
 * sum_array:
 *   rdi = arr, esi = n              -> retorna la suma en xmm0

	rdi = arr: Recibe en el registro de 64 bits (rdi) el puntero o dirreccion base del arreglo de entrada
	esi = n: Recibe en el registro de 32 bits (esi) el numero de elementos (n) que contiene el arreglo
	Esta funcion debe retornar la suma en el registro xmm0, puesto que devuelve el resultado flotante acumulado en el
	registro de punto flotante/SIMD llamado xmm0

 *
 * compute_stats:
 *   rdi = arr, esi = n, rdx = mean*, rcx = var*, r8 = min*, r9 = max*
 *   (var = varianza POBLACIONAL: var = sum((x - mean)^2) / n)
 *   Caso borde: si n == 0, escriba 0.0 en mean/var/min/max.

	rdi = arr: Recibe en el registro de 64 bits (rdi) el puntero o dirreccion base del arreglo de entrada
	esi = n: Recibe en el registro de 32 bits (esi) el numero de elementos (n) que contiene el arreglo

	rdi = arr, esi = n, rdx = mean*, rcx = var*, r8 = min*, r9 = max
	Punteros de memoria donde la subrutina debe escribir (por referencia) los resultados calculados: la media, la varianza
	poblacional, el valor minimo y el valor maximo.

	Asimismo, se analiza el caso borde: si n == 0, se debe escribir 0,0 en cada una de esas direcciones de memoria para
	evitar fallos
 *
 * normalize_array:
 *   rdi = in, rsi = out, edx = n, xmm0 = mean, xmm1 = stddev
 *   out[i] = (in[i] - mean) / stddev
 *   Caso borde: si stddev == 0.0, copie in[i] en out[i] tal cual
 *   (evite division por cero).

	rdi = in: Puntero al arreglo de entrada original
	rsi = out:  Puntero al arreglo de salida donde se guardaran los datos normalizados.
	edx =  n: Es el tamano del arreglo
	xmm0 = mean: Valor de la media ya calculado que se pasa como un argumento de entrada en un valor tipo punto flotante.
	xmm1 = stddev: Es el valor de la desviacion estandar de entrada

	Formula: se aplica la normalizacion estadistica estandar la cual se calcula con
	out [i] = ( in [i] - mean ) / stddev

	Finalmente se debe analizar el caso borde que es cuando stddev == 0.0, esta copia directamente in [i] en out [i] para prevenir 
	una interrupcion por division entre cero.

 */

float sum_array(const float *arr, int n);

void compute_stats(const float *arr, int n,
                    float *mean, float *var, float *min, float *max);

void normalize_array(const float *in, float *out, int n,
                      float mean, float stddev);

#ifdef __cplusplus
}
#endif

#endif /* STATS_H */
