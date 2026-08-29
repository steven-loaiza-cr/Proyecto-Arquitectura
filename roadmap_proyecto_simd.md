# Roadmap del Proyecto: Normalizador Estadístico Vectorizado (NASM/AVX2)

**Duración:** 6 semanas
**Entrega:** 1 de octubre
**Formato:** Trabajo en parejas
**Base de partida:** esqueleto de proyecto entregado por el profesor (no se parte de cero)

---

## Qué ya viene resuelto en el esqueleto (leer antes de tocar código)

El esqueleto ya trae, funcionando y sin necesidad de modificarlo:

- `src/driver.c`: lectura de `input.dat`, reserva de memoria alineada a 32 bytes (`aligned_alloc`), medición con `clock_gettime(CLOCK_MONOTONIC, ...)` con repeticiones configurables (3er argumento), impresión por consola y escritura de `output.dat` + `output.dat.stats.txt`.
- `include/stats.h`: firmas exactas y contrato de cada función (qué registros/punteros usa, qué hacer en N=0 y σ=0). Es la especificación que el ASM debe cumplir al pie de la letra.
- `Makefile`: compila y enlaza `driver.c` con `stats_scalar.asm` o `stats_vector.asm`, genera `bin/norm_scalar` y `bin/norm_vector`. Ya incluye flags de debug (`-g`, `-F dwarf`) para trabajar con GDB.
- `tools/gen_input.py`: genera `input.dat` en los tres modos `random`, `constant`, `edge`. Cubre todos los tamaños pedidos en el enunciado.
- `tools/verify_reference.py`: calcula la referencia en Python puro y compara contra `output.dat.stats.txt` con tolerancia 1×10⁻⁴, imprimiendo PASA/FALLA por campo.
- `sum_array` en **ambas** versiones (`stats_scalar.asm` y `stats_vector.asm`): implementación completa, sirve como patrón obligatorio a replicar. La versión vectorial ya muestra el patrón completo de bucle de 8 en 8, reducción horizontal (`vextractf128` + `vaddps` + `vhaddps` doble) y bucle de cierre escalar para el remanente.

**Lo único que falta implementar es código NASM:** `compute_stats` y `normalize_array`, en la versión escalar y en la vectorial (4 funciones en total). Todo lo demás (E/S, timing, generación de datos, verificación, build) ya está resuelto.

Esto cambia el roadmap respecto a un proyecto desde cero: no hay semana dedicada a escribir el driver, el Makefile o los scripts. El tiempo se concentra en (a) entender a fondo el contrato de la ABI y el patrón de `sum_array`, (b) implementar las 4 funciones faltantes, y (c) todo lo posterior a la corrección (GDB, benchmarking, informe, defensa), que sigue igual de exigente.

**Importante para la defensa (criterio de veto, 3.c):** aunque el driver, el Makefile y los scripts de Python no los escribieron ustedes, el profesor puede preguntar sobre cualquier parte del proyecto (por ejemplo, por qué la memoria se alinea a 32 bytes en el driver, o por qué `verify_reference.py` usa error relativo y no absoluto). Léanlos con el mismo cuidado que el código propio.

---

## Semana 1 — Apropiación del esqueleto y diseño

### Objetivos
- Entender completamente el esqueleto entregado (sin modificarlo aún) y dejar la arquitectura documentada antes de escribir una sola línea de ASM nueva.

