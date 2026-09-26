#!/usr/bin/env bash
# =============================================================
# run_test_cases.sh
#
# Genera los 6 casos de prueba obligatorios de la seccion 2.3 del
# enunciado, corre ambas versiones (escalar y vectorial), calcula
# la referencia en Python puro (reutilizando tools/verify_reference.py
# como modulo) y arma una tabla resumen con los valores numericos
# necesarios para la Tabla de casos de prueba del informe
# (columnas: Caso, Entrada, Referencia, Salida escalar,
# Salida vectorial, Pasa).
#
# Uso (desde la raiz del repo, donde esta el Makefile):
#   chmod +x run_test_cases.sh
#   ./run_test_cases.sh
#
# Requiere: make, nasm, gcc, python3, y que el proyecto ya compile.
# gen_input.py no trae un modo "solo negativos"; ese caso se genera
# aparte con un one-liner de Python que respeta el mismo formato
# binario (int32 n + n floats, little endian).
# =============================================================
set -u

DATA_DIR="data"
RESULTS_FILE="test_results.tsv"
TOOLS_DIR="tools"

# ---- 1. Compilar ---------------------------------------------------
echo "== Compilando (make) =="
make clean >/dev/null 2>&1
if ! make; then
    echo "ERROR: 'make' fallo. Revise la compilacion antes de continuar."
    exit 1
fi

mkdir -p "$DATA_DIR"
: > "$RESULTS_FILE"

# ---- 2. Generar los 6 casos obligatorios de la seccion 2.3 ---------
echo "== Generando datos de prueba =="

python3 "$TOOLS_DIR/gen_input.py" 0    "$DATA_DIR/input_N0.dat"        random   42 >/dev/null
python3 "$TOOLS_DIR/gen_input.py" 1    "$DATA_DIR/input_N1.dat"        random   42 >/dev/null
python3 "$TOOLS_DIR/gen_input.py" 15   "$DATA_DIR/input_remanente.dat" random   42 >/dev/null
python3 "$TOOLS_DIR/gen_input.py" 1000 "$DATA_DIR/input_constante.dat" constant 42 >/dev/null
python3 "$TOOLS_DIR/gen_input.py" 100  "$DATA_DIR/input_extremos.dat"  edge     42 >/dev/null

python3 - "$DATA_DIR/input_negativos.dat" <<'EOF'
import struct, random, sys
random.seed(42)
n = 64
values = [random.uniform(-500.0, -0.001) for _ in range(n)]
with open(sys.argv[1], "wb") as f:
    f.write(struct.pack("<i", n))
    f.write(struct.pack(f"<{n}f", *values))
EOF

# ---- 3. Definicion de los 6 casos (nombre | etiqueta LaTeX | archivo) ----
# El orden coincide con las filas de la tabla del informe.
CASES=(
    "N0|N = 0|input_N0.dat"
    "N1|N = 1|input_N1.dat"
    "remanente|N no multiplo de 8 (remanente, N=15)|input_remanente.dat"
    "constante|Todos los valores iguales (sigma=0, N=1000)|input_constante.dat"
    "negativos|Valores negativos (N=64)|input_negativos.dat"
    "extremos|Valores extremos (N=100)|input_extremos.dat"
)

# ---- 4. Helper: calcula la referencia en Python puro reutilizando ----
#         las mismas funciones que usa verify_reference.py, para no
#         duplicar la logica de calculo.
calc_reference() {
    local input_file="$1"
    python3 - "$input_file" "$TOOLS_DIR" <<'EOF'
import sys
sys.path.insert(0, sys.argv[2])
from verify_reference import read_input, reference_stats

n, values = read_input(sys.argv[1])
total, mean, var, stddev, vmin, vmax = reference_stats(values)
print(f"{n}\t{total:.6g}\t{mean:.6g}\t{var:.6g}\t{stddev:.6g}\t{vmin:.6g}\t{vmax:.6g}")
EOF
}

