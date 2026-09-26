#!/usr/bin/env bash
# =============================================================
# run_performance.sh
#
# Genera datos de rendimiento para la seccion "Resultados de
# rendimiento" del informe:
#   (a) tabla de tiempos promedio +/- desv. std. por tamano y version
#       (30 invocaciones independientes por tamano, reps=1 cada una)
#   (b) datos crudos para el grafico de Speedup vs. N (log X)
#   (c) salida de perf stat -e cycles,instructions,cache-misses
#       por version y tamano, para el analisis de IPC/cache-misses
#
# Tamanos exigidos por el enunciado (seccion 2.2): 10^3, 10^5, 10^6,
# 5x10^7.
#
# Uso (desde la raiz del repo, donde esta el Makefile):
#   chmod +x run_performance.sh
#   ./run_performance.sh
#
# Requiere: make, nasm, gcc, python3, y opcionalmente perf
# (paquete linux-tools). Si perf no esta disponible, el script
# omite el paso (c) con un aviso, sin abortar lo demas.
#
# ADVERTENCIA: N=5x10^7 reserva ~200 MB por arreglo (entrada,
# salida, y una copia en la referencia si se corre verify_reference.py
# aparte). Verifique espacio en disco y RAM disponibles.
# =============================================================
set -u

DATA_DIR="data"
REPS_PER_SAMPLE=30      # muestras independientes por tamano/version
SIZES=(1000 100000 1000000 50000000)

RAW_CSV="times_raw.csv"
SUMMARY_CSV="times_summary.csv"

mkdir -p "$DATA_DIR"

# ---- 0. Verificar AVX2 y compilar -----------------------------------
echo "== Verificando soporte AVX2 =="
lscpu | grep -qi avx2 && echo "AVX2 disponible." || echo "ADVERTENCIA: no se detecto AVX2 en lscpu."
echo

echo "== Compilando (make) =="
make clean >/dev/null 2>&1
if ! make; then
    echo "ERROR: 'make' fallo. Revise la compilacion antes de continuar."
    exit 1
fi
echo

HAVE_PERF=1
if ! command -v perf >/dev/null 2>&1; then
    echo "AVISO: 'perf' no esta instalado (paquete linux-tools). Se omite la parte (c)."
    HAVE_PERF=0
fi

# ---- 1. Generar entradas grandes (una sola vez por tamano) ----------
echo "== Generando datos de entrada =="
for n in "${SIZES[@]}"; do
    infile="$DATA_DIR/perf_input_${n}.dat"
    if [ ! -f "$infile" ]; then
        echo "  Generando N=$n ..."
        python3 tools/gen_input.py "$n" "$infile" random 42 >/dev/null
    else
        echo "  N=$n ya existe, se reutiliza."
    fi
done
echo

# ---- 2. Medir tiempos: REPS_PER_SAMPLE invocaciones independientes --
#         (reps=1 en cada invocacion; el promedio/desv.std. se calcula
#         sobre las N invocaciones, no sobre repeticiones internas)
echo "N,version,run,kernel_ms" > "$RAW_CSV"

for n in "${SIZES[@]}"; do
    infile="$DATA_DIR/perf_input_${n}.dat"

    for version in scalar vector; do
        bin="./bin/norm_${version}"
        outfile="$DATA_DIR/perf_output_${version}_${n}.dat"

        echo "== Midiendo N=$n version=$version ($REPS_PER_SAMPLE corridas independientes) =="
        for run in $(seq 1 "$REPS_PER_SAMPLE"); do
            "$bin" "$infile" "$outfile" 1 >/dev/null 2>&1
            kernel_ms=$(grep '^kernel_ms=' "${outfile}.stats.txt" | cut -d= -f2)
            echo "${n},${version},${run},${kernel_ms}" >> "$RAW_CSV"
        done
    done
done
echo

# ---- 3. Calcular promedio y desviacion estandar por tamano/version --
echo "== Calculando promedio y desviacion estandar =="
python3 - "$RAW_CSV" "$SUMMARY_CSV" <<'EOF'
import csv, sys, statistics
from collections import defaultdict

raw_path, summary_path = sys.argv[1], sys.argv[2]
groups = defaultdict(list)

with open(raw_path) as f:
    reader = csv.DictReader(f)
    for row in reader:
        key = (int(row["N"]), row["version"])
        groups[key].append(float(row["kernel_ms"]))

rows = []
for (n, version), values in sorted(groups.items()):
    mean = statistics.mean(values)
    std = statistics.stdev(values) if len(values) > 1 else 0.0
    rows.append((n, version, mean, std))

with open(summary_path, "w", newline="") as f:
    writer = csv.writer(f)
    writer.writerow(["N", "version", "mean_ms", "std_ms"])
    writer.writerows(rows)

# Tabla resumida en pantalla, ya con el speedup calculado
by_n = defaultdict(dict)
for n, version, mean, std in rows:
    by_n[n][version] = (mean, std)

print(f"{'N':>10} | {'escalar (ms)':>14} | {'std':>10} | {'vectorial (ms)':>15} | {'std':>10} | {'speedup':>8}")
print("-" * 80)
for n in sorted(by_n):
    mean_s, std_s = by_n[n].get("scalar", (float('nan'), float('nan')))
    mean_v, std_v = by_n[n].get("vector", (float('nan'), float('nan')))
    speedup = mean_s / mean_v if mean_v else float('nan')
    print(f"{n:>10} | {mean_s:>14.6f} | {std_s:>10.6f} | {mean_v:>15.6f} | {std_v:>10.6f} | {speedup:>8.4f}")
EOF
echo
echo "Tiempos crudos guardados en: $RAW_CSV"
echo "Resumen (para la tabla y el grafico de speedup) en: $SUMMARY_CSV"
echo

# ---- 4. perf stat por version y tamano -------------------------------
if [ "$HAVE_PERF" -eq 1 ]; then
    echo "== Ejecutando perf stat (cycles,instructions,cache-misses) =="
    mkdir -p perf_logs
    for n in "${SIZES[@]}"; do
        infile="$DATA_DIR/perf_input_${n}.dat"
        for version in scalar vector; do
            bin="./bin/norm_${version}"
            outfile="$DATA_DIR/perf_output_${version}_${n}.dat"
            logfile="perf_logs/perf_${version}_${n}.txt"

            echo "  perf stat: N=$n version=$version"
            # reps=30 para darle a perf suficiente trabajo del kernel
            # y diluir el overhead fijo de arranque del proceso
            sudo perf stat -e cycles,instructions,cache-misses \
                "$bin" "$infile" "$outfile" 30 \
                > "$logfile" 2>&1
        done
    done
    echo
    echo "Logs de perf guardados en: perf_logs/perf_<version>_<N>.txt"
else
    echo "Paso (c) omitido: perf no disponible."
fi

echo
echo "Listo. Para completar:"
echo "  (a) tabla de tiempos -> $SUMMARY_CSV"
echo "  (b) grafico de speedup -> columna 'speedup' de $SUMMARY_CSV (graficar N en log-X)"
echo "  (c) analisis IPC/cache-misses -> perf_logs/perf_<version>_<N>.txt"