### Tareas
- [ ] Confirmar soporte de AVX2 con `lscpu | grep avx2` y `cat /proc/cpuinfo | grep flags`. Si no hay soporte, decidir de inmediato el fallback a SSE2 y documentarlo.
- [ ] Verificar versiones instaladas: NASM ≥ 2.15, GCC, GDB ≥ 10, `perf` (paquete `linux-tools`).
- [ ] Leer `include/stats.h` línea por línea: confirmar qué registro de la ABI System V corresponde a cada parámetro de las 3 funciones, y qué se espera en los casos borde N=0 y σ=0.
- [ ] Leer `src/driver.c` completo: entender el flujo de lectura/escritura, cómo se reserva memoria alineada, qué mide exactamente `clock_gettime` (solo el kernel, no la E/S) y qué contiene `output.dat.stats.txt`.
- [ ] Leer y ejecutar `make` para confirmar que el esqueleto compila tal cual viene (con `compute_stats`/`normalize_array` como placeholders).
- [ ] Estudiar en detalle `sum_array` en `stats_scalar.asm` (patrón de acumulador + condición de salida) y en `stats_vector.asm` (cálculo de `ecx = n & ~7`, bucle de 8, reducción horizontal con `vextractf128`/`vhaddps`, bucle de cierre escalar). Este es el patrón que se reutiliza en las 4 funciones pendientes.
- [ ] Generar los archivos de prueba con `tools/gen_input.py` para todos los tamaños del enunciado (0, 1, 7, 8, 15, 16, 1000, 10³, 10⁵, 10⁶, 5×10⁷), incluyendo modos `random`, `constant` (σ=0) y `edge` (negativos/extremos).
- [ ] Correr `tools/verify_reference.py` contra el `output.dat.stats.txt` que genera el esqueleto placeholder, solo para confirmar que el pipeline de verificación funciona end-to-end (va a marcar FALLA en todo, eso es esperado).
- [ ] Diseñar el diagrama de bloques de la arquitectura de software (driver C, `libstats_scalar.asm`, `libstats_vector.asm`) y cómo se comunican vía la ABI.
- [ ] Diseñar el diagrama de flujo de control de ambos bucles (escalar vs. vectorial + remanente), basándose en el flujo real de `sum_array`.
- [ ] Diseñar la tabla de asignación de registros del kernel crítico (qué contiene `ymm0`, `ymm1`, `rdi`, `rsi`, `rcx`, etc. en cada etapa), anticipando los registros que usarán en `compute_stats` y `normalize_array`.
- [ ] Diseñar el diagrama de memoria: disposición de arreglos, alineación de dirección base (múltiplo de 32 bytes, ya la garantiza el driver), avance del puntero por iteración (4 bytes escalar vs. 32 bytes vectorial).

### Entregable de la semana
Esqueleto compilado y comprendido por ambos integrantes, datos de prueba generados, diagrama preliminar completo (arquitectura, flujo de control, registros, memoria).

---

## Semana 2 — Implementación escalar (`compute_stats` + `normalize_array`)

### Objetivos
- Completar los dos TODO de `asm/scalar/stats_scalar.asm`, verificados y correctos, antes de tocar AVX2.

### Tareas
- [ ] Implementar `compute_stats` escalar:
  - Guardar `arr`/`n`/`mean*`/`var*`/`min*`/`max*` en registros callee-saved (`rbx`, `r12`-`r15`) antes de llamar a `sum_array` (destruye caller-saved).
  - `mean = sum_array(arr, n) / n`.
  - Segunda pasada para acumular `sum((x - mean)^2)` con `subss/mulss/addss`, y dividir por `n` para obtener `var`.
  - Min/max con `comiss` + saltos condicionales o `minss/maxss`.
  - Caso borde N=0: escribir 0.0 en las cuatro salidas, sin dividir.
  - Restaurar registros callee-saved en el epílogo.
- [ ] Implementar `normalize_array` escalar:
  - Bucle elemento a elemento: `out[i] = (in[i] - mean) / stddev`.
  - Caso borde σ=0: copiar `in[i]` a `out[i]` sin dividir.
  - Cuidado con `xmm0`/`xmm1` (mean/stddev de entrada): guardarlos en registros que no se pisen dentro del bucle (o recargarlos desde la pila en cada iteración).
- [ ] Verificar correctud con `tools/verify_reference.py` para los tamaños pequeños: 0, 1, 7, 8, 15, 16, 1000 (modos random, constant y edge).
- [ ] Confirmar explícitamente los casos borde: N=0 (sin división por cero), σ=0 (sin división por cero), valores negativos y extremos.
- [ ] Primera sesión exploratoria de GDB sobre la versión escalar (`break compute_stats`, `stepi`, `info registers`) para validar la lógica de bajo nivel antes de vectorizar.

### Punto de control (bloqueante)
No avanzar a la Semana 3 sin que la versión escalar pase **todos** los casos borde de la sección 2.3 vía `verify_reference.py`.

### Entregable de la semana
`stats_scalar.asm` completo (las 3 funciones) y verificado; 10/10 pts de funcionalidad escalar según rúbrica 3.

---

## Semana 3 — Implementación vectorial (`compute_stats` + `normalize_array`, AVX2)

### Objetivos
- Completar los dos TODO de `asm/vector/stats_vector.asm`, funcionalmente equivalentes a la versión escalar, reutilizando el patrón de `sum_array` vectorial.

### Tareas
- [ ] Implementar `compute_stats` vectorial:
  - `mean` reutilizando `sum_array` (mismo cuidado con callee-saved que en la versión escalar).
  - Segunda pasada vectorizada: `vbroadcastss` de `mean` a los 8 carriles, `vsubps` + `vmulps` (o `vfmadd231ps`) para acumular `(x-mean)^2`, misma reducción horizontal que `sum_array`, bucle escalar de cierre para el remanente.
  - Min/max vectorizados con `vminps`/`vmaxps` a lo largo del bucle principal, reducción final (`vextractf128` + `vminps`/`vmaxps`, shuffles si se quiere reducir a un solo escalar), más bucle escalar de cierre con `minss`/`maxss`.
  - Caso borde N=0: escribir 0.0 en las cuatro salidas.
  - `vzeroupper` antes de cualquier `ret`.
