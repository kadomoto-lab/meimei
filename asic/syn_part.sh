#!/bin/sh
# technology mapping of one part of coarse.il (word-level synthesis result):
#   core: mm_core only (children are blackboxes) / fe: the frontend / rest: everything else
P=$1
Y=${YOSYS:-$HOME/skywater-pdk/env/conda/envs/skywater-pdk-scripts/bin/yosys}
L=asap7_rvt_tt.lib
case $P in
  core) PRE="hierarchy -top mm_core; blackbox *frontend* *issue_queue* *mm_freelist* *mm_wbpipe* mm_decode *mm_div* *fp_* mm_imem" ; SEL="mm_core" ;;
  fe)   PRE="delete mm_core *issue_queue* *mm_freelist* mm_decode *mm_div* *fp_* *mm_wbpipe*; blackbox mm_imem" ; SEL="*frontend*" ;;
  rest) PRE="delete mm_core *frontend* mm_imem" ; SEL="*" ;;
esac
cat > syn_$P.ys <<EOT
read_rtlil coarse.il
$PRE
synth -run fine:check
dfflibmap -liberty $L
abc -D 500 -liberty $L -script abc_sized.script
opt_clean
hilomap -hicell TIEHIx1_ASAP7_75t_R H -locell TIELOx1_ASAP7_75t_R L
tee -o stat_$P.txt stat -liberty $L
select $SEL
write_verilog -noattr -noexpr -selected net_$P.v
EOT
/usr/bin/time -f "%e s %M KB" $Y -l syn_$P.log syn_$P.ys > /dev/null 2> syn_$P.time