# ---- 5. Correr cada caso, verificar y armar la tabla ------------------
echo "== Ejecutando, verificando y calculando referencia =="
echo

{
printf "%-18s | %-6s | %-52s | %-52s | %-6s\n" \
    "CASO" "N" "REFERENCIA (sum/mean/var/std/min/max)" "ESCALAR (mean/var/min/max)" "VECT. (mean/var/min/max)"
} 

for case_def in "${CASES[@]}"; do
    IFS='|' read -r name label input_name <<< "$case_def"
    input_file="$DATA_DIR/$input_name"
    out_scalar="$DATA_DIR/output_${name}_scalar.dat"
    out_vector="$DATA_DIR/output_${name}_vector.dat"

    # 5a. Ejecutar ambas versiones (1 repeticion; el timing no importa aqui)
    ./bin/norm_scalar "$input_file" "$out_scalar" 1 >/dev/null 2>&1
    rc_scalar=$?
    ./bin/norm_vector "$input_file" "$out_vector" 1 >/dev/null 2>&1
    rc_vector=$?

    if [ $rc_scalar -ne 0 ] || [ $rc_vector -ne 0 ]; then
        echo "$name | (n/a) | CRASH escalar=$rc_scalar vectorial=$rc_vector | -- | --" | tee -a "$RESULTS_FILE"
        continue
    fi

    # 5b. Referencia en Python puro
    ref_line=$(calc_reference "$input_file")
    IFS=$'\t' read -r ref_n ref_sum ref_mean ref_var ref_std ref_min ref_max <<< "$ref_line"

    # 5c. Leer los .stats.txt que escribe el driver
    read_stat() { grep "^$1=" "$2" | cut -d= -f2; }

    mean_s=$(read_stat mean "${out_scalar}.stats.txt")
    var_s=$(read_stat var   "${out_scalar}.stats.txt")
    min_s=$(read_stat min   "${out_scalar}.stats.txt")
    max_s=$(read_stat max   "${out_scalar}.stats.txt")

    mean_v=$(read_stat mean "${out_vector}.stats.txt")
    var_v=$(read_stat var   "${out_vector}.stats.txt")
    min_v=$(read_stat min   "${out_vector}.stats.txt")
    max_v=$(read_stat max   "${out_vector}.stats.txt")

    # 5d. Verificacion formal contra la referencia (tolerancia 1e-4 por defecto)
    verif_scalar="FALLA"; verif_vector="FALLA"
    python3 "$TOOLS_DIR/verify_reference.py" "$input_file" "${out_scalar}.stats.txt" \
        >/tmp/verif_${name}_scalar.log 2>&1 && verif_scalar="PASA"
    python3 "$TOOLS_DIR/verify_reference.py" "$input_file" "${out_vector}.stats.txt" \
        >/tmp/verif_${name}_vector.log 2>&1 && verif_vector="PASA"

    if [ "$verif_scalar" = "PASA" ] && [ "$verif_vector" = "PASA" ]; then
        pasa="Si"
    else
        pasa="NO (esc=$verif_scalar, vec=$verif_vector)"
    fi

    ref_fmt="mu=$ref_mean var=$ref_var min=$ref_min max=$ref_max"
    esc_fmt="mu=$mean_s var=$var_s min=$min_s max=$max_s"
    vec_fmt="mu=$mean_v var=$var_v min=$min_v max=$max_v"

    printf "%-18s | %-6s | %-52s | %-52s | %-6s\n" \
        "$label" "$ref_n" "$ref_fmt" "$esc_fmt" "$vec_fmt" | tee -a "$RESULTS_FILE"
    echo "   -> Pasa: $pasa" | tee -a "$RESULTS_FILE"
    echo
done

echo ""
echo "Resultados guardados en: $RESULTS_FILE"
echo "Logs detallados de verify_reference.py en: /tmp/verif_<caso>_{scalar,vector}.log"
echo ""
echo "Si algun caso marca FALLA, revise el log correspondiente para el detalle campo por campo:"
echo "  cat /tmp/verif_<caso>_scalar.log"