- [ ] Implementar `normalize_array` vectorial:
  - `vbroadcastss` de `mean` y `stddev` a registros YMM (guardarlos antes en otros registros o en la pila, ya que `xmm0`/`xmm1` se van a reutilizar como temporales del bucle).
  - Bucle de 8 en 8: `vmovups`/`vmovaps` (carga), `vsubps`, `vdivps` (o `vmulps` por el recíproco si se quiere optimizar), `vmovups`/`vmovaps` (guarda).
  - Caso borde σ=0: copiar `in[i]` a `out[i]` sin dividir.
  - Bucle escalar de cierre para el remanente, igual que en `sum_array`.
  - `vzeroupper` antes del `ret`.
- [ ] Decidir y justificar por escrito la técnica de reducción horizontal usada (ya está fijada por el patrón de `sum_array`: `vextractf128` + `vaddps` + doble `vhaddps`; documentar por qué esa y no otra).
- [ ] Verificar alineación a 32 bytes en el camino principal (el driver ya la garantiza; usar `vmovaps` donde corresponda en vez de `vmovups` para aprovecharla).
- [ ] Verificar correctud con `tools/verify_reference.py` (tolerancia relativa 1×10⁻⁴) para los mismos tamaños de la Semana 2, incluyendo específicamente N no múltiplo de 8, arreglo constante (σ=0), valores negativos y extremos.

### Punto de control (bloqueante)
No avanzar a la Semana 4 sin que la versión vectorial pase la comparación de tolerancia contra la referencia para todos los casos borde.

### Entregable de la semana
`stats_vector.asm` completo (las 3 funciones) y verificado; 15/15 pts de funcionalidad vectorial según rúbrica.

---

## Semana 4 — Verificación GDB y benchmarking

### Objetivos
- Generar toda la evidencia de depuración y todos los datos crudos de rendimiento, usando la infraestructura de timing que ya trae el driver.

### Tareas
- [ ] Sesión formal de GDB con N = 16 (`data/input_small.dat` o generado con `gen_input.py 16`):
  - `gdb --args ./bin/norm_vector data/input16.dat data/out.dat 1`, `break normalize_array` (o el punto del bucle vectorial que corresponda), `run`.
  - Inspeccionar `ymm0` inmediatamente después de una instrucción `vaddps` (`info registers ymm0` o `print $ymm0.v8_float`, según la versión de GDB disponible).
  - Inspeccionar memoria del arreglo de salida en un breakpoint posterior al bucle de normalización (`x/8fw &out[0]`).
  - Documentar con transcripción o capturas de pantalla (va directo al informe, sección 2.4.a).
- [ ] Comparación cualitativa de iteraciones/instrucciones ejecutadas por cada versión usando `stepi`/`nexti` (contar cuántos pasos da el bucle escalar vs. el vectorial para el mismo N).
- [ ] Usar el argumento de repeticiones del driver (`./bin/norm_scalar input.dat output.dat 30`) para obtener al menos 30 mediciones por tamaño de N; el driver ya promedia y mide solo el kernel.
- [ ] Calcular manualmente (o con un script auxiliar) la desviación estándar de esas mediciones por tamaño y versión (el driver solo imprime el promedio).
- [ ] Ejecutar el benchmark completo para los 4 tamaños grandes: 10³, 10⁵, 10⁶, 5×10⁷.
- [ ] Ejecutar `perf stat -e cycles,instructions,cache-misses ./bin/norm_scalar ...` y lo mismo para `norm_vector`, para reportar IPC y fallos de caché.

### Entregable de la semana
Datos crudos de tiempos (30+ muestras por tamaño/versión), salida de `perf stat`, evidencia GDB documentada.

---

## Semana 5 — Análisis de resultados y diagrama final

### Objetivos
- Convertir los datos crudos en resultados interpretados y cerrar el diagrama de arquitectura.

### Tareas
- [ ] Calcular Speedup = tiempo_escalar / tiempo_vectorial por tamaño de N.
- [ ] Graficar N (eje X, escala logarítmica) vs. Speedup (eje Y).
- [ ] Interpretar IPC y tasa de fallos de caché de `perf stat`: determinar si el cuello de botella es de cómputo o de ancho de banda de memoria.
- [ ] Explicar por qué el speedup real no alcanza el 8x teórico de AVX2 (relacionar con Ley de Amdahl, latencia de instrucciones, overhead de la reducción horizontal).
- [ ] Finalizar el diagrama de arquitectura completo (bloques, flujo de control, tabla de registros, mapa de memoria) como archivo independiente (draw.io, Lucidchart, PlantUML, etc.), ajustándolo a la implementación real (no solo al diseño preliminar de la Semana 1).
- [ ] Completar la tabla de casos de prueba: entrada, salida esperada (referencia de `verify_reference.py`), salida obtenida por cada versión, resultado (pasa/no pasa) para los 6 casos borde de 2.3.

### Entregable de la semana
Gráfico de speedup vs. N, análisis de IPC/cache-misses redactado, diagrama final en archivo independiente.

---

## Semana 6 — Informe y preparación de defensa

### Objetivos
- Consolidar todo en el informe final y asegurar que ambos integrantes dominen el 100% del proyecto, incluyendo las partes que venían en el esqueleto.

### Tareas
- [ ] Redactar el informe completo según 3.b:
  1. Introducción y objetivos (2 pts)
  2. Entorno de pruebas: CPU, flags AVX2, versiones de NASM/GCC/GDB (2 pts)
  3. Explicación de la implementación escalar con fragmentos comentados (4 pts)
  4. Explicación de la implementación vectorial: elección de AVX2, reducción horizontal, manejo del remanente (5 pts)
  5. Tabla de los 6 casos borde (5 pts)
  6. Resultados de rendimiento: tabla de tiempos ± desviación estándar, gráfico de speedup, resultados de `perf stat` (4 pts)
  7. Evidencia de la sesión GDB (2 pts)
  8. Conclusiones, limitaciones y trabajo futuro (1 pt)
- [ ] Revisión cruzada entre ambos integrantes: cada uno debe poder explicar cualquier línea del código, incluido el que no escribió, **y también las partes del esqueleto que no escribió nadie del equipo** (driver.c, Makefile, scripts de Python).
- [ ] Ensayar la entrevista de defensa cubriendo, como mínimo:
  - Diferencia entre `movaps` y `movups`, cuándo usar cada una.
  - Justificación de la técnica de reducción horizontal elegida frente a las alternativas.
  - Demostración en vivo con GDB del contenido de un registro YMM en una iteración específica.
  - Qué instrucciones procesan exactamente los elementos sobrantes cuando N no es múltiplo de 8.
  - Por qué el speedup medido no llega a 8x (ancho de banda, latencia, overhead de reducción, Ley de Amdahl).
  - Convención de llamada C/NASM: registros de argumentos y registros que debe preservar el callee.
  - Por qué el driver reserva memoria con `aligned_alloc` a 32 bytes y qué pasaría si no lo hiciera.
  - Por qué `verify_reference.py` usa tolerancia relativa y no absoluta.
- [ ] Verificar que el repositorio compile limpio con el Makefile entregado (`make clean && make`).
- [ ] Confirmar que todos los entregables estén presentes: código NASM, driver C, Makefile, script de generación de datos, script de verificación de referencia, archivo del diagrama, informe en PDF.

### Entregable final
Repositorio completo y compilable, informe en PDF, diagrama independiente, ambos integrantes preparados para la entrevista.

---

## Puntos de control críticos (resumen)

| Punto de control | Condición | Consecuencia si se ignora |
|---|---|---|
| Fin de Semana 2 | Versión escalar (`compute_stats` + `normalize_array`) pasa todos los casos borde vía `verify_reference.py` | Retrasa toda la cadena; no avanzar a AVX2 con base incorrecta |
| Fin de Semana 3 | Versión vectorial pasa tolerancia 1×10⁻⁴ contra referencia | Datos de rendimiento y GDB de semana 4 quedarían inválidos |
| Continuo | Ambos integrantes entienden y pueden explicar todo el código, incluyendo el esqueleto no escrito por ellos (driver, Makefile, scripts) | Criterio de veto en la entrevista: nota total = 0, sin importar el resto de la rúbrica |

## Recomendación de división del trabajo

No dividir el proyecto por kernel (uno hace escalar, otro vectorial) sin una revisión cruzada posterior obligatoria. El criterio de veto de la entrevista (sección 3.c del enunciado) anula la nota completa si un integrante no puede defender decisiones de código que no escribió, y esto aplica también al código del esqueleto que ninguno de los dos escribió pero que ambos deben poder explicar. Se recomienda que ambos integrantes trabajen juntos en el diseño (Semana 1) y en la reducción horizontal (Semana 3), y que se turnen la explicación de cada función durante la revisión cruzada de la Semana 6.
